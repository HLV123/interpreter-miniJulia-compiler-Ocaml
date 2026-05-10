(* MiniJulia Parser — recursive descent *)
open Ast
open Lexer

(* ── state ── *)
type state = {
  toks : token array;
  mutable pos : int;
}

let make src =
  let toks = Array.of_list (Lexer.tokenize src) in
  { toks; pos = 0 }

let cur s  = if s.pos < Array.length s.toks then s.toks.(s.pos) else TEOF
let peek s = if s.pos + 1 < Array.length s.toks then s.toks.(s.pos + 1) else TEOF
let adv s  = let t = cur s in s.pos <- s.pos + 1; t
let rec eat s t =
  let got = adv s in
  if got <> t then
    failwith (Printf.sprintf "Parser: expected %s got %s"
      (show_tok t) (show_tok got))

and show_tok = function
  | TEq -> "=" | TLParen -> "(" | TRParen -> ")" | TEnd -> "end"
  | TComma -> "," | TColon -> ":" | TRBracket -> "]" | TEOF -> "EOF"
  | TNewline -> "newline" | TIn -> "in"
  | TIdent s -> s | _ -> "token"

let skip_nl s =
  while cur s = TNewline || cur s = TSemi do ignore (adv s) done

(* ── expressions ── *)
let rec expr s = expr_or s

and expr_or s =
  let l = ref (expr_and s) in
  while cur s = TOr do
    ignore (adv s); l := BinOp (Or, !l, expr_and s)
  done; !l

and expr_and s =
  let l = ref (expr_not s) in
  while cur s = TAnd do
    ignore (adv s); l := BinOp (And, !l, expr_not s)
  done; !l

and expr_not s =
  if cur s = TNot || cur s = TBang then
    (ignore (adv s); UnOp (Not, expr_not s))
  else expr_cmp s

and expr_cmp s =
  let l = expr_range s in
  match cur s with
  | TEqEq -> ignore (adv s); BinOp (Eq,  l, expr_range s)
  | TNeq  -> ignore (adv s); BinOp (Neq, l, expr_range s)
  | TLt   -> ignore (adv s); BinOp (Lt,  l, expr_range s)
  | TLte  -> ignore (adv s); BinOp (Lte, l, expr_range s)
  | TGt   -> ignore (adv s); BinOp (Gt,  l, expr_range s)
  | TGte  -> ignore (adv s); BinOp (Gte, l, expr_range s)
  | _     -> l

and expr_range s =
  let l = expr_add s in
  if cur s = TColon then begin
    ignore (adv s);
    let mid = expr_add s in
    if cur s = TColon then begin
      ignore (adv s);
      Range3 (l, mid, expr_add s)
    end else
      Range (l, mid)
  end else l

and expr_add s =
  let l = ref (expr_mul s) in
  let go = ref true in
  while !go do
    match cur s with
    | TPlus  -> ignore (adv s); l := BinOp (Add, !l, expr_mul s)
    | TMinus -> ignore (adv s); l := BinOp (Sub, !l, expr_mul s)
    | _      -> go := false
  done; !l

and expr_mul s =
  let l = ref (expr_pow s) in
  let go = ref true in
  while !go do
    match cur s with
    | TStar    -> ignore (adv s); l := BinOp (Mul, !l, expr_pow s)
    | TSlash   -> ignore (adv s); l := BinOp (Div, !l, expr_pow s)
    | TPercent -> ignore (adv s); l := BinOp (Mod, !l, expr_pow s)
    | _        -> go := false
  done; !l

and expr_pow s =
  let b = expr_unary s in
  if cur s = TCaret then (ignore (adv s); BinOp (Power, b, expr_unary s))
  else b

and expr_unary s =
  match cur s with
  | TMinus -> ignore (adv s); UnOp (Neg, expr_unary s)
  | _      -> expr_postfix s

and expr_postfix s =
  let e = ref (expr_atom s) in
  let go = ref true in
  while !go do
    match cur s with
    | TLBracket ->
        ignore (adv s);
        let idx = expr s in
        eat s TRBracket;
        e := Index (!e, idx)
    | TDot ->
        ignore (adv s);
        (match adv s with
         | TIdent _ -> () (* ignore field access for now *)
         | _ -> failwith "expected field name")
    | _ -> go := false
  done; !e

and expr_atom s =
  match cur s with
  | TNum n   -> ignore (adv s); Num n
  | TStr str -> ignore (adv s); Str str
  | TTrue    -> ignore (adv s); Bool true
  | TFalse   -> ignore (adv s); Bool false
  | TNothing -> ignore (adv s); Nil
  | TIdent name ->
      ignore (adv s);
      if cur s = TLParen then begin
        ignore (adv s);
        let args = parse_args s in
        eat s TRParen;
        Call (name, args)
      end else
        Var name
  | TLBracket ->
      ignore (adv s);
      skip_nl s;
      let elems = ref [] in
      while cur s <> TRBracket do
        skip_nl s;
        if cur s <> TRBracket then begin
          elems := expr s :: !elems;
          skip_nl s;
          if cur s = TComma || cur s = TSemi then ignore (adv s)
        end
      done;
      eat s TRBracket;
      Array (List.rev !elems)
  | TLParen ->
      ignore (adv s);
      let e = expr s in
      eat s TRParen;
      e
  | t -> failwith (Printf.sprintf "Unexpected token in expression: %s" (show_tok t))

and parse_args s =
  if cur s = TRParen then []
  else begin
    let first = expr s in
    let rest  = ref [] in
    while cur s = TComma do
      ignore (adv s);
      rest := expr s :: !rest
    done;
    first :: List.rev !rest
  end

(* ── statements ── *)
let rec stmt s =
  skip_nl s;
  match cur s with
  | TIf       -> parse_if s
  | TWhile    -> parse_while s
  | TFor      -> parse_for s
  | TFunction -> parse_funcdef s
  | TReturn   ->
      ignore (adv s);
      if cur s = TNewline || cur s = TSemi || cur s = TEOF || cur s = TEnd then
        Return Nil
      else Return (expr s)
  | TBreak    -> ignore (adv s); Break
  | TContinue -> ignore (adv s); Continue
  | TGlobal   ->
      ignore (adv s);
      (match adv s with
       | TIdent x -> Global x
       | _ -> failwith "expected ident after global")
  | _ ->
      let e = expr s in
      if cur s = TEq then begin
        ignore (adv s);
        let rhs = expr s in
        Assign (e, rhs)
      end else ExprStmt e

and parse_if s =
  ignore (adv s); (* eat 'if' *)
  let cond = expr s in
  skip_nl s;
  let body = stmts_until s [TElseif; TElse; TEnd] in
  let branches = ref [(cond, body)] in
  while cur s = TElseif do
    ignore (adv s);
    let c = expr s in skip_nl s;
    let b = stmts_until s [TElseif; TElse; TEnd] in
    branches := (c, b) :: !branches
  done;
  let else_b =
    if cur s = TElse then begin
      ignore (adv s); skip_nl s;
      Some (stmts_until s [TEnd])
    end else None
  in
  eat s TEnd;
  If (List.rev !branches, else_b)

and parse_while s =
  ignore (adv s);
  let cond = expr s in
  skip_nl s;
  let body = stmts_until s [TEnd] in
  eat s TEnd;
  While (cond, body)

and parse_for s =
  ignore (adv s);
  let var = match adv s with TIdent x -> x | _ -> failwith "expected var in for" in
  (match cur s with TIn | TEq -> ignore (adv s) | _ -> failwith "expected 'in' or '='");
  let range = expr s in
  skip_nl s;
  let body = stmts_until s [TEnd] in
  eat s TEnd;
  For (var, range, body)

and parse_funcdef s =
  ignore (adv s);
  let name = match adv s with TIdent x -> x | _ -> failwith "expected function name" in
  eat s TLParen;
  let params =
    if cur s = TRParen then []
    else begin
      let first = match adv s with TIdent x -> x | _ -> failwith "param name" in
      let rest = ref [] in
      while cur s = TComma do
        ignore (adv s);
        rest := (match adv s with TIdent x -> x | _ -> failwith "param name") :: !rest
      done;
      first :: List.rev !rest
    end
  in
  eat s TRParen;
  skip_nl s;
  let body = stmts_until s [TEnd] in
  eat s TEnd;
  FuncDef (name, params, body)

and stmts_until s stops =
  let acc = ref [] in
  skip_nl s;
  while not (List.mem (cur s) stops) && cur s <> TEOF do
    acc := stmt s :: !acc;
    skip_nl s
  done;
  List.rev !acc

(* ── entry point ── *)
let parse src =
  let s = make src in
  let acc = ref [] in
  skip_nl s;
  while cur s <> TEOF do
    acc := stmt s :: !acc;
    skip_nl s
  done;
  List.rev !acc

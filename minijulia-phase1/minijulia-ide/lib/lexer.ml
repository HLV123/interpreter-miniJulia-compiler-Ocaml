(* MiniJulia Lexer — pure OCaml, no ocamllex *)

type token =
  | TNum of float
  | TStr of string
  | TIdent of string
  | TTrue | TFalse | TNothing
  | TIf | TElseif | TElse | TEnd
  | TWhile | TFor | TIn | TDo
  | TFunction | TReturn | TBreak | TContinue
  | TLocal | TGlobal
  | TAnd | TOr | TNot
  | TPlus | TMinus | TStar | TSlash | TPercent | TCaret
  | TEq | TEqEq | TNeq | TLt | TLte | TGt | TGte | TBang
  | TLParen | TRParen | TLBracket | TRBracket | TLBrace | TRBrace
  | TComma | TSemi | TColon | TDot | TNewline
  | TEOF

let keywords = [
  "if", TIf; "elseif", TElseif; "else", TElse; "end", TEnd;
  "while", TWhile; "for", TFor; "in", TIn; "do", TDo;
  "function", TFunction; "return", TReturn;
  "break", TBreak; "continue", TContinue;
  "true", TTrue; "false", TFalse; "nothing", TNothing;
  "local", TLocal; "global", TGlobal;
  "and", TAnd; "or", TOr; "not", TNot;
]

let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_digit c = c >= '0' && c <= '9'
let is_alnum c = is_alpha c || is_digit c || c = '!' || c = '?'

let tokenize src =
  let n   = String.length src in
  let pos = ref 0 in
  let line = ref 1 in
  let tokens = ref [] in
  let emit t = tokens := t :: !tokens in

  let cur () = if !pos < n then src.[!pos] else '\000' in
  let next () = if !pos + 1 < n then src.[!pos + 1] else '\000' in
  let adv () = incr pos in
  let adv2 () = pos := !pos + 2 in

  let read_string () =
    adv ();
    let buf = Buffer.create 32 in
    let rec loop () =
      if !pos >= n then failwith "unterminated string"
      else match cur () with
      | '"' -> adv (); Buffer.contents buf
      | '\\' ->
          adv ();
          (match cur () with
           | 'n' -> Buffer.add_char buf '\n'; adv ()
           | 't' -> Buffer.add_char buf '\t'; adv ()
           | '"' -> Buffer.add_char buf '"';  adv ()
           | '\\' -> Buffer.add_char buf '\\'; adv ()
           | c  -> Buffer.add_char buf '\\'; Buffer.add_char buf c; adv ());
          loop ()
      | '\n' ->
          Buffer.add_char buf '\n'; incr line; adv (); loop ()
      | c -> Buffer.add_char buf c; adv (); loop ()
    in
    loop ()
  in

  let read_number () =
    let start = !pos in
    while !pos < n && is_digit (cur ()) do adv () done;
    if !pos < n && cur () = '.' && (next () >= '0' && next () <= '9') then begin
      adv ();
      while !pos < n && is_digit (cur ()) do adv () done
    end;
    float_of_string (String.sub src start (!pos - start))
  in

  let read_ident () =
    let start = !pos in
    while !pos < n && is_alnum (cur ()) do adv () done;
    String.sub src start (!pos - start)
  in

  while !pos < n do
    match cur () with
    | ' ' | '\t' | '\r' -> adv ()
    | '\n' ->
        emit TNewline; incr line; adv ()
    | '#' ->
        while !pos < n && cur () <> '\n' do adv () done
    | '"' ->
        let s = read_string () in emit (TStr s)
    | c when is_digit c ->
        let f = read_number () in emit (TNum f)
    | c when is_alpha c ->
        let s = read_ident () in
        (match List.assoc_opt s keywords with
         | Some t -> emit t
         | None   -> emit (TIdent s))
    | '=' ->
        if next () = '=' then (adv2 (); emit TEqEq)
        else (adv (); emit TEq)
    | '!' ->
        if next () = '=' then (adv2 (); emit TNeq)
        else (adv (); emit TBang)
    | '<' ->
        if next () = '=' then (adv2 (); emit TLte)
        else (adv (); emit TLt)
    | '>' ->
        if next () = '=' then (adv2 (); emit TGte)
        else (adv (); emit TGt)
    | '&' ->
        if next () = '&' then (adv2 (); emit TAnd)
        else (adv (); emit TBang)
    | '|' ->
        if next () = '|' then (adv2 (); emit TOr)
        else adv ()
    | '+' -> adv (); emit TPlus
    | '-' -> adv (); emit TMinus
    | '*' -> adv (); emit TStar
    | '/' -> adv (); emit TSlash
    | '%' -> adv (); emit TPercent
    | '^' -> adv (); emit TCaret
    | '(' -> adv (); emit TLParen
    | ')' -> adv (); emit TRParen
    | '[' -> adv (); emit TLBracket
    | ']' -> adv (); emit TRBracket
    | '{' -> adv (); emit TLBrace
    | '}' -> adv (); emit TRBrace
    | ',' -> adv (); emit TComma
    | ';' -> adv (); emit TSemi
    | ':' -> adv (); emit TColon
    | '.' -> adv (); emit TDot
    | c   ->
        failwith (Printf.sprintf "line %d: unexpected char '%c'" !line c)
  done;
  emit TEOF;
  ignore line;
  List.rev !tokens

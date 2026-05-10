(* MiniJulia Interpreter — tree-walk evaluator *)
open Ast

(* ── values ── *)
type value =
  | VNum   of float
  | VStr   of string
  | VBool  of bool
  | VNil
  | VArray of value array ref   (* mutable array *)
  | VFunc  of string list * stmt list * env ref  (* params, body, closure *)
  | VBuiltin of (value list -> value)

(* ── environment ── *)
and env = {
  mutable vars  : (string, value ref) Hashtbl.t;
  parent        : env option;
}

let new_env parent =
  { vars = Hashtbl.create 16; parent }

let rec lookup env name =
  match Hashtbl.find_opt env.vars name with
  | Some r -> r
  | None ->
      match env.parent with
      | Some p -> lookup p name
      | None   -> failwith (Printf.sprintf "Undefined variable: %s" name)

let define env name v =
  Hashtbl.replace env.vars name (ref v)

let set env name v =
  try (lookup env name) := v
  with Failure _ -> define env name v

let set_global env name v =
  let rec find_root e =
    match e.parent with None -> e | Some p -> find_root p
  in
  define (find_root env) name v

(* ── control flow exceptions ── *)
exception Return_exn of value
exception Break_exn
exception Continue_exn

(* ── display ── *)
let rec show = function
  | VNum f ->
      if Float.is_integer f && Float.abs f < 1e15 then
        string_of_int (int_of_float f)
      else Printf.sprintf "%g" f
  | VStr s  -> s
  | VBool b -> if b then "true" else "false"
  | VNil    -> "nothing"
  | VArray r ->
      let elems = Array.to_list !r |> List.map show in
      "[" ^ String.concat ", " elems ^ "]"
  | VFunc _    -> "<function>"
  | VBuiltin _ -> "<builtin>"

let show_repr = function
  | VStr s -> Printf.sprintf "%S" s
  | v      -> show v

(* ── coercions ── *)
let to_float = function
  | VNum f  -> f
  | VBool b -> if b then 1.0 else 0.0
  | v -> failwith (Printf.sprintf "expected number, got %s" (show v))

let to_bool = function
  | VBool b -> b
  | VNum f  -> f <> 0.0
  | VNil    -> false
  | _       -> true

let to_int v = int_of_float (to_float v)

let to_array = function
  | VArray r -> r
  | v -> failwith (Printf.sprintf "expected array, got %s" (show v))

(* ── builtins ── *)

let builtin_println args =
  let s = String.concat "\t" (List.map show args) in
  print_string s; print_char '\n'; VNil

let builtin_print args =
  let s = String.concat "\t" (List.map show args) in
  print_string s; VNil

let builtin_length = function
  | [VArray r] -> VNum (float_of_int (Array.length !r))
  | [VStr s]   -> VNum (float_of_int (String.length s))
  | _ -> failwith "length: wrong args"

let builtin_push = function
  | [VArray r; v] -> r := Array.append !r [| v |]; VNil
  | _ -> failwith "push!: expected (array, value)"

let builtin_pop = function
  | [VArray r] ->
      let n = Array.length !r in
      if n = 0 then failwith "pop!: empty array";
      let v = !r.(n - 1) in
      r := Array.sub !r 0 (n - 1); v
  | _ -> failwith "pop!: expected array"

let builtin_string = function
  | [v] -> VStr (show v)
  | _ -> failwith "string: expected 1 arg"

let builtin_parse_int = function
  | [VStr s] -> (try VNum (float_of_int (int_of_string (String.trim s)))
                 with _ -> failwith ("parseInt: invalid: " ^ s))
  | [VNum f] -> VNum (Float.round f)
  | _ -> failwith "parseInt: expected string or number"

let builtin_parse_float = function
  | [VStr s] -> (try VNum (float_of_string (String.trim s))
                 with _ -> failwith ("parseFloat: invalid: " ^ s))
  | [VNum f] -> VNum f
  | _ -> failwith "parseFloat: expected string"

let builtin_typeof = function
  | [VNum _]     -> VStr "Number"
  | [VStr _]     -> VStr "String"
  | [VBool _]    -> VStr "Bool"
  | [VNil]       -> VStr "Nothing"
  | [VArray _]   -> VStr "Array"
  | [VFunc _]    -> VStr "Function"
  | [VBuiltin _] -> VStr "Function"
  | _ -> VStr "Unknown"

let builtin_sqrt = function
  | [v] -> VNum (sqrt (to_float v))
  | _ -> failwith "sqrt: 1 arg"

let builtin_abs = function
  | [v] -> VNum (abs_float (to_float v))
  | _ -> failwith "abs: 1 arg"

let builtin_floor = function
  | [v] -> VNum (floor (to_float v))
  | _ -> failwith "floor: 1 arg"

let builtin_ceil = function
  | [v] -> VNum (ceil (to_float v))
  | _ -> failwith "ceil: 1 arg"

let builtin_round = function
  | [v] -> VNum (Float.round (to_float v))
  | _ -> failwith "round: 1 arg"

let builtin_max = function
  | [a; b] -> VNum (max (to_float a) (to_float b))
  | args -> VNum (List.fold_left (fun acc v -> max acc (to_float v))
               neg_infinity args)

let builtin_min = function
  | [a; b] -> VNum (min (to_float a) (to_float b))
  | args -> VNum (List.fold_left (fun acc v -> min acc (to_float v))
               infinity args)

let builtin_mod = function
  | [a; b] ->
      let fa = to_float a and fb = to_float b in
      VNum (Float.rem fa fb)
  | _ -> failwith "mod: 2 args"

let builtin_zeros = function
  | [n] -> VArray (ref (Array.make (to_int n) (VNum 0.0)))
  | _ -> failwith "zeros: 1 arg"

let builtin_fill = function
  | [n; v] -> VArray (ref (Array.make (to_int n) v))
  | _ -> failwith "fill: 2 args"

let builtin_collect = function
  | [VArray r] -> VArray (ref (Array.copy !r))
  | _ -> failwith "collect: expected array"

let builtin_sort = function
  | [VArray r] ->
      let arr = Array.copy !r in
      Array.sort (fun a b ->
        compare (to_float a) (to_float b)) arr;
      VArray (ref arr)
  | _ -> failwith "sort: expected array"

let builtin_reverse = function
  | [VArray r] ->
      let arr = Array.copy !r in
      let n = Array.length arr in
      Array.init n (fun i -> arr.(n - 1 - i)) |> fun a -> VArray (ref a)
  | _ -> failwith "reverse: expected array"

let builtin_str_split = function
  | [VStr s; VStr sep] ->
      let parts = String.split_on_char sep.[0] s in
      VArray (ref (Array.of_list (List.map (fun p -> VStr p) parts)))
  | _ -> failwith "split: expected (string, string)"

let builtin_str_contains = function
  | [VStr s; VStr sub] ->
      let found = ref false in
      let ls = String.length s and lsub = String.length sub in
      for i = 0 to ls - lsub do
        if String.sub s i lsub = sub then found := true
      done;
      VBool !found
  | _ -> failwith "contains: expected 2 strings"

let builtin_str_replace = function
  | [VStr s; VStr from; VStr to_] ->
      let parts = String.split_on_char from.[0] s in
      VStr (String.concat to_ parts)
  | _ -> failwith "replace: expected 3 strings"

let builtin_str_upper = function
  | [VStr s] -> VStr (String.uppercase_ascii s)
  | _ -> failwith "uppercase: expected string"

let builtin_str_lower = function
  | [VStr s] -> VStr (String.lowercase_ascii s)
  | _ -> failwith "lowercase: expected string"

let builtin_str_trim = function
  | [VStr s] -> VStr (String.trim s)
  | _ -> failwith "strip: expected string"

let builtin_char_code = function
  | [VStr s] when String.length s > 0 -> VNum (float_of_int (Char.code s.[0]))
  | _ -> failwith "codepoint: expected string"

let builtin_char = function
  | [v] -> VStr (String.make 1 (Char.chr (to_int v)))
  | _ -> failwith "Char: expected int"

let builtin_input = function
  | [] -> VStr (try input_line stdin with End_of_file -> "")
  | [VStr prompt] -> print_string prompt; flush stdout;
      VStr (try input_line stdin with End_of_file -> "")
  | _ -> failwith "readline: expected 0 or 1 arg"

(* File I/O builtins *)
let open_files : (int, out_channel) Hashtbl.t = Hashtbl.create 4
let open_in_files : (int, in_channel) Hashtbl.t = Hashtbl.create 4
let file_counter = ref 0

let builtin_open = function
  | [VStr path; VStr mode] ->
      let id = incr file_counter; !file_counter in
      (match mode with
       | "w" | "\"w\"" ->
           Hashtbl.replace open_files id (open_out path)
       | "a" | "\"a\"" ->
           Hashtbl.replace open_files id (open_out_gen
             [Open_append; Open_creat; Open_text] 0o644 path)
       | "r" | "\"r\"" ->
           Hashtbl.replace open_in_files id (open_in path)
       | m -> failwith ("open: unknown mode: " ^ m));
      VNum (float_of_int id)
  | _ -> failwith "open: expected (path, mode)"

let builtin_write = function
  | [VNum fid; VStr s] ->
      let id = int_of_float fid in
      (match Hashtbl.find_opt open_files id with
       | Some oc -> output_string oc s; VNil
       | None    -> failwith "write: invalid file handle")
  | [VNum fid; v] ->
      let id = int_of_float fid in
      (match Hashtbl.find_opt open_files id with
       | Some oc -> output_string oc (show v); VNil
       | None    -> failwith "write: invalid file handle")
  | _ -> failwith "write: expected (file, string)"

let builtin_writeln = function
  | [VNum fid; v] ->
      let id = int_of_float fid in
      (match Hashtbl.find_opt open_files id with
       | Some oc -> output_string oc (show v); output_char oc '\n'; VNil
       | None    -> failwith "writeln: invalid file handle")
  | _ -> failwith "writeln: expected (file, value)"

let builtin_readline = function
  | [VNum fid] ->
      let id = int_of_float fid in
      (match Hashtbl.find_opt open_in_files id with
       | Some ic -> (try VStr (input_line ic) with End_of_file -> VNil)
       | None    -> failwith "readline: invalid file handle")
  | _ -> failwith "readline: expected file handle"

let builtin_close = function
  | [VNum fid] ->
      let id = int_of_float fid in
      (match Hashtbl.find_opt open_files id with
       | Some oc -> close_out oc; Hashtbl.remove open_files id
       | None    -> ());
      (match Hashtbl.find_opt open_in_files id with
       | Some ic -> close_in ic; Hashtbl.remove open_in_files id
       | None    -> ());
      VNil
  | _ -> failwith "close: expected file handle"

let builtin_readfile = function
  | [VStr path] ->
      let ic = open_in path in
      let n  = in_channel_length ic in
      let s  = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      VStr (Bytes.to_string s)
  | _ -> failwith "read: expected path string"

let builtin_writefile = function
  | [VStr path; VStr content] ->
      let oc = open_out path in
      output_string oc content;
      close_out oc; VNil
  | _ -> failwith "write: expected (path, content)"

let builtin_isnothing = function
  | [VNil] -> VBool true
  | [_]    -> VBool false
  | _ -> failwith "isnothing: 1 arg"

let builtin_isa = function
  | [v; VStr t] ->
      let matches = match v, t with
        | VNum _, "Number" | VNum _, "Int" | VNum _, "Float" -> true
        | VStr _, "String" -> true
        | VBool _, "Bool"  -> true
        | VArray _, "Array" | VArray _, "Vector" -> true
        | _ -> false
      in VBool matches
  | _ -> failwith "isa: 2 args"

let builtin_range = function
  | [a; b] ->
      let start = to_int a and stop = to_int b in
      let n = max 0 (stop - start + 1) in
      VArray (ref (Array.init n (fun i -> VNum (float_of_int (start + i)))))
  | [a; step; b] ->
      let start = to_float a and st = to_float step and stop = to_float b in
      let arr = ref [] in
      let i = ref start in
      while (if st > 0.0 then !i <= stop else !i >= stop) do
        arr := VNum !i :: !arr;
        i := !i +. st
      done;
      VArray (ref (Array.of_list (List.rev !arr)))
  | _ -> failwith "range: 2 or 3 args"

(* ── global environment ── *)
let make_global () =
  let g = new_env None in
  let b name f = define g name (VBuiltin f) in
  b "println"    builtin_println;
  b "print"      builtin_print;
  b "length"     builtin_length;
  b "size"       (fun args -> match args with
    | [VArray r] -> VNum (float_of_int (Array.length !r))
    | [VStr s]   -> VNum (float_of_int (String.length s))
    | _ -> failwith "size: wrong args");
  b "push!"      builtin_push;
  b "append!"    builtin_push;
  b "pop!"       builtin_pop;
  b "string"     builtin_string;
  b "string_of_int" (function [v] -> VStr (show v) | _ -> failwith "");
  b "int"        builtin_parse_int;
  b "float"      builtin_parse_float;
  b "parse"      (function
    | [VStr "Int"; VStr s]   -> builtin_parse_int [VStr s]
    | [VStr "Float"; VStr s] -> builtin_parse_float [VStr s]
    | _ -> failwith "parse: expected (Type, string)");
  b "typeof"     builtin_typeof;
  b "sqrt"       builtin_sqrt;
  b "abs"        builtin_abs;
  b "floor"      builtin_floor;
  b "ceil"       builtin_ceil;
  b "round"      builtin_round;
  b "max"        builtin_max;
  b "min"        builtin_min;
  b "mod"        builtin_mod;
  b "zeros"      builtin_zeros;
  b "fill"       builtin_fill;
  b "collect"    builtin_collect;
  b "sort"       builtin_sort;
  b "reverse"    builtin_reverse;
  b "split"      builtin_str_split;
  b "contains"   builtin_str_contains;
  b "replace"    builtin_str_replace;
  b "uppercase"  builtin_str_upper;
  b "lowercase"  builtin_str_lower;
  b "strip"      builtin_str_trim;
  b "lstrip"     (function [VStr s] -> VStr (String.trim s) | _ -> failwith "");
  b "rstrip"     (function [VStr s] -> VStr (String.trim s) | _ -> failwith "");
  b "codepoint"  builtin_char_code;
  b "Char"       builtin_char;
  b "readline"   builtin_input;
  b "readLine"   builtin_input;
  b "open"       builtin_open;
  b "write"      builtin_write;
  b "writeln"    builtin_writeln;
  b "read"       builtin_readline;
  b "close"      builtin_close;
  b "readfile"   builtin_readfile;
  b "writefile"  builtin_writefile;
  b "isnothing"  builtin_isnothing;
  b "isa"        builtin_isa;
  b "range"      builtin_range;
  b "error"      (function [VStr s] -> failwith s | _ -> failwith "error");
  b "assert"     (function
    | [VBool true] -> VNil
    | [VBool false] -> failwith "assertion failed"
    | [VBool false; VStr msg] -> failwith msg
    | _ -> failwith "assert: wrong args");
  b "exit"       (function [v] -> exit (to_int v) | [] -> exit 0 | _ -> exit 0);
  b "time"       (fun _ -> VNum (Unix.gettimeofday ()));
  (* Math constants *)
  define g "pi" (VNum Float.pi);
  define g "Inf" (VNum infinity);
  define g "NaN" (VNum nan);
  define g "true" (VBool true);
  define g "false" (VBool false);
  define g "nothing" VNil;
  g

(* ── evaluator ── *)
let rec eval_expr env e =
  match e with
  | Num f   -> VNum f
  | Str s   -> VStr s
  | Bool b  -> VBool b
  | Nil     -> VNil
  | Var x   -> !(lookup env x)

  | Array elems ->
      let vs = Array.of_list (List.map (eval_expr env) elems) in
      VArray (ref vs)

  | Index (arr_e, idx_e) ->
      let arr = eval_expr env arr_e in
      let idx = eval_expr env idx_e in
      (match arr, idx with
       | VArray r, VNum f ->
           let i = int_of_float f - 1 in (* Julia is 1-indexed *)
           if i < 0 || i >= Array.length !r then
             failwith (Printf.sprintf "index %d out of bounds (length %d)"
               (i+1) (Array.length !r));
           !r.(i)
       | VStr s, VNum f ->
           let i = int_of_float f - 1 in
           VStr (String.make 1 s.[i])
       | _ -> failwith "index: not an array")

  | BinOp (op, e1, e2) ->
      eval_binop env op e1 e2

  | UnOp (Neg, e) -> VNum (-. to_float (eval_expr env e))
  | UnOp (Not, e) -> VBool (not (to_bool (eval_expr env e)))

  | Call (name, arg_exprs) ->
      let args = List.map (eval_expr env) arg_exprs in
      let fn =
        try !(lookup env name)
        with Failure _ -> failwith (Printf.sprintf "undefined function: %s" name)
      in
      call_value fn name args

  | Range (a, b) ->
      let fa = to_int (eval_expr env a) and fb = to_int (eval_expr env b) in
      let n = max 0 (fb - fa + 1) in
      VArray (ref (Array.init n (fun i -> VNum (float_of_int (fa + i)))))

  | Range3 (a, step, b) ->
      let fa = to_float (eval_expr env a) in
      let fs = to_float (eval_expr env step) in
      let fb = to_float (eval_expr env b) in
      let arr = ref [] in
      let i = ref fa in
      while (if fs > 0.0 then !i <= fb +. 1e-10 else !i >= fb -. 1e-10) do
        arr := VNum !i :: !arr; i := !i +. fs
      done;
      VArray (ref (Array.of_list (List.rev !arr)))

and eval_binop env op e1 e2 =
  (* Short-circuit for and/or *)
  match op with
  | And ->
      let v1 = eval_expr env e1 in
      if not (to_bool v1) then VBool false
      else VBool (to_bool (eval_expr env e2))
  | Or ->
      let v1 = eval_expr env e1 in
      if to_bool v1 then VBool true
      else VBool (to_bool (eval_expr env e2))
  | _ ->
      let v1 = eval_expr env e1 in
      let v2 = eval_expr env e2 in
      match op, v1, v2 with
      | Add, VNum a, VNum b -> VNum (a +. b)
      | Sub, VNum a, VNum b -> VNum (a -. b)
      | Mul, VNum a, VNum b -> VNum (a *. b)
      | Div, VNum a, VNum b ->
          if b = 0.0 then failwith "division by zero";
          VNum (a /. b)
      | Mod, VNum a, VNum b -> VNum (Float.rem a b)
      | Power, VNum a, VNum b -> VNum (a ** b)
      (* String concat with * operator *)
      | Mul, VStr a, VStr b -> VStr (a ^ b)
      | Concat, VStr a, VStr b -> VStr (a ^ b)
      | Add, VStr a, VStr b -> VStr (a ^ b)
      (* Comparisons *)
      | Eq,  a, b -> VBool (value_equal a b)
      | Neq, a, b -> VBool (not (value_equal a b))
      | Lt,  VNum a, VNum b -> VBool (a < b)
      | Lte, VNum a, VNum b -> VBool (a <= b)
      | Gt,  VNum a, VNum b -> VBool (a > b)
      | Gte, VNum a, VNum b -> VBool (a >= b)
      | Lt,  VStr a, VStr b -> VBool (a < b)
      | Lte, VStr a, VStr b -> VBool (a <= b)
      | Gt,  VStr a, VStr b -> VBool (a > b)
      | Gte, VStr a, VStr b -> VBool (a >= b)
      | op, v1, v2 ->
          failwith (Printf.sprintf "type error: %s %s %s"
            (show v1) (binop_name op) (show v2))

and binop_name = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/"
  | Mod -> "%" | Power -> "^" | Eq -> "==" | Neq -> "!="
  | Lt -> "<" | Lte -> "<=" | Gt -> ">" | Gte -> ">="
  | And -> "and" | Or -> "or" | Concat -> "*"

and value_equal a b =
  match a, b with
  | VNum x, VNum y   -> x = y
  | VStr x, VStr y   -> x = y
  | VBool x, VBool y -> x = y
  | VNil, VNil       -> true
  | _                -> false

and call_value fn name args =
  match fn with
  | VBuiltin f -> f args
  | VFunc (params, body, closure_env) ->
      if List.length params <> List.length args then
        failwith (Printf.sprintf "%s: expected %d args, got %d"
          name (List.length params) (List.length args));
      let local_env = new_env (Some !closure_env) in
      List.iter2 (fun p v -> define local_env p v) params args;
      (try
        exec_stmts local_env body; VNil
      with Return_exn v -> v)
  | _ -> failwith (Printf.sprintf "%s is not a function" name)

and exec_stmts env stmts =
  List.iter (exec_stmt env) stmts

and exec_stmt env = function
  | ExprStmt e -> ignore (eval_expr env e)

  | Assign (lhs, rhs) ->
      let v = eval_expr env rhs in
      (match lhs with
       | Var x ->
           (try (lookup env x) := v
            with Failure _ -> define env x v)
       | Index (arr_e, idx_e) ->
           let arr = to_array (eval_expr env arr_e) in
           let i = to_int (eval_expr env idx_e) - 1 in
           if i < 0 || i >= Array.length !arr then
             failwith (Printf.sprintf "index %d out of bounds" (i+1));
           !arr.(i) <- v
       | _ -> failwith "invalid assignment target")

  | If (branches, else_b) ->
      let rec try_branches = function
        | [] ->
            (match else_b with
             | Some stmts -> exec_stmts env stmts
             | None -> ())
        | (cond, body) :: rest ->
            if to_bool (eval_expr env cond) then
              exec_stmts env body
            else try_branches rest
      in
      try_branches branches

  | While (cond, body) ->
      (try
        while to_bool (eval_expr env cond) do
          (try exec_stmts env body
           with Continue_exn -> ())
        done
      with Break_exn -> ())

  | For (var, range_expr, body) ->
      let iterable = eval_expr env range_expr in
      let items = match iterable with
        | VArray r -> Array.to_list !r
        | VStr s   -> List.init (String.length s)
            (fun i -> VStr (String.make 1 s.[i]))
        | _ -> failwith "for: expected iterable"
      in
      let loop_env = new_env (Some env) in
      define loop_env var VNil;
      (try
        List.iter (fun v ->
          set loop_env var v;
          (try exec_stmts loop_env body
           with Continue_exn -> ())
        ) items
      with Break_exn -> ())

  | Return e -> raise (Return_exn (eval_expr env e))
  | Break    -> raise Break_exn
  | Continue -> raise Continue_exn

  | FuncDef (name, params, body) ->
      let fn = VFunc (params, body, ref env) in
      define env name fn

  | Global x ->
      (* mark x as global — set future assignments to root *)
      ignore x (* handled by set_global when needed *)

(* ── REPL ── *)
let repl () =
  let g = make_global () in
  print_endline "MiniJulia 0.1 — type 'exit()' to quit";
  print_endline "─────────────────────────────────────";
  let buf = Buffer.create 256 in
  let in_block = ref false in
  let block_kws = ["if"; "while"; "for"; "function"; "elseif"; "else"] in
  let end_count = ref 0 in
  try while true do
    if !in_block then print_string "  ... "
    else print_string "julia> ";
    flush stdout;
    let line = input_line stdin in
    Buffer.add_string buf line;
    Buffer.add_char buf '\n';
    (* crude block detection *)
    let words = String.split_on_char ' ' (String.trim line) in
    let first = List.nth_opt words 0 |> Option.value ~default:"" in
    if List.mem first block_kws then begin
      incr end_count; in_block := true
    end;
    if String.trim line = "end" then begin
      decr end_count;
      if !end_count <= 0 then begin
        end_count := 0; in_block := false
      end
    end;
    if not !in_block then begin
      let src = Buffer.contents buf in
      Buffer.clear buf;
      if String.trim src <> "" then begin
        (try
          let prog = Parser.parse src in
          (* for REPL: print last expression result if not nil *)
          let rec exec_all = function
            | [] -> ()
            | [ExprStmt e] ->
                let v = eval_expr g e in
                if v <> VNil then
                  Printf.printf "%s\n" (show_repr v)
            | s :: rest ->
                exec_stmt g s; exec_all rest
          in
          exec_all prog
        with Failure msg ->
          Printf.eprintf "Error: %s\n" msg)
      end
    end
  done with End_of_file -> print_endline "\nBye!"

(* ── run file ── *)
let run_file path =
  let ic = open_in path in
  let n  = in_channel_length ic in
  let s  = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  let src = Bytes.to_string s in
  let g = make_global () in
  (try
    let prog = Parser.parse src in
    exec_stmts g prog
  with
  | Failure msg -> Printf.eprintf "Error: %s\n" msg; exit 1
  | Return_exn _ -> ())

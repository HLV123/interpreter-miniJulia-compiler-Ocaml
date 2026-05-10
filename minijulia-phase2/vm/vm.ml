(* MiniJulia VM — stack-based virtual machine *)
open Bytecode

(* ── Values (same as interpreter but standalone) ── *)
type value =
  | VNum     of float
  | VStr     of string
  | VBool    of bool
  | VNil
  | VArray   of value array ref
  | VFunc    of string * string list * chunk * env
  | VBuiltin of string

(* ── Environment: linked scopes ── *)
and env = {
  vars   : (string, value ref) Hashtbl.t;
  parent : env option;
}

let new_env parent =
  { vars = Hashtbl.create 16; parent }

let rec env_get env name =
  match Hashtbl.find_opt env.vars name with
  | Some r -> !r
  | None ->
      match env.parent with
      | Some p -> env_get p name
      | None   -> failwith (Printf.sprintf "undefined variable: %s" name)

let rec env_set env name v =
  match Hashtbl.find_opt env.vars name with
  | Some r -> r := v
  | None ->
      match env.parent with
      | Some p -> (try env_set p name v
                   with Failure _ -> Hashtbl.replace env.vars name (ref v))
      | None   -> Hashtbl.replace env.vars name (ref v)

let env_def env name v =
  Hashtbl.replace env.vars name (ref v)

(* ── Display ── *)
let rec show = function
  | VNum f ->
      if Float.is_integer f && Float.abs f < 1e15 then
        string_of_int (int_of_float f)
      else Printf.sprintf "%g" f
  | VStr s   -> s
  | VBool b  -> if b then "true" else "false"
  | VNil     -> "nothing"
  | VArray r ->
      "[" ^ String.concat ", " (Array.to_list !r |> List.map show) ^ "]"
  | VFunc (name, _, _, _) -> Printf.sprintf "<function %s>" name
  | VBuiltin name          -> Printf.sprintf "<builtin %s>" name

let show_repr = function
  | VStr s -> Printf.sprintf "%S" s
  | v      -> show v

(* ── Type coercions ── *)
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

(* ── File handles ── *)
let open_out_files : (int, out_channel) Hashtbl.t = Hashtbl.create 4
let open_in_files  : (int, in_channel)  Hashtbl.t = Hashtbl.create 4
let file_counter = ref 0

(* ── Builtin dispatch ── *)
let call_builtin name args =
  match name, args with
  (* I/O *)
  | "println", _ ->
      print_string (String.concat "\t" (List.map show args));
      print_char '\n'; flush stdout; VNil
  | "print", _ ->
      print_string (String.concat "\t" (List.map show args)); VNil
  | ("length" | "size"), [VArray r] -> VNum (float_of_int (Array.length !r))
  | ("length" | "size"), [VStr s]   -> VNum (float_of_int (String.length s))
  | "push!", [VArray r; v] -> r := Array.append !r [|v|]; VNil
  | "append!", [VArray r; v] -> r := Array.append !r [|v|]; VNil
  | "pop!", [VArray r] ->
      let n = Array.length !r in
      if n = 0 then failwith "pop!: empty array";
      let v = !r.(n-1) in r := Array.sub !r 0 (n-1); v
  (* Type conversion *)
  | "string", [v]   -> VStr (show v)
  | "int",    [VStr s] -> (try VNum (float_of_int (int_of_string (String.trim s)))
                           with _ -> failwith ("int: invalid: " ^ s))
  | "int",    [VNum f] -> VNum (Float.round f)
  | "float",  [VStr s] -> (try VNum (float_of_string (String.trim s))
                           with _ -> failwith ("float: invalid: " ^ s))
  | "float",  [VNum f] -> VNum f
  | "parse", [VStr "Int"; VStr s] ->
      (try VNum (float_of_int (int_of_string (String.trim s)))
       with _ -> failwith ("parse Int: " ^ s))
  | "parse", [VStr "Float"; VStr s] ->
      (try VNum (float_of_string (String.trim s))
       with _ -> failwith ("parse Float: " ^ s))
  | "typeof", [VNum _]   -> VStr "Number"
  | "typeof", [VStr _]   -> VStr "String"
  | "typeof", [VBool _]  -> VStr "Bool"
  | "typeof", [VNil]     -> VStr "Nothing"
  | "typeof", [VArray _] -> VStr "Array"
  | "typeof", [VFunc _]  -> VStr "Function"
  | "typeof", [VBuiltin _] -> VStr "Function"
  (* Math *)
  | "sqrt",  [v] -> VNum (sqrt (to_float v))
  | "abs",   [v] -> VNum (abs_float (to_float v))
  | "floor", [v] -> VNum (floor (to_float v))
  | "ceil",  [v] -> VNum (ceil (to_float v))
  | "round", [v] -> VNum (Float.round (to_float v))
  | "max", vs    -> VNum (List.fold_left (fun a v -> max a (to_float v)) neg_infinity vs)
  | "min", vs    -> VNum (List.fold_left (fun a v -> min a (to_float v)) infinity vs)
  | "mod", [a; b] -> VNum (Float.rem (to_float a) (to_float b))
  | "pow", [a; b] -> VNum (to_float a ** to_float b)
  (* Array ops *)
  | "zeros", [n]    -> VArray (ref (Array.make (to_int n) (VNum 0.0)))
  | "fill",  [n; v] -> VArray (ref (Array.make (to_int n) v))
  | "sort",  [VArray r] ->
      let a = Array.copy !r in
      Array.sort (fun a b -> compare (to_float a) (to_float b)) a;
      VArray (ref a)
  | "reverse", [VArray r] ->
      let a = !r in let n = Array.length a in
      VArray (ref (Array.init n (fun i -> a.(n-1-i))))
  | "collect", [VArray r] -> VArray (ref (Array.copy !r))
  (* String ops *)
  | "split",    [VStr s; VStr sep] ->
      VArray (ref (Array.of_list
        (List.map (fun p -> VStr p) (String.split_on_char sep.[0] s))))
  | "contains", [VStr s; VStr sub] ->
      let found = ref false in
      let ls = String.length s and lsub = String.length sub in
      for i = 0 to ls - lsub do
        if String.sub s i lsub = sub then found := true
      done; VBool !found
  | "replace",  [VStr s; VStr from; VStr to_] ->
      VStr (String.concat to_ (String.split_on_char from.[0] s))
  | "uppercase", [VStr s] -> VStr (String.uppercase_ascii s)
  | "lowercase", [VStr s] -> VStr (String.lowercase_ascii s)
  | "strip",     [VStr s] -> VStr (String.trim s)
  | "codepoint", [VStr s] when String.length s > 0 ->
      VNum (float_of_int (Char.code s.[0]))
  | "Char", [v] -> VStr (String.make 1 (Char.chr (to_int v)))
  (* Input *)
  | ("readline" | "readLine"), [] ->
      VStr (try input_line stdin with End_of_file -> "")
  | ("readline" | "readLine"), [VStr prompt] ->
      print_string prompt; flush stdout;
      VStr (try input_line stdin with End_of_file -> "")
  (* File I/O *)
  | "open", [VStr path; VStr mode] ->
      let id = incr file_counter; !file_counter in
      (match mode with
       | "w" -> Hashtbl.replace open_out_files id (open_out path)
       | "a" -> Hashtbl.replace open_out_files id
                  (open_out_gen [Open_append;Open_creat;Open_text] 0o644 path)
       | "r" -> Hashtbl.replace open_in_files id (open_in path)
       | m   -> failwith ("open: unknown mode: " ^ m));
      VNum (float_of_int id)
  | "write", [VNum fid; v] ->
      let id = to_int (VNum fid) in
      (match Hashtbl.find_opt open_out_files id with
       | Some oc -> output_string oc (show v); VNil
       | None    -> failwith "write: invalid file handle")
  | "writeln", [VNum fid; v] ->
      let id = to_int (VNum fid) in
      (match Hashtbl.find_opt open_out_files id with
       | Some oc -> output_string oc (show v); output_char oc '\n'; VNil
       | None    -> failwith "writeln: invalid file handle")
  | "read", [VNum fid] ->
      let id = to_int (VNum fid) in
      (match Hashtbl.find_opt open_in_files id with
       | Some ic -> (try VStr (input_line ic) with End_of_file -> VNil)
       | None    -> failwith "read: invalid file handle")
  | "close", [VNum fid] ->
      let id = to_int (VNum fid) in
      (match Hashtbl.find_opt open_out_files id with
       | Some oc -> close_out oc; Hashtbl.remove open_out_files id | None -> ());
      (match Hashtbl.find_opt open_in_files id with
       | Some ic -> close_in ic;  Hashtbl.remove open_in_files id  | None -> ());
      VNil
  | "readfile", [VStr path] ->
      let ic = open_in path in
      let n  = in_channel_length ic in
      let s  = Bytes.create n in
      really_input ic s 0 n; close_in ic;
      VStr (Bytes.to_string s)
  | "writefile", [VStr path; VStr content] ->
      let oc = open_out path in
      output_string oc content; close_out oc; VNil
  (* Predicates *)
  | "isnothing", [VNil] -> VBool true
  | "isnothing", [_]    -> VBool false
  | "isa", [v; VStr t]  ->
      VBool (match v, t with
        | VNum _, ("Number"|"Int"|"Float") -> true
        | VStr _, "String"  -> true
        | VBool _, "Bool"   -> true
        | VArray _, ("Array"|"Vector") -> true
        | _ -> false)
  (* Range helpers *)
  | "__range2", [VNum a; VNum b] ->
      let ia = int_of_float a and ib = int_of_float b in
      let n  = max 0 (ib - ia + 1) in
      VArray (ref (Array.init n (fun i -> VNum (float_of_int (ia + i)))))
  | "__range3", [VNum a; VNum step; VNum b] ->
      let arr = ref [] in
      let i = ref a in
      while (if step > 0.0 then !i <= b +. 1e-10 else !i >= b -. 1e-10) do
        arr := VNum !i :: !arr; i := !i +. step
      done;
      VArray (ref (Array.of_list (List.rev !arr)))
  | "error", [VStr msg] -> failwith msg
  | "assert", [VBool true]  -> VNil
  | "assert", [VBool false] -> failwith "assertion failed"
  | "assert", [VBool false; VStr msg] -> failwith msg
  | "exit", [v] -> exit (to_int v)
  | "exit", []  -> exit 0
  | name, args ->
      failwith (Printf.sprintf "builtin %s: wrong args (%d given)" name (List.length args))

(* ── Call stack frame ── *)
type frame = {
  chunk   : chunk;
  mutable ip : int;
  env     : env;
}

(* ── VM ── *)
exception Return_exn of value

let rec run_chunk chunk global_env =
  let stack : value Stack.t = Stack.create () in
  let push v = Stack.push v stack in
  let pop () =
    if Stack.is_empty stack then failwith "VM: stack underflow"
    else Stack.pop stack
  in
  let peek () =
    if Stack.is_empty stack then failwith "VM: stack empty"
    else Stack.top stack
  in

  (* Call stack for nested functions *)
  let call_stack : frame Stack.t = Stack.create () in
  let frame = { chunk; ip = 0; env = global_env } in
  Stack.push frame call_stack;

  let running = ref true in
  while !running && not (Stack.is_empty call_stack) do
    let f = Stack.top call_stack in
    if f.ip >= Array.length f.chunk.code then begin
      (* Function ended without RETURN — push nil *)
      ignore (Stack.pop call_stack);
      push VNil;
      if Stack.is_empty call_stack then running := false
    end else begin
      let op = f.chunk.code.(f.ip) in
      f.ip <- f.ip + 1;
      match op with
      | PUSH_NUM f2  -> push (VNum f2)
      | PUSH_STR s   -> push (VStr s)
      | PUSH_BOOL b  -> push (VBool b)
      | PUSH_NIL     -> push VNil

      | LOAD x ->
          (try push (env_get f.env x)
           with Failure _ ->
             (* Try global *)
             try push (env_get global_env x)
             with Failure _ -> failwith (Printf.sprintf "undefined: %s" x))

      | STORE x ->
          let v = pop () in
          env_set f.env x v

      | LOAD_GLOBAL x ->
          (try push (env_get global_env x)
           with Failure _ -> push (VBuiltin x))

      | STORE_GLOBAL x ->
          let v = pop () in
          env_def global_env x v

      | ADD ->
          let b = pop () and a = pop () in
          (match a, b with
           | VNum x, VNum y -> push (VNum (x +. y))
           | VStr x, VStr y -> push (VStr (x ^ y))
           | _ -> failwith (Printf.sprintf "ADD: %s + %s" (show a) (show b)))
      | SUB -> let b = pop () and a = pop () in push (VNum (to_float a -. to_float b))
      | MUL ->
          let b = pop () and a = pop () in
          (match a, b with
           | VNum x, VNum y -> push (VNum (x *. y))
           | VStr x, VStr y -> push (VStr (x ^ y))
           | _ -> failwith (Printf.sprintf "MUL: %s * %s" (show a) (show b)))
      | DIV ->
          let b = pop () and a = pop () in
          let fb = to_float b in
          if fb = 0.0 then failwith "division by zero";
          push (VNum (to_float a /. fb))
      | MOD -> let b = pop () and a = pop () in push (VNum (Float.rem (to_float a) (to_float b)))
      | POW -> let b = pop () and a = pop () in push (VNum (to_float a ** to_float b))
      | NEG -> let a = pop () in push (VNum (-. to_float a))
      | CONCAT ->
          let b = pop () and a = pop () in
          push (VStr (show a ^ show b))

      | EQ  -> let b = pop () and a = pop () in push (VBool (value_eq a b))
      | NEQ -> let b = pop () and a = pop () in push (VBool (not (value_eq a b)))
      | LT  -> let b = pop () and a = pop () in push (VBool (to_float a < to_float b))
      | LTE -> let b = pop () and a = pop () in push (VBool (to_float a <= to_float b))
      | GT  -> let b = pop () and a = pop () in push (VBool (to_float a > to_float b))
      | GTE -> let b = pop () and a = pop () in push (VBool (to_float a >= to_float b))
      | AND -> let b = pop () and a = pop () in push (VBool (to_bool a && to_bool b))
      | OR  -> let b = pop () and a = pop () in push (VBool (to_bool a || to_bool b))
      | NOT -> let a = pop () in push (VBool (not (to_bool a)))

      | JUMP n          -> f.ip <- n
      | JUMP_IF_FALSE n -> if not (to_bool (pop ())) then f.ip <- n
      | JUMP_IF_TRUE  n -> if to_bool (pop ()) then f.ip <- n

      | MAKE_ARRAY n ->
          let items = Array.init n (fun _ -> pop ()) in
          let arr   = Array.of_list (List.rev (Array.to_list items)) in
          push (VArray (ref arr))

      | GET_INDEX ->
          let idx = pop () and arr = pop () in
          (match arr with
           | VArray r ->
               let i = to_int idx - 1 in
               if i < 0 || i >= Array.length !r then
                 failwith (Printf.sprintf "index %d out of bounds (length %d)"
                   (i+1) (Array.length !r));
               push !r.(i)
           | VStr s ->
               let i = to_int idx - 1 in
               push (VStr (String.make 1 s.[i]))
           | _ -> failwith "GET_INDEX: not an array")

      | SET_INDEX ->
          let v   = pop () in
          let idx = pop () in
          let arr = pop () in
          let r = to_array arr in
          let i = to_int idx - 1 in
          if i < 0 || i >= Array.length !r then
            failwith (Printf.sprintf "index %d out of bounds" (i+1));
          !r.(i) <- v

      | ARRAY_LEN ->
          (match pop () with
           | VArray r -> push (VNum (float_of_int (Array.length !r)))
           | VStr s   -> push (VNum (float_of_int (String.length s)))
           | v -> failwith (Printf.sprintf "ARRAY_LEN: %s" (show v)))

      | MAKE_FUNC (name, params, func_chunk) ->
          push (VFunc (name, params, func_chunk, f.env))

      | CALL nargs ->
          let args = List.init nargs (fun _ -> pop ()) |> List.rev in
          let fn   = pop () in
          (match fn with
           | VFunc (name, params, func_chunk, closure_env) ->
               if List.length params <> nargs then
                 failwith (Printf.sprintf "%s: expected %d args, got %d"
                   name (List.length params) nargs);
               let local_env = new_env (Some closure_env) in
               List.iter2 (fun p v -> env_def local_env p v) params args;
               let new_frame = { chunk = func_chunk; ip = 0; env = local_env } in
               Stack.push new_frame call_stack
           | VBuiltin bname ->
               push (call_builtin bname args)
           | _ -> failwith (Printf.sprintf "CALL: %s is not a function" (show fn)))

      | RETURN ->
          let v = pop () in
          ignore (Stack.pop call_stack);
          push v;
          if Stack.is_empty call_stack then running := false

      | CALL_BUILTIN (name, nargs) ->
          let args = List.init nargs (fun _ -> pop ()) |> List.rev in
          push (call_builtin name args)

      | POP -> ignore (pop ())
      | DUP -> push (peek ())
      | LINE _ -> ()
    end
  done;
  if Stack.is_empty stack then VNil else pop ()

and value_eq a b =
  match a, b with
  | VNum x, VNum y   -> x = y
  | VStr x, VStr y   -> x = y
  | VBool x, VBool y -> x = y
  | VNil, VNil       -> true
  | _                -> false

(* ── Global environment with builtins ── *)
let make_global () =
  let g = new_env None in
  env_def g "pi"      (VNum Float.pi);
  env_def g "Inf"     (VNum infinity);
  env_def g "NaN"     (VNum nan);
  env_def g "true"    (VBool true);
  env_def g "false"   (VBool false);
  env_def g "nothing" VNil;
  g

let save_bytecode chunk path =
  let oc = open_out_bin path in
  Marshal.to_channel oc chunk [];
  close_out oc;
  Printf.printf "Bytecode saved: %s\n" path

let load_bytecode path =
  let ic = open_in_bin path in
  let chunk : Bytecode.chunk = Marshal.from_channel ic in
  close_in ic;
  chunk

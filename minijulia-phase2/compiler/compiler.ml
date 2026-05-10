(* MiniJulia Compiler — AST → Bytecode
   Single-pass compiler with backpatching for jumps *)
open Ast
open Bytecode

(* ── Compiler state ── *)
type cstate = {
  mutable code    : opcode list;
  mutable globals : string list;   (* global variable names *)
  scope_depth     : int;
  func_name       : string;
  source          : string;
}

let new_cstate ?(func_name="<main>") ?(source="<unknown>") () =
  { code = []; globals = []; scope_depth = 0;
    func_name; source }

let emit s op =
  s.code <- s.code @ [op]

let current_pos s = List.length s.code

(* Emit placeholder and return its index for backpatching *)
let emit_jump s op =
  let pos = current_pos s in
  emit s (op 0);
  pos

let patch_jump s idx target =
  let arr = Array.of_list s.code in
  arr.(idx) <- (match arr.(idx) with
    | JUMP _          -> JUMP target
    | JUMP_IF_FALSE _ -> JUMP_IF_FALSE target
    | JUMP_IF_TRUE _  -> JUMP_IF_TRUE target
    | op -> op);
  s.code <- Array.to_list arr

(* ── Builtin names ── *)
let builtins = [
  "println"; "print"; "length"; "size"; "push!"; "append!"; "pop!";
  "string"; "int"; "float"; "parse"; "typeof"; "sqrt"; "abs"; "floor";
  "ceil"; "round"; "max"; "min"; "mod"; "zeros"; "fill"; "collect";
  "sort"; "reverse"; "split"; "contains"; "replace"; "uppercase";
  "lowercase"; "strip"; "codepoint"; "Char"; "readline"; "readLine";
  "open"; "write"; "writeln"; "read"; "close"; "readfile"; "writefile";
  "isnothing"; "isa"; "range"; "error"; "assert"; "exit";
]

let is_builtin name = List.mem name builtins

(* ── Compile expression ── *)
let rec compile_expr s = function
  | Num f   -> emit s (PUSH_NUM f)
  | Str str -> emit s (PUSH_STR str)
  | Bool b  -> emit s (PUSH_BOOL b)
  | Nil     -> emit s PUSH_NIL

  | Var x ->
      if is_builtin x then
        emit s (LOAD_GLOBAL x)
      else
        emit s (LOAD x)

  | Array elems ->
      List.iter (compile_expr s) elems;
      emit s (MAKE_ARRAY (List.length elems))

  | Index (arr, idx) ->
      compile_expr s arr;
      compile_expr s idx;
      emit s GET_INDEX

  | BinOp (Concat, e1, e2) ->
      compile_expr s e1;
      compile_expr s e2;
      emit s CONCAT

  | BinOp (And, e1, e2) ->
      (* Short-circuit: if e1 false, skip e2 *)
      compile_expr s e1;
      emit s DUP;
      let jmp = emit_jump s (fun n -> JUMP_IF_FALSE n) in
      emit s POP;
      compile_expr s e2;
      patch_jump s jmp (current_pos s)

  | BinOp (Or, e1, e2) ->
      (* Short-circuit: if e1 true, skip e2 *)
      compile_expr s e1;
      emit s DUP;
      let jmp = emit_jump s (fun n -> JUMP_IF_TRUE n) in
      emit s POP;
      compile_expr s e2;
      patch_jump s jmp (current_pos s)

  | BinOp (op, e1, e2) ->
      compile_expr s e1;
      compile_expr s e2;
      emit s (compile_binop op)

  | UnOp (Neg, e) ->
      compile_expr s e;
      emit s NEG

  | UnOp (Not, e) ->
      compile_expr s e;
      emit s NOT

  | Call (name, args) ->
      let nargs = List.length args in
      if is_builtin name then begin
        List.iter (compile_expr s) args;
        emit s (CALL_BUILTIN (name, nargs))
      end else begin
        emit s (LOAD name);
        List.iter (compile_expr s) args;
        emit s (CALL nargs)
      end

  | Range (a, b) ->
      compile_expr s a;
      compile_expr s b;
      emit s (CALL_BUILTIN ("__range2", 2))

  | Range3 (a, step, b) ->
      compile_expr s a;
      compile_expr s step;
      compile_expr s b;
      emit s (CALL_BUILTIN ("__range3", 3))

and compile_binop = function
  | Add -> ADD | Sub -> SUB | Mul -> MUL | Div -> DIV
  | Mod -> MOD | Power -> POW
  | Eq  -> EQ  | Neq -> NEQ | Lt -> LT | Lte -> LTE
  | Gt  -> GT  | Gte -> GTE
  | And -> AND | Or  -> OR
  | Concat -> CONCAT

(* ── Compile statement ── *)
and compile_stmt s = function
  | ExprStmt e ->
      compile_expr s e;
      emit s POP

  | Assign (Var x, rhs) ->
      compile_expr s rhs;
      if List.mem x s.globals then emit s (STORE_GLOBAL x)
      else emit s (STORE x)

  | Assign (Index (arr, idx), rhs) ->
      compile_expr s arr;
      compile_expr s idx;
      compile_expr s rhs;
      emit s SET_INDEX

  | Assign (_, _) ->
      failwith "compile: invalid assignment target"

  | If (branches, else_b) ->
      compile_if s branches else_b

  | While (cond, body) ->
      compile_while s cond body

  | For (var, range_expr, body) ->
      compile_for s var range_expr body

  | Return e ->
      compile_expr s e;
      emit s RETURN

  | Break ->
      (* Break is handled by For/While compilers via exception *)
      emit s (JUMP (-999))   (* placeholder, patched by loop compiler *)

  | Continue ->
      emit s (JUMP (-998))   (* placeholder, patched by loop compiler *)

  | FuncDef (name, params, body) ->
      let func_s = new_cstate ~func_name:name ~source:s.source () in
      func_s.globals <- s.globals;
      List.iter (compile_stmt func_s) body;
      (* Ensure function returns nil if no explicit return *)
      func_s.code <- func_s.code @ [PUSH_NIL; RETURN];
      let chunk = {
        code   = Array.of_list func_s.code;
        name;
        source = s.source;
      } in
      emit s (MAKE_FUNC (name, params, chunk));
      emit s (STORE name)

  | Global x ->
      s.globals <- x :: s.globals

and compile_if s branches else_b =
  let end_jumps = ref [] in
  List.iter (fun (cond, body) ->
    compile_expr s cond;
    let skip = emit_jump s (fun n -> JUMP_IF_FALSE n) in
    List.iter (compile_stmt s) body;
    let j = emit_jump s (fun n -> JUMP n) in
    end_jumps := j :: !end_jumps;
    patch_jump s skip (current_pos s)
  ) branches;
  (match else_b with
   | Some stmts -> List.iter (compile_stmt s) stmts
   | None -> ());
  let end_pos = current_pos s in
  List.iter (fun j -> patch_jump s j end_pos) !end_jumps

and compile_while s cond body =
  let loop_start = current_pos s in
  compile_expr s cond;
  let exit_jump = emit_jump s (fun n -> JUMP_IF_FALSE n) in
  (* Compile body, collecting break/continue positions *)
  let break_patches = ref [] in
  let cont_patches  = ref [] in
  let body_start = current_pos s in
  List.iter (compile_stmt s) body;
  (* Find placeholders *)
  let arr = Array.of_list s.code in
  Array.iteri (fun i op ->
    if i >= body_start then
      match op with
      | JUMP (-999) -> break_patches := i :: !break_patches
      | JUMP (-998) -> cont_patches  := i :: !cont_patches
      | _ -> ()
  ) arr;
  emit s (JUMP loop_start);
  let exit_pos = current_pos s in
  patch_jump s exit_jump exit_pos;
  List.iter (fun i -> patch_jump s i exit_pos) !break_patches;
  List.iter (fun i -> patch_jump s i loop_start) !cont_patches

and compile_for s var range_expr body =
  (* Compile range to array, then iterate with index *)
  (match range_expr with
   | Range (a, b) ->
       compile_expr s a; compile_expr s b;
       emit s (CALL_BUILTIN ("__range2", 2))
   | Range3 (a, step, b) ->
       compile_expr s a; compile_expr s step; compile_expr s b;
       emit s (CALL_BUILTIN ("__range3", 3))
   | _ -> compile_expr s range_expr);
  (* Stack: [array] *)
  let arr_var = Printf.sprintf "__for_arr_%d" (current_pos s) in
  let idx_var = Printf.sprintf "__for_idx_%d" (current_pos s) in
  emit s (STORE arr_var);
  emit s (PUSH_NUM 1.0);
  emit s (STORE idx_var);
  let loop_start = current_pos s in
  (* Check idx <= length(arr), 1-based *)
  emit s (LOAD idx_var);
  emit s (LOAD arr_var);
  emit s ARRAY_LEN;
  emit s LTE;
  let exit_jump = emit_jump s (fun n -> JUMP_IF_FALSE n) in
  (* Load arr[idx] into var *)
  emit s (LOAD arr_var);
  emit s (LOAD idx_var);
  emit s GET_INDEX;
  emit s (STORE var);
  (* Compile body *)
  let break_patches = ref [] in
  let cont_patches  = ref [] in
  let body_start = current_pos s in
  List.iter (compile_stmt s) body;
  let arr2 = Array.of_list s.code in
  Array.iteri (fun i op ->
    if i >= body_start then
      match op with
      | JUMP (-999) -> break_patches := i :: !break_patches
      | JUMP (-998) -> cont_patches  := i :: !cont_patches
      | _ -> ()
  ) arr2;
  (* Increment idx *)
  let incr_pos = current_pos s in
  emit s (LOAD idx_var);
  emit s (PUSH_NUM 1.0);
  emit s ADD;
  emit s (STORE idx_var);
  emit s (JUMP loop_start);
  let exit_pos = current_pos s in
  patch_jump s exit_jump exit_pos;
  List.iter (fun i -> patch_jump s i exit_pos)  !break_patches;
  List.iter (fun i -> patch_jump s i incr_pos)  !cont_patches

(* ── Top-level compile ── *)
let compile_program ?(source="<unknown>") prog =
  let s = new_cstate ~func_name:"<main>" ~source () in
  List.iter (compile_stmt s) prog;
  emit s PUSH_NIL;
  emit s RETURN;
  { code = Array.of_list s.code; name = "<main>"; source }

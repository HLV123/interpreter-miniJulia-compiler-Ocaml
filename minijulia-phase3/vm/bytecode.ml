(* MiniJulia Bytecode — instruction set definition
   Stack-based VM, similar to CPython / Lua 5 *)

(* ── Opcodes ── *)
type opcode =
  (* Push constants *)
  | PUSH_NUM   of float
  | PUSH_STR   of string
  | PUSH_BOOL  of bool
  | PUSH_NIL

  (* Variables *)
  | LOAD       of string   (* push value of var *)
  | STORE      of string   (* pop → var *)
  | LOAD_GLOBAL of string
  | STORE_GLOBAL of string

  (* Arithmetic *)
  | ADD | SUB | MUL | DIV | MOD | POW
  | NEG                    (* unary minus *)

  (* Comparison *)
  | EQ | NEQ | LT | LTE | GT | GTE

  (* Logic *)
  | AND | OR | NOT

  (* String concat *)
  | CONCAT

  (* Control flow — operand is absolute instruction index *)
  | JUMP          of int
  | JUMP_IF_FALSE of int
  | JUMP_IF_TRUE  of int

  (* Arrays *)
  | MAKE_ARRAY of int      (* pop N items, make array *)
  | GET_INDEX              (* pop idx, pop arr → push arr[idx] *)
  | SET_INDEX              (* pop val, pop idx, pop arr → arr[idx]=val *)
  | ARRAY_LEN              (* pop arr → push length *)

  (* Functions *)
  | MAKE_FUNC  of string * string list * chunk  (* name, params, code *)
  | CALL       of int      (* call with N args, func is on stack below args *)
  | RETURN                 (* return top of stack *)

  (* Builtins *)
  | CALL_BUILTIN of string * int  (* builtin name, arg count *)

  (* Stack *)
  | POP                    (* discard top *)
  | DUP                    (* duplicate top *)

  (* Debug *)
  | LINE       of int      (* source line number, for error messages *)

(* ── Chunk: compiled code unit ── *)
and chunk = {
  code      : opcode array;
  name      : string;        (* function name or "<main>" *)
  source    : string;        (* source filename *)
}

(* ── Disassembler ── *)
let show_op = function
  | PUSH_NUM f   -> Printf.sprintf "PUSH_NUM    %g" f
  | PUSH_STR s   -> Printf.sprintf "PUSH_STR    %S" s
  | PUSH_BOOL b  -> Printf.sprintf "PUSH_BOOL   %b" b
  | PUSH_NIL     -> "PUSH_NIL"
  | LOAD x       -> Printf.sprintf "LOAD        %s" x
  | STORE x      -> Printf.sprintf "STORE       %s" x
  | LOAD_GLOBAL x  -> Printf.sprintf "LOAD_GLOBAL  %s" x
  | STORE_GLOBAL x -> Printf.sprintf "STORE_GLOBAL %s" x
  | ADD  -> "ADD" | SUB -> "SUB" | MUL -> "MUL" | DIV -> "DIV"
  | MOD  -> "MOD" | POW -> "POW" | NEG -> "NEG"
  | EQ   -> "EQ"  | NEQ -> "NEQ" | LT  -> "LT"  | LTE -> "LTE"
  | GT   -> "GT"  | GTE -> "GTE"
  | AND  -> "AND" | OR  -> "OR"  | NOT -> "NOT"
  | CONCAT -> "CONCAT"
  | JUMP n          -> Printf.sprintf "JUMP        %d" n
  | JUMP_IF_FALSE n -> Printf.sprintf "JUMP_IF_FALSE %d" n
  | JUMP_IF_TRUE n  -> Printf.sprintf "JUMP_IF_TRUE  %d" n
  | MAKE_ARRAY n    -> Printf.sprintf "MAKE_ARRAY  %d" n
  | GET_INDEX  -> "GET_INDEX"
  | SET_INDEX  -> "SET_INDEX"
  | ARRAY_LEN  -> "ARRAY_LEN"
  | MAKE_FUNC (name, params, _) ->
      Printf.sprintf "MAKE_FUNC   %s(%s)" name (String.concat "," params)
  | CALL n          -> Printf.sprintf "CALL        %d" n
  | RETURN     -> "RETURN"
  | CALL_BUILTIN (name, n) -> Printf.sprintf "CALL_BUILTIN %s/%d" name n
  | POP  -> "POP"
  | DUP  -> "DUP"
  | LINE n -> Printf.sprintf "LINE        %d" n

let disassemble chunk =
  Printf.printf "=== %s ===\n" chunk.name;
  Array.iteri (fun i op ->
    Printf.printf "  %04d  %s\n" i (show_op op)
  ) chunk.code;
  Printf.printf "\n"

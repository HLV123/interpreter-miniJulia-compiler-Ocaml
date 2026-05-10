(* MiniJulia AST — Julia-like syntax *)

type binop =
  | Add | Sub | Mul | Div | Mod | Power
  | Eq | Neq | Lt | Lte | Gt | Gte
  | And | Or
  | Concat   (* string * operator *)

type unop = Neg | Not

type expr =
  | Num    of float
  | Str    of string
  | Bool   of bool
  | Nil
  | Var    of string
  | Array  of expr list
  | Index  of expr * expr
  | BinOp  of binop * expr * expr
  | UnOp   of unop  * expr
  | Call   of string * expr list
  | Range  of expr * expr        (* start:stop  or start:step:stop *)
  | Range3 of expr * expr * expr (* start:step:stop *)

type stmt =
  | Assign  of expr * expr
  | If      of (expr * stmt list) list * stmt list option
  | While   of expr * stmt list
  | For     of string * expr * stmt list
  | Return  of expr
  | Break
  | Continue
  | ExprStmt of expr
  | FuncDef  of string * string list * stmt list
  | Global   of string

type program = stmt list

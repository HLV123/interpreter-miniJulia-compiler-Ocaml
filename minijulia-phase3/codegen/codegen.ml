(* MiniJulia Native Codegen — Bytecode → C → gcc → binary
   
   Strategy: emit portable C99 with a minimal runtime.
   Each bytecode chunk becomes a C function.
   Values are tagged unions (NaN-boxing would be phase 4).
*)
open Bytecode

(* ── C runtime header (embedded) ── *)
let runtime_h = {|
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ── Value type ── */
typedef enum { T_NUM, T_STR, T_BOOL, T_NIL, T_ARRAY, T_FUNC, T_CLOSURE } VType;

typedef struct Value Value;
typedef struct Array Array;
typedef struct Closure Closure;
typedef Value (*FuncPtr)(Value* args, int nargs, Value* captures, int ncaps);

struct Array {
  Value* data;
  int    len;
  int    cap;
};

struct Closure {
  FuncPtr fn;
  Value*  caps;
  int     ncaps;
  char*   name;
};

struct Value {
  VType type;
  union {
    double      num;
    char*       str;
    int         boolean;
    Array*      array;
    Closure*    closure;
  };
};

/* ── Constructors ── */
static inline Value mk_num(double n)   { Value v; v.type=T_NUM;  v.num=n;     return v; }
static inline Value mk_bool(int b)     { Value v; v.type=T_BOOL; v.boolean=b; return v; }
static inline Value mk_nil()           { Value v; v.type=T_NIL;               return v; }
static inline Value mk_str(char* s)    { Value v; v.type=T_STR;  v.str=s;     return v; }

static Value mk_str_copy(const char* s) {
  Value v; v.type=T_STR;
  v.str = (char*)malloc(strlen(s)+1);
  strcpy(v.str, s);
  return v;
}

static Value mk_array(int cap) {
  Value v; v.type=T_ARRAY;
  v.array = (Array*)malloc(sizeof(Array));
  int c = cap > 0 ? cap : 256;
  v.array->data = (Value*)calloc(c, sizeof(Value));
  v.array->len  = 0;
  v.array->cap  = c;
  return v;
}

static Value mk_closure(FuncPtr fn, char* name, Value* caps, int ncaps) {
  Value v; v.type=T_CLOSURE;
  v.closure = (Closure*)malloc(sizeof(Closure));
  v.closure->fn    = fn;
  v.closure->name  = name;
  v.closure->ncaps = ncaps;
  v.closure->caps  = (Value*)malloc(sizeof(Value)*ncaps);
  for(int i=0;i<ncaps;i++) v.closure->caps[i] = caps[i];
  return v;
}

/* ── Error ── */
static void mj_error(const char* msg) {
  fprintf(stderr, "Error: %s\n", msg);
  exit(1);
}

/* ── Coercions ── */
static double to_num(Value v) {
  if(v.type==T_NUM)  return v.num;
  if(v.type==T_BOOL) return v.boolean ? 1.0 : 0.0;
  mj_error("expected number"); return 0;
}

static int to_bool(Value v) {
  if(v.type==T_BOOL) return v.boolean;
  if(v.type==T_NUM)  return v.num != 0.0;
  if(v.type==T_NIL)  return 0;
  return 1;
}

static int to_int(Value v) { return (int)to_num(v); }

/* ── String helpers ── */
static char* num_to_str(double n) {
  static char bufs[8][64]; static int bi=0;
  char* buf = bufs[bi++ % 8];
  if(n == (long long)n && n > -1e15 && n < 1e15)
    sprintf(buf, "%lld", (long long)n);
  else
    sprintf(buf, "%g", n);
  return buf;
}

static char* str_concat(const char* a, const char* b) {
  char* s = (char*)malloc(strlen(a)+strlen(b)+1);
  strcpy(s,a); strcat(s,b);
  return s;
}

/* ── Value to string ── */
static char* val_to_str(Value v) {
  if(v.type==T_STR)  return v.str;
  if(v.type==T_NUM)  return num_to_str(v.num);
  if(v.type==T_BOOL) return v.boolean ? "true" : "false";
  if(v.type==T_NIL)  return "nothing";
  if(v.type==T_ARRAY) {
    /* build "[a, b, c]" */
    char* buf = (char*)malloc(4096);
    strcpy(buf,"[");
    for(int i=0;i<v.array->len;i++) {
      if(i>0) strcat(buf,", ");
      char* s = val_to_str(v.array->data[i]);
      if(strlen(buf)+strlen(s)+4 < 4096) strcat(buf,s);
    }
    strcat(buf,"]");
    return buf;
  }
  return "<value>";
}

/* ── Value equality ── */
static int val_eq(Value a, Value b) {
  if(a.type!=b.type) return 0;
  switch(a.type){
    case T_NUM:  return a.num == b.num;
    case T_BOOL: return a.boolean == b.boolean;
    case T_NIL:  return 1;
    case T_STR:  return strcmp(a.str,b.str)==0;
    default:     return 0;
  }
}

/* ── Array ops ── */
static void array_push(Array* arr, Value v) {
  if(arr->len >= arr->cap) {
    int new_cap = arr->cap * 2;
    Value* new_data = (Value*)realloc(arr->data, sizeof(Value)*new_cap);
    if(!new_data) { fprintf(stderr,"array_push: out of memory\n"); exit(1); }
    arr->data = new_data;
    arr->cap  = new_cap;
  }
  arr->data[arr->len++] = v;
}

static Value array_get(Value arr, Value idx) {
  if(arr.type!=T_ARRAY) mj_error("index: not an array");
  int i = to_int(idx) - 1; /* 1-based */
  if(i<0||i>=arr.array->len) mj_error("index out of bounds");
  return arr.array->data[i];
}

static void array_set(Value arr, Value idx, Value val) {
  if(arr.type!=T_ARRAY) mj_error("array_set: not an array");
  int i = to_int(idx) - 1;
  if(i<0||i>=arr.array->len) mj_error("array_set: index out of bounds");
  arr.array->data[i] = val;
}

/* ── Range helpers ── */
static Value mk_range(double a, double b) {
  int n = (int)(b-a+1); if(n<0) n=0;
  Value arr = mk_array(n);
  for(int i=0;i<n;i++) array_push(arr.array, mk_num(a+i));
  return arr;
}

static Value mk_range3(double a, double step, double b) {
  Value arr = mk_array(16);
  double i  = a;
  while((step>0 ? i<=b+1e-10 : i>=b-1e-10)) {
    array_push(arr.array, mk_num(i));
    i += step;
  }
  return arr;
}

/* ── File handles (simple) ── */
#define MAX_FILES 32
static FILE* open_files[MAX_FILES] = {NULL};
static int   file_mode[MAX_FILES]  = {0}; /* 0=out,1=in */
static int   file_counter = 0;

static Value builtin_open(Value path, Value mode) {
  int id = ++file_counter % MAX_FILES;
  if(strcmp(mode.str,"w")==0) {
    open_files[id] = fopen(path.str,"w");
    file_mode[id]  = 0;
  } else if(strcmp(mode.str,"a")==0) {
    open_files[id] = fopen(path.str,"a");
    file_mode[id]  = 0;
  } else if(strcmp(mode.str,"r")==0) {
    open_files[id] = fopen(path.str,"r");
    file_mode[id]  = 1;
  } else { mj_error("open: unknown mode"); }
  if(!open_files[id]) mj_error("open: cannot open file");
  return mk_num(id);
}

static Value builtin_write(Value fid, Value val) {
  int id = to_int(fid);
  if(!open_files[id]) mj_error("write: invalid handle");
  fprintf(open_files[id], "%s", val_to_str(val));
  return mk_nil();
}

static Value builtin_writeln(Value fid, Value val) {
  int id = to_int(fid);
  if(!open_files[id]) mj_error("writeln: invalid handle");
  fprintf(open_files[id], "%s\n", val_to_str(val));
  return mk_nil();
}

static Value builtin_read(Value fid) {
  int id = to_int(fid);
  if(!open_files[id]) mj_error("read: invalid handle");
  char buf[4096];
  if(fgets(buf,sizeof(buf),open_files[id])==NULL) return mk_nil();
  /* strip newline */
  int n = strlen(buf);
  if(n>0 && buf[n-1]=='\n') buf[n-1]='\0';
  return mk_str_copy(buf);
}

static Value builtin_close(Value fid) {
  int id = to_int(fid);
  if(open_files[id]) { fclose(open_files[id]); open_files[id]=NULL; }
  return mk_nil();
}

/* ── Builtins ── */
static Value builtin_println(Value* args, int n) {
  for(int i=0;i<n;i++) { if(i) printf("\t"); printf("%s", val_to_str(args[i])); }
  printf("\n"); fflush(stdout);
  return mk_nil();
}

static Value builtin_print(Value* args, int n) {
  for(int i=0;i<n;i++) { if(i) printf("\t"); printf("%s", val_to_str(args[i])); }
  fflush(stdout);
  return mk_nil();
}

static Value builtin_string(Value v)   { return mk_str_copy(val_to_str(v)); }
static Value builtin_length(Value v)   {
  if(v.type==T_ARRAY) return mk_num(v.array->len);
  if(v.type==T_STR)   return mk_num(strlen(v.str));
  mj_error("length: wrong type"); return mk_nil();
}
static Value builtin_push(Value arr, Value v) {
  if(arr.type!=T_ARRAY) mj_error("push!: not an array");
  array_push(arr.array, v); return mk_nil();
}
static Value builtin_pop(Value arr) {
  if(arr.type!=T_ARRAY||arr.array->len==0) mj_error("pop!: empty");
  return arr.array->data[--arr.array->len];
}
static Value builtin_sqrt(Value v)  { return mk_num(sqrt(to_num(v))); }
static Value builtin_abs(Value v)   { return mk_num(fabs(to_num(v))); }
static Value builtin_floor(Value v) { return mk_num(floor(to_num(v))); }
static Value builtin_ceil(Value v)  { return mk_num(ceil(to_num(v))); }
static Value builtin_round(Value v) { return mk_num(round(to_num(v))); }
static Value builtin_mod(Value a, Value b) { return mk_num(fmod(to_num(a),to_num(b))); }
static Value builtin_max(Value a, Value b) { double x=to_num(a),y=to_num(b); return mk_num(x>y?x:y); }
static Value builtin_min(Value a, Value b) { double x=to_num(a),y=to_num(b); return mk_num(x<y?x:y); }
static Value builtin_isnothing(Value v) { return mk_bool(v.type==T_NIL); }
static Value builtin_typeof(Value v) {
  switch(v.type){
    case T_NUM:     return mk_str("Number");
    case T_STR:     return mk_str("String");
    case T_BOOL:    return mk_str("Bool");
    case T_NIL:     return mk_str("Nothing");
    case T_ARRAY:   return mk_str("Array");
    case T_CLOSURE: return mk_str("Function");
    default:        return mk_str("Unknown");
  }
}
static Value builtin_int(Value v) {
  if(v.type==T_STR) return mk_num((double)atoll(v.str));
  return mk_num(round(to_num(v)));
}
static Value builtin_float_fn(Value v) {
  if(v.type==T_STR) return mk_num(atof(v.str));
  return mk_num(to_num(v));
}
static Value builtin_zeros(Value n) {
  int sz = to_int(n);
  Value arr = mk_array(sz);
  for(int i=0;i<sz;i++) array_push(arr.array, mk_num(0.0));
  return arr;
}
static Value builtin_sort(Value arr) {
  if(arr.type!=T_ARRAY) mj_error("sort: not an array");
  /* copy then sort */
  Value res = mk_array(arr.array->len);
  for(int i=0;i<arr.array->len;i++) array_push(res.array, arr.array->data[i]);
  /* bubble sort for simplicity */
  int n = res.array->len;
  for(int i=0;i<n;i++)
    for(int j=0;j<n-i-1;j++)
      if(to_num(res.array->data[j]) > to_num(res.array->data[j+1])) {
        Value t = res.array->data[j];
        res.array->data[j]   = res.array->data[j+1];
        res.array->data[j+1] = t;
      }
  return res;
}
static Value builtin_uppercase(Value v) {
  char* s = (char*)malloc(strlen(v.str)+1);
  for(int i=0;v.str[i];i++) s[i] = (char)toupper((unsigned char)v.str[i]);
  s[strlen(v.str)]='\0';
  return mk_str(s);
}
static Value builtin_lowercase(Value v) {
  char* s = (char*)malloc(strlen(v.str)+1);
  for(int i=0;v.str[i];i++) s[i] = (char)tolower((unsigned char)v.str[i]);
  s[strlen(v.str)]='\0';
  return mk_str(s);
}
static Value builtin_contains(Value s, Value sub) {
  return mk_bool(strstr(s.str, sub.str) != NULL);
}
|}

(* ── Code generator state ── *)
type cgstate = {
  buf      : Buffer.t;
  mutable  tmp : int;
}

let new_cg () = { buf = Buffer.create 4096; tmp = 0 }
let emit cg s = Buffer.add_string cg.buf s
let emitln cg s = Buffer.add_string cg.buf s; Buffer.add_char cg.buf '\n'
let fresh cg = let n = cg.tmp in cg.tmp <- n+1; Printf.sprintf "t%d" n

(* ── Escape C string ── *)
let c_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (function
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c    ->
        let code = Char.code c in
        if code < 32 || code > 126 then
          Buffer.add_string buf (Printf.sprintf "\\x%02x" code)
        else
          Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(* ── Generate C for a chunk ── *)
let gen_chunk ?(params=[]) cg chunk func_decls =
  let code  = chunk.code in
  let n     = Array.length code in
  let fname = if chunk.name = "<main>" then "mj_main"
              else "mj_fn_" ^ String.concat "_"
                (String.split_on_char ' ' chunk.name |>
                 List.map (fun s ->
                   String.map (fun c ->
                     if (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9') then c
                     else '_') s)) in

  (* Collect all MAKE_FUNC — emit forward declarations *)
  Array.iter (function
    | MAKE_FUNC (name, _, inner) ->
        let iname = "mj_fn_" ^ String.map (fun c ->
          if (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9') then c else '_') name in
        Buffer.add_string func_decls
          (Printf.sprintf "static Value %s(Value* args, int nargs, Value* caps, int ncaps);\n" iname);
        ignore inner
    | _ -> ()
  ) code;

  (* Function signature *)
  if chunk.name = "<main>" then
    emitln cg "static Value mj_main(void) {"
  else
    emitln cg (Printf.sprintf
      "static Value %s(Value* args, int nargs, Value* caps, int ncaps) {" fname);

  (* Stack: global with per-frame base pointer *)
  emitln cg "  Value stack[32]; int sp=0;";
  emitln cg "  #define PUSH(v) stack[sp++]=(v)";
  emitln cg "  #define POP()   stack[--sp]";
  emitln cg "  #define TOP()   stack[sp-1]";

  (* Variable map: name → index in vars array *)
  let vars : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let var_count = ref 0 in
  let get_var name =
    match Hashtbl.find_opt vars name with
    | Some i -> i
    | None ->
        let i = !var_count in
        Hashtbl.add vars name i;
        var_count := i + 1;
        i
  in

  (* Pre-scan: register params first so they get lowest indices *)
  List.iter (fun pname -> ignore (get_var pname)) params;
  (* Then scan all instructions *)
  Array.iter (function
    | STORE x | LOAD x -> ignore (get_var x)
    | STORE_GLOBAL x | LOAD_GLOBAL x -> ignore (get_var x)
    | _ -> ()
  ) code;

  (* Declare variables *)
  if !var_count > 0 then begin
    emit cg "  Value _vars_arr[64]; memset(_vars_arr,0,sizeof(_vars_arr)); Value *vars=_vars_arr; /* ";
    emit cg (string_of_int !var_count);
    emitln cg " */ if(!vars) exit(1);";
    (* Initialize all to nil *)
    for i = 0 to !var_count - 1 do
      emitln cg (Printf.sprintf "  vars[%d] = mk_nil();" i)
    done
  end;

  (* Bind function params: copy args[i] into vars[param_i] *)
  if params <> [] then begin
    List.iteri (fun i pname ->
      let idx = get_var pname in
      emitln cg (Printf.sprintf "  vars[%d] = (nargs > %d) ? args[%d] : mk_nil(); /* param %s */" idx i i pname)
    ) params
  end;

  (* Generate instructions *)
  for i = 0 to n - 1 do
    emitln cg (Printf.sprintf "  lbl_%d:;" i);
    let op = code.(i) in
    (match op with
    | PUSH_NUM f ->
        emitln cg (Printf.sprintf "  PUSH(mk_num(%s));" (
          if Float.is_integer f then string_of_int (int_of_float f) ^ ".0"
          else Printf.sprintf "%g" f))

    | PUSH_STR s ->
        emitln cg (Printf.sprintf "  PUSH(mk_str_copy(\"%s\"));" (c_escape s))

    | PUSH_BOOL b ->
        emitln cg (Printf.sprintf "  PUSH(mk_bool(%d));" (if b then 1 else 0))

    | PUSH_NIL ->
        emitln cg "  PUSH(mk_nil());"

    | LOAD x ->
        let idx = get_var x in
        emitln cg (Printf.sprintf "  PUSH(vars[%d]); /* %s */" idx x)

    | STORE x ->
        let idx = get_var x in
        emitln cg (Printf.sprintf "  vars[%d] = POP(); /* %s */" idx x)

    | LOAD_GLOBAL x | STORE_GLOBAL x ->
        let idx = get_var x in
        (match op with
         | LOAD_GLOBAL _ -> emitln cg (Printf.sprintf "  PUSH(vars[%d]); /* global %s */" idx x)
         | _ ->            emitln cg (Printf.sprintf "  vars[%d] = POP(); /* global %s */" idx x))

    | ADD ->
        emitln cg "  { Value b=POP(),a=POP();";
        emitln cg "    if(a.type==T_STR&&b.type==T_STR) PUSH(mk_str(str_concat(a.str,b.str)));";
        emitln cg "    else PUSH(mk_num(to_num(a)+to_num(b))); }"
    | SUB ->
        emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_num(to_num(a)-to_num(b))); }"
    | MUL ->
        emitln cg "  { Value b=POP(),a=POP();";
        emitln cg "    if(a.type==T_STR&&b.type==T_STR) PUSH(mk_str(str_concat(a.str,b.str)));";
        emitln cg "    else PUSH(mk_num(to_num(a)*to_num(b))); }"
    | DIV ->
        emitln cg "  { Value b=POP(),a=POP(); double d=to_num(b);";
        emitln cg "    if(d==0.0) mj_error(\"division by zero\");";
        emitln cg "    PUSH(mk_num(to_num(a)/d)); }"
    | MOD ->
        emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_num(fmod(to_num(a),to_num(b)))); }"
    | POW ->
        emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_num(pow(to_num(a),to_num(b)))); }"
    | NEG ->
        emitln cg "  { Value a=POP(); PUSH(mk_num(-to_num(a))); }"
    | CONCAT ->
        emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_str_copy(str_concat(val_to_str(a),val_to_str(b)))); }"

    | EQ  -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(val_eq(a,b))); }"
    | NEQ -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(!val_eq(a,b))); }"
    | LT  -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_num(a)<to_num(b))); }"
    | LTE -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_num(a)<=to_num(b))); }"
    | GT  -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_num(a)>to_num(b))); }"
    | GTE -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_num(a)>=to_num(b))); }"
    | AND -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_bool(a)&&to_bool(b))); }"
    | OR  -> emitln cg "  { Value b=POP(),a=POP(); PUSH(mk_bool(to_bool(a)||to_bool(b))); }"
    | NOT -> emitln cg "  { Value a=POP(); PUSH(mk_bool(!to_bool(a))); }"

    | JUMP n ->
        emitln cg (Printf.sprintf "  goto lbl_%d;" n)

    | JUMP_IF_FALSE n ->
        emitln cg (Printf.sprintf "  { Value c=POP(); if(!to_bool(c)) goto lbl_%d; }" n)

    | JUMP_IF_TRUE n ->
        emitln cg (Printf.sprintf "  { Value c=POP(); if(to_bool(c)) goto lbl_%d; }" n)

    | MAKE_ARRAY cnt ->
        emitln cg (Printf.sprintf "  { Value arr=mk_array(%d);" cnt);
        emitln cg (Printf.sprintf "    for(int _i=%d-1;_i>=0;_i--) arr.array->data[_i]=stack[sp-%d+_i];" cnt cnt);
        emitln cg (Printf.sprintf "    arr.array->len=%d; sp-=%d;" cnt cnt);
        emitln cg "    PUSH(arr); }"

    | GET_INDEX ->
        emitln cg "  { Value idx=POP(),arr=POP(); PUSH(array_get(arr,idx)); }"

    | SET_INDEX ->
        emitln cg "  { Value v=POP(),idx=POP(),arr=POP(); array_set(arr,idx,v); }"

    | ARRAY_LEN ->
        emitln cg "  { Value a=POP();";
        emitln cg "    if(a.type==T_ARRAY) PUSH(mk_num(a.array->len));";
        emitln cg "    else if(a.type==T_STR) PUSH(mk_num(strlen(a.str)));";
        emitln cg "    else mj_error(\"ARRAY_LEN: not an array\"); }"

    | MAKE_FUNC (name, params, inner_chunk) ->
        (* Generate the inner function recursively *)
        let inner_name = "mj_fn_" ^ String.map (fun c ->
          if (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9') then c else '_') name in
        (* We'll emit the inner chunk separately — collect for later *)
        (* For now emit a closure with no captures *)
        let nparams = List.length params in
        ignore (nparams, inner_chunk, inner_name);
        emitln cg (Printf.sprintf "  { Value caps[1]; caps[0]=mk_nil();");
        emitln cg (Printf.sprintf "    PUSH(mk_closure(%s, \"%s\", caps, 0)); }"
          inner_name (c_escape name))

    | CALL nargs ->
        emitln cg (Printf.sprintf "  { Value args_[%d];" (max nargs 1));
        emitln cg (Printf.sprintf "    for(int _i=%d-1;_i>=0;_i--) args_[_i]=stack[--sp];" nargs);
        emitln cg "    Value fn_=POP();";
        emitln cg "    if(fn_.type!=T_CLOSURE) mj_error(\"CALL: not a function\");";
        emitln cg (Printf.sprintf "    PUSH(fn_.closure->fn(args_,%d,fn_.closure->caps,fn_.closure->ncaps)); }" nargs)

    | RETURN ->
        emitln cg "  { Value _ret=POP(); return _ret; }"

    | CALL_BUILTIN (name, nargs) ->
        let tmp = fresh cg in
        emitln cg (Printf.sprintf "  { Value %s;" tmp);
        (match name, nargs with
        | "println", _ ->
            emitln cg (Printf.sprintf "    Value _pa[%d];" (max nargs 1));
            emitln cg (Printf.sprintf "    for(int _i=%d-1;_i>=0;_i--) _pa[_i]=stack[sp-%d+_i]; sp-=%d;" nargs nargs nargs);
            emitln cg (Printf.sprintf "    %s=builtin_println(_pa,%d);" tmp nargs)
        | "print", _ ->
            emitln cg (Printf.sprintf "    Value _pa[%d];" (max nargs 1));
            emitln cg (Printf.sprintf "    for(int _i=%d-1;_i>=0;_i--) _pa[_i]=stack[sp-%d+_i]; sp-=%d;" nargs nargs nargs);
            emitln cg (Printf.sprintf "    %s=builtin_print(_pa,%d);" tmp nargs)
        | "string", 1  -> emitln cg (Printf.sprintf "    %s=builtin_string(POP());" tmp)
        | "int", 1     -> emitln cg (Printf.sprintf "    %s=builtin_int(POP());" tmp)
        | "float", 1   -> emitln cg (Printf.sprintf "    %s=builtin_float_fn(POP());" tmp)
        | "length", 1 | "size", 1 ->
            emitln cg (Printf.sprintf "    %s=builtin_length(POP());" tmp)
        | "push!", 2 | "append!", 2 ->
            (* Inline push to avoid copy-by-value issues *)
            emitln cg (Printf.sprintf
              "    { Value _v=POP(),_a=POP(); if(_a.array->len>=_a.array->cap){int nc=_a.array->cap*2;Value*nd=(Value*)malloc(sizeof(Value)*nc);if(nd){memcpy(nd,_a.array->data,sizeof(Value)*_a.array->len);_a.array->data=nd;_a.array->cap=nc;}} _a.array->data[_a.array->len++]=_v; %s=mk_nil(); }"
              tmp)
        | "pop!", 1    -> emitln cg (Printf.sprintf "    %s=builtin_pop(POP());" tmp)
        | "sqrt", 1    -> emitln cg (Printf.sprintf "    %s=builtin_sqrt(POP());" tmp)
        | "abs", 1     -> emitln cg (Printf.sprintf "    %s=builtin_abs(POP());" tmp)
        | "floor", 1   -> emitln cg (Printf.sprintf "    %s=builtin_floor(POP());" tmp)
        | "ceil", 1    -> emitln cg (Printf.sprintf "    %s=builtin_ceil(POP());" tmp)
        | "round", 1   -> emitln cg (Printf.sprintf "    %s=builtin_round(POP());" tmp)
        | "mod", 2     ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_mod(_a,_b); }" tmp)
        | "max", 2     ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_max(_a,_b); }" tmp)
        | "min", 2     ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_min(_a,_b); }" tmp)
        | "zeros", 1   -> emitln cg (Printf.sprintf "    %s=builtin_zeros(POP());" tmp)
        | "sort", 1    -> emitln cg (Printf.sprintf "    %s=builtin_sort(POP());" tmp)
        | "uppercase", 1 -> emitln cg (Printf.sprintf "    %s=builtin_uppercase(POP());" tmp)
        | "lowercase", 1 -> emitln cg (Printf.sprintf "    %s=builtin_lowercase(POP());" tmp)
        | "isnothing", 1 -> emitln cg (Printf.sprintf "    %s=builtin_isnothing(POP());" tmp)
        | "typeof", 1  -> emitln cg (Printf.sprintf "    %s=builtin_typeof(POP());" tmp)
        | "contains", 2 ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_contains(_a,_b); }" tmp)
        | "open", 2    ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_open(_a,_b); }" tmp)
        | "write", 2   ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_write(_a,_b); }" tmp)
        | "writeln", 2 ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=builtin_writeln(_a,_b); }" tmp)
        | "read", 1    -> emitln cg (Printf.sprintf "    %s=builtin_read(POP());" tmp)
        | "close", 1   -> emitln cg (Printf.sprintf "    %s=builtin_close(POP());" tmp)
        | "__range2", 2 ->
            emitln cg (Printf.sprintf "    { Value _b=POP(),_a=POP(); %s=mk_range(to_num(_a),to_num(_b)); }" tmp)
        | "__range3", 3 ->
            emitln cg (Printf.sprintf "    { Value _c=POP(),_b=POP(),_a=POP(); %s=mk_range3(to_num(_a),to_num(_b),to_num(_c)); }" tmp)
        | _ ->
            emitln cg (Printf.sprintf "    /* TODO builtin %s/%d */ %s=mk_nil();" name nargs tmp);
            emitln cg (Printf.sprintf "    sp -= %d;" nargs))
        ;
        emitln cg (Printf.sprintf "    PUSH(%s); }" tmp)

    | POP -> emitln cg "  POP();"
    | DUP -> emitln cg "  PUSH(TOP());"
    | LINE _ -> ()
    );
  done;

  emitln cg "  #undef PUSH";
  emitln cg "  #undef POP";
  emitln cg "  #undef TOP";
  emitln cg "  return mk_nil();";
  emitln cg "}";
  emitln cg ""

(* ── Collect all chunks recursively with their params ── *)
let rec collect_chunks acc chunk params =
  let acc = acc @ [(chunk, params)] in
  Array.fold_left (fun a op ->
    match op with
    | MAKE_FUNC (_, ps, inner) -> collect_chunks a inner ps
    | _ -> a
  ) acc chunk.code

(* ── Main codegen entry ── *)
let codegen chunk outfile =
  let all_chunks = collect_chunks [] chunk [] in

  (* Forward declarations *)
  let fwd = Buffer.create 512 in
  let func_decls = Buffer.create 512 in

  (* Generate all functions *)
  let bodies = Buffer.create 4096 in

  List.iter (fun (ch, ps) ->
    let cg = new_cg () in
    gen_chunk ~params:ps cg ch func_decls;
    Buffer.add_buffer bodies cg.buf
  ) all_chunks;

  (* Assemble output *)
  Buffer.add_string fwd runtime_h;
  Buffer.add_string fwd "\n/* Forward declarations */\n";
  Buffer.add_buffer fwd func_decls;
  Buffer.add_string fwd "\n";
  Buffer.add_buffer fwd bodies;

  (* main() *)
  Buffer.add_string fwd {|
int main(int argc, char** argv) {
  (void)argc; (void)argv;
  mj_main();
  return 0;
}
|};

  let oc = open_out outfile in
  Buffer.output_buffer oc fwd;
  close_out oc

# MiniJulia — Kiến trúc 3 Giai đoạn

## Tổng quan Pipeline

```
source.jl
    │
    ├─── Phase 1 ──▶ Interpreter ──────────────▶ Output
    │
    ├─── Phase 2 ──▶ Compiler ──▶ Bytecode VM ─▶ Output
    │                              (.mjc file)
    │
    └─── Phase 3 ──▶ Compiler ──▶ C Codegen ──▶ gcc ──▶ Binary ──▶ Output
```

---

## Phase 1: Tree-Walk Interpreter

### Pipeline
```
source.jl ──▶ Lexer ──▶ Tokens ──▶ Parser ──▶ AST ──▶ Interpreter ──▶ Output
```

### Các module
| File | Chức năng |
|------|-----------|
| `lib/lexer.ml` | Tokenizer: chia source thành tokens (NUM, STR, IDENT, keyword...) |
| `lib/ast.ml` | Định nghĩa AST nodes: Expr, Stmt, BinOp, Call, FuncDef... |
| `lib/parser.ml` | Recursive descent parser: tokens → AST |
| `lib/interpreter.ml` | Tree-walk evaluator: duyệt AST và thực thi trực tiếp |
| `server/server.ml` | HTTP server thuần OCaml (Unix socket), phục vụ Web IDE |
| `web/index.html` | Frontend IDE: editor, output panel, file tree |

### Đặc điểm kỹ thuật
- **Scoping**: Linked list of hash tables (env chain)
- **Values**: OCaml variant type `VNum | VStr | VBool | VNil | VArray | VFunc`
- **Functions**: First-class, closure capture environment
- **Builtins**: ~40 built-in functions (println, push!, sqrt, open, read...)
- **Control flow**: if/else, while, for (range), break, continue, return

---

## Phase 2: Bytecode VM

### Pipeline
```
source.jl ──▶ Lexer ──▶ AST ──▶ Compiler ──▶ Bytecode ──▶ VM ──▶ Output
                                              (.mjc)
```

### Instruction Set (Stack-based, ~30 opcodes)

```
Constants:   PUSH_NUM f | PUSH_STR s | PUSH_BOOL b | PUSH_NIL
Variables:   LOAD x | STORE x | LOAD_GLOBAL x | STORE_GLOBAL x
Arithmetic:  ADD | SUB | MUL | DIV | MOD | POW | NEG
Comparison:  EQ | NEQ | LT | LTE | GT | GTE
Logic:       AND | OR | NOT
Strings:     CONCAT
Control:     JUMP n | JUMP_IF_FALSE n | JUMP_IF_TRUE n
Arrays:      MAKE_ARRAY n | GET_INDEX | SET_INDEX | ARRAY_LEN
Functions:   MAKE_FUNC | CALL n | RETURN | CALL_BUILTIN name/n
Stack:       POP | DUP
```

### Compiler (`compiler/compiler.ml`)
- **Single-pass** với backpatching cho jumps
- Mỗi function → một `chunk` (opcode array + metadata)
- Short-circuit evaluation cho AND/OR

### VM (`vm/vm.ml`)
- **Call stack**: Stack of frames, mỗi frame có `chunk + ip + env`
- **Value stack**: OCaml Stack module
- **Closures**: Capture environment tại thời điểm MAKE_FUNC
- **Serialization**: OCaml Marshal → `.mjc` bytecode file

### Bytecode file format (.mjc)
```
OCaml Marshal format:
  chunk {
    code:   opcode array
    name:   string          -- "<main>" hoặc function name
    source: string          -- source filename
  }
```

---

## Phase 3: Native C Compilation

### Pipeline
```
source.jl ──▶ Lexer ──▶ AST ──▶ Compiler ──▶ Bytecode ──▶ C Codegen ──▶ generated.c ──▶ gcc ──▶ binary
```

### C Codegen (`codegen/codegen.ml`)

Mỗi bytecode chunk → một C function. Cấu trúc generated code:

```c
// Runtime header (embedded)
typedef struct Value Value;   // tagged union
typedef struct Array Array;   // dynamic array

// Per-function pattern:
static Value mj_fn_fib(Value* args, int nargs, ...) {
    Value stack[32]; int sp=0;   // evaluation stack
    Value _vars_arr[64];         // local variables
    Value *vars = _vars_arr;
    
    // Generated instructions as labeled gotos:
    lbl_0:; PUSH(mk_num(0.0));
    lbl_1:; vars[0] = POP();
    lbl_2:; PUSH(vars[0]);
    ...
    return POP();
}

int main() { mj_main(); return 0; }
```

### Value representation (C struct)
```c
typedef enum { T_NUM, T_STR, T_BOOL, T_NIL, T_ARRAY, T_CLOSURE } VType;

struct Value {
    VType type;           // 4 bytes
    // padding: 4 bytes
    union {
        double  num;      // 8 bytes
        char*   str;
        int     boolean;
        Array*  array;
        Closure* closure;
    };
};
// sizeof(Value) = 16 bytes
```

### Key design decisions
- **goto-based control flow**: JUMP → `goto lbl_N` (tận dụng C optimizer)
- **Stack trên C stack**: `Value stack[32]` local per function call
- **Vars trên C stack**: `Value _vars_arr[64]` local per function call
- **Heap allocation**: Array data, strings, closures trên heap
- **Inline push!**: `realloc` thay thế bằng `malloc+memcpy` để tránh heap reuse

---

## Web IDE Architecture

```
Browser
  │  HTTP JSON
  ▼
server.ml (OCaml HTTP server, port 7777)
  │  POST /run  {code: "..."}
  │  write to /tmp/repl_input.jl
  │  exec main.exe /tmp/repl_input.jl
  │  read stdout/stderr
  └─▶ {status: "ok", output: "..."}
```

### Frontend (index.html — single file, ~600 LOC)
- **Editor**: `<textarea>` với line numbers sync
- **File system**: In-memory JS objects (không persist)
- **Examples**: Embedded JS strings
- **Run**: `fetch('/run', {method:'POST', body: JSON.stringify({code})})`

---

## Cấu trúc thư mục

```
minijulia-phase3/
├── bin/
│   └── main.ml          # CLI: parse args, dispatch to interpreter/VM/codegen
├── lib/
│   ├── ast.ml            # AST type definitions
│   ├── lexer.ml          # Tokenizer
│   ├── parser.ml         # Recursive descent parser
│   └── interpreter.ml    # Tree-walk interpreter + builtins
├── compiler/
│   └── compiler.ml       # AST → Bytecode compiler
├── vm/
│   ├── bytecode.ml       # Opcode definitions + disassembler
│   └── vm.ml             # Stack VM + serialize/deserialize
├── codegen/
│   └── codegen.ml        # Bytecode → C code generator
├── server/
│   └── server.ml         # HTTP server for Web IDE
├── web/
│   └── index.html        # Frontend IDE
├── examples/
│   ├── demo.jl
│   ├── fibonacci.jl
│   ├── prime.jl
│   ├── bubble_sort.jl
│   ├── file_io.jl
│   └── bench.jl
├── Dockerfile            # Alpine + OCaml + gcc
├── Makefile
└── dune-project
```

---

## So sánh 3 phases

| Tiêu chí | Phase 1 | Phase 2 | Phase 3 |
|----------|---------|---------|---------|
| Cách thực thi | Tree-walk | Stack VM | Native binary |
| Parse mỗi lần chạy | ✅ | ✅ | ✅ (compile time) |
| Precompile | ❌ | ✅ (.mjc) | ✅ (binary) |
| Tốc độ (bench) | baseline (0.006s) | 0.6x chậm hơn (0.010s) | 7.7x nhanh hơn (0.0008s) |
| Dependencies khi run | OCaml runtime | OCaml runtime | Không (standalone) |
| File output | — | `.mjc` | ELF binary |
| Độ phức tạp code | Thấp | Trung bình | Cao |

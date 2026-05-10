# Những Điểm Kỹ Thuật Chính — MiniJulia Project

## 1. Lexer & Parser

### Recursive Descent Parser
Parser viết tay không dùng parser generator (menhir/ocamlyacc). Ưu điểm: kiểm soát hoàn toàn error message, dễ debug, không cần học DSL mới.

**Mutual recursion trong OCaml**:
```ocaml
(* Cần let rec khi hàm A gọi B mà B được định nghĩa sau A *)
let rec eat s t = ...
and parse_expr s = ...
and parse_stmt s = ...
```

### Operator Precedence
Implement bằng Pratt parsing (precedence climbing):
- Mỗi operator có precedence level
- `parse_expr` nhận `min_prec` parameter
- Loop tiếp tục khi operator tiếp theo có precedence cao hơn

---

## 2. OCaml Pattern Matching cho Interpreter

OCaml's pattern matching là công cụ lý tưởng cho tree-walk interpreter:

```ocaml
let rec eval_expr env = function
  | Num f         -> VNum f
  | BinOp(Add, a, b) -> VNum (to_float (eval_expr env a) +. to_float (eval_expr env b))
  | Call(name, args) -> call_function env name (List.map (eval_expr env) args)
  | ...
```

**Exhaustiveness checking**: OCaml compiler cảnh báo nếu thiếu case → không bao giờ bỏ sót AST node.

---

## 3. Bytecode VM Design

### Stack-based vs Register-based
Dự án dùng **stack-based** (như JVM, CPython) thay vì register-based (như Lua 5):
- Stack-based: đơn giản hơn, compiler dễ viết, instruction nhỏ gọn
- Register-based: nhanh hơn vì ít memory ops, nhưng compiler phức tạp hơn

### Backpatching
Compiler single-pass cần backpatching cho forward jumps:
```ocaml
(* Emit JUMP_IF_FALSE với placeholder 0 *)
let skip_pos = current_pos s in
emit s (JUMP_IF_FALSE 0);

(* Compile body *)
compile_stmts s body;

(* Patch placeholder với địa chỉ thật *)
patch_jump s skip_pos (current_pos s)
```

### Closure Representation
```ocaml
| MAKE_FUNC (name, params, chunk) ->
    (* Capture current environment at definition time *)
    push (VFunc (name, params, chunk, current_env))
```

---

## 4. C Code Generation

### goto-based Control Flow
Bytecode JUMP instructions → C `goto` labels:
```c
// JUMP_IF_FALSE 15
{ Value c=POP(); if(!to_bool(c)) goto lbl_15; }

// JUMP 7
goto lbl_7;
```
Đây là kỹ thuật "computed goto" phổ biến trong VM implementation (CPython cũng dùng).

### Tagged Union cho Value Type
```c
struct Value {
    VType type;   // tag
    union {       // payload
        double num;
        char*  str;
        Array* array;
        ...
    };
};
```
`sizeof(Value) = 16` bytes trên x86-64 (4 + 4 padding + 8).

### Memory Management trong C Codegen
Key insight từ bug debugging:

**Vấn đề**: `vars[]` size được tính bằng `var_count` (số biến unique). Nhưng `params` được register vào hashtable **sau** pre-scan → index bị lệch, access `vars[N]` vượt bounds → buffer overflow vào memory kề.

**Fix**: Luôn dùng size cố định (64) thay vì exact count:
```c
Value _vars_arr[64];
memset(_vars_arr, 0, sizeof(_vars_arr));
Value *vars = _vars_arr;
```

### Heap vs Stack Allocation
- **Stack allocation** (`Value arr[N]`): nhanh, tự động cleanup, nhưng limited size và bị deallocate khi function return
- **Heap allocation** (`malloc`): linh hoạt, persist sau function return, nhưng cần quản lý lifetime
- **Lesson**: Array data phải trên heap (persist sau push), stack/vars có thể trên C stack

---

## 5. Debugging Strategies

### Binary Search Bug Isolation
Thay vì debug toàn bộ, thu hẹp phạm vi bằng cách thêm checkpoint:
```python
# Thêm fprintf(stderr) vào generated C
# Kiểm tra từng label để tìm điểm corrupt
for n in range(61, 81):
    if f'lbl_{n}:;' in line:
        insert_debug(f"lbl_{n} data[0]=%g", vars[2].array->data[0].num)
```

### Address-based Debug
Khi nghi ngờ pointer corruption:
```c
fprintf(stderr, "arr=%p data=%p len=%d\n",
    (void*)arr.array, (void*)arr.array->data, arr.array->len);
```
Nếu address thay đổi giữa 2 lần print → pointer bị overwrite.

### Hypothesis Testing
Mỗi lần debug phải có hypothesis rõ ràng:
1. "Tôi nghĩ vấn đề là X"
2. "Nếu đúng, thì Y sẽ xảy ra khi tôi test Z"
3. Test → kết quả xác nhận hay bác bỏ

Không nên thay đổi nhiều thứ cùng lúc — mỗi lần chỉ thay một biến.

---

## 6. OCaml Build System (Dune)

### Library dependencies
```lisp
; Tránh circular dependency: vm không depend compiler
(library (name vm_lib) (libraries minijulia_lib))
(library (name compiler_lib) (libraries minijulia_lib vm_lib))
(library (name codegen_lib) (libraries vm_lib compiler_lib))
(executable (name main) (libraries minijulia_lib vm_lib compiler_lib codegen_lib unix))
```

### Wrapped vs Unwrapped
```lisp
(wrapped false)  ; Cho phép dùng module name trực tiếp thay vì Vm_lib.Vm
```

---

## 7. WSL2 Specifics

### mydocker trên WSL2
- Network namespace (`CLONE_NEWNET`) partial support → suppress error, tiếp tục
- Output buffering: stdout của process trong container bị buffer → thêm `&& sync`
- File permissions: files tạo bởi root trong container → `sudo chmod 666`
- Stack size: musl/Alpine có stack nhỏ hơn glibc → cẩn thận với large local arrays

### Port forwarding
mydocker không hỗ trợ `-p port:port`, nhưng WSL2 tự động forward ports từ container ra Windows host → `http://localhost:7777` accessible từ browser Windows.

---

## 8. Language Design Decisions

### 1-based Array Indexing (như Julia)
```julia
arr = [10, 20, 30]
arr[1]  # = 10, không phải arr[0]
```
Ảnh hưởng đến codegen: `GET_INDEX` phải trừ 1 trước khi access C array.

### `*` cho String Concatenation (như Julia)
```julia
"Hello" * " " * "World"  # = "Hello World"
```
Compiler phải detect khi cả 2 operand là string và emit CONCAT thay vì MUL.

### Semicolon Optional
```julia
a = 1; b = 2  # valid
a = 1
b = 2         # cũng valid
```
Lexer treat newline và `;` như nhau khi ở cuối statement.

---

## 9. Performance Profile

### Tại sao VM (Phase 2) chậm hơn Interpreter (Phase 1)?

OCaml native-compiled interpreter duyệt AST trực tiếp — OCaml compiler optimize pattern matching rất tốt. Bytecode VM thêm overhead:
- Decode opcode (pattern match trên variant)
- Stack push/pop (Hashtbl lookup cho variables)
- Function call overhead

VM sẽ nhanh hơn khi:
- Code chạy nhiều lần (amortize parse cost với `.mjc`)
- Dùng register-based VM
- Hoặc phase 3: compile ra native binary

### Native (Phase 3) nhanh hơn vì:
- Không có dispatch loop — mỗi instruction là C code trực tiếp
- gcc -O2 optimize: dead code elimination, register allocation, inlining
- Không có OCaml GC overhead

---

## 10. Tổng kết

| Kỹ thuật | Học được |
|----------|---------|
| Lexer/Parser từ đầu | Recursive descent, operator precedence, error recovery |
| Tree-walk interpreter | Environment chain, closure, first-class functions |
| Bytecode compiler | Single-pass, backpatching, stack frame |
| Stack VM | Dispatch loop, call stack, serialization |
| C codegen | goto-based CF, tagged union, memory layout |
| Debugging | Binary search, address tracking, hypothesis testing |
| OCaml | Pattern matching, variant types, dune build, mutual recursion |
| WSL2/Container | mydocker, Alpine Linux, musl libc, stdout buffering |

> **Insight lớn nhất**: Compiler engineering là về việc transform representation. Mỗi phase transform một intermediate representation thành dạng gần machine hơn. Debug hiệu quả nhất là isolate đúng tầng đang có vấn đề.

# Nhật ký Dự án MiniJulia

## Điểm xuất phát

Dự án bắt đầu với source code của **mydocker** — một container runtime tối giản viết bằng Go. Mục tiêu: xây dựng một ngôn ngữ lập trình Julia-like từ đầu, chạy trong isolated container, với 3 giai đoạn tiến hóa từ interpreter → bytecode VM → native compilation.

---

## Giai đoạn 0: Dựng môi trường

### Build mydocker trên WSL2
- Compile Go source thành 2 binary: `mydocker.real` (CLI) và `mydockerd.real` (daemon)
- Fix lỗi network namespace trên WSL2: suppress `move veth to netns` error thay vì fatal
- Tạo Docker image `minimlc-env:v1` từ Alpine + OCaml + gcc + dune

### Môi trường
- Windows 11 + WSL2 Ubuntu 24 (kernel 6.6.87.2-microsoft-standard-WSL2)
- mydocker chạy container Alpine Linux
- OCaml 4.14.2, dune build system, gcc (Alpine musl)

---

## Phase 1: Tree-Walk Interpreter

### Thiết kế
Viết từ đầu hoàn toàn bằng OCaml thuần:
- **Lexer**: hand-written tokenizer
- **Parser**: recursive descent, không dùng parser generator
- **AST**: OCaml variant types
- **Interpreter**: pattern matching trên AST nodes

### Các bug gặp phải và cách fix

**Bug 1: Comment trong string literal**
```ocaml
(* lexer.ml line 46 *)
adv (); (* skip opening " *)   ← lỗi: OCaml thấy comment chưa đóng
adv ();                         ← fix: bỏ comment trong string
```

**Bug 2: Mutual recursion trong parser**
```ocaml
let eat s t = ...        ← lỗi: show_tok dùng trước khi định nghĩa
let rec eat s t = ...    ← fix: thêm rec
```

**Bug 3: Variable scope conflict trong fibonacci**
```julia
# Dùng biến i cho cả outer loop và inner function
# fix: đổi thành fa, fb, fk, ft trong fib function
```

### Kết quả Phase 1
- Chạy đúng 5 examples: demo, fibonacci, prime, bubble_sort, file_io
- Web IDE hoạt động tại localhost:7777
- Server viết bằng pure OCaml Unix socket (không deps ngoài)

---

## Phase 2: Bytecode VM

### Thiết kế
- **Instruction set**: Stack-based, ~30 opcodes, tham khảo CPython/Lua
- **Compiler**: Single-pass với backpatching cho jumps
- **VM**: Call stack với frames, mỗi frame có chunk + ip + env
- **Serialization**: OCaml Marshal → `.mjc` files

### Các bug gặp phải và cách fix

**Bug 1: Circular dependency**
```
vm.ml gọi Compiler.compile_program → circular dep
fix: bỏ run_source/run_file khỏi vm.ml, để main.ml xử lý
```

**Bug 2: `let rec` cho value_eq**
```ocaml
let run_chunk ...     ← lỗi: value_eq chưa định nghĩa
let rec run_chunk ... ← fix
```

**Bug 3: For loop index 0-based vs 1-based**
```
MiniJulia dùng 1-based indexing
For loop internal iterator phải bắt đầu từ 1, dùng LTE thay LT
```

**Bug 4: Output buffer**
```bash
# mydocker buffer stdout, thêm sync để flush
make run FILE=x.jl   → sh -c "... && sync"
```

### Kết quả Phase 2
- VM chạy đúng tất cả examples
- Benchmark: VM ~0.6x interpreter (OCaml native đã rất nhanh)
- `.mjc` bytecode files hoạt động
- `make disasm` hiển thị bytecode listing

---

## Phase 3: Native C Compilation

### Thiết kế
- Mỗi bytecode chunk → một C function
- Control flow dùng `goto lbl_N` (tận dụng C goto label)
- Runtime embedded trong generated C file (~400 LOC C header)
- Compile với `gcc -O2`

### Hành trình debug Phase 3 (phần khó nhất)

Phase 3 gặp một bug dai dẳng với array+function combination. Quá trình debug kéo dài và có nhiều bước quan trọng:

**Vấn đề**: `push!(fibs, fib(jj))` → array values bị corrupt khi đọc lại

**Các hypothesis đã thử (sai)**:
1. Stack overflow do `Value stack[1024]` quá lớn → giảm xuống 256, 64, 32
2. Heap allocation cho stack bị memory leak → malloc/free
3. Global stack với base pointer → phức tạp, không fix
4. `static` stack bị share giữa function calls → đúng một phần
5. `vars[]` overflow → tăng từ exact count lên +16, lên 64
6. `realloc` trong array_push → thay bằng malloc+memcpy
7. `mk_str_copy` double malloc → thay bằng `mk_str`
8. `calloc` cho vars → malloc+memset

**Root cause thật sự** (tìm ra sau debug granular):
- Data trong array **đúng** tại mọi điểm trong push loop
- Corrupt xảy ra **trong print loop** khi `builtin_length(fibs)` được gọi
- **`BEF_LEN` lần 1**: data[0]=0 ✅
- **`BEF_LEN` lần 2**: data[0]=5.05748e-309 ❌
- Điều duy nhất xảy ra giữa 2 lần: thân print loop lần 1
- `array_get` trả về đúng, `builtin_string` nhận đúng input
- **Bug thật**: `vars[]` size = exact `var_count` = 5, nhưng có `vars[5]` và `vars[6]` được access → buffer overflow!

**Fix cuối cùng**:
```ocaml
(* Emit vars với size cố định 64 thay vì exact count *)
emit cg "  Value _vars_arr[64];";
emit cg "  memset(_vars_arr,0,sizeof(_vars_arr));";
emit cg "  Value *vars=_vars_arr;";
```

**Lesson**: Pre-scan đếm var_count đúng, nhưng `params` được register sau pre-scan → index bị lệch → overflow vào memory kề.

### Kết quả Phase 3
- Native binaries chạy đúng: demo, fibonacci, prime, bubble_sort, file_io
- UTF-8 string trong C có warning hex escape nhưng chạy đúng trên browser
- Native speedup ~6x so với interpreter trên bench.jl

---

## Fresh Install Test

Sau khi hoàn thành, test lại từ môi trường sạch hoàn toàn:

1. Xóa tất cả code và mydocker cũ
2. Copy `mydocker.real` + `mydockerd.real` từ Downloads
3. Copy `minijulia-phase3/` từ Downloads
4. `sudo mydocker.real build -t minimlc-env:v1 .`
5. `make compile && make server`

**Kết quả**: Tất cả examples chạy đúng, Web IDE hoạt động hoàn hảo.

---

## Timeline tổng quan

```
  ├── Setup mydocker trên WSL2
  ├── Phase 1: Lexer + Parser
  └── Phase 1: Interpreter cơ bản
  ├── Fix bugs lexer/parser
  ├── Thêm builtins (file I/O, string, math)
  ├── Web IDE server
  └── Phase 1 hoàn thành ✅
  ├── Phase 2: Bytecode design
  ├── Phase 2: Compiler + VM
  ├── Fix circular deps
  └── Phase 2 hoàn thành ✅
  ├── Phase 3: C codegen skeleton
  ├── Fix param binding
  ├── Debug array corruption (dài nhất)
  ├── Fix vars[] overflow
  └── Phase 3 hoàn thành ✅
  └── Fresh install test

```

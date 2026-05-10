# interpreter-miniJulia-compiler-Ocaml

Ngôn ngữ lập trình Julia-like viết từ đầu bằng OCaml, chạy trong container runtime tự build (mydocker). Ba giai đoạn tiến hóa từ interpreter đến native compiler, kèm Web IDE chạy trên browser.

## Ba giai đoạn

| Giai đoạn | Mô tả | Thư mục chính |
|-----------|-------|---------------|
| Phase 1 | Tree-walk interpreter + Web IDE | `lib/`, `server/`, `web/` |
| Phase 2 | Bytecode VM + file `.mjc` | `compiler/`, `vm/` |
| Phase 3 | Native C codegen → gcc → binary | `codegen/` |

## Chạy nhanh

```bash
# 1. Cài mydocker
sudo cp mydocker.real mydockerd.real /usr/local/bin/
sudo chmod +x /usr/local/bin/mydocker.real /usr/local/bin/mydockerd.real

# 2. Khởi động daemon
sudo mydockerd.real &

# 3. Build Docker image (chỉ lần đầu)
cd minijulia-phase3
sudo mydocker.real build -t minimlc-env:v1 .

# 4. Compile OCaml tools
make compile

# 5. Mở Web IDE
make server
# Truy cập http://localhost:7777
```

## Benchmark (examples/bench.jl)

| Mode | Thời gian | Speedup |
|------|-----------|---------|
| Interpreter | 0.006s | baseline |
| Bytecode VM | 0.010s | 0.6x |
| Native binary | 0.0008s | **7.7x** |

## Yêu cầu

- Windows 10/11 + WSL2 (Ubuntu 22.04+)
- `mydocker.real` + `mydockerd.real` (có sẵn trong repo)
- Kết nối internet (để pull Alpine Linux image)

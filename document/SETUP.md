# MiniJulia — Hướng dẫn Setup và Sử dụng

## Yêu cầu hệ thống

- Windows 10/11 với WSL2 (Ubuntu 22.04+)
- RAM: 4GB+
- Kết nối internet (lần đầu để build Docker image)

---

## Bước 1: Cài mydocker

Từ thư mục chứa project, copy 2 file binary vào WSL2:

```bash
sudo cp /mnt/c/path/to/mydocker.real /usr/local/bin/
sudo cp /mnt/c/path/to/mydockerd.real /usr/local/bin/
sudo chmod +x /usr/local/bin/mydocker.real /usr/local/bin/mydockerd.real
```

> **Lưu ý:** `mydocker.real` là CLI tool, `mydockerd.real` là daemon quản lý container.

---

## Bước 2: Khởi động daemon

```bash
sudo /usr/local/bin/mydockerd.real &
```

Chờ thấy dòng:
```
mydockerd listening on /var/run/mydocker.sock
```

> Mỗi lần mở terminal mới cần chạy lại lệnh này nếu daemon chưa chạy.

---

## Bước 3: Copy code về WSL2

```bash
# Thay đường dẫn tương ứng với vị trí code của bạn
cp -r /mnt/c/path/to/minijulia-phase3 ~/
cd ~/minijulia-phase3
```

---

## Bước 4: Build Docker image

Chỉ cần làm **một lần duy nhất**:

```bash
sudo /usr/local/bin/mydocker.real build -t minimlc-env:v1 .
```

Quá trình này tải Alpine Linux và cài OCaml, mất khoảng 2-5 phút tùy tốc độ mạng.

---

## Bước 5: Compile source code

```bash
make compile
```

Output mong đợi:
```
Build OK
```

---

## Bước 6: Chạy Web IDE

```bash
make server
```

Mở browser Windows và vào: **http://localhost:7777**

---

## Trải nghiệm Web IDE

### Giao diện
- **Sidebar trái**: danh sách file, examples có sẵn, quick snippets
- **Editor giữa**: soạn code MiniJulia, hỗ trợ Tab, Ctrl+S
- **Output panel dưới**: kết quả chạy
- **Status bar**: vị trí cursor, trạng thái

### Phím tắt
| Phím | Chức năng |
|------|-----------|
| `Ctrl+Enter` | Chạy code |
| `Ctrl+S` | Lưu file |
| `Tab` | Indent 4 spaces |

### Chạy thử examples
Click vào sidebar:
1. **demo.jl** — kiểu dữ liệu, toán tử, mảng, hàm
2. **fibonacci.jl** — dãy Fibonacci iterative
3. **prime.jl** — sàng số nguyên tố
4. **bubble_sort.jl** — thuật toán sắp xếp
5. **file_io.jl** — đọc/ghi file

---

## Chạy thử Phase 3 (Native Compilation)

### Compile ra binary native
```bash
make build FILE=examples/fibonacci.jl
```

Output:
```
Generated C: examples/fibonacci.c
Compiled:    examples/fibonacci
```

### Chạy binary trực tiếp
```bash
sudo /usr/local/bin/mydocker.real run \
  -v ~/minijulia-phase3:/workspace \
  minimlc-env:v1 \
  sh -c "cd /workspace && ./examples/fibonacci"
```

### Xem generated C code
```bash
make dump-c FILE=examples/fibonacci.jl
```

### Benchmark 3 modes
```bash
make bench FILE=examples/bench.jl
```

Output ví dụ:
```
Benchmark: examples/bench.jl

Interpreter: 0.006s
Bytecode VM: 0.010s
Native bin:  0.001s

Native speedup: 6.0x
```

---

## Tất cả lệnh make

| Lệnh | Mô tả |
|------|-------|
| `make compile` | Build OCaml tools |
| `make server` | Khởi động Web IDE tại localhost:7777 |
| `make run FILE=f.jl` | Chạy file với VM |
| `make build FILE=f.jl` | Compile ra native binary |
| `make disasm FILE=f.jl` | Xem bytecode disassembly |
| `make dump-c FILE=f.jl` | Xem generated C code |
| `make bench FILE=f.jl` | Benchmark 3 modes |
| `make clean` | Xóa build artifacts |

---

## Troubleshooting

### Lỗi "daemon not running"
```bash
sudo /usr/local/bin/mydockerd.real &
```

### Lỗi "EADDRINUSE" (port 7777 bị chiếm)
```bash
sudo kill -9 $(sudo ss -tlnp | grep 7777 | grep -oP 'pid=\K[0-9]+')
make server
```

### Lỗi "image not found: minimlc-env:v1"
```bash
sudo /usr/local/bin/mydocker.real build -t minimlc-env:v1 .
```

### Files trong examples/ bị Permission denied
```bash
sudo chmod 666 ~/minijulia-phase3/examples/*.jl
```

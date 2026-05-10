# mydocker — Kỹ thuật Build và Hoạt động

## 2 file binary được sinh ra như thế nào

mydocker source code Go có 2 entry point riêng biệt. Mỗi entry point compile thành 1 binary độc lập:

```
cmd/mydocker/main.go   ──▶  go build  ──▶  mydocker.real   (CLI,    ~7.3MB)
cmd/mydockerd/main.go  ──▶  go build  ──▶  mydockerd.real  (Daemon, ~7.9MB)
```

```bash
cd ~/mydocker
go build -o mydocker.real  ./cmd/mydocker/
go build -o mydockerd.real ./cmd/mydockerd/
```

`go build` compile + link tĩnh toàn bộ Go runtime (GC, goroutine scheduler, reflection) vào binary — không cần shared library, copy sang máy khác chạy thẳng.

---

## Kiến trúc client-daemon

```
User
  │
  ▼
mydocker.real  (CLI)
  │
  │  HTTP over Unix socket
  │  /var/run/mydocker.sock
  ▼
mydockerd.real  (Daemon)
  │
  ├── /var/lib/mydocker/images/       ← extracted image layers
  ├── /var/lib/mydocker/containers/   ← OCI bundles
  └── Runtime: namespaces + exec
```

---

## Cấu trúc source

```
mydocker/
├── cmd/
│   ├── mydocker/main.go      # CLI: parse flags, gọi client
│   └── mydockerd/main.go     # Daemon: mở Unix socket, serve requests
├── client/
│   └── client.go             # HTTP-over-Unix-socket đến daemon
├── daemon/
│   ├── daemon.go             # Route requests đến handlers
│   ├── container.go          # create/start/stop/remove container
│   └── network.go            # veth pair, network namespace
├── image/
│   ├── image.go              # Layer management
│   └── pull.go               # OCI Registry API v2
├── runtime/
│   └── runtime.go            # OCI bundle, Linux namespaces, exec
└── go.mod
```

---

## Luồng `mydocker run`

```
mydocker.real run -v /host:/workspace alpine sh -c "..."
  │
  ├── 1. Parse: image="alpine", volumes=["/host:/workspace"], cmd=["sh","-c","..."]
  │
  ├── 2. client.go: POST /containers/create
  │         → daemon tạo container ID, chuẩn bị bundle dir
  │
  └── 3. client.go: POST /containers/{id}/start
            │
            daemon/container.go:
            ├── Pull "alpine" nếu chưa có trong image store
            ├── Extract layers → /var/lib/mydocker/containers/{id}/bundle/rootfs/
            ├── Tạo config.json (OCI Runtime Spec)
            ├── Bind mount volumes vào rootfs
            └── runtime.go: clone() với namespace flags + exec cmd
```

---

## OCI Bundle

```
/var/lib/mydocker/containers/{id}/bundle/
├── rootfs/           ← Alpine filesystem (extracted từ image layers)
└── config.json       ← OCI Runtime Spec
```

`config.json` chỉ định namespaces, mounts, process:

```json
{
  "process": { "args": ["sh", "-c", "..."] },
  "root":    { "path": "rootfs" },
  "mounts":  [ { "destination": "/workspace", "source": "/host", "type": "bind" } ],
  "linux": {
    "namespaces": [
      { "type": "pid"   },
      { "type": "mount" },
      { "type": "uts"   }
    ]
  }
}
```

---

## Linux Namespaces

| Namespace | Flag | Tác dụng |
|-----------|------|---------|
| PID | `CLONE_NEWPID` | Container có PID namespace riêng, process đầu = PID 1 |
| Mount | `CLONE_NEWNS` | `pivot_root` vào rootfs, không thấy host filesystem |
| UTS | `CLONE_NEWUTS` | Hostname riêng |
| Network | `CLONE_NEWNET` | ⚠️ Partial trên WSL2 |

`runtime.go` dùng `syscall.SysProcAttr` để set namespace flags khi fork:

```go
cmd.SysProcAttr = &syscall.SysProcAttr{
    Cloneflags: syscall.CLONE_NEWPID |
                syscall.CLONE_NEWNS  |
                syscall.CLONE_NEWUTS,
}
```

---

## Fix WSL2: Network Namespace

WSL2 kernel không hỗ trợ đầy đủ `CLONE_NEWNET` + veth pair. `netlink.LinkSetNsPid` trả về `operation not permitted`.

```go
// Trước — fatal crash:
if err := moveVethToNetns(veth, pid); err != nil {
    log.Fatalf("move veth to netns: %v", err)
}

// Sau — warning, tiếp tục:
if err := moveVethToNetns(veth, pid); err != nil {
    log.Printf("warning: move veth to netns: %v", err)
    // container chạy với host network stack
}
```

Container không có network isolation nhưng vẫn chạy được — đủ cho mục đích project.

---

## Volume Mount: Bind Mount

```go
// daemon/container.go
for _, vol := range volumes {
    host, container := split(vol, ":")
    target := filepath.Join(rootfs, container)
    os.MkdirAll(target, 0755)
    syscall.Mount(host, target, "", syscall.MS_BIND|syscall.MS_REC, "")
}
```

Bind mount **không copy file** — kernel map trực tiếp host directory vào container mount namespace. Write từ container xuất hiện ngay trên host và ngược lại. Đây là lý do `make compile` trong container tạo binary và file xuất hiện ngay tại `~/minijulia-phase3/_build/` trên WSL2.

---

## Image Pull: OCI Distribution Spec v2

```
pull.go thực hiện 4 bước:

1. GET https://auth.docker.io/token
        ?service=registry.docker.io
        &scope=repository:{name}:pull
   ← Bearer token

2. GET https://registry-1.docker.io/v2/{name}/manifests/{tag}
        Authorization: Bearer {token}
   ← JSON manifest: danh sách layer digests

3. Với mỗi digest:
   GET https://registry-1.docker.io/v2/{name}/blobs/sha256:{digest}
   ← tar.gz layer

4. Extract từng layer vào /var/lib/mydocker/images/{name}/
   (overlay: layer sau đè lên layer trước)
```

---

## Giới hạn trên WSL2

| Feature | Docker | mydocker | Lý do |
|---------|--------|---------|-------|
| Network isolation | ✅ | ⚠️ | `CLONE_NEWNET` partial trên WSL2 |
| Volume mount | ✅ | ✅ | Bind mount hoạt động đầy đủ |
| Image pull | ✅ | ✅ | OCI Registry API v2 |
| Interactive TTY `-it` | ✅ | ❌ | PTY allocation chưa implement |
| Port mapping `-p` | ✅ | ❌ | Không cần — WSL2 tự forward ports |
| Multi-stage build | ✅ | ❌ | Dockerfile parser chưa hỗ trợ |

> WSL2 tự forward tất cả ports từ Linux host ra Windows — `http://localhost:7777` accessible từ browser Windows mà không cần `-p 7777:7777`.
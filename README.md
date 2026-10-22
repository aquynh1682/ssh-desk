# SSH Desk

App macOS native (dùng cá nhân) để quản lý hồ sơ máy chủ, mở SSH trong Warp, truyền file kiểu Xftp qua OpenSSH, và vài công cụ vận hành đi kèm (SSH Keys, port forward, Project Analyst, Monitor). Không backend, không tài khoản, không telemetry; mọi thứ chạy local.

## Yêu cầu
- macOS 14 trở lên (đã dùng trên macOS 27, arm64).
- Command Line Tools (không cần Xcode.app) — Swift 6 + SwiftPM.
- [Warp](https://www.warp.dev) để mở SSH.
- Windows App (`com.microsoft.rdc.macos`) — tuỳ chọn, chỉ cần khi có máy Windows.
- OpenSSH có sẵn của macOS (`/usr/bin/ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-copy-id`).

## Cài đặt
```
make install
```
Lệnh này build `.app` (ký ad-hoc, không notarize) rồi cài vào `/Applications/SSH Desk.app`. **Phải thoát app (⌘Q) trước**, nếu app đang chạy lệnh sẽ dừng. Sau đó mở bằng icon (Launchpad/Spotlight/Dock). Chạy lại `make install` để cập nhật.

Các lệnh khác: `make check` (lint + build + test), `make run`, `make app`. Xem [docs/TESTING.md](docs/TESTING.md).

## Tính năng
- **Máy chủ + thư mục:** thêm/sửa/xoá/nhân bản, tìm kiếm, môi trường (DEV/UAT/STG/PROD/OTHER), yêu thích, bastion (ProxyJump), import alias có sẵn từ `~/.ssh/config` (chỉ đọc). Thư mục ở sidebar, kéo host vào thư mục.
- **Mở Warp:** sinh Tab Config và mở tab Warp chạy `ssh`; không có Warp thì Copy lệnh SSH. Click 1 lần = chọn, double-click / Return = mở.
- **Tự đăng nhập bằng password:** tuỳ chọn lưu password trong Keychain cho từng host; Warp đăng nhập qua helper `SSH_ASKPASS` (env chỉ chứa tham chiếu, không chứa password).
- **Truyền file kiểu Xftp:** hai khung (Mac | server), tab cho từng server, kéo thả, hàng đợi (huỷ, thử lại, ghi đè/đổi tên/bỏ qua), tạo thư mục / đổi tên / xoá trên server. Dùng `scp` (giao thức SFTP) và `sftp` qua một kết nối ControlMaster mỗi tab.
- **SSH Keys:** liệt kê key trong `~/.ssh` (chỉ đọc `*.pub`), tạo key mới, "Cài key lên server" (`ssh-copy-id`).
- **Port forward (-L):** lưu danh sách forward theo host, Mở/Dừng tunnel riêng, hiển thị trạng thái.
- **Project Analyst:** quét một thư mục server (Linux), dựng bản đồ kết nối giữa các server, thử kết nối TCP, lưu lịch sử, xuất báo cáo Markdown/CSV.
- **Monitor:** lưới thẻ CPU / RAM / swap / đĩa / load / uptime theo thư mục (Linux).
- **Máy Windows:** khai báo host RDP, mở bằng Windows App qua file `.rdp`; tuỳ chọn copy mật khẩu lên clipboard khi mở (tự xoá).
- **Xuất / nhập:** danh sách máy chủ ra file JSON `*.sshdesk.json` (không có secret) và nhập lại có xem trước.
- **Cài đặt (đang hoàn thiện):** ⌘, hoặc mục "Cài đặt" ở sidebar — mặc định Warp, truyền file, SSH config, bảo mật, Analyst, Monitor, Windows App, dữ liệu.
- **Vòng đời app, phím tắt (đang hoàn thiện):** hỏi xác nhận khi thoát lúc còn job/tunnel/Monitor/Analyst; ⌘N, ⌘F, ⌘D, ⌘Return, ⌘E, ⌘1…⌘6.

### Trạng thái kiểm chứng
Tất cả logic có test tự động. Nhưng nhiều tính năng mới chỉ chạy với sshd tạm ở `127.0.0.1` và **chưa được thử tay với server thật** (đánh dấu `[~]` trong [plan.md](plan.md)):

| Tính năng | Đã thử thật | Còn chờ |
|---|---|---|
| Mở Warp (Tab Config) | Có (A7) | — |
| Project Analyst | Có, 3 server Linux (2026-10-22) | Tự điền password PAM (G4) |
| Máy Windows (mở bằng Windows App) | Có (H0) | Copy mật khẩu (H2), SSH tunnel cho RDP |
| UI máy chủ/thư mục (B3), double-click (E0) | Một phần (SSH qua Warp chạy được) | Kịch bản thử tay còn lại |
| Truyền file, auth prompt (C3/C4, F2) | Chỉ sshd tạm | Server thật: password, MFA, host key |
| Password Keychain + askpass (E2) | Chỉ test đơn vị | Server có password; ACL Keychain khi chạy từ `.app` |
| SSH Keys (E1), Port forward (E3) | Chỉ sshd tạm | Server thật |
| Monitor (I1/I2) | Chưa | Server Linux thật, giao diện |
| Xuất/nhập (D1) | Chỉ test | Thử tay |
| Cài đặt (D4), vòng đời app (D2) | — | Đang làm |
| Logo/giao diện (UI1) | — | Người dùng xem app |

Kịch bản thử tay: [docs/TESTING.md](docs/TESTING.md). Giới hạn đã biết: [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

## Dữ liệu lưu ở đâu
| Nội dung | Vị trí |
|---|---|
| SQLite (hồ sơ, lịch sử truyền/Analyst, forward, cài đặt) | `~/Library/Application Support/SSHDesk/sshdesk.sqlite` (thư mục 0700) |
| SSH config do app sinh | `~/Library/Application Support/SSHDesk/ssh/config` (0600) |
| File `.rdp` | `~/Library/Application Support/SSHDesk/rdp/<uuid>/` |
| Tab Config của Warp | `~/.warp/tab_configs/sshdesk_<uuid>.toml` |
| Socket ControlMaster | `/tmp/sshdesk-<uid>/` (0700) |
| Password | Chỉ Keychain (service `local.sshdesk.credentials`) |

App **không** sửa `~/.ssh/config` hay Tab Config của bạn; chỉ ghi file mang tiền tố `sshdesk_` / thư mục riêng của app, và `Include` config của bạn từ config của app.

## Bảo mật (tóm tắt)
- Password/passphrase/OTP không vào file, SQLite, log, argv, env, URI, export. Chỉ Keychain. Ngoại lệ có chủ đích: copy mật khẩu máy Windows lên clipboard (đánh dấu concealed/transient, tự xoá).
- Chạy process bằng executable + argv, không qua `sh -c` với input người dùng.
- Không bao giờ `StrictHostKeyChecking=no`; host key mới/đổi luôn hỏi người dùng.
- Mọi giá trị ghi vào SSH config / Tab Config / `.rdp` bị cấm newline và ký tự điều khiển.
- Chỉ lệnh xem, whitelist cố định cho Analyst và Monitor; không `sudo`.

## Tài liệu
- [docs/OVERVIEW.md](docs/OVERVIEW.md) — module, luồng chính, DB, danh sách ADR.
- [docs/TESTING.md](docs/TESTING.md) — chạy test, quy tắc, kịch bản thử tay.
- [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) — rủi ro chấp nhận và điều chưa kiểm chứng.
- Gốc: [docs/spec.md](docs/spec.md), [docs/architecture.md](docs/architecture.md) (ADR đầy đủ), [plan.md](plan.md), [progress.md](progress.md).

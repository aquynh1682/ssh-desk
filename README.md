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
Lệnh này build `.app` (mặc định ký ad-hoc, không notarize; nên ký bằng chứng chỉ của bạn, xem mục dưới) rồi cài vào `/Applications/SSH Desk.app`. **Phải thoát app (⌘Q) trước**, nếu app đang chạy lệnh sẽ dừng. Sau đó mở bằng icon (Launchpad/Spotlight/Dock). Chạy lại `make install` để cập nhật.

### Ký app bằng chứng chỉ của bạn (khuyến nghị)
**Vì sao:** ký ad-hoc làm chữ ký app đổi sau mỗi lần build, nên Keychain hỏi lại quyền đọc password đã lưu sau mỗi lần `make install`. Ký bằng một chứng chỉ cố định thì chữ ký ổn định. App **không** tự tạo chứng chỉ và không sửa Keychain; bạn tự làm các bước sau (một lần):
1. Mở Keychain Access → menu Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: ví dụ `SSH Desk Local`; Identity Type: Self Signed Root; Certificate Type: Code Signing. Tạo xong.
3. Nếu `codesign` báo chứng chỉ không tin cậy: mở chứng chỉ → Trust → Code Signing: Always Trust.
4. Kiểm tra: `security find-identity -p codesigning` (phải thấy tên chứng chỉ).
5. Build: `make install SIGN_IDENTITY="SSH Desk Local"`, hoặc `export SSHDESK_SIGN_IDENTITY="SSH Desk Local"` rồi `make install`.

Lưu ý: tên chứa `$` thì dùng biến môi trường (make sẽ mở rộng `$`). Hai chứng chỉ trùng tên thì dùng mã SHA-1 của chứng chỉ thay cho tên. Không tìm thấy identity thì build ký ad-hoc và in cảnh báo (không lỗi). Lần đầu sau khi đổi từ ad-hoc sang chứng chỉ, Keychain có thể hỏi quyền một lần cho password đã lưu từ trước: chọn "Luôn cho phép" (Always Allow). Chưa thử thật trên máy (xem [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md)).

Các lệnh khác: `make check` (lint + build + test), `make run`, `make app`. Xem [docs/TESTING.md](docs/TESTING.md).

## Tính năng
- **Máy chủ + thư mục:** thêm/sửa/xoá/nhân bản, tìm kiếm, môi trường (DEV/UAT/STG/PROD/OTHER), yêu thích, bastion (ProxyJump), import alias có sẵn từ `~/.ssh/config` (chỉ đọc). Thư mục ở sidebar, kéo host vào thư mục.
- **Mở Warp:** sinh Tab Config và mở tab Warp chạy `ssh`; không có Warp thì Copy lệnh SSH. Click 1 lần = chọn, double-click / Return = mở.
- **Tự đăng nhập bằng password:** tuỳ chọn lưu password trong Keychain cho từng host; Warp đăng nhập qua helper `SSH_ASKPASS` (env chỉ chứa tham chiếu, không chứa password).
- **Agent ngoài (1Password, Bitwarden, Secretive):** chọn agent ở form host (mục Nâng cao) hoặc đặt mặc định trong Cài đặt → SSH config. App chỉ ghi `IdentityAgent "<socket>"` vào config của app, không đọc private key. Với agent ngoài nên để IdentityFile trống, hoặc trỏ tới file `.pub` của key nằm trong agent. Màn SSH Keys có thẻ "Key trong agent" (liệt kê public key bằng `ssh-add -L`). Chỉ áp dụng cho host managed loại SSH. Chưa thử với agent thật.
- **Truyền file kiểu Xftp:** hai khung (Mac | server), tab cho từng server, kéo thả, hàng đợi (huỷ, thử lại, ghi đè/đổi tên/bỏ qua), tạo thư mục / đổi tên / xoá trên server. Dùng `scp` (giao thức SFTP) và `sftp` qua một kết nối ControlMaster mỗi tab.
- **SSH Keys:** liệt kê key trong `~/.ssh` (chỉ đọc `*.pub`), tạo key mới, "Cài key lên server" (`ssh-copy-id`).
- **Port forward (-L):** lưu danh sách forward theo host, Mở/Dừng tunnel riêng, hiển thị trạng thái.
- **Project Analyst:** quét một thư mục server (Linux), dựng bản đồ kết nối giữa các server, thử kết nối TCP, lưu lịch sử, xuất báo cáo Markdown/CSV.
- **Monitor:** lưới thẻ CPU / RAM / swap / đĩa / load / uptime theo thư mục (Linux).
- **Máy Windows:** khai báo host RDP, mở bằng Windows App qua file `.rdp`; tuỳ chọn copy mật khẩu lên clipboard khi mở (tự xoá).
- **CLI `sshdesk` + liên kết `sshdesk://`:** liệt kê và mở host từ terminal, Alfred, Raycast (mục bên dưới). Chưa thử tay.
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

## Dòng lệnh `sshdesk`
Sau `make install`, CLI nằm ở `/Applications/SSH Desk.app/Contents/Helpers/sshdesk`. App **không** sửa PATH; bạn tự tạo symlink (một lần):
```
mkdir -p ~/bin && ln -s "/Applications/SSH Desk.app/Contents/Helpers/sshdesk" ~/bin/sshdesk
```
rồi thêm `~/bin` vào PATH (vd `export PATH="$HOME/bin:$PATH"` trong `~/.zshrc`).

| Lệnh | Việc |
|---|---|
| `sshdesk list [--folder <tên>] [--json]` | Liệt kê máy chủ (JSON: `id, name, alias, folder, environment, kind, hostName, port, user`). |
| `sshdesk open <id\|alias\|tên>` | Nhờ app mở host trong Warp. Khớp chính xác theo thứ tự id, alias imported, tên hiển thị; nhiều host khớp thì báo lỗi liệt kê id. |
| `sshdesk help` | Trợ giúp. |

Exit code: 0 = thành công (kể cả `help`), 1 = lỗi chung (chưa có DB, schema lệch, không mở được app), 2 = tham số sai, 3 = không giải được host (không thấy, nhiều host khớp, hoặc máy Windows: CLI v1 chưa hỗ trợ). Host môi trường PROD luôn hiện hộp xác nhận trong app; host khác mở ngay. CLI chỉ mở DB ở chế độ chỉ đọc, không ghi gì, không đọc Keychain/mật khẩu; không có lệnh nào nhận mật khẩu hay tham số `ssh` tuỳ ý. Chưa thử end-to-end trên máy thật (xem [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) B10).

## Liên kết `sshdesk://`
- `sshdesk://open?id=<uuid>` hoặc `sshdesk://open?name=<tên hoặc alias>` (chỉ đúng một tham số; tham số khác, giá trị quá 256 ký tự hoặc có ký tự điều khiển bị từ chối).
- **Luôn** hiện hộp xác nhận (tên, môi trường, user@host) trước khi mở, kể cả host không PROD. Chỉ áp dụng cho máy SSH.
- Thử: `open 'sshdesk://open?name=My%20Server'` (mã hoá khoảng trắng thành `%20`).

## Alfred / Raycast
Chỉ có hướng dẫn, không có extension.

**Alfred (Script Filter).** Tạo workflow: Script Filter (Language `/bin/zsh`, with input as argv), nối tới Run Script chạy `~/bin/sshdesk open "{query}"` (Alfred không dùng PATH của bạn nên ghi đường dẫn đầy đủ). Script Filter dùng `/usr/bin/python3` (nếu máy chưa có thì dùng `jq`, xem dưới):
```
~/bin/sshdesk list --json | /usr/bin/python3 -c '
import sys, json
q = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
items = [{"title": h["name"],
          "subtitle": "%s  %s@%s" % (h["environment"], h["user"], h["hostName"]),
          "arg": h["id"]}
         for h in json.load(sys.stdin)
         if q in (h["name"] + " " + (h["alias"] or "")).lower()]
print(json.dumps({"items": items}))
' "$1"
```
Với `jq`: `~/bin/sshdesk list --json | jq --arg q "$1" '{items: [.[] | select((.name + " " + (.alias // "")) | ascii_downcase | contains($q | ascii_downcase)) | {title: .name, subtitle: "\(.environment)  \(.user)@\(.hostName)", arg: .id}]}'`. `arg` là id nên `open` khớp chính xác.

**Raycast.** Tạo Script Command (bash) với tham số văn bản, thân script: `~/bin/sshdesk open "$1"` (đặt `#!/bin/zsh`, `@raycast.mode silent`). Ví dụ hai script chưa chạy thử trên máy thật.

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

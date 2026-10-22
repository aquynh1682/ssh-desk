# Kiến trúc SSH Desk

Bản đọc nhanh. Quyết định đầy đủ và lý do: [architecture.md](architecture.md) (ADR). Khi hai nơi khác nhau, `architecture.md` thắng.

## Stack
Swift 6, SwiftUI (+ AppKit khi cần), SwiftPM, SQLite hệ thống (`import SQLite3`), không dependency ngoài, không App Sandbox. Không có `.xcodeproj`; `.app` đóng gói bằng `scripts/build-app.sh` (ký ad-hoc). UI không dùng `@State` mà dùng `@Local` (ADR-009).

## Module trong `Sources/`
| Target | Vai trò |
|---|---|
| `SSHDeskCore` | Toàn bộ logic, không import SwiftUI, có test. |
| `SSHDesk` | UI SwiftUI, mỏng, chỉ gọi vào Core. |
| `AskpassKit` | Logic phân loại prompt dùng chung cho helper askpass (có bảng test). |
| `sshdesk-askpass` | Executable helper trong bundle: đọc Keychain theo tham chiếu, in password cho `ssh`. |
| `sshdesk-ctty` | Executable helper gán controlling tty rồi `execv` (posix_spawn trên macOS không tự cấp). |

Thư mục trong `SSHDeskCore/`:
- `Hosts/` — `HostProfile`, `HostRepository`, `Database` (migration), thư mục server, presentation.
- `SSHConfig/` — `SSHConfigWriter` (sinh config riêng). `SSHImport/` — đọc alias từ `~/.ssh/config`.
- `Warp/` — `WarpTabConfigRenderer`, `WarpLauncher`, `ZshQuoting`.
- `Process/` — `PTYProcess`, `PromptDetector`, `ScpProgressParser`, `OutputSanitizer`.
- `Credentials/` — `CredentialStore` (Keychain), `PasswordAutofillPolicy`.
- `Transfer/` — `TransferManager`, `ScpCommandBuilder`, `TransferRepository`, state machine job.
- `Remote/` — `RemoteSession` (master), `SessionPool`, `SessionConnector`, `RemoteFileService`, `SftpBatch`, `SftpListingParser`, `LocalFileService`.
- `Browser/` — logic thuần của màn Truyền file (tab, đường dẫn, kế hoạch truyền).
- `Keys/` — kiểm kê, tạo, cài SSH key. `Tunnel/` — `TunnelManager`, `PortForward`.
- `Analyst/`, `Monitor/` — lệnh whitelist, parser, coordinator. `Windows/` — `.rdp`, Windows App, clipboard bí mật.
- `Exchange/` — xuất/nhập JSON. `Settings/` — `AppSettings`, `SettingsRepository` (đang hoàn thiện). `App/` — `AppPaths`, `ConnectionService`, `HostDraft`, `QuitActivity` (đang hoàn thiện).

## Luồng chính
**SSH config riêng + Include (ADR-006).** App sinh `~/Library/Application Support/SSHDesk/ssh/config` từ DB: mỗi host managed là `Host sshdesk-<uuid>`, cuối file là `Match all` + `Include <~/.ssh/config>` (host của app đứng trước nên giá trị của app thắng; alias của bạn vẫn resolve). Mọi kết nối là `/usr/bin/ssh -F <config tuyệt đối> <alias>` (`scp`/`sftp` cũng `-F`). Giá trị được quote và cấm newline/ký tự điều khiển.

**Warp Tab Config (ADR-007).** Ghi `~/.warp/tab_configs/sshdesk_<uuid>.toml` (một pane, `commands` = lệnh ssh đã quote cho zsh), mở bằng `warp://tab_config/sshdesk_<uuid>`. App chỉ biết "đã yêu cầu mở"; lỗi thì Copy lệnh.

**Askpass (ADR-010, 010b).** Host có password lưu: lệnh trong Tab Config đặt `SSH_ASKPASS=<helper> SSH_ASKPASS_REQUIRE=force SSHDESK_HOST_REF=<tham chiếu>`. Helper chỉ trả password cho đúng prompt password của đúng host, một lần mỗi tiến trình ssh, và chỉ khi cha là `/usr/bin/ssh`; prompt khác (host key, MFA, passphrase) hỏi người dùng trên `/dev/tty`. Host có bastion không dùng askpass. Truyền file/tunnel/Analyst/Monitor dùng PTY và `PasswordAutofillPolicy` (khớp `user@host's password:` hoặc `(user@host) Password:`, tối đa 1 lần mỗi phiên).

**ControlMaster + SessionPool (ADR-013, 016, 019).** Mỗi host một master: `ssh -M -N -o ControlPath=/tmp/sshdesk-<uid>/<hostID> -o ControlPersist=no`. sftp, scp, lệnh Analyst và Monitor chạy qua master đó. `SessionPool` dùng chung giữa Truyền file / Analyst / Monitor (một master/host; phiên do Analyst/Monitor tự mở thì tự đóng).

**scp / sftp (ADR-008, 013).** `scp` (giao thức SFTP, không `-O`) qua PTY cho truyền file; `sftp -b -` cho liệt kê/mkdir/rename/rm. Download ghi `.part` rồi rename độc quyền. Job chưa xong khi khởi động lại thành "Bị gián đoạn".

**Project Analyst (ADR-016).** Whitelist `ss -Htanp`, `ip -o addr show`, `hostname`; dựng cạnh A→B:port từ kết nối ESTAB tới cổng B đang LISTEN; probe TCP từ server nguồn; lưu lịch sử (migration v4). Chỉ Linux, không sudo.

**Monitor (ADR-019).** Whitelist `cat /proc/{stat,meminfo,loadavg,uptime}`, `nproc`, `df -P -k`; làm mới 5/10/30 giây, tối đa 4 host song song; sparkline chỉ trong RAM.

**Tunnel (ADR-011).** Phiên riêng `ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:<lp>:<rh>:<rp>`; dừng bằng SIGTERM process group; thoát app thì dừng hết.

**RDP (ADR-017, 018).** Sinh `.rdp` UTF-8/CRLF, mở bằng Windows App. Password (nếu lưu) copy lên clipboard concealed, tự xoá.

## Database
`~/Library/Application Support/SSHDesk/sshdesk.sqlite`, bảng `schema_version`, migration tuần tự trong `Database.swift`. DB mới hơn app hoặc file hỏng thì báo lỗi, không đè.

| Phiên bản | Nội dung | ADR |
|---|---|---|
| v1 | `hosts` | 005 |
| v2 | `transfer_jobs` (không FK tới hosts) | 008 |
| v3 | `host_folders` (thư mục rỗng) | 015 |
| v4 | `analyst_runs`, `analyst_servers`, `analyst_flows` | 016 |
| v5 | `hosts.kind` + cột `rdp_*` (máy Windows) | 017 |
| v6 | `port_forwards` | 011 |
| v7 | `settings(key, value)` — đang hoàn thiện | 021 |

## Danh sách ADR
Chi tiết trong [architecture.md](architecture.md).

| ADR | Tên | Tóm tắt |
|---|---|---|
| 001 | Swift 6 + SwiftUI + SwiftPM | Không Xcode; `.app` đóng gói bằng script, macOS 14+, không sandbox. |
| 002 | Tách Core / UI | Logic ở `SSHDeskCore`, UI chỉ gọi vào. |
| 003 | Swift Testing | Không XCTest; cần `-plugin-path`. |
| 004 | Secret chỉ trong Keychain | DB chỉ giữ tham chiếu. |
| 005 | SQLite hệ thống | Không dependency; migration tuần tự. |
| 006 | SSH config riêng + Include | `-F` tuyệt đối, `Match all`, validate chống chèn directive. |
| 007 | Warp qua Tab Config | File `sshdesk_*.toml` + URI `warp://tab_config/`. |
| 008 | Truyền file bằng scp qua PTY | Escape remote theo chiều, từ chối symlink, recovery, ghi đè. |
| 009 | `@Local` thay `@State` | CLT thiếu plugin macro SwiftUI. |
| 010 / 010b | Đăng nhập tự động | Askpass + Keychain; tự điền keyboard-interactive. |
| 011 | Local port forward | Tunnel riêng `ssh -N -L`, bảng `port_forwards`. |
| 012 | Logo + giao diện theo mockup | Tiếng Việt, theo sáng/tối hệ thống. |
| 013 | Duyệt file kiểu Xftp | ControlMaster mỗi tab, sftp batch, xoá đệ quy do app làm. |
| 014 | SSH Keys | Chỉ đọc `.pub`, `ssh-keygen`, `ssh-copy-id`. |
| 015 | Phản hồi UI | Gộp xác thực, thư mục server, click/double-click. |
| 016 | Project Analyst | Lệnh whitelist, tự phát hiện luồng, probe TCP, Linux only. |
| 017 | Máy Windows qua Windows App | File `.rdp`, không SSH/truyền file. |
| 018 | Mật khẩu Windows qua clipboard | Ngoại lệ có chủ đích, concealed + tự xoá. |
| 019 | Monitor | Đọc `/proc` + `df`, làm mới định kỳ. |
| 020 | Xuất/nhập danh sách máy | JSON không secret, xem trước, transaction. |
| 021 | Màn Cài đặt | Bảng `settings`, `AppSettings` có mặc định + kẹp (đang hoàn thiện). |
| 022 | Vòng đời app | Xác nhận khi thoát, empty state, phím tắt (đang hoàn thiện). |

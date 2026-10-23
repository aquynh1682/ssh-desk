# Plan

Mỗi task nhỏ, xong khi `make check` xanh và PM đã review. Đánh dấu `[x]` khi xong.

## Giai đoạn 0 — Nền móng
- [x] Context: CLAUDE.md, docs/spec.md, docs/architecture.md, plan.md, progress.md
- [x] Harness: SwiftPM, `make check`, hook format, permissions
- [x] Đội agent: `coder` (Sonnet), `researcher` (Haiku), PM (Opus)
- [x] Chốt spec + ADR từ `CLAUDE_CODE_SSH_DESK_PROMPT.md`

## Bước A — Kiểm chứng tích hợp
- [x] A1 (researcher): kiểm chứng ADR-006 bằng config tạm + `ssh -G` (ProxyJump có truyền `-F`, thứ tự ưu tiên, Match all + Include)
- [x] A2 (researcher): scp/sftp OpenSSH 10 — glob remote, cách giữ đường dẫn literal, prompt xác thực
- [x] A3 (coder): đổi tên package → SSHDesk/SSHDeskCore; script `scripts/build-app.sh` ra `build/SSH Desk.app`
- [x] A4 (coder): SSHConfigWriter (Match all, -F tuyệt đối, cấm newline/ctrl) + quoting/validation + test
- [x] A5 (coder): WarpLauncher (TOML + URI) + test; thử mở Warp thật với 1 Tab Config (thủ công)
- [x] A6 (coder): OpenSSHProcessRunner qua PTY + test với process giả lập (không cần server)
- [x] PM chốt ADR-008, ghi giới hạn phát hiện được

- [x] A7 (người dùng + PM): thử mở Warp thật với 1 Tab Config do app sinh; xác nhận URI mở đúng tab (đóng `[~]` của A5)

## Bước B — Hồ sơ máy chủ
- [x] B1 SQLite + migration + HostRepository + test
- [x] B2 Import alias từ ~/.ssh/config (chỉ đọc, Include có giới hạn độ sâu) + test
- [~] B3 UI (code xong, PM duyệt; chờ người dùng thử tay 14 kịch bản): sidebar, tìm kiếm, danh sách, chi tiết, form hồ sơ, Mở Warp / Copy lệnh

## Bước C — Truyền file
- [x] C1 TransferJob + state machine + TransferRepository + test
- [x] C2 TransferManager: queue, huỷ, retry, file tạm, recovery "Bị gián đoạn"
- [x] C2b Sửa PTYProcess cấp controlling tty thật + bỏ trampoline sh trong TransferManager
- [~] C3+C4 (code xong, chờ thử với server test thật) Auth prompt UI (password/passphrase/MFA, host key mới/đổi)
- [~] C4 UI Tải về / Tải lên / Queue / Lịch sử

## Giao diện (người dùng yêu cầu)
- [~] UI1 Logo/icon + giao diện theo mockup (ADR-012) — code xong, PM duyệt build/test; chờ người dùng xem app. Còn: form/import/prompt/màn lỗi DB chưa theo Theme.

## Bước E — Mở rộng (người dùng yêu cầu, sau Bước C)
- [~] E0 Double-click host = Mở Warp (code xong, chờ thử tay)
- [~] E1 Màn SSH Keys + nút "Cài key lên server" (ssh-copy-id qua PTY) — ADR-010, ADR-014 (code xong, PM duyệt; chờ thử tay)
- [~] E2 Lưu password Keychain + helper SSH_ASKPASS cho Warp — ADR-010 (code xong, PM duyệt; chờ thử với server có password)
- [~] E3 (code xong, PM duyệt; chờ thử tay) Local port forward: lưu danh sách, mở/dừng tunnel — ADR-011

## Bước F — Duyệt file kiểu Xftp (ADR-013, người dùng yêu cầu)
- [x] R1 (researcher) spike ControlMaster + sftp liệt kê/mkdir/rename/rm + scp dùng chung socket
- [x] F1 Core: RemoteSession (master), RemoteFileService (list/mkdir/rename/rm), LocalFileService
- [~] F2 (code xong, PM duyệt; chờ thử với server test) UI 2 khung + tab server + kéo thả → TransferManager

## Bước G — Project Analyst (ADR-016, người dùng yêu cầu)
- [x] G1 Core: whitelist lệnh, chạy lệnh qua master, parser `ss`/`ip addr`, dựng topology, probe, xuất báo cáo (thuần, chưa DB)
- [~] G2 (code xong, PM duyệt; chờ thử với server Linux test) DB lịch sử chạy + UI (sidebar PROJECTS, tab Servers/Bản đồ/Kết quả/Lịch sử, graph, panel chi tiết) — sau khi xong thư mục server

- [~] G3 (code xong, PM duyệt; chờ người dùng xem) Sửa UI Analyst theo phản hồi: khung Kết quả quá to/đè bản đồ, nhãn cạnh chồng nhau, thẻ server ưu tiên port có cạnh vào, ẩn/đánh dấu LISTEN loopback (:53 systemd-resolved)

- [~] G4 (code xong, PM duyệt; chờ thử với Ping-Identity) Tự điền password cho prompt keyboard-interactive `(user@host) Password:` (ADR-010b) — PTY + askpass

## Bước I — Monitor tài nguyên (ADR-019, người dùng yêu cầu)
- [~] I1 (code xong, PM duyệt) Core: lệnh whitelist, parser /proc + df, tính CPU %, MonitorCoordinator (vòng làm mới, owner `.monitor`)
- [~] I2 (code xong, PM duyệt; chờ người dùng xem) UI: mục Monitor ở sidebar, lưới thẻ theo thư mục, sparkline, Dừng/Tiếp tục, xác nhận PROD

## Bước H — Máy Windows (ADR-017, người dùng yêu cầu)
- [x] H0 (người dùng) thử file .rdp thật (UTF-8 CRLF mở + đăng nhập được) với Windows App: host + user có điền sẵn không
- [~] H1 (code xong, PM duyệt; chờ thử tay) Loại máy Windows (RDP): model + migration, form, sinh .rdp, Mở Windows App, ẩn chức năng SSH
- [~] H2 (code xong, PM duyệt; chờ thử tay) Mật khẩu Windows: lưu Keychain, copy tự động khi mở (ADR-018)

## Bước D — Hoàn thiện
- [~] D1 (code xong, PM duyệt; chờ thử tay) Xuất/nhập danh sách máy chủ — ADR-020
- [~] D2 (code xong, QA đạt, PM duyệt; chờ thử tay) (ADR-022) Vòng đời app (thoát khi đang truyền), empty states, shortcut
- [~] D4 (code xong, QA đạt, PM duyệt; chờ thử tay) Màn Cài đặt (spec mục Settings + đề xuất PM: Keychain/clipboard, Analyst, Monitor, Windows App, dữ liệu) — ADR-021
- [x] D3 (README, docs/OVERVIEW.md, TESTING, KNOWN_LIMITATIONS) README.md, ARCHITECTURE.md, TESTING.md, KNOWN_LIMITATIONS.md; build `.app`

## Bước K — Hướng mở rộng chiến lược (người dùng chọn 2026-10-22, ADR-023..028)
- [~] K1 (code xong, QA đạt sau sửa, PM duyệt; chờ người dùng tạo chứng chỉ và thử 2 lần make install) Ký app bằng chứng chỉ ổn định qua `SIGN_IDENTITY`/`SSHDESK_SIGN_IDENTITY`, fallback ad-hoc + cảnh báo — ADR-023
- [~] K2 (code xong, QA đạt, PM duyệt; chờ thử với agent thật) IdentityAgent theo host + mặc định Cài đặt, validate chống chèn directive, migration v8 — ADR-024
- [~] K3 (code xong, QA đạt sau sửa, PM duyệt; chờ thử URL scheme + `sshdesk open` sau make install) CLI `sshdesk` (list/open/help) + URL scheme `sshdesk://` có xác nhận — ADR-025
- [~] K4s (code xong, QA chặn→sửa, PM duyệt; chờ thử UI bộ đăng nhập) Bộ đăng nhập dùng chung (credential set) + cột hold tự điền, migration v9 — ADR-030
- [~] K4e (code xong, QA chặn→sửa, PM duyệt; chờ người dùng thử migration + askpass sau make install) Backend Secure Enclave + ECIES cho mọi secret + migration item plaintext cũ — ADR-004c (ngay sau K4s)
- [x] K4r (researcher) Kiểm chứng đọc/tạo `.xlsx` bằng `unzip -p`/`zip` + XMLParser — ADR-026
- [~] K4a (code xong, QA chưa đạt→sửa, PM duyệt; chờ người dùng mở file mẫu trong Excel/Numbers và thử nhập) Khung nguồn đồng bộ + Excel mẫu + XLSX/CSV ghép cột, migration v10 — ADR-026
- [~] K4c (code xong, QA đạt, PM duyệt; chờ thử với server thật có password) Hỏi mật khẩu lần đầu + "Lưu vào Keychain" có kiểm tra (Warp/Analyst/Monitor/Truyền file/Windows) — ADR-029
- [ ] K4b (coder) Nguồn JSON `.sshdesk.json` + Ansible INI/YAML tĩnh — ADR-026
- [x] K5r (researcher) Kiểm chứng khoá Secure Enclave macOS 27 / OpenSSH 10.3 — ADR-027
- [ ] K5 (coder, chỉ khi K5r đạt) Tạo/dùng khoá Secure Enclave — ADR-027
- [ ] K6 (coder) Monitor đọc Prometheus/Zabbix, migration v11 — ADR-028
- [ ] K7 (doc-writer) README/OVERVIEW/TESTING/KNOWN_LIMITATIONS cho K1–K6, hướng dẫn tạo chứng chỉ, CLI/Alfred, file Excel mẫu

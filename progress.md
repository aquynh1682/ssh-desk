# Progress

Ghi mới nhất ở trên. Mỗi phiên: làm gì, còn dở gì, bước tiếp theo.

## 2026-10-21 — Phiên 1 (tiếp): nhận yêu cầu SSH Desk, lập đội
- Nhận `CLAUDE_CODE_SSH_DESK_PROMPT.md` → viết lại spec, ADR-001..008, plan theo Bước A–D.
- Đội: PM = agent chính (Opus); `.claude/agents/coder.md` (Sonnet), `.claude/agents/researcher.md` (Haiku).
  Agent tạo giữa phiên chưa được nạp → tạm gọi `general-purpose` + `model` tương ứng; phiên sau dùng trực tiếp tên agent.
- Môi trường: macOS 27.0.1 arm64, OpenSSH_10.3p1, Warp 0.2026.10.14, có `~/.warp/tab_configs/`.
- A3 xong, PM đã review (make check xanh, bundle ký ad-hoc hợp lệ; chưa mở app thử). A1+A2 xong: ADR-006 xác nhận bằng thử nghiệm, ADR-008 chốt `scp` SFTP qua PTY (chi tiết trong architecture.md). Đã dọn file tạm của researcher.
- A4 (SSHConfigWriter) xong, PM đã đọc code + `make check` xanh 23 test. A5 (WarpLauncher) xong, PM duyệt; còn **chưa thử mở Warp thật** (cần người dùng thử thủ công) — nên đánh dấu `[~]` trong plan.
- A6 xong, PM duyệt: PTY runner (posix_spawn + SETSID, controlling tty kiểm chứng được trên macOS này), cancel theo process group, PromptDetector, ScpProgressParser, OutputSanitizer; `launch()` kiểm tra Warp trước khi ghi file. `make check` xanh 60 test.
- Lưu ý khi dùng runner ở tầng trên: `send(_:redact:)` mặc định che chuỗi đã gửi nếu con in lại → truyền `redact: false` cho câu trả lời không bí mật ("yes"). PromptDetector chỉ dùng trong giai đoạn xác thực; chỉ điền credential khi người dùng xác nhận. Redaction theo chunk, không che được secret bị tách giữa 2 lần read (ECHO đã tắt nên tty không echo).
- A7 xong: người dùng thử thật, Warp 0.2026.10.14 mở tab mới từ `warp://tab_config/sshdesk_<uuid>` và chạy đúng lệnh trong Tab Config (ảnh chụp xác nhận). **Bước A hoàn tất.**
- Chưa kiểm chứng: ssh/scp thật, app mở từ Finder (SSH_AUTH_SOCK).
- B1 (HostProfile/SQLite/HostRepository) + B2 (import alias chỉ đọc) xong, PM duyệt: SQL chỉ bind tham số; importer không exec/ghi; `make check` xanh 104 test.
  Quyết định chấp nhận: Database kiểm header 16 byte trước khi mở (tránh SQLite ghi đè file rác); search lọc trong Swift (không phân biệt dấu); imported host không có jumpHostID.
- B3 xong phần code: ConnectionService (Core, có test) + UI SwiftUI. `make check` xanh 117 test, `make app` OK. Phát hiện `@State` không build với CLT → ADR-009 dùng `@Local`.
- Người dùng đã thử B3: SSH qua Warp chạy được. Người dùng yêu cầu thêm → ADR-010 (key + Keychain/askpass), ADR-011 (local forward), Bước E (sau C).
- E0 double-click (code xong, chờ thử tay). C1 xong, PM duyệt: 145 test; kết quả escape/symlink ghi vào ADR-008.
- C2 (TransferManager) + C2b (helper sshdesk-ctty sửa controlling tty) xong, PM duyệt: 164 test, probe stty qua PTYProcess exit 0. Lỗi A6 (kiểm chứng qua /bin/sh che lỗi) đã ghi vào coder.md.
- C3+C4 xong phần code, PM duyệt: 183 test, `.app` có sshdesk-ctty. Chờ người dùng thử truyền file với server test thật (8 kịch bản). Chưa kiểm chứng: auth/host key với ssh thật, helper tìm thấy khi chạy từ .app.
- UI1 (logo + giao diện mockup, ADR-012) xong code: 194 test, .app có AppIcon.icns. Rủi ro: bảng host tự dựng (ScrollView+LazyVStack) — phím/double-click chưa chạy thử. `Bundle.module` không dùng (fatalError trong .app) → AppLogo nạp thủ công.
- Người dùng yêu cầu: cửa sổ duyệt file kiểu Xftp (ADR-013, mockup `Resources/Design/file-transfer-mockup.png`, đặt trong cửa sổ chính) + lưu password/đăng nhập thẳng Warp (E2).
- R1 xong (researcher, sshd tạm 127.0.0.1 đã dọn): ControlMaster dùng chung cho sftp/scp; socket phải ở `/tmp/sshdesk-<uid>` (≤86 byte); rename sftp ghi đè im lặng; không có xoá đệ quy; askpass được gọi cho host key, SSH_ASKPASS_PROMPT unset, BatchMode yes chặn askpass. Đã chuyển các điểm askpass cho E2.
- E2, F1, F2 xong phần code, PM duyệt: 290 test (make check có thể treo hiếm — đã sửa TempSshd.reap; khi chạy tay bọc `perl -e 'alarm 400; exec @ARGV' make check`). PM phát hiện lỗ hổng tự điền password cho host có bastion trong TransferManager → sửa bằng PasswordAutofillPolicy (F2).
- **Chờ người dùng thử với server test:** E2 (password lưu → Warp/truyền file), F2 (màn Truyền file, kéo thả, thao tác remote). Chưa có commit nào — đề xuất commit mốc.
- 2026-10-21 (tiếp): E1 SSH Keys, gộp mật khẩu vào Xác thực + click 1 lần chọn, thư mục server (ADR-015), Project Analyst G1+G2 (ADR-016) — tất cả code xong trên nhánh `feat/e1-ssh-keys`, `make check` xanh 406 test. Có `make install`.
- Bài học: agent `isolation: worktree` tạo từ `main` → gây xung đột khi gộp (đã ghi CLAUDE.md).
- **Chờ người dùng thử** (make install): click/double-click, thư mục, SSH Keys, Project Analyst trên server Linux test, E2/F2 với server có password.
- Sau đó: Bước E còn lại (E1 cài key, E2 Keychain+askpass, E3 local forward), rồi Bước D.
- Chờ người dùng thử tay B3 (kịch bản trong tin nhắn phiên 1). Chưa xác minh: ⌘F focus, Return mở Warp, sidebar disabled, dark/light.
- **Tiếp theo (cũ):** Bước B (B1 SQLite/HostRepository, B2 import alias, B3 UI).
- Lưu ý: dùng `echo ======` trong zsh sẽ lỗi (`=` expansion) — tránh trong lệnh Bash.

## 2026-10-21 — Phiên 1: dựng nền
- Tạo các file context (CLAUDE.md, spec, architecture, plan, progress).
- Dựng SwiftPM package: `SSHAppCore` (model `Server`), `SSHApp` (cửa sổ SwiftUI trống), 2 test mẫu.
- `make check` xanh.
- Phát hiện: máy chỉ có Command Line Tools → XCTest không có; Swift Testing cần cờ `-plugin-path` (đã gói vào Makefile).
- Harness: hook tự `swift format` file .swift sau khi sửa; permissions trong `.claude/settings.json`.
- **Tiếp theo:** nhận mô hình + yêu cầu từ chủ dự án → hoàn thiện docs/spec.md → chia Giai đoạn 1 trong plan.md.

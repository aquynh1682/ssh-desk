# SSH Desk

App macOS native (cá nhân) quản lý hồ sơ máy chủ, mở SSH trong Warp, upload/download qua OpenSSH.
- Yêu cầu gốc đầy đủ: `CLAUDE_CODE_SSH_DESK_PROMPT.md` (đọc theo mục khi cần, không đọc hết mỗi lần).
- `docs/spec.md` (tóm tắt phạm vi), `docs/architecture.md` (quyết định đã chốt), `plan.md` / `progress.md` (đang ở đâu).

## Đầu / cuối mỗi phiên
1. Đọc `progress.md` để biết đang dừng ở bước nào.
2. Cuối phiên: đánh dấu bước xong trong `plan.md`, ghi tóm tắt vào `progress.md`.

## Đội và quy trình
- **Agent chính (Opus) = PM:** chốt quyết định, chia task, giao việc, review diff, approve. Không tự viết code tính năng.
- **`coder` (Sonnet):** viết code + test theo task.
- **`researcher` (Haiku):** đọc file, tra tài liệu, kiểm chứng hành vi công cụ bằng lệnh chỉ đọc.
- **`qa-reviewer` (Sonnet):** kiểm tra phần coder vừa làm theo checklist bảo mật/ADR, chỉ đọc.
- **`pm` (Opus):** điều phối triển khai theo skill `ssh-desk-delivery` (ADR → coder → QA → commit).
- **`product-advisor` (Fable):** tư vấn sản phẩm, đề xuất ý tưởng và roadmap, không triển khai.
- **`doc-writer` (Sonnet):** viết tài liệu `.md`, không đụng code, chạy song song với coder được.
- Quyết định mới hoặc đổi quyết định → PM ghi vào `docs/architecture.md` trước, rồi mới giao code.
- Task chỉ được tính xong khi PM đã review và `make check` xanh.
- Agent chạy với `isolation: worktree` được tạo từ **`main`**, không phải nhánh hiện tại → chỉ dùng worktree khi việc không đụng file đã đổi trên nhánh chưa merge, hoặc merge nhánh vào `main` trước.

## Lệnh
- `make check` — lint + build + test. **Phải xanh trước khi báo xong việc.**
- `make test` / `make build` / `make lint` / `make format` / `make run`
- `make install` — build `.app` rồi cài vào `/Applications/SSH Desk.app` (người dùng mở bằng icon). Phải thoát app trước.
- Không gọi thẳng `swift test`: máy chỉ có Command Line Tools, Makefile thêm cờ plugin cho Swift Testing.

## Stack & cấu trúc
- Swift 6, SwiftUI (+ AppKit khi cần), SwiftPM. Không có .xcodeproj, không có Xcode.app.
- `Sources/SSHDeskCore/` — logic thuần (model, SQLite, sinh SSH config/Tab Config, process runner, queue). Không import SwiftUI.
- `Sources/SSHDesk/` — UI SwiftUI, chỉ gọi vào SSHDeskCore.
- **UI: không dùng `@State`** (là macro, CLT thiếu plugin `SwiftUIMacros` → lỗi build). Dùng `@Local` (`Sources/SSHDesk/LocalState.swift`). `@Observable`, `@Bindable`, `@Environment` dùng bình thường.
- `Tests/SSHDeskCoreTests/` — Swift Testing (`import Testing`, `@Test`, `#expect`). Không dùng XCTest (không có trên máy).

## Quy ước
- Logic mới đặt trong SSHDeskCore và có test; View giữ mỏng.
- Format theo `.swift-format` (hook tự chạy sau khi sửa file .swift).
- UI, comment, doc viết tiếng Việt.

## Không được làm
- Không đưa password/passphrase/OTP vào file, SQLite, log, argv, env, URI, clipboard — chỉ Keychain.
- Không chạy process qua `sh -c` với input người dùng; dùng executable + argv.
- Không sửa `~/.ssh/config` hay Tab Config của người dùng; chỉ ghi file app sở hữu (`sshdesk_*`).
- Không kết nối server thật, không `StrictHostKeyChecking=no`, không commit/push nếu chưa được yêu cầu.
- Không tự thêm dependency bên ngoài; không đổi quyết định trong `docs/architecture.md` mà không qua PM.

## Harness: giao việc SSH Desk
**Mục tiêu:** làm tiếp các bước trong plan.md qua đội agent mà không đè nhau.
**Khi nào dùng:** làm tiếp tính năng, sửa theo phản hồi, chạy lại QA, viết hoặc cập nhật tài liệu → dùng skill `ssh-desk-delivery`. Câu hỏi đơn giản thì trả lời trực tiếp.

| Ngày | Thay đổi | Đối tượng | Lý do |
| --- | --- | --- | --- |
| 2026-10-22 | Thêm `qa-reviewer`, `doc-writer`, skill `ssh-desk-delivery` | agents, skills | Người dùng yêu cầu thêm agent để làm nốt việc còn lại |
| 2026-10-22 | Thêm `pm` (Opus) và `product-advisor` (Fable) | agents, skill | Người dùng cần PM chuyên điều phối và chuyên gia tư vấn và ý tưởng |

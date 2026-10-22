# Checklist QA — SSH Desk

## Bảo mật (mục nào vi phạm là "Chặn")
- Password/passphrase/OTP chỉ nằm trong Keychain. Không được xuất hiện trong argv, env (env chỉ chứa *tham chiếu*), log, SQLite, URI, TOML, `.rdp`, file xuất, chuỗi lỗi hiển thị.
- Ngoại lệ duy nhất là ADR-018: clipboard cho password **Windows**, có Concealed+Transient, tự xoá theo hạn, xoá khi thoát app. Host SSH thì không bao giờ dùng clipboard.
- Tự điền theo `PasswordAutofillPolicy` / `AskpassDecision`: host có `jumpHostID` không bao giờ được điền; host managed chỉ điền khi prompt khớp user@hostName; mỗi phiên chỉ điền một lần; cài đặt tắt tự điền phải được tôn trọng ở **mọi** đường (PTY, askpass, clipboard Windows).
- Process: dùng executable + argv, không dùng `sh -c` với input. Lệnh chạy trên server (Analyst/Monitor) là chuỗi hằng trong whitelist; chỗ duy nhất được ghép là số/IP đã validate.
- Không `StrictHostKeyChecking=no`, không `sudo`, không đọc private key, không sửa `~/.ssh/config` hay Tab Config không có tiền tố `sshdesk_`.
- Giá trị ghi vào SSH config / `.rdp` / TOML: không có newline hoặc ký tự điều khiển (chống chèn directive).
- SQL: chỉ dùng bind tham số.
- File app ghi ra: ghi atomically, quyền phù hợp (0600 cho file có metadata), đường dẫn nằm trong thư mục của app.

## Đúng ADR
- Hành vi khớp mục "Đã chốt" của ADR liên quan. Lệch thì phải có trong báo cáo coder và PM duyệt.
- Migration đánh số liên tiếp, không sửa migration cũ.

## Nối UI ↔ Core
- Mỗi cài đặt hoặc tuỳ chọn trên UI được lưu **và** được nơi dùng đọc lại. Lần theo tới argv/hằng số thật.
- Vòng đời: rời màn, thoát app, xoá host thì dừng process, đóng phiên, xoá clipboard đúng như ADR-022.
- Không dùng `@State` (phải dùng `@Local`), UI tiếng Việt, View mỏng, logic đặt trong Core.

## Test
- Logic mới trong Core có test, gồm ca biên và ca chèn ký tự.
- Test không kết nối server thật (chỉ sshd tạm trên 127.0.0.1), dọn process và file tạm sau khi chạy.

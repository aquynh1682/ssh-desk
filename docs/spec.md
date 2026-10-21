# Spec — SSH Desk

Nguồn chính: `CLAUDE_CODE_SSH_DESK_PROMPT.md`. File này chỉ tóm tắt để tra nhanh; mâu thuẫn thì file prompt thắng.

## Cho ai
Một người dùng duy nhất: DevOps engineer dùng Mac + Warp. Không đăng nhập, không nhiều người dùng, không cloud.

## MVP
- Hồ sơ máy chủ: thêm/sửa/xoá, tìm kiếm, nhóm dự án, môi trường (DEV/UAT/STG/PROD/OTHER), yêu thích.
- Hai kiểu hồ sơ: `managed` (app sinh SSH config) và `existingSSHConfigAlias` (tham chiếu alias có sẵn).
- Xác thực: key, agent, tương tác (password/passphrase/MFA); bastion qua ProxyJump.
- **Mở Warp**: Tab Config + `warp://tab_config/<stem>`; fallback **Copy lệnh SSH**.
- **Tải về / Tải lên** file hoặc thư mục; hàng đợi, huỷ, thử lại, lịch sử.
- Import/export metadata hồ sơ (không có secret).
- Lưu SQLite trong Application Support; chạy được offline với server LAN/VPN.

## Để sau MVP
File explorer 2 cột, sync/resume, server→server, tunnel, script quản trị, terminal khác.

## Không làm
Web/backend/Docker, tài khoản/tenant, terminal tự viết, AI/telemetry, auto-update bắt buộc, cần quyền root.

## Nghiệm thu
Xem mục 14 của file prompt.

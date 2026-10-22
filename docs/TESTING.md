# Kiểm thử

## Chạy kiểm tra
```
make check   # lint + build + test; phải xanh trước khi báo xong việc
make test    # chỉ test
```
Không gọi thẳng `swift test`. Máy chỉ có Command Line Tools (không Xcode.app): XCTest không có, còn Swift Testing cần plugin macro mà SwiftPM không tự nạp. `Makefile` thêm cờ `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` khi thư mục đó tồn tại (ADR-003). Test viết bằng Swift Testing (`import Testing`, `@Test`, `#expect`) trong `Tests/SSHDeskCoreTests/`.

Test tích hợp (SSH, scp, tunnel) khởi động nhiều tiến trình nên hiếm khi treo. Khi chạy tay hãy bọc timeout:
```
perl -e 'alarm 550; exec @ARGV' make check
```

## sshd tạm 127.0.0.1
Test tích hợp (`RemoteIntegrationTests`, `TransferScpIntegrationTests`, `TunnelManagerTests`, `SSHKeyTests`, `Analyst*Tests`...) dùng sshd dựng tạm trong thư mục tạm, lắng nghe `127.0.0.1` cổng ngẫu nhiên, key auth, và dọn khi xong. Chúng chứng minh ssh/scp/sftp/ControlMaster hoạt động với OpenSSH thật ở local, **không** thay cho việc thử với server thật (password, MFA, host key, bastion, shell lạ).

Lưu ý: sshd tạm ở localhost dùng chung home thật nên `ssh-copy-id -t <path>` chỉ dùng trong test (ADR-014).

## Quy tắc không chạm server thật
- Test và agent không kết nối server thật; chỉ `127.0.0.1` hoặc process giả lập.
- Không `StrictHostKeyChecking=no`; không ghi vào `~/.ssh/config` hay Tab Config của người dùng; không đặt password thật vào test hay log.
- Ví dụ trong tài liệu dùng `192.0.2.10`, `example.com`.
- Kịch bản thử tay bên dưới do người dùng chạy với server của mình.

## Chạy app
- `make run` — chạy nhanh từ SwiftPM. Một số thứ chỉ có trong `.app`: kéo thả file (UTType khai báo trong Info.plist), icon, helper `sshdesk-askpass` / `sshdesk-ctty` trong `Contents/MacOS`, ACL Keychain.
- `make app` — tạo `build/SSH Desk.app`. `make install` — cài vào `/Applications` (thoát app trước). Thử tay nên dùng bản đã cài. Lưu ý: nếu app chạy từ `build/` cũ thì chưa có thay đổi mới.

## Kịch bản thử tay (các mục còn `[~]` trong plan.md)
Dùng server của bạn (nên là server test, không phải PROD). Báo kết quả theo mã mục.

**B3 / E0 — UI máy chủ.** (1) Thêm host managed (key/agent), host dùng alias import. (2) Tìm kiếm (⌘F), lọc môi trường/yêu thích. (3) Click 1 lần chỉ chọn + hiện chi tiết; double-click hoặc Return mở Warp. (4) Copy lệnh SSH khi tắt/không có Warp. (5) Sửa, nhân bản, xoá có xác nhận. (6) Giao diện sáng/tối. (7) Thư mục: tạo, đổi tên (trùng → gộp), xoá (host về "Chưa phân loại"), kéo host vào thư mục.

**C3/C4 — Truyền file + auth prompt.** Upload/download file và thư mục (tên có khoảng trắng, Unicode). Với server hỏi password / MFA: thẻ prompt hiện đúng và câu trả lời không lộ. Host key mới và host key đổi: phải hỏi, không tự chấp nhận. Huỷ giữa chừng, thử lại, ghi đè/đổi tên/bỏ qua, thoát app khi đang truyền rồi mở lại (job thành "Bị gián đoạn").

**F2 — Màn duyệt file.** Mở tab server, duyệt, tạo thư mục, đổi tên (đích tồn tại phải hỏi), xoá file và thư mục không rỗng (có danh sách xác nhận), kéo thả hai chiều, đóng tab khi còn job (phải hỏi), mở hai tab cùng host.

**UI1 — Giao diện.** So với mockup, cả sáng/tối, logo/icon ở Dock và thanh tiêu đề.

**E1 — SSH Keys.** Liệt kê key; tạo key ed25519 có/không passphrase (không ghi đè file có sẵn); "Cài key…" lên server test bằng password, sau đó đăng nhập bằng key; đề nghị đổi host sang key.

**E2 — Password Keychain + askpass.** Lưu password cho host; Mở Warp phải đăng nhập tự động; hộp thoại Keychain có hiện không (ký ad-hoc có thể hỏi lại sau mỗi lần build); host key mới/MFA vẫn hỏi trên tty; host có bastion không tự điền; sai password không lặp lại.

**E3 — Port forward.** Thêm forward, Mở: trạng thái Đang kết nối → Đang chạy, truy cập `127.0.0.1:<lp>` được; cổng local đang bận báo đúng; Dừng; ngắt mạng thì hiện Lỗi + Chạy lại; thoát app dừng hết tunnel.

**G2/G3/G4 — Project Analyst.** Quét một thư mục Linux nhiều server: bản đồ, bảng Kết quả không đè bản đồ, nhãn cạnh đọc được; thư mục có PROD hiện hộp xác nhận lệnh; Thử kết nối; xuất Markdown/CSV; xem lịch sử. G4: server PAM (keyboard-interactive) phải tự điền password đã lưu, và không điền cho `Verification code`.

**I1/I2 — Monitor.** Chọn thư mục: thẻ hiện CPU/RAM/swap/đĩa/load/uptime, sparkline; đổi chu kỳ; Dừng/Tiếp tục; host Windows bị bỏ qua; host không phải Linux báo "Không hỗ trợ"; host đăng nhập lỗi không tự thử lại mỗi chu kỳ.

**H1/H2 — Máy Windows.** Tạo host Windows, Mở Windows App: cửa sổ tên theo tên file, `username` điền sẵn, đăng nhập được. H2: lưu mật khẩu, mở, dán (⌘V), clipboard tự xoá sau thời gian cấu hình; copy thứ khác trong thời gian đó thì không bị xoá.

**D1 — Xuất/nhập.** Xuất tất cả và chỉ thư mục đang chọn; mở file kiểm tra không có password/credentialReference; nhập lại: xem trước (mới/trùng/lỗi), Bỏ qua và Nhập thành bản sao, jump host được ánh xạ lại.

**D4 / D2 (đang hoàn thiện).** Cài đặt mở bằng ⌘, và từ sidebar; mỗi nhóm lưu và áp đúng sau khi mở lại; "Xoá mọi mật khẩu đã lưu" có xác nhận. Thoát (⌘Q) khi còn job/tunnel/Monitor/Analyst: hộp xác nhận liệt kê đúng từng loại; empty state mọi màn; phím tắt hiện trong menu.

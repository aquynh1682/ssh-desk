# Giới hạn đã biết

Gom từ mục "Rủi ro chấp nhận" và "Chưa kiểm chứng" trong [architecture.md](architecture.md) và [progress.md](progress.md). Mỗi mục: mô tả, ảnh hưởng, cách tránh, ADR nguồn.

## A. Rủi ro chấp nhận (đã biết, cố ý giữ)

### A1. Process khác cùng user có thể gọi helper askpass
- **Mô tả:** `sshdesk-askpass` đọc Keychain theo tham chiếu trong env. Helper kiểm tra cha là `/usr/bin/ssh` và Keychain item có ACL trusted apps, nhưng không chặn được hoàn toàn.
- **Ảnh hưởng:** malware chạy dưới cùng user có thể lấy password đã lưu (vốn cũng đọc được nhiều thứ khác ở mức quyền này).
- **Tránh:** chỉ lưu password cho host cần; ưu tiên SSH key/agent; tắt "tự điền mật khẩu đã lưu" khi cài đặt xong (D4).
- **ADR:** 010.

### A2. ProxyJump của host imported
- **Mô tả:** host alias import từ `~/.ssh/config` mà config của bạn có `ProxyJump`: app không biết có bastion. Hệ quả: askpass/tự điền password PTY có thể trả password của đích cho prompt của bastion (ssh con thừa kế env, cha cũng là `/usr/bin/ssh`). Host managed có `jumpHostID` thì không tự điền.
- **Ảnh hưởng:** lộ password đích cho bastion (chỉ khi dùng password lưu cho host imported đó).
- **Tránh:** không lưu password cho host imported đi qua bastion; khai báo host managed + bastion trong app.
- **ADR:** 010 (và 010b).

### A3. Clipboard mật khẩu máy Windows
- **Mô tả:** khi Mở Windows App với password lưu, password được đặt lên clipboard (concealed + transient), tự xoá sau 10/30/60/90 giây (mặc định 30) chỉ khi clipboard vẫn là giá trị app đặt; thoát app thì xoá ngay.
- **Ảnh hưởng:** trong thời gian đó app khác trên Mac đọc được; nếu bật chia sẻ clipboard của RDP, password có thể đồng bộ sang clipboard máy Windows. Trình quản lý clipboard không tuân chuẩn nspasteboard vẫn có thể lưu lịch sử.
- **Tránh:** tắt "chia sẻ clipboard" cho host đó; không lưu password, tự nhập trong Windows App; rút ngắn thời gian xoá.
- **ADR:** 018.

### A4. Đổi tên (rename) qua sftp có race
- **Mô tả:** sftp rename ghi đè im lặng (posix-rename). App liệt kê kiểm tra đích trước rồi mới hỏi, nhưng giữa kiểm tra và rename có khoảng hở.
- **Ảnh hưởng:** nếu ai đó tạo file cùng tên đúng lúc đó, file bị ghi đè không hỏi.
- **Tránh:** tránh đổi tên trong thư mục đang bị người/tiến trình khác ghi.
- **ADR:** 013.

### A5. Upload có thể ghi đè trên server
- **Mô tả:** scp không có no-clobber, kiểm tra tên trùng không nguyên tử. Upload thư mục trong màn duyệt file **gộp** vào thư mục trùng tên (file trùng bị ghi đè); sheet Tải lên cũ ở màn Máy chủ thì lồng vào trong.
- **Ảnh hưởng:** file cùng tên trên server có thể bị ghi đè; không resume.
- **Tránh:** đọc kỹ hộp thoại xung đột; đặt tên đích duy nhất.
- **ADR:** 008, 013.

### A6. Symlink khi truyền file
- **Mô tả:** upload thư mục có symlink bị từ chối (liệt kê symlink); upload trực tiếp symlink cũng bị từ chối. Download: server tự dereference, app không kiểm soát được.
- **Ảnh hưởng:** tải về có thể lấy cả nội dung nằm ngoài cây thư mục nếu có symlink trỏ ra ngoài.
- **Tránh:** kiểm tra thư mục nguồn trên server trước khi tải đệ quy.
- **ADR:** 008.

### A7. Tunnel "Đang chạy" dựa trên thử bind
- **Mô tả:** trạng thái "Đang chạy" suy từ việc cổng local bị ssh giữ (thử bind, không SO_REUSEADDR), không phải từ xác nhận đích. Timeout kết nối 60 giây. Không tự chạy lại khi rớt (hiện Lỗi + nút Chạy lại); `ServerAlive*` giúp phát hiện tunnel chết ngầm. Sửa forward phải Dừng trước.
- **Ảnh hưởng:** tunnel báo "Đang chạy" nhưng đích remote có thể không lắng nghe; một process khác chiếm cổng đúng lúc có thể bị nhận nhầm.
- **Tránh:** thử kết nối thật tới `127.0.0.1:<lp>` sau khi mở.
- **ADR:** 011.

### A8. Project Analyst chỉ thấy kết nối đang mở, chỉ Linux
- **Mô tả:** phát hiện luồng từ `ss` tại thời điểm quét; kết nối ngắn hạn hoặc không hoạt động lúc đó không thấy. Server không có `ss`/`bash`/`timeout`, hoặc không phải Linux thì báo rõ. User thường có thể không thấy tên process ("không rõ"). IPv6 chỉ probe qua `nc -6`. `nc` exit 1 không thông điệp = "không phân biệt được timeout hay bị từ chối". Nguyên nhân lỗi chỉ ghi "chưa xác nhận". Đích ngoài project chỉ được đếm, không vẽ.
- **Ảnh hưởng:** bản đồ có thể thiếu cạnh; kết quả "Failed" không nói rõ vì sao.
- **Tránh:** quét lúc hệ thống đang có tải; dùng quyền đủ để thấy process; đối chiếu bằng tay.
- **ADR:** 016.

### A9. Monitor chỉ Linux, v1 hạn chế
- **Mô tả:** đọc `/proc` + `df`; host khác hoặc thiếu `/proc` báo "Không hỗ trợ". Không có top tiến trình, lịch sử dài hạn, cảnh báo, mạng/IO. Sparkline chỉ trong RAM. Host kết nối thất bại không tự thử lại mỗi chu kỳ (tránh khoá tài khoản khi sai password), phải bấm "Thử lại". CPU lần đọc đầu hiện "—".
- **Ảnh hưởng:** không dùng thay hệ thống monitoring thật.
- **Tránh:** xem Monitor như bảng xem nhanh.
- **ADR:** 019.

### A10. Host Windows bị loại khỏi nhiều tính năng
- **Mô tả:** máy Windows chỉ khai báo + Mở Windows App. Không truyền file, Analyst, Monitor, SSH Keys, Warp, port forward, Keychain SSH, và không làm bastion. Mật khẩu không đưa được vào Windows App qua kênh chính thức.
- **Ảnh hưởng:** phải dán password thủ công (A3) hoặc nhập trong Windows App.
- **ADR:** 017, 018.

### A11. Xoá đệ quy do app tự làm
- **Mô tả:** sftp không có xoá đệ quy; app liệt kê cây, xác nhận, xoá từng file rồi rmdir từ dưới lên. Không đi theo symlink (xoá chính link). Quyền theo user SSH, không sudo.
- **Ảnh hưởng:** thư mục lớn xoá chậm; nếu giữa chừng lỗi thì xoá dở.
- **ADR:** 013.

### A12. Socket ControlMaster ở `/tmp`
- **Mô tả:** thư mục `/tmp/sshdesk-<uid>` (0700, kiểm lstat owner/mode). Chọn `/tmp` vì giới hạn độ dài `sun_path`.
- **Ảnh hưởng:** app crash có thể để lại socket/master; app dọn socket cũ khi mở lại tab. Một master/host nên màn Truyền file / Analyst / Monitor cùng host dùng chung và có lúc báo "đang dùng".
- **ADR:** 013, 016.

### A13. Ký ad-hoc, không notarize
- **Mô tả:** `.app` ký ad-hoc, không notarize, không App Sandbox.
- **Ảnh hưởng:** Gatekeeper có thể cảnh báo nếu chuyển sang máy khác; ACL Keychain có thể hỏi lại sau mỗi lần build (xem B2). Kéo thả file chỉ chắc chắn trong `.app`, không đảm bảo với `swift run`.
- **ADR:** 001, 013.
- **Ký bằng chứng chỉ tự tạo (ADR-023):** chứng chỉ tự ký không được Gatekeeper công nhận (không ảnh hưởng app build tại máy, không bị quarantine). Item Keychain tạo khi còn ký ad-hoc mang ACL cũ nên lần đầu sau khi đổi có thể hỏi quyền một lần (chọn Luôn cho phép). Mất/xoá chứng chỉ thì build quay về ad-hoc. Makefile mở rộng `$` trong `SIGN_IDENTITY=`: tên có `$` phải đặt bằng biến môi trường `SSHDESK_SIGN_IDENTITY`. Chưa thử thật trên máy. **ADR:** 023.

### A14. Phụ thuộc vào Warp, OpenSSH, Windows App
- **Mô tả:** app chỉ biết "đã yêu cầu mở Warp", không biết Warp có thực sự mở tab. Hành vi theo OpenSSH 10.3p1 / Warp 0.2026.10.14 / Windows App 11.4.0 đã kiểm tra; `scp -O` chưa thử.
- **Ảnh hưởng:** nâng cấp các công cụ này có thể đổi hành vi.
- **ADR:** 007, 008, 017.

### A15. Dữ liệu cục bộ
- **Mô tả:** SQLite không mã hoá (không chứa secret). Lịch sử Analyst giữ N lần mỗi thư mục (mặc định 50); đổi tên thư mục không đổi tên trong lịch sử cũ. Xuất JSON không chứa secret nhưng chứa host/user/đường dẫn key, nên coi là nhạy cảm vừa phải.
- **ADR:** 005, 016, 020.

### A16. CLI/URL: request file giả mạo, hết hạn, không có Windows
- Process cục bộ cùng user ghi được file request trong thư mục app thì **bỏ qua hộp xác nhận cho host không PROD** (PROD vẫn hỏi). Chấp nhận vì process đó vốn chạy được `ssh` trực tiếp, không mở thêm quyền. URL từ web luôn xác nhận vì không tạo được file request.
- Request hết hạn sau 30 giây: nếu app khởi động chậm hơn (hoặc `createdAt` ở tương lai quá 5 giây) thì bị bỏ, chạy lại lệnh.
- CLI v1 không hỗ trợ máy Windows (exit 3) và không có lệnh nào ngoài `list`/`open`/`help`.
**ADR:** 025.

### A17. Kho secret Secure Enclave (ADR-004c, 030)
- **Đổi máy / cài lại macOS mất mật khẩu:** khoá Secure Enclave gắn với máy (`ThisDeviceOnly`), không backup, không xuất. Khôi phục sang máy khác hoặc cài lại macOS thì mọi password/passphrase đã lưu không giải mã được; phải nhập lại (app báo "Mật khẩu đã lưu không còn dùng được trên máy này"). **Tránh:** giữ password trong trình quản lý mật khẩu của bạn.
- **Process tin cậy vẫn đọc được:** Secure Enclave chống trích xuất khoá, không chống process cùng user mà Keychain cho phép (app + helper) gọi giải mã trên chính máy này. Mức bảo vệ chính vẫn là ACL Keychain như A1.
- **Không Touch ID:** không dùng được `.userPresence` với cách lưu hiện tại (đã kiểm chứng lỗi -34018).
- **Máy không có Secure Enclave:** không lưu được mật khẩu (không lưu plaintext); Intel không T2 không phải mục tiêu.
- **Passphrase của bộ không tự điền ngoài Warp:** Truyền file, Tunnel, Analyst, Monitor, Cài key luôn hỏi. Lý do bảo mật: server có thể in prompt giả `Enter passphrase for key`, passphrase sẽ bị gửi lên server qua PTY.
- **Trạng thái "đã có mật khẩu" trong form** có thể vẫn đúng khi mục đã không còn giải mã được; chỉ khi dùng mới biết.
- **Gán bộ chỉ theo thư mục:** bảng máy chủ chưa chọn nhiều dòng; gán cho vài host riêng lẻ thì dùng form từng host.
- **ADR:** 004b, 004c, 030.

### A18. Hỏi mật khẩu lần đầu (ADR-029)
- **Kiểm tra mở thêm một kết nối:** trước khi lưu, app đăng nhập thử (mở rồi đóng master). Server giới hạn số lần thử/đăng nhập hoặc có fail2ban sẽ thấy thêm một lần đăng nhập; mật khẩu sai là một lần thất bại.
- **Máy imported alias không hỏi:** app không biết user@host thật của alias trong `~/.ssh/config`, nên không hiện sheet; mật khẩu nhập trong terminal như cũ.
- **Mật khẩu tạm nằm trong bộ nhớ app trong thời gian phiên** (String Swift không xoá chủ động được), giống luồng PTY hiện có. Không ghi file/log/DB/Keychain khi không tích lưu; bỏ khi đóng phiên hoặc đổi địa chỉ máy.
- **Warp không nhận mật khẩu tạm:** không tích lưu thì Warp luôn để bạn gõ trong terminal (không đi qua env/argv/Tab Config).
- **Nút "Mở Warp" trong UI không hỏi xác nhận PROD** (chỉ URL scheme/CLI có); hành vi cũ, không đổi bởi ADR-029. Với PROD, sheet mật khẩu vẫn xác nhận PROD trước.
- **ADR:** 029.

### A19. Khoá SSH trong Secure Enclave (ADR-027)
- **Khoá gắn máy:** private key nằm trong chip, không backup, không xuất. Đổi máy hoặc cài lại macOS là mất khoá; phải tạo khoá mới và cài lại lên server (nên giữ thêm một khoá dự phòng).
- **Xoá không khôi phục được**, và server vẫn tin public key cũ cho tới khi bạn gỡ khỏi `authorized_keys`.
- **Server cũ không hỗ trợ `sk-ecdsa`:** cần OpenSSH server >= 8.2; server cũ hơn sẽ từ chối khoá.
- **`ssh-keygen -K` timeout 90 giây, không có nút Huỷ:** tạo khoá phải chờ hết hoặc xong.
- **Identity tạo ngoài app chỉ xem** (khác `p-256-ne` hoặc nhãn không hợp lệ); nhiều identity trùng nhãn thì từ chối xoá. `sc_auth delete-ctk-identity` exit 0 cả khi lỗi nên app kiểm lại bằng list.
- **Phụ thuộc file hệ thống** `/usr/lib/ssh-keychain.dylib` và `sc_auth`; thiếu thì mục này ẩn.
- **ADR:** 027.

## B. Chưa kiểm chứng (với hệ thống thật)

### B1. Truyền file với server thật
Auth password/MFA/host key qua `ssh`/`scp` thật, helper `sshdesk-ctty` được tìm thấy khi chạy từ `.app`, `scp -O`, app mở từ Finder (`SSH_AUTH_SOCK`). Mới thử bằng sshd tạm `127.0.0.1`. **Ảnh hưởng:** có thể gặp khác biệt ở server dùng shell/SFTP lạ. **Tránh/làm:** thử kịch bản C3/C4/F2 trong [TESTING.md](TESTING.md). **ADR:** 008, 013.

### B2. Password Keychain + askpass
Prompt `password:` qua askpass với ssh thật; hộp thoại ACL Keychain khi chạy từ `.app` (ký ad-hoc có thể hỏi lại sau mỗi lần build, chọn "Always Allow" mỗi lần). **ADR:** 010.

### B3. Prompt PAM / keyboard-interactive
Tự điền `(user@host) Password:` (G4) chưa thử với server PAM thật (Ping-Identity). Prompt dạng khác (`Verification code`, `OTP`, `Password for ...`, `Password:` trơn) cố ý không tự điền. **Tránh:** nhập tay nếu không khớp. **ADR:** 010b.

### B4. Monitor
Chưa chạy với server Linux thật và chưa duyệt giao diện. **ADR:** 019.

### B5. Windows App
Chưa biết Windows App có nhớ password cho file `.rdp` mở ngoài không (người dùng báo là không); chưa thử SSH tunnel cho RDP (lệch tên chứng chỉ); `.rdp` trên Mac chưa có tài liệu chính thức. **ADR:** 017, 018.

### B9. Agent ngoài (IdentityAgent)
Chưa cài/thử thật với 1Password, Bitwarden, Secretive. Đường dẫn socket Secretive (`~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`) **chưa có nguồn chính thức**; Bitwarden bản App Store dùng đường dẫn khác, phải chọn Tuỳ chỉnh. Agent đòi Touch ID/xác nhận mà kết nối chạy `BatchMode` (Project Analyst, Monitor) có thể bị timeout hoặc thất bại vì không có ai bấm xác nhận kịp. Socket không tồn tại chỉ cảnh báo trong form, không chặn lưu. **ADR:** 024.

### B6. Giao diện
Chưa chạy thử: ⌘F focus, Return mở Warp, sidebar disabled, dark/light, bảng host tự dựng (ScrollView + LazyVStack) với phím/double-click. **ADR:** 012, 015.

### B7. Port forward, SSH Keys, Xuất/nhập
Chưa thử tay với server thật. **ADR:** 011, 014, 020.

### B8. Cài đặt (D4) và vòng đời app (D2) — đang hoàn thiện
Chưa xong lúc viết tài liệu; mục tương ứng sẽ cập nhật khi hoàn tất. **ADR:** 021, 022.

### B10. CLI `sshdesk` và URL scheme (ADR-025)
Chưa thử trên máy thật: (1) scheme `sshdesk://` có đăng ký với LaunchServices sau `make install` (có thể phải mở app một lần); (2) Apple Event khi app tắt hoặc đang chạy; SwiftUI `WindowGroup` có thể mở thêm cửa sổ; (3) `sshdesk open` end-to-end; (4) nhánh dự phòng mở DB `mode=ro` / `immutable=1` có thật sự cần không (`immutable` chỉ dùng khi không có `-wal`). Script Alfred/Raycast trong README chưa chạy thử. **Tránh/làm:** kịch bản K3 trong [TESTING.md](TESTING.md). **ADR:** 025.

### B11. Bộ đăng nhập và kho Secure Enclave (ADR-030, 004c)
Chỉ có test đơn vị (khoá phần mềm; test SE thật có điều kiện) và sshd tạm; chưa thử trên `.app` đã cài: (1) migration chuyển password cũ không mất; (2) askpass dưới Warp không hiện hộp thoại Keychain khi ký bằng chứng chỉ; (3) hành vi khi mất khoá `local.sshdesk.sekey`; (4) passphrase của bộ qua Warp với server thật; (5) luồng hold/"Xác nhận" sau khi nhập file. **Tránh/làm:** kịch bản K4s/K4e trong [TESTING.md](TESTING.md). **ADR:** 004c, 030.

### B12. Nguồn máy chủ Excel/CSV, JSON, Ansible (ADR-026)
Chỉ có test đơn vị (đọc XLSX kiểm chứng bằng `unzip`/`zip` của macOS, Spotlight/QuickLook nhận được XML tối thiểu); chưa thử tay trên `.app`.
- **File mẫu chưa mở thử trong Excel/Numbers:** file có thêm cột rộng, chữ đậm, validation Port 1–65535 so với XML tối thiểu đã kiểm; dropdown Môi trường/Loại chưa xem thực tế. **Làm:** kịch bản K4a trong [TESTING.md](TESTING.md).
- **Không tính công thức:** ô có công thức chỉ lấy giá trị đã lưu (cache); không có giá trị thì để trống, app cảnh báo số ô công thức. Không đọc `.xls`, `.xlsm`, liên kết ngoài.
- **Tiêu đề bị coi là cột bí mật:** nhận diện rộng (password, mật khẩu, secret, passphrase, otp, token, api key, credential...), nên tiêu đề tiếng Anh "Credential Set" cũng bị bỏ qua. **Tránh:** dùng tiêu đề "Bộ đăng nhập" (đúng mẫu).
- **Phát hiện file đổi chỉ khi mở hoặc kích hoạt app** (mtime + fingerprint), không theo dõi liên tục.
- **Bảng chọn một dòng:** chưa chọn nhiều máy để thao tác hàng loạt.
- Lệnh xuất JSON riêng, NetBox/Proxmox/AWS để sau.
- **Nguồn JSON/Ansible chỉ có test đơn vị, chưa thử với inventory thật.** Làm: kịch bản K4b trong [TESTING.md](TESTING.md).
- **Ansible YAML là tập con:** không chuỗi nhiều dòng, không danh sách, không anchor/alias; tag `!` ngoài `!vault` báo lỗi. Lỗi cú pháp YAML = lỗi cả file.
- **Ansible chỉ tĩnh:** không `host_vars/`, `group_vars/`, không inventory động/plugin.
- **Giới hạn Ansible:** pattern host ≤255 ký tự và ≤8 khoảng (`web[01:03]`); ≤100 tag mỗi máy.
- **`ansible_connection=local/winrm` vẫn nhập như máy SSH** (không lọc).
- **"Dòng N" của JSON** là thứ tự máy trong mảng `hosts`, không phải số dòng file.
- **Chưa quyết:** có cho lưu mật khẩu từ cột mật khẩu vào Keychain không (hiện luôn bỏ qua).
- Giới hạn cứng: file nén ≤ 20 MB, ≤ 5000 dòng, ≤ 200 cột; CSV ≤ 5 MB.
- **ADR:** 026, 030.

### B13. Hỏi mật khẩu lần đầu (ADR-029)
Chỉ có test đơn vị và ssh giả; **chưa thử với server thật**: host key mới, mật khẩu đúng/sai, mất mạng, bộ sai + cập nhật bộ, OTP, Monitor/Analyst nhiều máy, sheet lồng Tải về/Tải lên + Esc, Windows. Kịch bản: TESTING mục K4c.
- **ADR:** 029, 030.

### B14. Khoá Secure Enclave (ADR-027)
Đã kiểm chứng bằng lệnh tay (macOS 27, OpenSSH_10.3p1) và test đơn vị/`-t none` với sshd tạm 127.0.0.1. **Chưa kiểm chứng:**
- `-t bio` (Touch ID mỗi lần ký) khi tạo và khi đăng nhập qua Warp.
- Kết nối `BatchMode` (Project Analyst, Monitor) với khoá Touch ID: có thể timeout hoặc thất bại vì không ai kịp chạm Touch ID.
- `ssh-copy-id` với `.pub` sk-ecdsa lên server thật.
- Hành vi prompt PIN/passphrase của `-K` trên các phiên bản macOS khác.
Kịch bản: TESTING mục K5. **ADR:** 027.

### B15. Monitor Prometheus/Zabbix (ADR-028)
Chỉ có test đơn vị (`URLProtocol` giả); **chưa thử** với Prometheus/Zabbix thật, TLS thật (kể cả CA nội bộ), và hành vi ATS khi chạy `.app`. Kịch bản: TESTING mục K6.
- Gán nguồn theo **tên** thư mục: đổi tên thư mục thì thư mục đó về SSH.
- Zabbix: không có swap; chỉ none/Bearer (không Basic, không đăng nhập bằng mật khẩu).
- Prometheus: mỗi máy 6 truy vấn chạy song song, nhiều máy thì tải lên Prometheus tăng theo.
- http tới tên miền đầy đủ (FQDN) bị ATS chặn; chỉ http tới IP, tên không dấu chấm, `.local` chạy được. Có cho phép rộng hơn không là **câu hỏi mở đang chờ người dùng quyết**.
- Không tắt được kiểm tra TLS; CA nội bộ phải tự tin cậy trong macOS.
- Nguồn metrics không hỏi xác nhận PROD (không chạy lệnh trên server).
- Đợt này không có nhật ký phiên, cảnh báo/thông báo macOS, liên kết Grafana.
- **ADR:** 028.

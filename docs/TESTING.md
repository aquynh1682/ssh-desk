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

**E2 — Password Keychain + askpass.** Lưu password cho host; Mở Warp phải đăng nhập tự động; hộp thoại Keychain có hiện không (ký ad-hoc có thể hỏi lại sau mỗi lần build; ký bằng chứng chỉ thì xem K1); host key mới/MFA vẫn hỏi trên tty; host có bastion không tự điền; sai password không lặp lại.

**E3 — Port forward.** Thêm forward, Mở: trạng thái Đang kết nối → Đang chạy, truy cập `127.0.0.1:<lp>` được; cổng local đang bận báo đúng; Dừng; ngắt mạng thì hiện Lỗi + Chạy lại; thoát app dừng hết tunnel.

**G2/G3/G4 — Project Analyst.** Quét một thư mục Linux nhiều server: bản đồ, bảng Kết quả không đè bản đồ, nhãn cạnh đọc được; thư mục có PROD hiện hộp xác nhận lệnh; Thử kết nối; xuất Markdown/CSV; xem lịch sử. G4: server PAM (keyboard-interactive) phải tự điền password đã lưu, và không điền cho `Verification code`.

**I1/I2 — Monitor.** Chọn thư mục: thẻ hiện CPU/RAM/swap/đĩa/load/uptime, sparkline; đổi chu kỳ; Dừng/Tiếp tục; host Windows bị bỏ qua; host không phải Linux báo "Không hỗ trợ"; host đăng nhập lỗi không tự thử lại mỗi chu kỳ.

**H1/H2 — Máy Windows.** Tạo host Windows, Mở Windows App: cửa sổ tên theo tên file, `username` điền sẵn, đăng nhập được. H2: lưu mật khẩu, mở, dán (⌘V), clipboard tự xoá sau thời gian cấu hình; copy thứ khác trong thời gian đó thì không bị xoá.

**D1 — Xuất/nhập.** Xuất tất cả và chỉ thư mục đang chọn; mở file kiểm tra không có password/credentialReference; nhập lại: xem trước (mới/trùng/lỗi), Bỏ qua và Nhập thành bản sao, jump host được ánh xạ lại.

**K1 — Ký bằng chứng chỉ (ADR-023).** Tạo chứng chỉ theo README. (1) `make install SIGN_IDENTITY="SSH Desk Local"`, chạy `codesign -d -r- "/Applications/SSH Desk.app"` và ghi lại dòng designated requirement. (2) Build + cài lần hai, chạy lại lệnh: DR phải giống hệt lần một (ad-hoc thì đổi). (3) Lưu password cho một host, mở Warp (askpass đăng nhập); build lại, mở Warp lần nữa: không hộp thoại Keychain hỏi lại (lần đầu sau khi đổi từ ad-hoc có thể hỏi một lần, chọn Luôn cho phép). (4) Thử `SIGN_IDENTITY="không-tồn-tại"`: build vẫn xong, có cảnh báo ký ad-hoc.

**K2 — IdentityAgent (ADR-024).** Cần đã cài 1Password và bật SSH agent. (1) Sửa host managed → Nâng cao → Agent: 1Password, lưu. (2) Kiểm config sinh ra: `ssh -G -F "$HOME/Library/Application Support/SSHDesk/ssh/config" sshdesk-<uuid> | grep -i identityagent` phải ra đường dẫn socket 1Password. (3) Màn SSH Keys → thẻ "Key trong agent" liệt kê public key. (4) Mở Warp tới server test dùng key trong agent (IdentityFile trống). (5) Đặt mặc định ở Cài đặt → SSH config, host để "Theo mặc định": `ssh -G` ra cùng giá trị; đổi sang "Hệ thống": không còn dòng identityagent do app ghi. (6) Host imported/Windows: không có picker agent. Bitwarden/Secretive: chỉ thử nếu có cài.

**D4 / D2 (đang hoàn thiện).** Cài đặt mở bằng ⌘, và từ sidebar; mỗi nhóm lưu và áp đúng sau khi mở lại; "Xoá mọi mật khẩu đã lưu" có xác nhận. Thoát (⌘Q) khi còn job/tunnel/Monitor/Analyst: hộp xác nhận liệt kê đúng từng loại; empty state mọi màn; phím tắt hiện trong menu.

**K3 — CLI và `sshdesk://` (ADR-025).** Cần `make install` (thoát app trước), mở app một lần để LaunchServices đăng ký scheme, tạo symlink theo README.
1. Khi app **đang chạy**: `open 'sshdesk://open?name=<tên host SSH>'` -> hộp xác nhận (tên, môi trường, user@host) -> xác nhận thì Warp mở; Huỷ thì không mở. Ghi lại có mở thừa cửa sổ app không.
2. Thoát app (⌘Q), chạy lại lệnh trên: app tự khởi động, hộp xác nhận hiện; kiểm tra có **mở thừa cửa sổ** SwiftUI không.
3. `sshdesk open <tên>` với host không PROD: mở ngay, không hỏi. Host PROD: hộp xác nhận trong app (kiểu cảnh báo). Thử cả khi app tắt.
4. URL lạ phải bị từ chối và báo: `open 'sshdesk://open?name=x&cmd=ls'`, `sshdesk://open` không tham số, `sshdesk://cli?request=khong-ton-tai`, giá trị quá 256 ký tự. Host Windows: "chưa hỗ trợ" (exit 3).
5. `sshdesk list`, `sshdesk list --folder <tên>`, `sshdesk list --json` (kiểm tra JSON hợp lệ, không có credentialReference/ghi chú); `sshdesk bogus` -> exit 2; `echo $?` sau mỗi lệnh.
6. Thư mục `~/Library/Application Support/SSHDesk/requests/` không còn file sau khi mở. Chạy `sshdesk list` khi app đang ghi DB: không lỗi khoá lâu.
7. Alfred/Raycast: thử script trong README nếu dùng.

**K4s — Bộ đăng nhập (ADR-030).** Dùng `make install`, server test.
1. Cài đặt → Bảo mật: tạo bộ (user, password, tuỳ chọn key + passphrase). Gán cho một host qua form; mở Warp: đăng nhập tự động.
2. Gán bộ cho cả thư mục bằng "Gán bộ đăng nhập…" (menu thư mục): xem trước số host, host có mật khẩu riêng vẫn dùng mật khẩu riêng.
3. Sửa password của bộ: mọi host dùng bộ nhận password mới (mở Warp lại). Xoá bộ: host mất liên kết nhưng còn; không lỗi.
4. Host có mật khẩu riêng + bộ: chi tiết máy ghi "Mật khẩu riêng (ưu tiên hơn bộ ...)"; mở Warp dùng mật khẩu riêng; bấm "Xoá mật khẩu riêng" thì chuyển sang password của bộ.
5. Passphrase: bộ có key mã hoá passphrase, mở bằng Warp -> tự điền một lần. Mở cùng host qua Truyền file/Tunnel/Analyst/Monitor -> phải hỏi bằng thẻ prompt, không tự điền.
6. Nhập JSON có trường bộ đăng nhập: xem trước báo tên bộ chưa có sẽ tạo bộ rỗng; sau nhập host bị tạm tắt tự điền, mở Warp báo cần xác nhận; mở chi tiết máy bấm "Xác nhận" -> tự điền lại. File xuất không chứa password/passphrase/đường dẫn key của bộ.

**K4e — Kho Secure Enclave + migration (ADR-004b/004c).** Cần bản có password đã lưu từ trước, rồi `make install` (ký chứng chỉ, ADR-023). Ghi lại kết quả.
1. Mở app lần đầu, vào Keychain Access (login), tìm `local.sshdesk`: hết item `local.sshdesk.credentials`; có `local.sshdesk.sekey` và `local.sshdesk.sealed` (mỗi tham chiếu một item). Mật khẩu cũ vẫn tự điền khi mở Warp, không phải nhập lại.
2. Lưu mật khẩu mới cho host và bộ: thêm item `sealed`; mở Warp vẫn đăng nhập tự động.
3. Thoát app, xoá item `local.sshdesk.sekey`, mở lại: host có mật khẩu lưu hiện "Mật khẩu đã lưu không còn dùng được trên máy này", không tự điền, không crash; nhập lại thì dùng được.
4. Askpass dưới Warp (ký bằng chứng chỉ, ADR-023): không hiện hộp thoại Keychain; build + cài lại cũng không hỏi lại.
5. "Xoá mọi mật khẩu đã lưu" (có xác nhận): item `sealed` bị xoá, khoá `sekey` còn lại.

**K4a — Nguồn máy chủ Excel/CSV (ADR-026).** Cần `make install`. Dùng dữ liệu giả (`192.0.2.x`, `example.com`), không cần server thật. Chưa ai chạy mục này; ghi lại kết quả.
1. **File mẫu:** hub "Nguồn máy chủ" (nút ở header THƯ MỤC, menu Tệp, menu Xuất/nhập) -> "Tải file mẫu…" -> lưu. Mở bằng **Excel và Numbers**: có 2 sheet ("Máy chủ", "Hướng dẫn"); cột Môi trường và Loại có dropdown; cột Port từ chối giá trị ngoài 1–65535; tiêu đề đậm, cột đủ rộng. Ghi lại chỗ nào hiển thị sai hoặc báo file hỏng. Lệnh `make template` tạo lại bản trong `docs/templates/` (không ghi đè).
2. **Nhập file đúng mẫu:** điền 3–5 dòng, trong đó 1 dòng lỗi (vd Port 70000 hoặc thiếu IP), một dòng có Jump host trỏ tên máy khác trong file. Lưu, "Thêm nguồn": vào thẳng xem trước (không hỏi ghép cột). Lỗi hiện theo dòng (số dòng, cột, lý do); dòng lỗi bị bỏ qua; các dòng còn lại áp dụng được. Sau Áp dụng: máy có trong thư mục, form khoá các trường do nguồn quản lý.
3. **Đổi trong file:** sửa IP một máy, lưu file, quay lại app (kích hoạt app): banner "Nguồn có thay đổi" -> Xem trước (IP cũ -> mới) -> Áp dụng. Máy đó bị tạm tắt tự điền mật khẩu (chi tiết máy ghi lý do; mở Warp báo cần xác nhận) -> bấm "Xác nhận" -> tự điền lại. Xoá một dòng khỏi file rồi đồng bộ: máy hiện "Không còn trong nguồn", không bị xoá.
4. **File khách + cột mật khẩu:** file Excel tự làm có cột "Mật khẩu" hoặc "Password" (và thử "Token"): app báo "sẽ bỏ qua", cột đó không chọn được ở bất kỳ ô ghép nào, giá trị không hiện trong xem trước. Tiêu đề lạ: chọn sheet/dòng tiêu đề, app đoán cột VN/EN, ghép tay phần còn lại. "Đồng bộ lại" và "Chọn file mới…" không hỏi ghép cột lần hai nếu tiêu đề không đổi.
5. **CSV có `;`:** file CSV UTF-8 dùng `;` (xuất từ Excel Việt) và một file có BOM: nhập đúng cột, tiếng Việt không vỡ dấu.
6. **Tách và xoá nguồn:** "Tách khỏi nguồn" ở một máy: máy thành máy tạo tay, sửa được, đồng bộ sau không đụng tới. Xoá nguồn: mọi máy vẫn còn.
7. **Từ chối an toàn:** đổi đuôi `.xls`/`.xlsm` hoặc file không phải zip: báo lỗi rõ, không crash.

**K4b — Nguồn JSON và Ansible (ADR-026).** Cần `make install`. Dùng dữ liệu giả (`192.0.2.x`, `example.com`), không cần server thật. Chưa ai chạy mục này; ghi lại kết quả.
1. **INI:** file có `[web]` với `web[01:03].example.com ansible_host=192.0.2.11 ansible_user=deploy`, `[db]`, `[prod:children]` gồm web và db, `[web:vars]` đặt `ansible_port=2222`, một host có `ansible_password=x`. "Thêm nguồn" -> Ansible: xem trước có 3 máy web (01..03) với port 2222, tag theo group (web, prod); cảnh báo "đã bỏ qua biến mật khẩu"; mật khẩu không hiện ở xem trước, ghi chú hay chi tiết máy.
2. **YAML:** file `all/children/hosts` có một biến `!vault |` (hoặc `ansible_password` kiểu !vault): bỏ qua kèm cảnh báo, các máy khác vẫn nhập được.
3. **Đổi ansible_host:** sửa IP một máy, quay lại app: banner "Nguồn có thay đổi" -> Xem trước (IP cũ -> mới) -> Áp dụng. Máy bị tạm tắt tự điền (chi tiết ghi lý do; mở Warp báo cần xác nhận) -> "Xác nhận địa chỉ" -> tự điền lại.
4. **Thiếu ansible_user:** máy mới dùng tên đăng nhập macOS và có cảnh báo; máy đã có giữ user cũ khi bỏ `ansible_user` khỏi file.
5. **Tag chỉ cộng thêm:** tự thêm một tag vào máy, đồng bộ lại: tag của bạn còn; group mới thêm tag mới.
6. **JSON:** xuất danh sách từ app (Xuất/nhập), "Thêm nguồn" -> JSON chọn file đó: xem trước khớp máy hiện có. Sửa một máy trong file, đồng bộ: hiện thay đổi từng trường. Lỗi hiện "Dòng N" là thứ tự máy trong mảng `hosts`.
7. **Lỗi dòng:** YAML có anchor/alias (`&a`, `*a`), danh sách (`- x`) hoặc chuỗi nhiều dòng: báo lỗi theo dòng, không crash. Pattern host quá dài hoặc >8 khoảng: máy đó bị bỏ, báo lỗi.
8. **Không process:** trong lúc đồng bộ Ansible không có tiến trình `ansible*` nào chạy (Activity Monitor).

**K4c — Hỏi mật khẩu lần đầu (ADR-029).** Cần `make install`, server thật (Linux, đăng nhập bằng mật khẩu) có thể thử. Mới chạy với ssh giả; ghi lại kết quả. Máy phải chưa lưu mật khẩu, không bastion, không imported alias, tự điền bật.
1. **Host key mới:** máy chưa từng kết nối (xoá dòng cũ khỏi known_hosts của bạn nếu cần), Mở -> sheet -> nhập mật khẩu, tích lưu: app báo "Chưa xác nhận host key", không lưu, không tự yes. Dùng "Bỏ qua, nhập trong terminal", gõ yes ở Warp, rồi thử lại.
2. **Mật khẩu đúng:** tích lưu -> lưu, mở Warp tự điền; mở lại không hỏi nữa. **Mật khẩu sai:** báo "Sai mật khẩu", nhập lại được, không có mục lưu mới (chi tiết máy vẫn "chưa lưu").
3. **Mất mạng:** ngắt mạng khi bấm Tiếp tục: sau tối đa 20 giây hỏi "Không kiểm tra được. Vẫn lưu?", nút mặc định là Không.
4. **Bộ đăng nhập:** chọn "Dùng bộ có sẵn" với bộ đúng: máy được gán bộ, không phải nhập lại. Bộ có mật khẩu sai với máy này: báo "Mật khẩu của bộ không đúng với máy này", mật khẩu bộ không đổi; nhập mật khẩu mới + xác nhận "Cập nhật mật khẩu của bộ (ảnh hưởng N máy)" thì các máy khác dùng bộ nhận mật khẩu mới. "Lưu thành bộ mới": bộ xuất hiện trong Cài đặt → Bảo mật và máy được gán.
5. **OTP/MFA:** máy có prompt thứ hai: báo mở terminal lần đầu, không lưu.
6. **Không tích lưu:** Warp -> terminal vẫn hỏi, gõ tay được, Keychain không có mục mới. Monitor/Analyst nhiều máy chưa lưu: hỏi lần lượt từng máy, Huỷ = bỏ qua máy đó; chạy xong khi đóng phiên thì hỏi lại từ đầu.
7. **Truyền file:** sheet "Tải về/Tải lên" cho máy chưa lưu hỏi mật khẩu; sheet lồng sheet nhập mật khẩu: Esc/Huỷ đóng đúng lớp, không kẹt hay mất job. Job từ tab Duyệt file dùng master của tab (không hỏi lại).
8. **Windows:** máy Windows chưa có mật khẩu -> Mở: sheet có ô "Lưu vào Keychain"; không tích thì dán được một lần (⌘V), clipboard tự xoá, không có mục Keychain mới.
9. **Mật khẩu tạm biến mất:** nhập không tích lưu cho Monitor, đóng Monitor, mở lại: phải hỏi lại. Đổi IP/Port/User của máy khi đang có mật khẩu tạm: hỏi lại.
10. **Cài đặt:** tắt "Hỏi mật khẩu khi máy chưa lưu" -> không còn sheet, quay luồng terminal hỏi. Máy PROD: xác nhận PROD trước sheet.

**K5 — Khoá Secure Enclave (ADR-027).** Cần `make install`, máy có Touch ID, server test (không PROD). Mới có test đơn vị và `-t none` với sshd tạm; ghi lại kết quả, nhất là `-t bio`.
1. **Tạo khoá Touch ID:** SSH Keys -> "Tạo khoá Secure Enclave…", nhãn `test-se`, giữ Touch ID mặc định. Có hỏi Touch ID/mật khẩu máy không, có hiện prompt lạ nào (PIN/passphrase) không; tạo xong thẻ khoá hiện, `~/.ssh/id_ecdsa_sk_rk_test-se` và `.pub` tồn tại, `.pub` loại `sk-ecdsa-sha2-nistp256@openssh.com`. Thử nhãn trùng và nhãn sai ký tự: báo lỗi; tạo lại khi file đã có: không ghi đè.
2. **Cài lên server test:** "Cài lên server…" chọn khoá đó (nhập password server nếu cần). Ghi lại: `ssh-copy-id` với `.pub` sk-ecdsa có chạy được không, server cũ (OpenSSH < 8.2) có từ chối không.
3. **Warp:** đặt IdentityFile của host là khoá này, kiểm `ssh -G -F "$HOME/Library/Application Support/SSHDesk/ssh/config" sshdesk-<uuid> | grep -i securitykeyprovider`. Mở Warp: phải hiện Touch ID mỗi lần ký (mở lần hai cũng hỏi lại).
4. **Analyst / Monitor (BatchMode):** chạy với host dùng khoá Touch ID: ghi lại có hiện Touch ID kịp không hay timeout/thất bại.
5. **Xoá khoá:** "Xoá khoá Secure Enclave": có xác nhận cảnh báo không khôi phục; xong, identity biến mất khỏi `sc_auth list-ctk-identities`, file handle trong `~/.ssh` bị xoá, các file khác không đụng. Đăng nhập bằng khoá cũ phải thất bại.
6. **Identity ngoài app:** nếu có identity tạo bằng `sc_auth` kiểu khác, app chỉ xem, không có nút xoá.
7. **Máy thiếu dylib:** (máy khác hoặc đổi tên tạm đường dẫn không được, vì là file hệ thống; chỉ ghi nhận nếu có máy không có `/usr/lib/ssh-keychain.dylib`) mục "Tạo khoá Secure Enclave" phải ẩn, không lỗi.

**K6 — Monitor từ Prometheus/Zabbix (ADR-028).** Cần `make install` và hệ thống giám sát thật (không PROD nếu tránh được). Mới có test đơn vị với `URLProtocol` giả; ghi lại kết quả.
1. **Prometheus thật:** Cài đặt -> Nguồn số liệu -> thêm Prometheus (URL https), "Thử kết nối" báo thành công. Màn Monitor: chọn nguồn cho một thư mục; thẻ CPU/RAM/swap/đĩa/load/uptime hiện số khớp với `node_exporter`/Grafana của bạn. Đổi tên thư mục: về SSH. Xoá nguồn: thư mục về SSH.
2. **Ngưỡng màu:** máy có CPU/RAM/đĩa cao (hoặc hạ ngưỡng trong Cài đặt -> Monitor): thẻ đổi màu đúng ngưỡng.
3. **Mẫu instance:** máy dùng tên/cổng khác `{{hostName}}:9100`: ban đầu thẻ báo không có dữ liệu; sửa mẫu instance trong nguồn thì có số. Mẫu có ký tự `"` hoặc `\` không làm hỏng truy vấn.
4. **Xác thực Prometheus:** Bearer đúng/sai, Basic đúng/sai: sai báo lỗi trên thẻ, không lộ header/token. Đổi URL hoặc kiểu xác thực: bắt nhập lại token.
5. **Zabbix 7:** token API (Bearer) đúng: "Thử kết nối" ok, thẻ hiện số (có tổng RAM/đĩa, số nhân, load 5/15, không có swap). **Zabbix bản cũ** (< 7.0, token trong `auth`): cùng kết quả.
6. **Zabbix token sai:** báo lỗi xác thực rõ, **không tự thử lại** (kiểm log Zabbix chỉ 1 request lỗi mỗi lần làm mới). Token thiếu quyền `host.get`/`item.get`: báo lỗi quyền.
7. **http tới tên miền nội bộ (ADR-028b):** nguồn `http://prom.corp.example.com:9090`: không còn bị ATS chặn, kết nối được; form vẫn cảnh báo đỏ. Ghi lại có đúng vậy không.
8. **http + token:** `http://192.0.2.10:9090` (và cả tên miền nội bộ) với Bearer: form hiện cảnh báo đỏ, không lưu được nếu chưa tick "Tôi hiểu token gửi không mã hoá"; tick xong thì lưu và kết nối được. Loopback (`http://127.0.0.1`) không cần tick.
9. **CA nội bộ:** https với chứng chỉ do CA nội bộ: khi CA chưa tin cậy trong macOS thì lỗi TLS (không có cách bỏ qua); sau khi tin cậy CA thì chạy.
10. **Redirect / phản hồi lớn:** URL trả 3xx bị từ chối (không theo redirect); phản hồi > 5 MB bị bỏ.
11. **Làm mới:** rời màn Monitor thì dừng gọi API; quay lại thì tiếp tục.

**K8a — Lưu mật khẩu từ cột file khách (ADR-031).** Cần `make install` và một file Excel/CSV giả (host ví dụ `192.0.2.10`, không server thật cho tới bước tự điền). Mới có test đơn vị; ghi lại kết quả.
1. **Mặc định bỏ qua:** nhập file có cột "Mật khẩu": cảnh báo "sẽ bỏ qua", tuỳ chọn lưu tắt; sau nhập máy không có mật khẩu.
2. **Bật lưu:** bật "Lưu mật khẩu từ cột ..."; xem trước chỉ hiện ••••, có số máy sẽ lưu / đã có mật khẩu riêng; bấm Áp dụng hiện xác nhận "Lưu mật khẩu cho N máy"; sau đó mở Warp máy đó, kiểm tự điền chạy (server thật hoặc sshd tạm 127.0.0.1).
3. **Máy đã có mật khẩu:** không bật "Ghi đè" thì giữ mật khẩu cũ; bật "Ghi đè" thì mật khẩu mới thay. Ô trống không đụng.
4. **Đồng bộ lại:** "Đồng bộ lại"/"Chọn file mới…" không tự lưu mật khẩu (phải bật lại); tự áp dụng khi chỉ có máy mới cũng không lưu.
5. **Nhắc xoá file gốc:** sau khi lưu có alert "Đã hiểu" nhắc xoá hoặc bảo vệ file Excel gốc.
6. **Áp dụng lỗi:** gây lỗi (ví dụ kho lỗi hoặc DB lỗi): app báo số lỗi và nhắc bật lại; kế hoạch và bộ nhớ bị bỏ, không in mật khẩu.
7. **Không lộ:** mật khẩu không có trong log, file DB, `config_json`.

**K8b — Tự thêm máy mới (ADR-026b).** Cần `make install` và nguồn Excel/CSV giả (`192.0.2.x`). Mới có test đơn vị; ghi lại kết quả.
1. **Tự thêm:** thêm một dòng máy mới vào file, quay lại app: máy được thêm luôn (không qua xem trước), banner "Đã thêm N máy"; máy không có mật khẩu.
2. **Xem:** bấm Xem trên banner: tới đúng các máy vừa thêm.
3. **Hoàn tác:** bấm Hoàn tác: các máy vừa thêm bị xoá, "Tự thêm máy mới" của nguồn tắt; lần đổi file sau hiện xem trước như cũ.
4. **Sửa rồi Hoàn tác:** tự thêm 2 máy, sửa tay một máy (vd ghi chú), Hoàn tác: máy đã sửa được giữ, máy kia bị xoá.
5. **Qua xem trước:** thêm một dòng mới và đồng thời sửa IP một dòng khác: không tự thêm, hiện banner "Nguồn có thay đổi" và xem trước. Tương tự khi có dòng lỗi, thiếu `ansible_user` hoặc cột mật khẩu.
6. **Toggle:** tắt "Tự thêm máy mới" rồi thêm dòng: qua xem trước.

**K9 — Tự gõ mật khẩu vào Windows App (ADR-018b).** Cần `make install`, một máy Windows thật (không PROD), Windows App 11.4. Mới có test đơn vị; ghi lại kết quả, nhất là mục 3.
1. **Chưa có quyền:** System Settings → Privacy & Security → Accessibility chưa bật SSH Desk. Mở Windows App cho máy có mật khẩu đã lưu: hiện hộp xin quyền + thông báo "lần này dùng clipboard"; mật khẩu được copy, dán bằng ⌘V đăng nhập được.
2. **Cấp quyền:** bật SSH Desk trong Accessibility, thoát và mở lại app nếu macOS yêu cầu.
3. **Tự gõ:** Mở lại: app chờ tới khi ô mật khẩu hiện, gõ mật khẩu và Return, đăng nhập được. Ghi lại: ô có đúng là `AXSecureTextField` không (nếu không, app chờ 30 giây rồi dùng clipboard), Windows App có nhận phím không, tiếng Việt/ký tự đặc biệt trong mật khẩu gõ đúng không. Clipboard **không** bị đặt khi đã gõ thành công (kiểm bằng ⌘V ở nơi khác).
4. **Hết 30 giây:** mở rồi không để Windows App ra ô mật khẩu (vd chuyển sang app khác): sau 30 giây có thông báo và rơi về clipboard.
5. **Cửa sổ đổi giữa chừng:** trong lúc đang gõ, bấm sang app khác: gõ dừng, báo xoá ô và nhập lại, không copy clipboard, không có ký tự nào rơi vào app khác.
6. **Mở lại khi đang gõ:** bấm Mở lần nữa giữa lúc gõ: lần cũ bị huỷ; ghi lại ô có còn nửa mật khẩu không (đã biết, A21).
7. **Cài đặt:** tắt "Tự gõ mật khẩu vào Windows App" → chỉ copy clipboard. Tắt "Tự điền mật khẩu đã lưu" → không gõ, không copy. Máy đang bị hold (tạm tắt tự điền): ghi lại hành vi.
8. **Máy SSH:** Mở Warp không bao giờ gõ hay xin quyền Trợ năng.
9. **Build lại:** `make install` ký ad-hoc rồi mở Windows App: ghi lại macOS có đòi cấp lại quyền không; thử lại với chứng chỉ ADR-023.
10. **Không lộ:** mật khẩu không có trong log, DB, `.rdp`.

**K10 — Hộp thoại Keychain và "Làm mới quyền Keychain" (ADR-004d).** Cần `make install`, đã có vài mật khẩu lưu (host và bộ đăng nhập). Ghi lại số hộp thoại thấy được ở từng bước.
1. **Không hỏi khi vẽ:** nhập mật khẩu lần đầu cho một máy rồi chọn máy, chuyển qua lại chi tiết máy và danh sách nhiều lần: không có hộp thoại Keychain hiện thêm khi chỉ xem (chỉ có khi thật sự kết nối).
2. **Một thao tác, tối đa một lần đọc khoá:** lưu hoặc dùng một mật khẩu: không còn 2 hộp thoại liên tiếp cho cùng một thao tác.
3. **Sau `make install` ký ad-hoc:** mở Warp một máy có mật khẩu lưu: có thể hỏi lại một lần (app 1, helper 1–2); ghi lại số lần. Chọn "Luôn cho phép".
4. **Làm mới quyền:** Cài đặt → Bảo mật → "Làm mới quyền Keychain": đọc mô tả, bấm; chọn "Luôn cho phép" ở các hộp thoại. Báo số mục đã làm mới / lỗi. Sau đó build + cài lại bằng chứng chỉ (K1) và mở Warp: không hỏi lại.
5. **Từ chối:** lặp lại bước 4 và bấm "Từ chối" ở một hộp thoại: ghi lại mục đó có thành "Mật khẩu đã lưu không còn dùng được" không (dự kiến có thể), nhập lại thì dùng được; các mục khác không hỏng, khoá không mất.
6. **Không tự làm mới:** khởi động lại app không tự bật chuỗi hộp thoại làm mới.
7. **Khôi phục khoá:** (chỉ khi thử được) ngắt giữa lúc làm mới (thoát app): lần mở sau mật khẩu vẫn dùng được (khôi phục từ `default-refresh` nếu cần). Trong Keychain Access không còn item tạm sau khi xong.
8. **Không lộ:** không có mật khẩu trong log/DB.

**Ghi chú tạo khoá Secure Enclave (K5):** `ssh-keygen -w /usr/lib/ssh-keychain.dylib -K` đang báo "Unable to load resident keys: invalid format" trên máy dev (2026-10-23), nên test e2e SE bỏ qua lỗi này và luồng "Tạo khoá Secure Enclave…" trong app cần thử tay.

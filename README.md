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

## Nhập danh sách máy chủ từ Excel
Luồng chính để đưa nhiều máy chủ vào app (ADR-026). Mới có test đơn vị, **chưa thử tay** và file mẫu **chưa mở thử trong Excel/Numbers** (xem [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) B12).

1. **Lấy file mẫu:** bấm "Tải file mẫu…" trong hub "Nguồn máy chủ" (mở bằng nút ở header THƯ MỤC của sidebar, menu Tệp, hoặc menu Xuất/nhập). Hoặc dùng bản trong repo `docs/templates/sshdesk-hosts-template.xlsx` (sinh lại bằng `make template`).
2. **Điền sheet "Máy chủ"** (dòng 1 là tiêu đề, giữ nguyên):

| Cột | Ý nghĩa |
|---|---|
| Tên | Tên hiển thị; cũng là khoá nhận ra máy khi đồng bộ lại |
| IP/Hostname | Địa chỉ máy |
| Port | Trống = 22 (SSH) hoặc 3389 (Windows) |
| User | Tên đăng nhập (máy Windows: user RDP) |
| Môi trường | DEV / UAT / STG / PROD (trống = OTHER) |
| Thư mục/Dự án | Thư mục chứa máy |
| Loại | SSH hoặc Windows (trống = SSH) |
| Jump host | **Tên** máy khác làm bastion (trong cùng file, hoặc máy đã có trong app) |
| Bộ đăng nhập | **Tên** bộ đăng nhập (ADR-030); tên chưa có thì xem trước báo "sẽ tạo bộ rỗng" |
| Ghi chú | Ghi chú tự do |

3. **Không có cột mật khẩu.** Mật khẩu nhập trong app (form máy hoặc bộ đăng nhập), không bao giờ nằm trong file. Sheet "Hướng dẫn" trong file giải thích từng cột và giá trị hợp lệ.
4. **Chọn file:** file đúng mẫu vào thẳng màn xem trước (không phải ghép cột). Lỗi báo theo dòng (số dòng Excel, cột, lý do); dòng lỗi bị bỏ qua, dòng hợp lệ vẫn nhập được.

### File của khách (ghép cột)
File Excel/CSV không theo mẫu: chọn sheet và dòng tiêu đề, rồi ghép cột vào Tên, IP/Hostname, Port, User, Môi trường, Thư mục/Dự án, Ghi chú. App đoán sẵn theo tiêu đề tiếng Việt (có/không dấu) hoặc tiếng Anh. Cột có tiêu đề giống mật khẩu (password, mật khẩu, secret, passphrase, otp, token...) không ghép được vào trường nào của máy và **mặc định bị bỏ qua** (cảnh báo "sẽ bỏ qua"). Bạn có thể bật "Lưu mật khẩu từ cột X vào kho" cho riêng lần nhập đó (thêm "Ghi đè mật khẩu đã lưu" nếu máy đã có mật khẩu riêng; mặc định không ghi đè). Xem trước chỉ hiện ••••, bấm Áp dụng thì hỏi xác nhận trước khi lưu; mật khẩu vào kho mã hoá Secure Enclave, không vào DB/log. Phải bật lại mỗi lần; "Đồng bộ lại" và tự động áp dụng không bao giờ lưu mật khẩu. Sau khi nhập hãy xoá hoặc bảo vệ file gốc (nó chứa mật khẩu dạng rõ, app không tự xoá). File mẫu của app vẫn không có cột mật khẩu. Cách ghép được lưu theo nguồn, nên khi khách gửi bản mới chỉ cần "Đồng bộ lại" (cùng file) hoặc "Chọn file mới…" cho nguồn (một chạm). CSV nhận dấu phân cách `,` `;` hoặc tab.

### Nguồn JSON và Ansible
Trong hub "Nguồn máy chủ…", menu "Thêm nguồn" có Excel/CSV, JSON, Ansible. Mới có test đơn vị, **chưa thử tay**, chưa thử với inventory thật.
- **JSON:** file đúng định dạng xuất của app (`*.sshdesk.json`, `sshdesk-hosts` v1). Khoá nhận ra máy là `id` trong file.
- **Ansible:** inventory **tĩnh** INI hoặc YAML. App tự đọc file, **không chạy `ansible-inventory`** hay process nào, không đọc `host_vars/`/`group_vars/`.
  - Lấy `ansible_host`, `ansible_port`, `ansible_user` (và dạng `ansible_ssh_*`). Khoá = tên host trong inventory.
  - Biến mật khẩu (`ansible_password`, `ansible_ssh_pass`, `ansible_become_pass`...) và giá trị `!vault` bị **bỏ qua**, app cảnh báo.
  - Tên group thành tag; tag từ nguồn **chỉ cộng thêm**, không gỡ tag bạn tự đặt.
  - Thiếu `ansible_user`: máy **mới** dùng tên đăng nhập macOS (có cảnh báo); máy đã có giữ user cũ.

### Đồng bộ một chiều
- Mở app hoặc quay lại app, nếu file đổi thì app so với nguồn:
  - **Chỉ có máy mới** (ADR-026b): tự thêm luôn, **không lưu mật khẩu**; hiện banner "Đã thêm N máy" với nút Xem / Hoàn tác / Đóng. Mỗi nguồn có toggle "Tự thêm máy mới" (mặc định bật).
  - **Có bất kỳ sửa, máy biến mất, lỗi dòng hay cảnh báo** (vd thiếu `ansible_user`, cột mật khẩu bị bỏ, bộ đăng nhập cần tạo): không tự áp dụng; hiện banner "Nguồn có thay đổi" và màn xem trước như cũ (thêm / đổi từng trường cũ → mới / không còn trong nguồn / lỗi).
  - Không tự thêm khi hub, wizard hoặc màn xem trước đang mở.
  - **Hoàn tác** chỉ xoá những máy vừa thêm mà bạn **chưa sửa**, rồi tắt "Tự thêm máy mới" của nguồn đó. Chỉ dùng được trong phiên hiện tại. Mới có test đơn vị, chưa thử tay.
- **Không tự xoá máy**: máy biến mất khỏi file chỉ bị đánh "Không còn trong nguồn". Xoá nguồn cũng không xoá máy.
- Trường do nguồn quản lý (tên, địa chỉ, port, user, môi trường, thư mục, jump host) bị khoá trong form; ghi chú, yêu thích, forward, mật khẩu... vẫn là của app. Muốn sửa tay thì bấm "Tách khỏi nguồn".
- **Tạm tắt tự điền mật khẩu:** khi IP/Port/User/Jump của máy đổi qua đồng bộ (hoặc bộ đăng nhập được gán từ file), app tạm tắt tự điền cho máy đó tới khi bạn mở chi tiết máy, xem lý do và bấm "Xác nhận". Lý do: file có thể bị sửa để trỏ tên máy quen sang địa chỉ lạ, và mật khẩu đã lưu sẽ bị đưa sang máy đó.

## Tính năng
- **Máy chủ + thư mục:** thêm/sửa/xoá/nhân bản, tìm kiếm, môi trường (DEV/UAT/STG/PROD/OTHER), yêu thích, bastion (ProxyJump), import alias có sẵn từ `~/.ssh/config` (chỉ đọc). Thư mục ở sidebar, kéo host vào thư mục.
- **Mở Warp:** sinh Tab Config và mở tab Warp chạy `ssh`; không có Warp thì Copy lệnh SSH. Click 1 lần = chọn, double-click / Return = mở.
- **Tự đăng nhập bằng password:** tuỳ chọn lưu password trong Keychain cho từng host; Warp đăng nhập qua helper `SSH_ASKPASS` (env chỉ chứa tham chiếu, không chứa password).
- **Bộ đăng nhập (Cài đặt → Bảo mật):** tạo bộ dùng chung gồm user, password, file key, passphrase của key, agent (mỗi phần tuỳ chọn). Gán cho host ở form host (picker "Bộ đăng nhập") hoặc cho cả thư mục bằng "Gán bộ đăng nhập…" ở menu thư mục (bảng máy chủ chưa chọn nhiều dòng). Giá trị riêng của host luôn ưu tiên hơn bộ (host > bộ > Cài đặt). Sửa password/key của bộ thì mọi host dùng bộ nhận giá trị mới. Passphrase của bộ chỉ tự điền khi mở bằng Warp (askpass); Truyền file, Tunnel, Analyst, Monitor... luôn hỏi bạn. Xuất/nhập JSON chỉ mang **tên** bộ, không password, passphrase hay đường dẫn key của bộ. Chưa thử tay (xem [TESTING](docs/TESTING.md)).
- **Xác nhận địa chỉ / tạm tắt tự điền:** khi bộ đăng nhập được gán từ file nhập (hoặc sau này khi nguồn đồng bộ đổi địa chỉ máy), app tạm tắt tự điền mật khẩu cho host đó để password không bị đưa sang máy lạ. Mở chi tiết máy, xem lý do rồi bấm "Xác nhận" để bật lại. Trong lúc tạm tắt, mở Warp vẫn được nhưng bạn tự nhập mật khẩu. Gán bằng tay trong app không bị tạm tắt.
- **Agent ngoài (1Password, Bitwarden, Secretive):** chọn agent ở form host (mục Nâng cao) hoặc đặt mặc định trong Cài đặt → SSH config. App chỉ ghi `IdentityAgent "<socket>"` vào config của app, không đọc private key. Với agent ngoài nên để IdentityFile trống, hoặc trỏ tới file `.pub` của key nằm trong agent. Màn SSH Keys có thẻ "Key trong agent" (liệt kê public key bằng `ssh-add -L`). Chỉ áp dụng cho host managed loại SSH. Chưa thử với agent thật.
- **Truyền file kiểu Xftp:** hai khung (Mac | server), tab cho từng server, kéo thả, hàng đợi (huỷ, thử lại, ghi đè/đổi tên/bỏ qua), tạo thư mục / đổi tên / xoá trên server. Dùng `scp` (giao thức SFTP) và `sftp` qua một kết nối ControlMaster mỗi tab.
- **SSH Keys:** liệt kê key trong `~/.ssh` (chỉ đọc `*.pub`), tạo key mới, "Cài key lên server" (`ssh-copy-id`).
- **Khoá SSH trong Secure Enclave (ADR-027):** màn SSH Keys có nút "Tạo khoá Secure Enclave…" (dùng `/usr/lib/ssh-keychain.dylib` có sẵn của macOS, không cài thêm gì). Nhập nhãn (`A-Z a-z 0-9 . _ -`, tối đa 64 ký tự, chưa trùng identity có sẵn), chọn bảo vệ bằng Touch ID (mặc định) hoặc không. Private key sinh và nằm trong chip, **không rời chip**; file `~/.ssh/id_ecdsa_sk_rk_<nhãn>` (+ `.pub`) chỉ là tham chiếu, không chứa key, không ghi đè file đã có. Cài lên server bằng "Cài lên server…" như key thường. Host (hoặc bộ đăng nhập) dùng khoá này thì app tự thêm `SecurityKeyProvider "/usr/lib/ssh-keychain.dylib"` vào Host block trong config của app (không ghi toàn cục, không đụng `~/.ssh/config`). Xoá khoá bằng "Xoá khoá Secure Enclave" (có xác nhận) **không khôi phục được**: server còn tin public key đó nhưng bạn không đăng nhập được nữa, nhớ gỡ khỏi `authorized_keys`. Identity tạo ngoài app (không phải `p-256-ne` hoặc nhãn lạ) chỉ xem, không xoá từ app. Mục này ẩn nếu máy thiếu dylib. Chưa thử `-t bio` và đăng nhập thật, xem bảng bên dưới.
  Lệnh tay tương đương (để hiểu app làm gì; chạy trong thư mục tạm vì `-K` xuất mọi resident key, nhấn Enter ở PIN/passphrase):
  ```
  sc_auth create-ctk-identity -l <nhãn> -k p-256-ne -t bio -N <nhãn>   # -t none nếu không dùng Touch ID
  ssh-keygen -w /usr/lib/ssh-keychain.dylib -K
  ssh -o SecurityKeyProvider=/usr/lib/ssh-keychain.dylib -i id_ecdsa_sk_rk_<nhãn> user@example.com
  ```
- **Port forward (-L):** lưu danh sách forward theo host, Mở/Dừng tunnel riêng, hiển thị trạng thái.
- **Project Analyst:** quét một thư mục server (Linux), dựng bản đồ kết nối giữa các server, thử kết nối TCP, lưu lịch sử, xuất báo cáo Markdown/CSV.
- **Monitor:** lưới thẻ CPU / RAM / swap / đĩa / load / uptime theo thư mục (Linux). Mỗi thư mục chọn nguồn: SSH (mặc định) hoặc Prometheus/Zabbix (mục dưới).
- **Máy Windows:** khai báo host RDP, mở bằng Windows App qua file `.rdp`; tự gõ mật khẩu đã lưu vào ô đăng nhập (cần quyền Trợ năng, mục dưới), không được thì copy lên clipboard (tự xoá).
- **CLI `sshdesk` + liên kết `sshdesk://`:** liệt kê và mở host từ terminal, Alfred, Raycast (mục bên dưới). Chưa thử tay.
- **Nguồn máy chủ:** nhập và đồng bộ một chiều từ Excel/CSV (có file mẫu), JSON, Ansible inventory tĩnh (mục trên).
- **Xuất / nhập:** danh sách máy chủ ra file JSON `*.sshdesk.json` (không có secret) và nhập lại có xem trước.
- **Cài đặt (đang hoàn thiện):** ⌘, hoặc mục "Cài đặt" ở sidebar — mặc định Warp, truyền file, SSH config, bảo mật, Analyst, Monitor, Windows App, dữ liệu.
- **Vòng đời app, phím tắt (đang hoàn thiện):** hỏi xác nhận khi thoát lúc còn job/tunnel/Monitor/Analyst; ⌘N, ⌘F, ⌘D, ⌘Return, ⌘E, ⌘1…⌘6.

### Nhập mật khẩu lần đầu (ADR-029)
Mở máy SSH dùng mật khẩu mà chưa lưu thì app hiện sheet "Nhập mật khẩu cho user@host" thay vì để terminal hỏi.
- **Khi nào hiện:** máy SSH, đăng nhập bằng mật khẩu, chưa lưu mật khẩu (kể cả bộ đăng nhập). **Không hiện** khi: máy đi qua bastion; đang bị tạm tắt tự điền; máy alias import từ `~/.ssh/config`; hoặc tắt "Tự điền mật khẩu đã lưu" / tắt Cài đặt → Bảo mật → "Hỏi mật khẩu khi máy chưa lưu" (mặc định bật). Khi đó vẫn là luồng cũ (hỏi trong terminal). Máy PROD xác nhận PROD trước.
- **Ô "Lưu vào Keychain" (mặc định bật), 3 cách lưu:** chỉ cho máy này; dùng bộ đăng nhập có sẵn (chỉ liệt kê bộ đã có mật khẩu); lưu thành bộ mới (đặt tên).
- **Kiểm tra đăng nhập trước khi lưu** (mở thêm một kết nối ngắn, tối đa 20 giây): đúng thì lưu rồi mở Warp tự điền; sai thì báo "Sai mật khẩu", cho nhập lại, không lưu; host key chưa xác nhận (máy mới/đổi key) hoặc có OTP/MFA thì không kiểm tra được, báo mở terminal lần đầu ("Bỏ qua, nhập trong terminal"), app không tự trả lời yes; lỗi mạng/timeout hỏi "Vẫn lưu?" (mặc định Không). Chọn bộ có sẵn mà mật khẩu bộ sai với máy này thì không ghi đè mật khẩu bộ, trừ khi bạn nhập mật khẩu mới và xác nhận "Cập nhật mật khẩu của bộ (ảnh hưởng N máy)".
- **Không tích lưu:** mở Warp thì app không giữ mật khẩu, bạn gõ trong terminal. Analyst, Monitor, Truyền file (sheet Tải về/Tải lên) giữ mật khẩu trong bộ nhớ app tới khi đóng phiên, không ghi ra đâu; đổi địa chỉ máy thì bỏ mục tạm.
- **Máy Windows:** sheet có ô "Lưu vào Keychain"; không kiểm tra được; mật khẩu copy lên clipboard như mục Windows (không tích thì copy một lần, không lưu).
- Mới có test đơn vị và ssh giả, **chưa thử với server thật** (xem [TESTING](docs/TESTING.md) K4c).

### Máy Windows: tự gõ mật khẩu (ADR-018b)
Mới có test đơn vị, **chưa kiểm chứng** với Windows App 11.4 (có dùng ô mật khẩu `AXSecureTextField` và nhận phím gửi theo pid không), xem [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) A21/B18.
- **Cấp quyền (một lần):** System Settings → Privacy & Security → Accessibility → bật SSH Desk. Lần Mở đầu tiên chưa có quyền, app hỏi quyền và lần đó dùng clipboard.
- **Cách chạy:** bấm Mở Windows App cho máy có mật khẩu đã lưu: app mở `.rdp`, chờ tối đa 30 giây tới khi Windows App đang ở trước và con trỏ nằm trong ô mật khẩu còn trống, rồi gõ mật khẩu (chỉ gửi tới Windows App) và Return. Chỉ gõ một lần mỗi lần bấm Mở.
- **Bật/tắt:** Cài đặt → Bảo mật → "Tự gõ mật khẩu vào Windows App" (mặc định bật). Tắt "Tự điền mật khẩu đã lưu" thì không gõ cũng không copy.
- **Fallback clipboard:** chưa có quyền, hết 30 giây không thấy ô mật khẩu, hoặc tắt tính năng: mật khẩu được copy như trước (concealed, tự xoá), bạn dán bằng ⌘V.
- **Gõ dở:** nếu cửa sổ đổi giữa chừng, app dừng và báo; hãy xoá ô mật khẩu rồi nhập lại. Không gõ vào app nào khác ngoài Windows App, và không bao giờ cho máy SSH.
- Ký ad-hoc có thể làm macOS đòi cấp lại quyền sau mỗi lần `make install`: ký bằng chứng chỉ (mục "Ký app bằng chứng chỉ của bạn").

### Monitor từ Prometheus/Zabbix (ADR-028)
Ngoài cách mặc định (SSH vào máy đọc `/proc`), Monitor có thể đọc số liệu từ hệ thống giám sát có sẵn. Chỉ gọi API đọc, không chạy lệnh trên server.
- **Thêm nguồn:** Cài đặt -> "Nguồn số liệu": chọn loại (Prometheus/Zabbix), URL, xác thực. Prometheus: không / Bearer / Basic. Zabbix: không / Bearer (token API; không hỗ trợ Basic hay đăng nhập bằng mật khẩu). Token lưu trong kho mã hoá Secure Enclave, không vào DB/log/URL. Bấm "Thử kết nối" để kiểm tra.
- **Dùng:** màn Monitor -> chọn nguồn cho từng thư mục. Gán theo **tên** thư mục: đổi tên thư mục thì thư mục đó về SSH. Làm mới chỉ khi màn Monitor đang hiện.
- **Prometheus:** cần `node_exporter` trên các máy. Mẫu ghép nhãn `instance` mặc định `{{hostName}}:9100`, sửa được trong form nguồn nếu bạn dùng tên/cổng khác. Mỗi máy 6 truy vấn chạy song song.
- **Zabbix:** tìm host theo host/name; token cần quyền đọc `host.get` và `item.get`. Hỗ trợ Zabbix 7 (Bearer) và bản cũ (token gửi trong trường `auth`). Không có thẻ swap.
- **https khuyến nghị.** `http://` hiện cảnh báo đỏ; nếu có token và không phải loopback, phải tick "Tôi hiểu token gửi không mã hoá" mới lưu được. http tới tên miền nội bộ (vd `prom.corp.example.com`) được phép (ADR-028b, ATS đã nới), nhưng không mã hoá nên vẫn cảnh báo đỏ và cần tick khi gửi token qua http. https bắt buộc TLS >= 1.2.
- **TLS:** https vẫn kiểm chứng chỉ, app không bao giờ tắt kiểm tra. CA nội bộ phải được tin cậy trong macOS (Keychain Access).
- **Đổi URL (origin) hoặc kiểu xác thực** thì phải nhập lại token.
- **Chưa kiểm chứng** với Prometheus/Zabbix/TLS thật và ATS khi chạy thật (xem [TESTING](docs/TESTING.md) K6). Đợt này chưa có nhật ký phiên, cảnh báo, liên kết Grafana.

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
| Bộ đăng nhập (K4s), kho Secure Enclave + migration (K4e) | Chỉ test đơn vị | Thử tay trên `.app` đã cài (TESTING mục K4s/K4e) |
| Hỏi mật khẩu lần đầu (K4c) | Chỉ test đơn vị + ssh giả | Server thật (TESTING mục K4c) |
| SSH Keys (E1), Port forward (E3) | Chỉ sshd tạm | Server thật |
| Khoá Secure Enclave (K5, ADR-027) | `-t none` + sshd tạm 127.0.0.1; kiểm chứng lệnh tay trên macOS 27 | `-t bio` (Touch ID mỗi lần ký), Warp/Analyst, server thật (TESTING mục K5) |
| Monitor (I1/I2) | Chưa | Server Linux thật, giao diện |
| Monitor Prometheus/Zabbix (K6, ADR-028) | Chỉ test đơn vị (URLProtocol giả) | Prometheus/Zabbix thật, TLS, ATS (TESTING mục K6) |
| Xuất/nhập (D1) | Chỉ test | Thử tay |
| Nguồn máy chủ Excel/CSV (K4a) | Chỉ test đơn vị; XLSX kiểm bằng unzip/zip của macOS | Mở file mẫu trong Excel/Numbers, thử tay (TESTING mục K4a) |
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
| Password, passphrase | Chỉ Keychain, dạng mã hoá (xem “Mật khẩu lưu ở đâu”): khoá `local.sshdesk.sekey`, ciphertext `local.sshdesk.sealed` |

App **không** sửa `~/.ssh/config` hay Tab Config của bạn; chỉ ghi file mang tiền tố `sshdesk_` / thư mục riêng của app, và `Include` config của bạn từ config của app.

## Mật khẩu lưu ở đâu
- Password và passphrase (host, bộ đăng nhập, token) được **mã hoá bằng khoá Secure Enclave của chính máy này** rồi lưu ciphertext trong Keychain (item `local.sshdesk.sealed`; handle khoá ở item `local.sshdesk.sekey`). Không cần Touch ID. DB không giữ password, chỉ giữ tham chiếu.
- Lần đầu mở bản mới, app tự chuyển mật khẩu cũ (item `local.sshdesk.credentials`) sang dạng mã hoá, kiểm tra đọc lại khớp rồi mới xoá item cũ. Chưa thử trên máy thật.
- **Đổi máy, cài lại macOS hoặc khôi phục backup sang máy khác thì mất mật khẩu đã lưu** (khoá gắn với máy, không có backup/xuất): phải nhập lại. Mục không giải mã được hiện "Mật khẩu đã lưu không còn dùng được trên máy này"; nhập lại sẽ ghi đè.
- Máy không có Secure Enclave thì không lưu được mật khẩu (không bao giờ lưu plaintext). Giới hạn: [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) mục A17.
- **Hộp thoại Keychain cứ hiện lại (ADR-004d):** sau mỗi `make install` bản ký ad-hoc, macOS có thể hỏi quyền lại. Cách xử lý: (1) nên ký bằng chứng chỉ ổn định (ADR-023, mục "Ký app bằng chứng chỉ của bạn"); (2) vào Cài đặt → Bảo mật → bấm **"Làm mới quyền Keychain"** một lần; (3) mỗi hộp thoại chọn **"Luôn cho phép"** (đừng chọn "Cho phép" hay "Từ chối": "Từ chối" có thể làm mục đó không đọc được, phải nhập lại mật khẩu). App không tự làm mới khi khởi động. Chưa thử thật trên máy (xem [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md) A20/B18).

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

# Ý tưởng tính năng — SSH Desk

Người viết: product-advisor, 2026-10-22. Đây chỉ là **đề xuất để người dùng chọn**. Chưa có ADR nào cho các mục dưới đây; muốn làm mục nào thì PM ghi ADR trước rồi mới giao code.

## 0. Bối cảnh và ràng buộc

**Đã có:** hồ sơ máy chủ, thư mục, môi trường, bastion; mở Warp qua Tab Config; tự đăng nhập bằng password (Keychain + askpass); truyền file kiểu Xftp; SSH Keys; port forward `-L`; Project Analyst; Monitor; máy Windows (RDP); xuất/nhập JSON. **Đang làm:** Cài đặt (D4), vòng đời app (D2).

**Lưu ý trước khi thêm tính năng:** nhiều tính năng còn `[~]`, tức chưa thử với server thật (truyền file, askpass, Monitor, port forward…). Thêm tính năng mới trên nền chưa kiểm chứng sẽ làm tăng nợ. Nên xen kẽ: thử thật xong một cụm rồi mới mở rộng cụm đó.

**Ràng buộc phải giữ** (CLAUDE.md "Không được làm", spec "Không xây"):
- Secret chỉ ở Keychain. Không đưa vào file, SQLite, log, argv, env, URI, clipboard (Windows là ngoại lệ đã chốt ở ADR-018).
- Không `sh -c` với input người dùng. Không sửa `~/.ssh/config`, Tab Config của người dùng. Không `StrictHostKeyChecking=no`.
- Analyst và Monitor chỉ chạy **lệnh xem, whitelist cố định**, không sudo.
- Không tự viết terminal, không AI/telemetry, không đồng bộ cloud mặc định, không cộng tác nhóm, không thêm dependency.

Ký hiệu trong tài liệu: **Độ khó** S (≤ 1 task), M (2–3 task), L (nhiều task hoặc cần quyết định lớn). **Giá trị** cao/vừa/thấp, đánh giá cho người dùng này: kỹ sư vận hành nhiều server Linux theo dự án (vd Ping-Identity gồm AM/IDM/DS/App, môi trường DEV…PROD) và vài máy Windows. Ý tưởng có dấu **⚠ cần ADR** là ý tưởng chạm ràng buộc hoặc quyết định đã chốt, phải qua PM và người dùng đồng ý.

---

## 1. Vận hành hằng ngày

### 1.1 Tab Warp có màu và tiêu đề theo môi trường — S · Giá trị cao
- **Tình huống:** đang mở 6 tab Warp, có cả DEV lẫn PROD. Gõ nhầm `systemctl restart` vào tab PROD vì các tab trông giống nhau.
- **Cách hoạt động:** Tab Config do app sinh có thêm `title = "<tên host> · PROD"` và `color` theo môi trường (PROD đỏ, STG vàng, UAT xanh dương, DEV xanh lá). Cho phép đổi màu trong Cài đặt.
- **Tận dụng:** `WarpTabConfigRenderer`. Hiện renderer chỉ ghi `name` và `commands`, chưa ghi `title`/`color`. Theo tài liệu Warp, Tab Config có hai trường này (đã kiểm chứng [1]).
- **Bảo mật:** tên hiển thị đi vào `title` nên phải dùng cùng bộ lọc cấm newline/ký tự điều khiển như `name`.

### 1.2 Mở cả thư mục trong một tab Warp chia pane — M · Giá trị cao
- **Tình huống:** sự cố trên Ping-Identity, cần mở AM, IDM, DS cùng lúc. Hiện phải mở 3 lần.
- **Cách hoạt động:** nút "Mở cả thư mục" (hoặc chọn nhiều host). App sinh **một** Tab Config `sshdesk_<uuid>.toml` có cây `[[panes]]` chia lưới, mỗi pane chạy lệnh `ssh` của một host. Có giới hạn số pane (vd ≤ 6), nhiều hơn thì chia thành nhiều tab.
- **Tận dụng:** `WarpLauncher`, lệnh ssh/askpass đã có cho từng host. Tab Config hỗ trợ pane lồng nhau, mỗi pane có `commands` riêng (đã kiểm chứng [1]).
- **Bảo mật:** giữ đúng quy tắc askpass theo từng host. Host có bastion thì không dùng askpass, kể cả khi nằm chung tab với host khác.
- **Gắn với 2.1:** đây là nền cho chạy lệnh trên nhiều server.

### 1.3 Mở console web qua tunnel bằng một nút — S · Giá trị cao
- **Tình huống:** muốn vào console admin của Ping-AM (`:8443`) hoặc IDM, nhưng firewall chỉ mở cổng 22. Hiện phải mở tunnel, nhớ cổng local, rồi tự gõ URL.
- **Cách hoạt động:** mỗi forward có thêm "URL mở sau khi chạy" (`https://127.0.0.1:<lp>/am/console`). Bấm "Mở console" thì app chạy tunnel, chờ trạng thái "Đang chạy", kiểm tra kết nối thật tới `127.0.0.1:<lp>` (khắc phục A7 của KNOWN_LIMITATIONS), rồi mở trình duyệt mặc định.
- **Tận dụng:** Tunnel (E3), bảng `port_forwards` (thêm một cột).
- **Bảo mật:** URL chỉ cho scheme `http`/`https` với host `127.0.0.1`/`localhost`, không chứa userinfo. Trình duyệt sẽ cảnh báo chứng chỉ không khớp tên; đây là việc của trình duyệt, app không bỏ qua cảnh báo hộ.

### 1.4 Liên kết và ghi chú vận hành cho từng host/thư mục — S · Giá trị vừa
- **Tình huống:** đường dẫn cài đặt (`/opt/ping/...`), tên service, link wiki, số ticket nằm rải rác trong Notes của Mac.
- **Cách hoạt động:** ghi chú Markdown ngắn cho **thư mục** (hiện chỉ host có notes), cộng danh sách liên kết (URL wiki, console). Hiển thị ở panel chi tiết.
- **Tận dụng:** cột `notes` của host, bảng thư mục, xuất/nhập JSON.
- **Bảo mật:** nhắc người dùng không ghi password vào ghi chú. Có thể cảnh báo khi phát hiện chuỗi giống `password=`.

### 1.5 Mục "Gần đây" và sắp theo tần suất — S · Giá trị vừa
- **Tình huống:** 80% thời gian chỉ dùng 5–6 host, nhưng mỗi lần vẫn phải tìm.
- **Cách hoạt động:** lưu thời điểm mở gần nhất và số lần mở (Warp, Truyền file, Windows App). Thêm mục "Gần đây" ở sidebar và cách sắp "Hay dùng".
- **Tận dụng:** SQLite, migration mới (chỉ metadata).
- **Bảo mật:** không có.

### 1.6 Mở Warp vào thẳng một thư mục trên server — M · Giá trị vừa
- **Tình huống:** lần nào vào AM cũng gõ `cd /opt/forgerock/am/logs`.
- **Cách hoạt động:** host có "thư mục mặc định khi mở Warp" (hoặc chọn từ bookmark có sẵn). Lệnh thành `ssh -t … -- 'cd <path> && exec "$SHELL" -l'`.
- **Tận dụng:** bookmark/thư mục mặc định đã có trong host (ADR-020).
- **Bảo mật:** ⚠ cần ADR. Đường dẫn đi vào shell **phía server**. Cần quoting POSIX chặt cho remote (ngoài `ZshQuoting` phía local) và validate ký tự. Phải test kỹ với đường dẫn có dấu cách và dấu nháy.

---

## 2. Chạy lệnh trên nhiều server

### 2.1 Gõ một lần, chạy trên mọi pane (dựa vào Warp) — S (sau 1.2) · Giá trị cao
- **Tình huống:** cần chạy `df -h` hoặc `tail` trên cả 4 server của dự án.
- **Cách hoạt động:** sau khi mở thư mục dạng pane (1.2), app hướng dẫn bật **Synchronized Inputs** của Warp (⌥⌘I). Lệnh gõ ở một pane được gửi nguyên lệnh sang mọi pane trong tab (đã kiểm chứng [2]). App không tự gửi phím. Cách này tương đương MultiExec của MobaXterm [3] và "Send Key Input to All Sessions" của Xshell [4].
- **Tận dụng:** 1.2. Không cần code chạy lệnh mới.
- **Bảo mật:** an toàn hơn tự chạy lệnh hộ, vì người dùng gõ trong terminal thật. Với tab có host PROD thì nhắc rõ trước khi mở. Warp có lỗi đã báo: pane đã đóng vẫn nhận lệnh đồng bộ [2], nên ghi vào KNOWN_LIMITATIONS.

### 2.2 Thư viện lệnh hay dùng (snippets) — M · Giá trị cao
- **Tình huống:** các lệnh dài như `journalctl -u openam --since "10 min ago"` hay `ldapsearch -H ldaps://… -b "ou=…"` phải tra lại mỗi lần. Termius có Snippets, có thể chạy trên nhiều host [5]; SecureCRT có Button Bar [6]; Xshell có Quick Commands [4].
- **Cách hoạt động:** lưu snippet trong SQLite (tên, lệnh, mô tả, tham số `{{tên}}`, gắn thư mục/tag). Thao tác "Copy" (đặt lên clipboard, không bí mật) hoặc "Mở Warp và gõ sẵn". Phương án gọn hơn: xuất snippet thành Warp Workflow để dùng từ Command Palette của Warp, vì Warp đã hỗ trợ workflow có tham số [7].
- **Tận dụng:** SQLite, xuất/nhập JSON. Warp đọc được workflow YAML local [8]; vị trí thư mục và tiền tố `sshdesk_` cần researcher kiểm chứng.
- **Bảo mật:** snippet không được chứa secret. Có thể cảnh báo khi thấy mẫu `-w <pass>`, `password=`, hoặc `-D … -w`. Gợi ý dùng `-W` (hỏi password) cho `ldapsearch`.

### 2.3 Hỏi nhanh nhiều server, kết quả dạng bảng — M/L · Giá trị cao · ⚠ cần ADR
- **Tình huống:** "Các server PROD đang chạy Java bản nào?", "Server nào còn TZ sai?". Hiện phải vào từng máy.
- **Cách hoạt động:** chọn thư mục và một **lệnh xem** (từ snippet đánh dấu "chỉ đọc"). App chạy song song (≤ 4) qua `SessionPool`, hiện bảng host | exit code | output rút gọn, tô các dòng khác nhau, có nút xuất CSV.
- **Tận dụng:** `RemoteCommandRunner`, `SessionPool`, xác nhận PROD, xuất CSV của Analyst.
- **Bảo mật:** đây là thay đổi lớn. Hiện chỉ có whitelist cố định, còn ý tưởng này chạy lệnh tự do của người dùng, nhưng không phải `sh -c` phía local. `ssh host -- <lệnh>` luôn đưa chuỗi cho **shell của server** diễn giải. Cần ADR: chỉ người dùng tự gõ hoặc chọn, luôn hiện đúng lệnh sẽ chạy, PROD luôn xác nhận, không lưu output thô. Nếu không muốn đổi quy tắc thì dùng 2.4 (whitelist mở rộng) để thay.

### 2.4 Kiểm kê cấu hình và so sánh môi trường — M · Giá trị cao
- **Tình huống:** UAT chạy được mà PROD lỗi. Nghi lệch phiên bản Java, OS, timezone hoặc NTP.
- **Cách hoạt động:** bộ "facts" có **whitelist cố định**, gồm `cat /etc/os-release`, `uname -r`, `java -version`, `timedatectl show` (hoặc `date +%Z`), `ulimit -n`, `getconf _NPROCESSORS_ONLN`, `nproc`, `free -k`. Hiện bảng theo host, nhóm theo môi trường, tô ô lệch giữa DEV/UAT/PROD. Lưu snapshot để so sánh hai lần quét.
- **Tận dụng:** cơ chế whitelist của Analyst/Monitor, parser, lịch sử SQLite.
- **Bảo mật:** giữ đúng mô hình đã chốt, chỉ cần thêm vào whitelist (vẫn cần ADR nhỏ). `java` có thể không nằm trong PATH của shell non-login; khi đó báo "không tìm thấy", không đoán.

### 2.5 Trạng thái dịch vụ theo thư mục — M · Giá trị vừa
- **Tình huống:** sau khi reboot cửa sổ bảo trì, cần xác nhận `openam`, `opendj`, `openidm` đều active trên mọi node.
- **Cách hoạt động:** mỗi thư mục khai báo danh sách unit systemd. App chạy `systemctl is-active -- <unit>` và `systemctl show -p ActiveEnterTimestamp -- <unit>`, hiện lưới host × service.
- **Tận dụng:** Monitor (lưới thẻ, chu kỳ), whitelist.
- **Bảo mật:** tên unit do người dùng nhập, phải validate bằng regex chặt (`^[A-Za-z0-9@._-]+$`) rồi mới ghép, giống cách Analyst làm với IP/port. Chỉ đọc, không có nút restart (muốn restart thì là quyết định khác).

---

## 3. Log

### 3.1 Tải log hàng loạt (gói log sự cố) — M · Giá trị cao
- **Tình huống:** sự cố PROD, Ping support yêu cầu log của AM, IDM, DS trong cùng khoảng thời gian. Hiện phải tải từng server, từng thư mục.
- **Cách hoạt động:** thư mục có "mẫu gói log": danh sách đường dẫn theo host hoặc theo tag (vd `/opt/ping/am/logs/*`). Bấm "Thu log" thì đưa vào hàng đợi tải về `~/Downloads/<thư mục>/<yyyyMMdd-HHmm>/<host>/`. Có tuỳ chọn chỉ lấy file sửa trong N giờ gần nhất (liệt kê qua sftp rồi lọc theo mtime phía app). Xong thì mở Finder.
- **Tận dụng:** `TransferManager` (hàng đợi, huỷ, thử lại), `RemoteFileService` (liệt kê qua sftp), Settings (thư mục local mặc định).
- **Bảo mật:** log có thể chứa token hoặc dữ liệu cá nhân, nên tạo thư mục đích quyền 0700. Lưu ý symlink trong log dir (A6).

### 3.2 Xem log trực tiếp nhiều server — S (sau 1.2) · Giá trị vừa
- **Tình huống:** theo dõi một request đi qua AM rồi DS.
- **Cách hoạt động:** "Theo dõi log" mở Tab Config nhiều pane, mỗi pane chạy `ssh -t … -- tail -F -n 200 -- <path>` với đường dẫn lấy từ mẫu gói log. Dùng tìm kiếm và block của Warp để đọc.
- **Tận dụng:** 1.2, mẫu gói log của 3.1.
- **Bảo mật:** ⚠ đường dẫn đi vào shell server, nên áp quy tắc quoting và validate như 1.6.

### 3.3 Tìm chuỗi trong log của nhiều server — M · Giá trị vừa · ⚠ cần ADR
- **Tình huống:** tìm một transactionId trên mọi node.
- **Cách hoạt động:** nhập chuỗi (chỉ so khớp literal), app chạy `grep -F -n -m 200 -- <chuỗi> <các file mẫu>`, gộp kết quả theo host và thời gian.
- **Tận dụng:** 2.3 hoặc cơ chế whitelist, 3.1.
- **Bảo mật:** chuỗi người dùng đi vào shell server, nên phải quote chặt và giới hạn ký tự. Không lưu kết quả vào DB.

---

## 4. Bảo mật và khoá

### 4.1 Touch ID trước khi dùng mật khẩu đã lưu — M · Giá trị cao
- **Tình huống:** Mac không khoá màn hình trong vài phút, người khác hoặc malware có thể dùng password đã lưu (rủi ro A1).
- **Cách hoạt động:** Cài đặt có tuỳ chọn "Yêu cầu Touch ID/mật khẩu Mac khi dùng mật khẩu đã lưu". Có hai cách: Keychain item có access control `userPresence`, hoặc app hỏi một lần rồi nhớ trong N phút.
- **Tận dụng:** `Credentials`, Settings (D4).
- **Bảo mật:** giảm A1. Cần researcher kiểm chứng helper askpass (process riêng, ký ad-hoc) có gọi được Keychain với `userPresence` không. Có thể phải đổi luồng.

### 4.2 Passphrase khoá SSH qua Keychain của macOS — S · Giá trị vừa
- **Tình huống:** dùng key có passphrase thì phải gõ passphrase mỗi lần mở tab mới.
- **Cách hoạt động:** host dùng key có tuỳ chọn ghi `AddKeysToAgent yes` và `UseKeychain yes` vào **config của app**. Đây là tính năng có sẵn của OpenSSH bản Apple, passphrase nằm trong Keychain của hệ thống.
- **Tận dụng:** `SSHConfigWriter`, màn SSH Keys.
- **Bảo mật:** phù hợp quy tắc chỉ dùng Keychain. Cần kiểm chứng `UseKeychain` trên OpenSSH 10.3p1 có trong máy, vì nếu là bản OpenSSH không phải của Apple thì phải đặt sau `IgnoreUnknown`.

### 4.3 Kiểm tra sức khoẻ khoá và chuyển host từ password sang key — S · Giá trị vừa
- **Tình huống:** không nhớ host nào còn đăng nhập bằng password, key nào là RSA 2048 cũ.
- **Cách hoạt động:** màn SSH Keys hiện loại và độ dài key (đọc `.pub` qua `ssh-keygen -l`), cảnh báo DSA/RSA < 3072, và cho biết host nào dùng key nào. Có danh sách "host còn dùng password" kèm nút "Cài key" (E1) để chuyển dần sang key.
- **Tận dụng:** E1 (`ssh-keygen`, `ssh-copy-id`), metadata auth method của host.
- **Bảo mật:** chỉ đọc `.pub`, không đọc private key.

### 4.4 Xem fingerprint và xử lý "host key đã đổi" — M · Giá trị vừa · ⚠ cần ADR
- **Tình huống:** server được dựng lại, ssh báo REMOTE HOST IDENTIFICATION HAS CHANGED, phải tự sửa `known_hosts`.
- **Cách hoạt động:** hiện fingerprint đang lưu và fingerprint mới, hướng dẫn kiểm chứng qua kênh khác. Chỉ khi người dùng xác nhận mới gỡ dòng cũ. Có hai phương án: (a) app dùng `UserKnownHostsFile` riêng của app (thêm vào config app) để tự quản lý file của mình; (b) gọi `ssh-keygen -R` vào `~/.ssh/known_hosts` của người dùng.
- **Bảo mật:** (b) chạm vào file của người dùng, đi ngược tinh thần "không sửa file người dùng". (a) an toàn hơn nhưng đổi ADR-006. Không bao giờ tự chấp nhận key mới.

### 4.5 Nhắc tuổi mật khẩu đã lưu — S · Giá trị thấp
- Lưu ngày lưu hoặc đổi password (metadata, không phải secret). Cảnh báo khi quá N ngày theo chính sách đổi mật khẩu của khách hàng. Cảnh báo nhẹ ngay trong danh sách.

### 4.6 Xác nhận khi mở PROD — S · Giá trị vừa
- Tuỳ chọn hỏi "Bạn đang mở PROD: <host>" trước khi mở Warp, Truyền file hoặc tunnel tới host PROD. Kết hợp với 1.1. Royal TSX có cơ chế tương tự: bắt xác nhận trước khi gửi phím [9].

---

## 5. Monitor và Analyst mở rộng

### 5.1 Trạng thái online/offline ngay trong danh sách — S · Giá trị cao
- **Tình huống:** mở Warp xong mới biết server tắt hoặc VPN chưa bật.
- **Cách hoạt động:** app thử TCP connect từ Mac tới `HostName:Port` (22 hoặc 3389), timeout ngắn, khi mở danh sách hoặc thư mục. Hiện chấm xanh/đỏ/xám. Host qua bastion thì hiện "qua bastion", không đo.
- **Tận dụng:** Network framework (không thêm dependency), danh sách host.
- **Bảo mật:** chỉ mở socket TCP rồi đóng, không đăng nhập. Một số IDS có thể ghi nhận, nên cho tắt trong Cài đặt.

### 5.2 Kiểm tra hạn chứng chỉ TLS (LDAPS, HTTPS) — M · Giá trị cao
- **Tình huống:** chứng chỉ LDAPS của DS (`:1636`) hoặc HTTPS của AM hết hạn, gây sự cố cả hệ thống. Đây là lỗi kinh điển với Ping/ForgeRock.
- **Cách hoạt động:** mỗi host hoặc thư mục khai báo cổng TLS, hoặc lấy gợi ý từ các cổng LISTEN mà Analyst đã thấy. App bắt tay TLS **từ Mac** (Security/Network framework), đọc subject, SAN, issuer, ngày hết hạn và hiện "còn N ngày". Cổng không ra được từ Mac thì đi qua tunnel (E3).
- **Tận dụng:** dữ liệu LISTEN của Analyst, Tunnel, xuất báo cáo.
- **Bảo mật:** không gửi credential, chỉ handshake. Không chạy lệnh trên server.

### 5.3 So sánh hai lần chạy Analyst — S/M · Giá trị cao
- **Tình huống:** sau deploy cần biết luồng nào mới xuất hiện và luồng nào biến mất (vd IDM không còn nối DS:1636).
- **Cách hoạt động:** chọn hai lần trong Lịch sử, hiện cạnh thêm, cạnh mất, cạnh đổi kết quả probe, tô trên bản đồ.
- **Tận dụng:** `AnalystRunRepository` đã lưu flows có cấu trúc.
- **Bảo mật:** không có.

### 5.4 Luồng mong đợi: smoke test sau deploy — M · Giá trị cao
- **Tình huống:** checklist "AM→DS:1636, IDM→DS:1389, App→AM:8443 phải thông" hiện đang kiểm bằng tay.
- **Cách hoạt động:** đánh dấu cạnh trên bản đồ là "bắt buộc" hoặc thêm tay. "Chạy kiểm tra" chỉ probe các cạnh này, kể cả khi lúc đó không có kết nối ESTAB (bù giới hạn A8). Kết quả Đạt/Không đạt, xuất Markdown cho ticket.
- **Tận dụng:** probe whitelist của Analyst (IP và port đã validate), lịch sử, xuất báo cáo.
- **Bảo mật:** giữ đúng ADR-016, vì IP và port vẫn được validate chặt.

### 5.5 Monitor: top tiến trình, mạng, IO — M · Giá trị vừa
- Thêm vào whitelist `ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu` (cắt 10 dòng), `/proc/net/dev`, `/proc/diskstats`. Bấm vào thẻ thì hiện top 10 tiến trình (`java` của AM/IDM/DS thường đứng đầu). Phải cập nhật phạm vi ADR-019 ("ngoài phạm vi v1").

### 5.6 Cảnh báo ngưỡng bằng thông báo macOS — M · Giá trị vừa · ⚠ cần ADR
- Khi Monitor đang chạy mà đĩa hoặc RAM vượt ngưỡng đỏ, gửi thông báo của macOS (UserNotifications), có chống lặp. Muốn chạy nền khi đóng màn Monitor thì phải đổi ADR-019 (hiện chỉ chạy khi màn đang hiện). Cần ghi rõ đây không thay hệ thống monitoring thật.

---

## 6. Dữ liệu và đồng bộ

### 6.1 Nhập hàng loạt từ danh sách hoặc CSV — M · Giá trị cao
- **Tình huống:** dự án mới bàn giao 20 server dưới dạng bảng Excel (tên, IP, user, môi trường).
- **Cách hoạt động:** dán văn bản hoặc chọn CSV, ghép cột (tên/IP/port/user/môi trường/thư mục), xem trước, rồi nhập. Royal TSX có "Import – CSV" [10]. Mở rộng sau: inventory Ansible dạng INI.
- **Tận dụng:** màn xem trước và validator của ADR-020, transaction SQLite.
- **Bảo mật:** bỏ qua cột password nếu có và báo rõ "không nhập password". CSV thường có cột này.

### 6.2 Sao lưu tự động định kỳ — S · Giá trị vừa
- Tuỳ chọn tự xuất `*.sshdesk.json` mỗi ngày vào thư mục người dùng chọn, giữ N bản. Thư mục có thể là iCloud Drive nếu người dùng tự chọn, không phải mặc định. Dùng `Exchange` (ADR-020). File không có secret nhưng nhạy cảm vừa (A15), nên ghi quyền 0600.

### 6.3 Trường và tag hiển thị (vai trò, phiên bản) — S · Giá trị vừa
- Hiện `tags` đã có trong DB và search nhưng chưa có trường "vai trò" (Analyst đang dùng môi trường làm badge, ADR-016). Thêm tag hiển thị dạng chip (AM, IDM, DS), lọc theo tag, và dùng tag cho mẫu gói log (3.1) và badge Analyst.

### 6.4 Đồng bộ giữa hai Mac — L · Giá trị thấp · ⚠ cần ADR
- Termius và Core Tunnel bản trả phí có đồng bộ, Termius mã hoá phía client [11][12]. Spec ghi "không đồng bộ cloud mặc định". Có thể làm bản tối thiểu: 6.2 vào thư mục đồng bộ, rồi nhập ở máy kia. Không nên làm hơn mức này.

---

## 7. UX và tốc độ

### 7.1 Command palette ⌘K — M · Giá trị cao
- Một ô gõ tìm host, thư mục và hành động ("ping-am prod → Mở Warp / Truyền file / Monitor thư mục / Mở console"). Mũi tên chọn, Return thực thi. Tận dụng search không phân biệt dấu sẵn có và các phím tắt D2.

### 7.2 Menu bar — M · Giá trị vừa
- Biểu tượng trên thanh menu: host yêu thích hoặc gần đây (mở Warp), tunnel đang chạy (Dừng/Mở console), số job truyền file. Hợp với Core Tunnel vốn điều khiển từ menu bar [12]. Cần thống nhất với cài đặt "Giữ chạy nền" (ADR-021).

### 7.3 Phím tắt toàn cục và Shortcuts — M · Giá trị vừa · ⚠ cần ADR
- App Intents ("Mở host X trong Warp") để dùng từ Shortcuts, Spotlight hoặc Raycast. Không mở URL scheme `sshdesk://` công khai, hoặc nếu có thì luôn xác nhận, vì trang web nào cũng gọi được URL scheme. Không bao giờ nhận secret qua URL.

### 7.4 Tunnel tự nối lại và tự chạy khi mở app — M · Giá trị vừa
- Core Tunnel tự khôi phục tunnel sau khi rớt mạng hoặc Mac ngủ dậy, và có tuỳ chọn tự kết nối khi mở app [12]. Hiện E3 cố ý không tự chạy lại (A7). Đề xuất bật được cho từng forward, với backoff tăng dần và **dừng hẳn khi lỗi xác thực** (tránh khoá tài khoản, giống lý do của Monitor). Kết hợp với `ServerAlive*` đã có.

### 7.5 Dynamic forward (SOCKS, `-D`) — S · Giá trị vừa · ⚠ cần ADR
- Một forward kiểu SOCKS `127.0.0.1:1080` để duyệt nhiều web console trong mạng nội bộ dự án mà không cần một tunnel cho mỗi cổng. Termius và Core Tunnel đều có [12][13]. ADR-011 hiện chỉ cho `-L`. Vẫn chỉ bind 127.0.0.1.

---

## 8. Windows

### 8.1 RDP qua SSH tunnel (bastion Linux) — M · Giá trị vừa
- Máy Windows chỉ vào được qua một Linux jump host. App mở tunnel `-L 127.0.0.1:<lp>:<win>:3389` rồi sinh `.rdp` trỏ `127.0.0.1:<lp>`. Tận dụng E3 và H1. Rủi ro đã biết: chứng chỉ RDP lệch tên (B5), cần người dùng thử thật trước.

### 8.2 Trạng thái cổng 3389 và đăng nhập gần nhất — S · Giá trị thấp
- Dùng chung 5.1 cho máy Windows (TCP 3389). Ghi lại thời điểm mở gần nhất (1.5).

### 8.3 Máy Windows có OpenSSH Server — M · Giá trị thấp
- Windows Server 2019 trở lên có thể bật OpenSSH Server. Cho phép một host Windows có thêm "SSH" để dùng Truyền file (scp/sftp), nhưng vẫn loại khỏi Analyst/Monitor (vốn chỉ Linux). Cần kiểm chứng sftp với đường dẫn Windows.

---

## 9. Bảng xếp ưu tiên

Điểm ưu tiên = giá trị chia độ khó (cao/S lên đầu). Những mục ⚠ bị đẩy xuống vì cần quyết định trước.

| # | Ý tưởng | Nhóm | Giá trị | Độ khó | ⚠ ADR | Ưu tiên |
|---|---|---|---|---|---|---|
| 1.1 | Màu và tiêu đề tab Warp theo môi trường | Vận hành | Cao | S | — | **1** |
| 5.1 | Online/offline trong danh sách | Monitor | Cao | S | — | **1** |
| 1.3 | Mở console web qua tunnel | Vận hành | Cao | S | — | **1** |
| 1.2 + 2.1 | Mở cả thư mục dạng pane + Synchronized Inputs | Nhiều server | Cao | M | — | **2** |
| 3.1 | Tải log hàng loạt | Log | Cao | M | — | **2** |
| 5.2 | Hạn chứng chỉ TLS | Monitor | Cao | M | — | **2** |
| 5.3 | So sánh hai lần chạy Analyst | Analyst | Cao | S/M | — | **2** |
| 7.1 | Command palette ⌘K | UX | Cao | M | — | **2** |
| 2.4 | Kiểm kê cấu hình, so sánh môi trường | Nhiều server | Cao | M | nhỏ | **2** |
| 5.4 | Luồng mong đợi (smoke test) | Analyst | Cao | M | — | **2** |
| 6.1 | Nhập CSV hoặc danh sách | Dữ liệu | Cao | M | — | **2** |
| 4.1 | Touch ID cho password đã lưu | Bảo mật | Cao | M | — | **2** |
| 2.2 | Snippets | Nhiều server | Cao | M | — | **3** |
| 1.5 | Gần đây và hay dùng | Vận hành | Vừa | S | — | 3 |
| 4.2 | UseKeychain cho passphrase | Bảo mật | Vừa | S | — | 3 |
| 4.3 | Sức khoẻ khoá, chuyển sang key | Bảo mật | Vừa | S | — | 3 |
| 4.6 | Xác nhận khi mở PROD | Bảo mật | Vừa | S | — | 3 |
| 6.2 | Sao lưu tự động | Dữ liệu | Vừa | S | — | 3 |
| 6.3 | Tag hiển thị và vai trò | Dữ liệu | Vừa | S | — | 3 |
| 1.4 | Ghi chú và liên kết thư mục | Vận hành | Vừa | S | — | 3 |
| 3.2 | Xem log trực tiếp nhiều server | Log | Vừa | S | quoting | 3 |
| 2.5 | Trạng thái dịch vụ systemd | Nhiều server | Vừa | M | nhỏ | 4 |
| 5.5 | Monitor top tiến trình, mạng, IO | Monitor | Vừa | M | nhỏ | 4 |
| 7.2 | Menu bar | UX | Vừa | M | — | 4 |
| 7.4 | Tunnel tự nối lại | UX | Vừa | M | đổi E3 | 4 |
| 7.5 | SOCKS `-D` | UX | Vừa | S | có | 4 |
| 8.1 | RDP qua SSH tunnel | Windows | Vừa | M | — | 4 |
| 1.6 | Mở Warp tại thư mục server | Vận hành | Vừa | M | có | 4 |
| 2.3 | Hỏi nhanh nhiều server (lệnh tự do) | Nhiều server | Cao | M/L | **lớn** | 5 |
| 3.3 | Grep log nhiều server | Log | Vừa | M | có | 5 |
| 4.4 | Known hosts / host key đổi | Bảo mật | Vừa | M | có | 5 |
| 5.6 | Cảnh báo ngưỡng chạy nền | Monitor | Vừa | M | có | 5 |
| 7.3 | Shortcuts / App Intents | UX | Vừa | M | có | 5 |
| 6.4 | Đồng bộ hai Mac | Dữ liệu | Thấp | L | có | 6 |
| 8.2, 8.3, 4.5 | Còn lại | — | Thấp | S/M | — | 6 |

---

## 10. Năm việc nên làm tiếp

1. **Gói "An toàn khi làm nhiều tab" (1.1 + 4.6), độ khó S.** Rẻ nhất mà giảm rủi ro thật (gõ nhầm vào PROD). Chỉ cần sửa `WarpTabConfigRenderer` và thêm một hộp xác nhận. Không cần ADR mới ngoài ghi chú.
2. **Mở cả thư mục dạng pane, gõ một lần chạy mọi nơi (1.2 + 2.1), độ khó M.** Có được tính năng MultiExec/Send-to-all mà MobaXterm, Xshell, SecureCRT đều có [3][4][6] mà **không** phải chạy lệnh hộ: người dùng gõ trong Warp thật, nên không đụng whitelist. Đây cũng là nền cho 3.2 (xem log nhiều pane).
3. **Online/offline (5.1) + Mở console qua tunnel (1.3), độ khó S + S.** Đỡ thao tác thừa hằng ngày (mở xong mới biết server tắt, tunnel xong phải tự gõ URL). Làm 1.3 thì sửa luôn được điểm yếu A7 (kiểm tra kết nối thật sau khi mở tunnel).
4. **Tải log hàng loạt (3.1), độ khó M.** Hợp đúng việc của kỹ sư vận hành Ping khi có sự cố (gửi log cho vendor), và dùng lại hoàn toàn `TransferManager`. Nên làm sau khi truyền file đã được thử với server thật (B1).
5. **Hạn chứng chỉ TLS (5.2), độ khó M.** Ngăn loại sự cố phổ biến nhất của LDAPS/HTTPS. Chạy từ Mac nên không chạm whitelist trên server. Tận dụng được danh sách cổng LISTEN mà Analyst đã có.

Đáng cân nhắc ngay sau: 5.3/5.4 (mở rộng Analyst, vì Analyst đã chạy thật trên Ping-Identity), 7.1 (⌘K), 6.1 (nhập CSV).

Mục cần người dùng quyết định nguyên tắc trước: **2.3 "Hỏi nhanh nhiều server"** có giá trị cao nhưng nghĩa là cho phép app chạy lệnh tự do của người dùng trên server. Nếu chưa muốn thì 2.4 (whitelist kiểm kê) và 2.1 (qua Warp) thay được phần lớn nhu cầu.

**Câu hỏi cho người dùng:** bạn chọn những mục nào trong 5 mục trên (hoặc mục khác theo số)? Bạn có muốn mở quy tắc để app chạy lệnh tự do (2.3) không?

---

## 11. Nguồn

Đã kiểm chứng bằng trang tài liệu của nhà sản xuất là [1] [2] [3] [4] [7] [8] [9]. Thông tin từ trang thứ ba hoặc review là [5] [6] [10] [11] [12] [13], có thể đã đổi theo phiên bản. Chỗ nào ghi "cần kiểm chứng" ở trên là suy đoán chưa thử trên máy này.

1. Warp — Tab Configs (`title`, `color`, `[[panes]]`, `commands`, `[params]`): https://docs.warp.dev/terminal/sessions/tab-configs ; Launch Configurations (legacy, đã được Tab Configs thay): https://docs.warp.dev/terminal/sessions/launch-configurations
2. Warp — Synchronized Inputs (⌥⌘I, gửi nguyên lệnh tới mọi pane của tab hoặc mọi tab): https://docs.warp.dev/terminal/entry/synchronized-inputs ; lỗi pane đã đóng vẫn nhận lệnh: https://github.com/warpdotdev/warp/issues/8293
3. MobaXterm — features (MultiExec, SSH tunnels, macros, password management, SSH gateway): https://mobaxterm-en.mobatek.net/features.html
4. Xshell — Sending Strings to Multiple Open Sessions (Compose Bar/Pane, Quick Commands, Send Key Input To All Sessions): https://netsarang.atlassian.net/wiki/spaces/ENSUP/pages/31392021/Sending+Strings+to+Multiple+Open+Sessions
5. Termius — snippets, groups, port forwarding (release notes, docs Collaborate): https://termius.com/documentation/collaborate ; https://www.apkmirror.com/?p=863200 ; SFTP: https://docs.termius.com/organize-and-connect-to-hosts/managing-files-with-sftp
6. SecureCRT — Command window gửi tới mọi phiên: https://vandyke.com/support/tips/chatsendcom.html ; Button Bar: https://vandyke.com/products/securecrt/customizable_button_bar.html
7. Warp — Workflows (tham số `{{arg}}`, giá trị mặc định): https://docs.warp.dev/knowledge-and-collaboration/warp-drive/workflows/
8. Warp — YAML workflows: https://docs.warp.dev/terminal/entry/yaml-workflows
9. Royal TS/X — Key Sequence Task (xác nhận trước khi gửi phím, kế thừa từ folder): https://docs.royalapps.com/r2023/royalts/reference/tasks/key-sequence.html
10. Royal TSX — Dynamic Folder, Import CSV (forum/support): https://docs.royalapps.com/r2023/royalserver/royal-server-configuration/dynamic-folder.html ; https://community.royalapps.com/t/dynamic-folder-based-on-custom-field/1286
11. Termius — sync mã hoá phía client (release notes 5.7.0): https://apkmirror.com/apk/termius-corporation/termius-ssh-telnet-client/termius-ssh-telnet-client-5-7-0-release
12. Core Tunnel — App Store (local/remote/dynamic forward, tự khôi phục khi rớt mạng hoặc ngủ dậy, auto-connect, menu bar, đọc ssh_config, Keychain): https://apps.apple.com/us/app/core-tunnel/id1354318707 ; https://setapp.com/apps/core-tunnel
13. Tabby — SSH client, port forwarding, jump host, login scripts: https://github.com/Eugeny/tabby

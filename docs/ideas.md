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

---

## Hướng mở rộng (chiến lược)

Người viết: product-advisor, 2026-10-22. Phần này bổ sung cho mục 1–11: không lặp tính năng lẻ mà xét **hướng đi lớn**. Gặp tính năng đã có ở trên thì chỉ dẫn số mục. Tất cả vẫn là **đề xuất**. Hướng nào chạm "Không được làm" (CLAUDE.md) hoặc "Không xây" (spec) đều ghi **⚠ đổi quy tắc**, và chỉ người dùng mới quyết được.

Chi phí: S (≤ 1 task), M (2–3 task), L (một bước như Bước E/G), XL (gần như một sản phẩm mới). Nguồn web ký hiệu [Sx] (danh sách ở cuối phần). **Đã kiểm chứng** = có trong tài liệu của hãng, hoặc đã đọc trực tiếp trên máy này. **Suy đoán** = chưa thử, cần spike.

### H-0. Đã kiểm chứng trên máy này (chỉ đọc, 2026-10-22)
- CLT có `notarytool` và `stapler` (`/Library/Developer/CommandLineTools/usr/bin/`), nghĩa là notarize được mà không cần Xcode.app.
- CLT **không có** `appintentsmetadataprocessor`. Đây là công cụ Xcode dùng để trích metadata App Intents.
- SDK `MacOSX27.0.sdk` của CLT có `AppIntents.framework` và `FoundationModels.framework` (có `.swiftinterface`). **Không có SDK iOS**, CLT chỉ có SDK macOS 26.5 và 27.0.
- `/Applications` chỉ có Warp. Chưa cài iTerm2, Ghostty, kitty, 1Password, Bitwarden hay Secretive. Terminal.app là app hệ thống.
- `/usr/lib/ssh-keychain.dylib` có trên máy (liên quan H-2b).
- `scripts/build-app.sh` ký ad-hoc (`codesign --force --sign -`) cho app và hai helper.

### Bảng tổng quan

| # | Hướng | Giá trị cho người dùng này | Chi phí | Chạm ràng buộc | Khuyến nghị |
|---|---|---|---|---|---|
| H-1 | Nguồn máy chủ tự đồng bộ (một chiều) | Cao nếu khách hàng có inventory máy đọc được | M khung + S–M mỗi nguồn | Không, nếu chỉ đọc và có xem trước | Giai đoạn 2 |
| H-2a | Agent ngoài: 1Password, Bitwarden, Secretive | Cao | S | Không (tăng an toàn) | **Ngay** |
| H-2b | Khoá Secure Enclave có sẵn của macOS | Cao | M | Không | Spike ngay, làm ở giai đoạn 2 |
| H-2c | YubiKey/FIDO2 (`sk-ssh-ed25519`) | Thấp | L | Phải bỏ `/usr/bin/ssh` | Không làm |
| H-2d | 1Password/Bitwarden CLI làm nguồn password | Vừa | M | ⚠ đổi "chỉ Keychain" | Hỏi người dùng |
| H-2e | Vault SSH CA, Teleport, AWS SSM | Tuỳ hạ tầng | M | ProxyCommand ⚠ | Xa hơn, khi có nhu cầu |
| H-3 | Chia sẻ theo nhóm qua file | Vừa | S (sau H-1) | ⚠ nhẹ, spec "không cộng tác nhóm" | Giai đoạn 2 |
| H-4 | Đa thiết bị / iOS / Linux / Windows | Thấp | S (qua file) đến XL | iOS cần Xcode | Chỉ đồng bộ qua file |
| H-5 | Terminal khác ngoài Warp | Vừa (bảo hiểm) | M | Không (spec để sau MVP) | Giai đoạn 2 |
| H-6a | CLI `sshdesk` + URL scheme + Alfred/Raycast | Cao | S–M | URL scheme cần xác nhận | **Ngay** (CLI) |
| H-6b | App Intents / Shortcuts | Vừa | M + rủi ro toolchain | Có thể cần Xcode | Xa hơn |
| H-6c | Lệnh do người dùng khai báo (whitelist mở) | Cao | M | ⚠ đổi "whitelist cố định" | Hỏi người dùng |
| H-7 | Đọc Prometheus/Zabbix, nhật ký phiên | Vừa–cao | S–M | Không | Giai đoạn 2 |
| H-8 | Trợ lý AI | Thấp–vừa | M | ⚠ spec "Không xây AI" | Hỏi người dùng |
| H-9a | Ký bằng chứng chỉ ổn định | Cao (hết bị hỏi Keychain lại) | S | Không | **Ngay** |
| H-9b | Developer ID, notarize, Sparkle, Homebrew | Thấp lúc này | M + 99 USD/năm | Sparkle là dependency ⚠ | Chỉ khi chia sẻ app |

---

### H-1. Nguồn máy chủ tự đồng bộ từ hạ tầng

**Giá trị.** Dự án Ping-Identity mới thường được bàn giao bằng Excel. Nhưng nếu khách hàng đã có Ansible inventory (hay dùng khi deploy AM/IDM/DS; đây là suy đoán), vCenter, Proxmox hoặc NetBox, thì việc gõ tay 20 server và giữ IP luôn khớp với thực tế là việc lặp lại, dễ sai. Termius đã làm việc này cho DigitalOcean và Azure: nhóm host tự cập nhật theo tài khoản cloud, dùng token chỉ đọc [S16]. Royal TSX có "Dynamic Folder": chạy script của người dùng để sinh JSON danh sách kết nối [S19][10].

**Cách làm đề xuất: một khung, nhiều nguồn.**
- Thêm khái niệm "Nguồn" gắn với **một thư mục**. Host đến từ nguồn có `source_id` và `external_id`. Đồng bộ luôn **một chiều** (nguồn → app). Mỗi lần đồng bộ hiện màn xem trước (thêm / đổi / biến mất), dùng lại màn preview và validator của ADR-020. Không bao giờ tự xoá: host biến mất được đánh dấu "không còn trong nguồn". Các trường chỉ có ở app (ghi chú, yêu thích, forward, tham chiếu password) luôn được giữ.
- **Nguồn 1, "Lệnh xuất JSON" (generic, rẻ nhất):** người dùng chọn một file thực thi cùng tham số. App chạy bằng executable + argv (không `sh -c`), đọc stdout theo đúng định dạng `sshdesk-hosts` v1 (ADR-020), giới hạn 5 MB. Script nhỏ của người dùng (jq, Python) chuyển AWS, NetBox hay Proxmox sang định dạng này. Một adapter dùng cho mọi hạ tầng, đúng mô hình Dynamic Folder của Royal.
- **Nguồn 2, "File JSON"**: một đường dẫn `*.sshdesk.json`, đọc lại khi file đổi. Đây cũng là nền cho H-3 và H-4.
- **Nguồn 3, Ansible INI/YAML tĩnh:** app tự parse, **không** gọi `ansible-inventory`. Lý do: `ansible-inventory --list` [S15] chạy cả plugin và script inventory động, tức là thực thi code. Chỉ lấy `ansible_host`, `ansible_port`, `ansible_user`; nhóm thành tag.
- **Nguồn API (làm sau, mỗi nguồn S–M):** NetBox REST [S17], Proxmox `/cluster/resources?type=vm` (token cần role PVEAuditor, privilege separation trả về rỗng nếu chưa gán quyền) [S18], Zabbix `host.get` [S26], AWS qua CLI `aws ec2 describe-instances` của người dùng (app không giữ credential AWS). Gọi HTTP bằng URLSession, không thêm dependency. Suy đoán cần spike: kết quả `/cluster/resources` của Proxmox có thể không chứa IP, phải lấy qua guest agent.
- **Không khuyến nghị Terraform state:** state thường chứa secret ở dạng rõ, và đọc state remote cần credential của backend.

**Thay đổi kiến trúc.** Migration thêm `inventory_sources` cùng cột `source_id`/`external_id` cho host. Thêm `InventorySync` trong Core (thuần, có test, dựa trên `Exchange`). Thêm UI nguồn trong menu thư mục. Cần ADR mới.

**Rủi ro bảo mật.**
- Token API (NetBox, Proxmox, Zabbix) chỉ lưu trong Keychain, chỉ HTTPS, không tắt kiểm tra chứng chỉ.
- **Rủi ro mới, quan trọng:** nếu nguồn bị sửa (hoặc file chia sẻ bị kẻ xấu chỉnh) để đổi `HostName` của "PROD-AM" sang máy lạ, askpass có thể **tự điền password đã lưu cho máy lạ**, vì quy tắc tự điền khớp theo user@hostName của chính hồ sơ (ADR-010b). Kiểm tra host key vẫn hỏi, nhưng người dùng dễ bấm yes. **Biện pháp bắt buộc:** khi đồng bộ làm đổi HostName, Port, User hoặc ProxyJump của host có password lưu, app tắt tự điền cho host đó cho tới khi người dùng xác nhận lại.
- Giá trị lấy từ nguồn phải qua đúng validator cấm newline/ký tự điều khiển (ADR-006), vì đây là kênh chèn `ProxyCommand`.

**Spike nhỏ nhất (không viết code app):** lấy một inventory thật của dự án (Excel hoặc Ansible), dùng script ngoài app chuyển sang `*.sshdesk.json`, rồi nhập bằng D1. Đếm số phút tiết kiệm được và số trường bị thiếu. Nếu giá trị rõ thì mới làm Nguồn 1 và 2.

---

### H-2. Bí mật và danh tính

**a) Agent ngoài cho từng host (1Password, Bitwarden, Secretive). S, giá trị cao.**
- Đã kiểm chứng: 1Password dùng `IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"` và hỏi duyệt (Touch ID) khi dùng key [S7]. Bitwarden có SSH agent từ bản 2025.1.2; bản tải `.dmg` hỗ trợ agent, bản App Store thì không [S8]. Secretive giữ key trong Secure Enclave, không xuất được key, có Touch ID và thông báo mỗi lần dùng [S9].
- Cách làm: thêm trường "Agent" cho hồ sơ (Hệ thống / 1Password / Bitwarden / Secretive / đường dẫn tuỳ chọn). `SSHConfigWriter` ghi `IdentityAgent "<path>"` vào **Host block của app** (file app sở hữu, đúng ADR-006). Màn SSH Keys hiện được key của agent đã chọn bằng `ssh-add -L` với `SSH_AUTH_SOCK` trỏ socket đó (truyền qua env của process con; đây là đường dẫn socket, không phải secret).
- Lợi ích: private key không nằm trên đĩa, không cần lưu password, Touch ID theo từng lần dùng. Giảm rủi ro A1 mạnh hơn cả 4.1.
- Suy đoán cần thử: Analyst và Monitor dùng `BatchMode=yes`. Hộp duyệt của 1Password là GUI nên vẫn hiện được, nhưng khi duyệt chậm thì master có thể hết timeout.
- Spike: cài thử một agent, thêm tay một dòng `IdentityAgent` vào bản sao config tạm, rồi `ssh -G` để xác nhận thứ tự ưu tiên với `IdentitiesOnly yes`.

**b) Khoá Secure Enclave có sẵn của macOS (không cần app ngoài). M, giá trị cao. Cần spike.**
- Nguồn cộng đồng [S10] mô tả: từ macOS Tahoe, `/usr/lib/ssh-keychain.dylib` có hiện thực `SecurityKeyProvider`. Tạo key bằng `sc_auth create-ctk-identity -l ssh -k p-256-ne -t bio`, lấy tham chiếu bằng `ssh-keygen -w /usr/lib/ssh-keychain.dylib -K`, kết nối với `-o SecurityKeyProvider=/usr/lib/ssh-keychain.dylib`. File "private" chỉ là tham chiếu, key không rời chip.
- Đã kiểm chứng: dylib có trên máy này. **Chưa kiểm chứng:** việc này có chạy với macOS 27 và OpenSSH 10.3p1 hay không. Không có tài liệu chính thức của Apple trong kết quả tìm được.
- Cách làm: màn SSH Keys có nút "Tạo khoá Secure Enclave (Touch ID)". Mọi lệnh chạy bằng argv. Config app ghi `SecurityKeyProvider` cho host dùng loại khoá này. Cài lên server bằng E1 (`ssh-copy-id`).
- Spike: researcher tạo một identity thử rồi kết nối tới sshd tạm 127.0.0.1 (cách R1 đã làm), sau đó xoá identity.

**c) YubiKey/FIDO2 (`sk-ssh-ed25519`). L, giá trị thấp, không khuyến nghị.** OpenSSH đi kèm macOS thiếu middleware libfido2. Yubico khuyên cài OpenSSH từ Homebrew [S11]. Đổi sang `ssh` của Homebrew sẽ phá mô hình hiện tại: askpass kiểm tra cha là `/usr/bin/ssh`, `UseKeychain` là tính năng riêng của bản Apple, và mọi kiểm chứng ADR-006/008 đều làm trên bản Apple. Chỉ làm nếu công ty bắt buộc dùng YubiKey.

**d) 1Password/Bitwarden CLI làm nguồn password (`op read op://...`). M, giá trị vừa. ⚠ đổi quy tắc.** Phù hợp khi đội lưu password server trong vault chung. Password sẽ đi từ stdout của `op` vào bộ nhớ app/askpass: không qua file, argv hay env, nhưng **không còn là "chỉ Keychain"**. Nếu người dùng muốn thì phải ghi ngoại lệ vào ADR-004, giống cách ADR-018 làm cho Windows.

**e) Lớp truy cập: Vault SSH CA, Teleport, AWS SSM. M mỗi loại, chỉ khi hạ tầng có sẵn.**
- Vault: engine SSH ký public key của người dùng thành chứng chỉ ngắn hạn [S12]. App có nút "Lấy chứng chỉ" chạy `vault write <mount>/sign/<role> public_key=@<pub>` bằng argv. Token do `vault login` của người dùng quản lý, app không giữ. Config app ghi `CertificateFile`. Vault OTP thì là password, nên rơi vào trường hợp d) ⚠.
- Teleport: `tsh config` in ra cấu hình OpenSSH [S13]. App có thể lưu kết quả vào một file app sở hữu (`sshdesk_teleport.conf`) rồi `Include` từ config app, không đụng `~/.ssh/config`.
- AWS SSM: cần `ProxyCommand aws ssm start-session --document-name AWS-StartSSHSession ...` [S14]. Hiện writer không cho ProxyCommand vì đây là kênh chèn lệnh. Nếu làm thì chỉ cho **một mẫu cố định**, instance id phải qua regex chặt. Cần ADR.

---

### H-3. Dùng theo nhóm (chia sẻ danh sách server, snippet)

**Giá trị: vừa.** Đồng nghiệp cùng dự án Ping cần đúng danh sách 20 server và các forward console. Hiện mỗi người tự nhập.

**Sản phẩm khác làm thế nào (đã kiểm chứng từ tài liệu hãng):** Termius dùng "vault" mã hoá đầu-cuối qua server của họ, có Team vault và Personal vault; credential riêng nên để ở Personal vault [S20]. Royal TS chia sẻ "document" chỉ chứa kết nối, còn credential gán **theo tên** và nằm trong document cá nhân có mật khẩu [S19]. Warp Drive đã chia sẻ được workflow và notebook trong đội, gói miễn phí giới hạn 10 workflow chia sẻ [S21].

**Đề xuất: không xây server.** Chia sẻ bằng **file trong Git repo hoặc thư mục dùng chung**, dựa vào Nguồn 2 của H-1:
- Xuất "gói dự án" `*.sshdesk.json` bỏ các trường cá nhân (user, đường dẫn key, cờ password), giống cách Royal tách credential. Mỗi người tự gắn user và key của mình bằng "ghi đè cục bộ".
- Người nhận đăng ký đường dẫn file làm nguồn. Mỗi lần đổi hiện diff, áp dụng đúng biện pháp chống đổi HostName ở H-1.
- Snippet chia sẻ: dùng Warp Drive hoặc xuất Warp Workflow YAML (mục 2.2), không tự làm kênh riêng.

**Chi phí:** S nếu đã có H-1, M nếu làm riêng.

**Ràng buộc:** spec ghi "Không xây cộng tác nhóm". Chia sẻ file thủ công nằm ở vùng xám, nên **⚠ cần người dùng xác nhận**. Không bao giờ có secret trong gói. File vẫn nhạy cảm vừa (lộ sơ đồ IP, A15), nên nhắc dùng repo private.

**Spike:** xuất bằng D1, đưa vào một repo private, đồng nghiệp nhập thử. Ghi lại các trường cá nhân bị lẫn vào.

---

### H-4. Đa thiết bị, đa nền tảng

- **Giữa các Mac (S):** dùng 6.2 (sao lưu tự động) cộng Nguồn 2 của H-1 trỏ vào iCloud Drive hoặc thư mục đồng bộ người dùng chọn. Password không đi theo, người dùng nhập lại trên máy kia (đúng ADR-004). Suy đoán: đồng bộ thật bằng CloudKit hay iCloud Keychain (`kSecAttrSynchronizable`) cần entitlement và provisioning profile của tài khoản Apple Developer, không làm được với bản ký ad-hoc. Đồng thời đi ngược spec "không đồng bộ cloud mặc định". Không khuyến nghị.
- **iOS/iPad (XL, giá trị thấp):** đã kiểm chứng CLT không có SDK iOS, nên phải cài Xcode.app. Suy đoán: Warp không có bản iOS, nên app iPad phải nhúng terminal, vi phạm "Không xây terminal tự viết". Lựa chọn duy nhất hợp quy tắc là app xem danh sách rồi chuyển sang app SSH khác. Không đáng làm.
- **Linux/Windows (XL, giá trị thấp):** SwiftUI không có trên hai nền tảng này. Các thư viện thay thế như SwiftCrossUI hay SwiftOpenUI đều là bên thứ ba, có bản còn ghi "experimental" [S22], và đều là dependency ngoài. Core cũng phụ thuộc macOS: Keychain, `posix_spawn`, helper ctty, NSWorkspace, Windows App. Người dùng chỉ dùng Mac, nên không làm.

---

### H-5. Hỗ trợ terminal khác ngoài Warp

**Giá trị: vừa.** Đây là bảo hiểm khi Warp đổi Tab Config hoặc URI, hay đòi đăng nhập, và cho phép mở nhanh bằng Terminal.app khi Warp lỗi. Spec để mục này ở "Để sau MVP", tức là được phép.

**Cơ chế từng app (đã kiểm chứng ở tài liệu hãng, chưa thử trên máy này):**

| Terminal | Cơ chế | Ghi chú |
|---|---|---|
| Terminal.app | Mở file `.command` do app sinh, hoặc AppleScript `do script` [S6] | Cách file `.command` không cần quyền Automation (suy đoán, cần thử). Không có tab color hay pane. |
| iTerm2 | Dynamic Profiles: file JSON/plist trong `~/Library/Application Support/iTerm2/DynamicProfiles`, có `Guid`, `Name`, `Custom Command`, `Command`; iTerm2 tự nạp lại [S4]. Mở bằng AppleScript `create window with profile`/`... command` [S3] | Rất giống mô hình Tab Config: app chỉ ghi file `sshdesk_*.json` của mình. |
| Ghostty ≥ 1.3 | AppleScript: `new window`/`new tab`/`split` với `surface configuration` (command, initial input, env) [S1] | Bản 1.3 là preview, API có thể đổi ở 1.4 [S2]. Cần quyền Automation (TCC). |
| kitty | `kitten @ launch --type=tab\|os-window` qua remote control; cần `allow_remote_control` hoặc `--listen-on` [S5] | Tài liệu kitty cảnh báo process nào có quyền cũng điều khiển được kitty. Nên xếp ưu tiên thấp. |

**Thay đổi kiến trúc.** Thêm protocol `TerminalLauncher` trong Core. `WarpLauncher` trở thành một hiện thực, mỗi loại khai báo khả năng của mình (tab, pane, màu, tiêu đề). Cài đặt có mục "Terminal mặc định" (ADR-021). Lệnh `ssh`/askpass giữ nguyên: askpass hoạt động với mọi terminal vì nó chỉ cần env tham chiếu cộng `/dev/tty`. Cần ADR (mở rộng ADR-007).

**Chi phí:** M cho khung, Terminal.app và iTerm2. Mỗi terminal thêm S.

**Rủi ro bảo mật.** AppleScript là chuỗi mã nên lệnh phải được escape cho AppleScript (thêm một tầng quoting). Ưu tiên cơ chế file như iTerm2 Dynamic Profile và `.command` để tránh việc này. File `.command` có quyền thực thi, chỉ đặt trong thư mục app (0700), xoá sau khi mở. Không ghi secret, giống Tab Config.

**Spike:** sinh một `sshdesk_test.command` chứa `/usr/bin/ssh -V`, mở bằng NSWorkspace với Terminal.app. Kiểm tra có bị Gatekeeper hay quarantine chặn không và có cần hỏi quyền không.

---

### H-6. Khả năng mở rộng kỹ thuật

**a) CLI `sshdesk`, URL scheme, Alfred/Raycast. S–M, giá trị cao.**
- CLI là executable thứ hai trong SwiftPM, link `SSHDeskCore`: `sshdesk list [--folder X] [--json]`, `sshdesk open <tên|id>` (sinh Tab Config rồi mở Warp, như nút Mở Warp), `sshdesk config-path`. Đây là nền cho mọi tích hợp khác: Alfred Script Filter gọi `sshdesk list --json` (S, không cần npm). Raycast extension viết bằng TypeScript/React; đã có tiền lệ là extension "Hop" mở SSH trong Warp, iTerm, kitty [S23]. Extension Raycast nằm ngoài repo Swift và cần toolchain npm, nên tính là dự án phụ.
- Ràng buộc kỹ thuật: CLI mở SQLite **chỉ đọc**, chỉ app mới ghi config. Cần kiểm tra chế độ journal và busy timeout khi app đang chạy. CLI không nằm trong danh sách trusted app của Keychain item nên không đọc được password; đó là điều tốt. Askpass vẫn trỏ helper trong bundle.
- URL scheme `sshdesk://open?id=<uuid>`: khai báo `CFBundleURLTypes` trong Info.plist do `build-app.sh` sinh (S). Lợi ích: đặt link host trong wiki hoặc Obsidian. **Bắt buộc** hiện hộp xác nhận, vì trang web nào cũng gọi được URL. Chỉ nhận `id`, không bao giờ nhận lệnh hay secret (đúng 7.3).
- Spike: target CLI `list --json` đọc DB thật ở chế độ read-only trong khi app đang mở.

**b) App Intents / Shortcuts / Spotlight. M, cộng rủi ro toolchain.**
- Đã kiểm chứng: framework có trong SDK của CLT, nhưng `appintentsmetadataprocessor` thì không. Theo các thread diễn đàn Apple, bước "Extract app intents metadata" chạy trong build của Xcode; thiếu metadata thì intent không hiện trong Shortcuts mà không báo lỗi [S24].
- Suy đoán: build bằng SwiftPM với CLT thì intent không xuất hiện. Hệ quả: hoặc cài Xcode.app (khi đó bỏ được `@Local`, ADR-009), hoặc dùng CLI hay URL scheme thay thế. Shortcuts gọi được CLI qua hành động "Run Shell Script".
- Spike: một `AppIntent` tối thiểu, build bằng `make app`, xem Shortcuts có thấy không. Nửa ngày là đủ.

**c) Thư mục lệnh do người dùng khai báo ("plugin" an toàn). M, giá trị cao. ⚠ đổi "whitelist cố định".**
- Mỗi lệnh là file JSON trong `~/Library/Application Support/SSHDesk/commands/`, gồm: tên, argv cố định, tham số có kiểu (`unit`, `path`, `ip`, `port`) cùng regex validate có sẵn của app, cờ "chỉ đọc", có hiện trong Monitor hay không, parser (bảng, dòng, số). App hiện lệnh đã ghép trước khi chạy, PROD luôn xác nhận, không lưu output thô.
- Đây là dạng có nguyên tắc của 2.3, 2.4, 2.5 và 5.5: thay vì PM thêm từng lệnh vào whitelist, người dùng tự khai báo. Nhưng chuỗi vẫn đi vào shell của server (ADR-016 đã nêu), nên đây là quyết định lớn của người dùng.
- Không làm plugin dạng code (dylib, script local tuỳ ý): mỗi plugin như vậy là một lỗ chạy code không kiểm soát, và cũng đi ngược "không `sh -c`".

---

### H-7. Quan sát và vận hành

**Nhận định chiến lược:** Monitor hiện đo bằng SSH mỗi 5 giây, chỉ khi màn đang mở (ADR-019). Hướng đúng **không phải** biến SSH Desk thành Zabbix thứ hai, mà là **đọc từ hệ thống monitoring có sẵn** và **liên kết sang đó**.

- **Đọc Prometheus (M):** `GET /api/v1/query?query=...` trả về vector [S25]. Metric node_exporter như `node_filesystem_avail_bytes` có nhãn `mountpoint` [S25]. Monitor có thêm chế độ "nguồn Prometheus": không mở phiên SSH, không có nguy cơ khoá tài khoản, có lịch sử thật. Ánh xạ host theo nhãn `instance`. Suy đoán: AM/IDM/DS của Ping/ForgeRock có endpoint metric Prometheus, cần kiểm chứng với phiên bản khách hàng dùng.
- **Đọc Zabbix (M):** JSON-RPC `api_jsonrpc.php`, token gửi qua header Bearer từ bản 7.0 [S26]. `host.get` dùng được cho H-1, còn cảnh báo đang mở thì lấy qua `problem.get` (chưa đọc tài liệu chi tiết).
- **Liên kết Grafana hoặc console monitoring (S):** mỗi thư mục hoặc host có URL dashboard mẫu, kiểu `...&var-host={{hostName}}`. Thực chất là mở rộng 1.4.
- **Cảnh báo bằng thông báo macOS:** xem 5.6. Giá trị cao hơn hẳn nếu dữ liệu lấy từ Prometheus hoặc Zabbix (đã chạy nền phía server), vì app chỉ cần hỏi định kỳ một API.
- **Nhật ký phiên cục bộ (S, giá trị vừa):** bảng `activity_log(time, host_id, environment, action)` với action là mở Warp, truyền file, tunnel, chạy Analyst, Monitor. Không lưu lệnh hay output. Dùng cho câu hỏi "hôm qua tôi vào PROD lúc nào" khi viết báo cáo sự cố hoặc change request, và làm dữ liệu cho 1.5 (Gần đây). Phải ghi rõ: **không phải audit chống chối bỏ** (người dùng tự sửa được DB), audit thật là việc của server (auditd, Teleport).
- **Rủi ro:** token Prometheus/Zabbix lưu trong Keychain, ưu tiên token chỉ đọc, chỉ HTTPS.
- **Spike:** hỏi người dùng hạ tầng Ping-Identity có Prometheus hay Zabbix không. Nếu có, thử một `curl` chỉ đọc từ Mac (người dùng tự chạy) để xem nhãn host.

---

### H-8. Trợ lý AI

**Ràng buộc:** spec mục "Không xây" ghi rõ "AI". Toàn bộ hướng này **⚠ cần người dùng đổi quy tắc**.

**Bối cảnh đã kiểm chứng:** Warp, terminal người dùng đang dùng, đã có AI agent. Tài liệu Warp nói nhà cung cấp LLM của họ cam kết zero data retention, nhưng trang FAQ lại ghi ZDR thuộc gói Enterprise, hai chỗ chưa khớp. Secret redaction của Warp **mặc định tắt** [S27]. Nghĩa là người dùng đã có AI ngay trong terminal để giải thích lỗi hay gợi ý lệnh. SSH Desk không cần làm lại phần này. Nên nhắc người dùng bật Secret Redaction trong Warp nếu dùng AI của Warp trên server khách hàng.

**Nếu muốn làm trong app**, chỉ có một chỗ có giá trị riêng là **tóm tắt kết quả có cấu trúc** của Analyst/Monitor/2.4 thành đoạn văn tiếng Việt cho ticket ("IDM mất kết nối DS:1636 so với lần chạy trước").
- **Model trên máy (khuyến nghị nếu làm):** đã kiểm chứng `FoundationModels.framework` có trong SDK của CLT. Theo nguồn thứ cấp, model chạy trên máy, offline, cần Mac hỗ trợ và đã bật Apple Intelligence [S28]. Suy đoán: macro `@Generable` không dùng được với CLT, cùng lý do với `@State` (ADR-009), nên chỉ dùng được phản hồi dạng text. Dữ liệu không rời máy.
- **API cloud:** không khuyến nghị. Nếu người dùng vẫn muốn thì phải bật theo từng lần, hiện đúng payload sẽ gửi, thay IP và hostname bằng nhãn (`server-1`), không bao giờ gửi log thô. API key lưu trong Keychain.

**Chi phí:** M. **Giá trị:** thấp–vừa.

**Spike:** script Swift khoảng 20 dòng gọi FoundationModels trên máy này với một báo cáo Analyst đã ẩn danh. Kiểm tra máy có model không và chất lượng tiếng Việt thế nào.

---

### H-9. Phân phối và ký app

**a) Chứng chỉ ký ổn định cho bản cá nhân. S, giá trị cao, nên làm sớm.**
- Vấn đề: ad-hoc signing sinh cdhash mới sau mỗi build. ACL của Keychain item và quyền TCC gắn với designated requirement (DR), nên mỗi lần `make install` macOS có thể coi app là "app khác" và hỏi lại quyền truy cập Keychain. ADR-010 đã ghi điều này là "chưa kiểm chứng". Nguồn: thread diễn đàn Apple về DR của Keychain item [S29], và một dự án mô tả quyền Accessibility bị mất sau mỗi build ad-hoc, hết khi ký bằng chứng chỉ cố định [S29].
- Cách làm: người dùng tạo một chứng chỉ "Code Signing" tự ký trong Keychain Access (miễn phí). `build-app.sh` ký app và hai helper bằng tên chứng chỉ đọc từ biến môi trường, không có thì giữ ad-hoc. DR trở nên ổn định qua các lần build. Không được Gatekeeper công nhận, nhưng app build tại máy thì không bị quarantine nên không ảnh hưởng.
- Đây là điều kiện cho 4.1 (Touch ID, `userPresence`) và H-2 chạy mượt.
- Spike: build hai lần với chứng chỉ tự ký, so `codesign -d -r-` giữa hai lần, rồi thử askpass đọc Keychain sau khi cài lại.

**b) Developer ID, notarize, auto-update, Homebrew. M cộng 99 USD/năm, giá trị thấp lúc này.**
- Notarize được không cần Xcode, vì đã kiểm chứng `notarytool` và `stapler` có trong CLT. Cần tài khoản Apple Developer Program và Developer ID Application. Cần bật Hardened Runtime (`codesign -o runtime --timestamp`) cho app và cả hai helper. Suy đoán: Hardened Runtime không cản `posix_spawn`, PTY hay Keychain, nhưng phải thử lại toàn bộ askpass và ctty.
- Sparkle (auto-update) [S31] là **dependency ngoài** (⚠ CLAUDE.md), cần khoá EdDSA và nơi chứa appcast. Spec cũng loại "cập nhật tự động bắt buộc". Với app build từ mã nguồn, `make install` chính là cách cập nhật.
- Homebrew cask: Homebrew 5 yêu cầu cask được ký và notarize, cask không ký sẽ bị gỡ khỏi tap chính trước tháng 9/2026 (nguồn thứ cấp, chưa xác nhận đã thi hành) [S32]. Chỉ liên quan nếu phát hành cho người khác.
- Kết luận: chỉ làm khi người dùng quyết định chia sẻ app cho đồng nghiệp (gắn với H-3).

---

### H-10. Điều kiện tiên quyết: củng cố trước khi mở rộng

Hơn 15 mục trong `plan.md` còn `[~]`: truyền file, askpass, tunnel, Monitor, Windows, Cài đặt, vòng đời app. Mọi hướng ở trên đều xây trên các phần này. Muốn mở rộng tiếp thì nên có ít nhất một vòng người dùng thử thật (`make install`) cho truyền file, askpass và tunnel. Đặc biệt H-9a nên làm **trước** vòng thử này, nếu không các lần cài lại sẽ liên tục hỏi quyền Keychain và làm sai kết quả thử.

---

### Lộ trình đề xuất 3 giai đoạn

**Giai đoạn 1, ngay (1–2 tuần, chủ yếu S, không đổi quy tắc):**
1. H-9a: ký bằng chứng chỉ tự ký ổn định (spike rồi sửa `build-app.sh`).
2. H-10: người dùng thử thật các mục `[~]` sau khi đã có H-9a.
3. H-2a: chọn agent cho từng host (1Password, Bitwarden, Secretive, `IdentityAgent`).
4. H-6a: CLI `sshdesk list/open`; URL scheme có xác nhận (tuỳ chọn).
5. Spike không code: H-1 (chuyển một inventory thật sang `.sshdesk.json`), H-2b (Secure Enclave), H-6b (App Intents với CLT), H-5 (`.command` với Terminal.app).

**Giai đoạn 2, 1–2 tháng (M, cần ADR mới nhưng không đổi quy tắc):**
1. H-1: khung Nguồn đồng bộ (Lệnh xuất JSON, File JSON, Ansible tĩnh) có xem trước, kèm biện pháp tắt tự điền khi HostName đổi.
2. H-3: gói dự án chia sẻ qua Git, dựa trên H-1 (nếu người dùng đồng ý vùng xám "nhóm").
3. H-5: `TerminalLauncher` cùng Terminal.app và iTerm2 (Dynamic Profiles).
4. H-2b: khoá Secure Enclave trong màn SSH Keys (nếu spike đạt).
5. H-7: nhật ký phiên cục bộ. Đọc Prometheus hoặc Zabbix nếu hạ tầng có.

**Giai đoạn 3, xa hơn (tuỳ quyết định của người dùng):**
- Nguồn API: NetBox, Proxmox, AWS CLI, Zabbix `host.get`.
- H-2e: Vault CA, Teleport, SSM, khi công ty dùng.
- H-6c: thư mục lệnh do người dùng khai báo (⚠ đổi whitelist).
- H-2d: password từ 1Password/Bitwarden CLI (⚠ đổi "chỉ Keychain").
- H-8: AI trên máy (⚠ đổi "không AI").
- H-6b: App Intents, nếu cài Xcode.app.
- H-9b: Developer ID và notarize, nếu chia sẻ app.

**Không khuyến nghị:** app iOS/iPad, bản Linux/Windows, Sparkle, YubiKey qua OpenSSH Homebrew, đọc Terraform state, plugin dạng code chạy local.

### Câu hỏi người dùng cần quyết

1. Khách hàng hoặc công ty có nguồn danh sách server máy đọc được không (Ansible inventory, vCenter, Proxmox, NetBox, AWS, Zabbix)? Hay chủ yếu là Excel?
2. Bạn có dùng (hoặc được phép dùng) 1Password, Bitwarden, Secretive, Vault hay Teleport không? Key SSH hiện để ở đâu?
3. Bạn có định chia sẻ danh sách server hoặc chính app cho đồng nghiệp không? Câu trả lời quyết định H-3 và việc có trả 99 USD/năm cho Developer ID (H-9b).
4. Warp có phải terminal duy nhất bạn muốn dùng không, hay cần dự phòng Terminal.app/iTerm2?
5. Bạn có muốn nới ba quy tắc sau không: "whitelist cố định" thành "whitelist do bạn khai báo" (H-6c); "chỉ Keychain" để lấy password từ vault công ty (H-2d); "không AI" thành "chỉ AI chạy trên máy" (H-8)?
6. Bạn có cài được Xcode.app không? Nếu có thì mở được App Intents và bỏ được `@Local`.

### Nguồn của phần chiến lược

Tài liệu của hãng: [S1] [S3] [S4] [S5] [S7] [S8] [S12] [S13] [S14] [S15] [S16] [S17] [S19] [S20] [S21] [S25] [S26] [S27] [S31]. Nguồn cộng đồng hoặc thứ cấp, cần kiểm chứng lại: [S2] [S6] [S9] [S10] [S11] [S18] [S22] [S23] [S24] [S28] [S29] [S30] [S32].

- S1. Ghostty — AppleScript (từ 1.3.0; new window/tab/split, surface configuration, TCC): https://ghostty.org/docs/features/applescript
- S2. Ghostty — AppleScript là preview ở 1.3, có thể đổi API ở 1.4 (trích issue): https://claudeissues.com/issue/24189-feature-request-add-ghostty-as-a-split-pane-backend-for-agent-teams-teammatemode
- S3. iTerm2 — Scripting (`create window with default profile command`): https://iterm2.com/3.4/documentation-scripting.html
- S4. iTerm2 — Dynamic Profiles (thư mục, `Guid`, `Name`, `Custom Command`, `Command`, tự nạp lại): https://iterm2.com/documentation-dynamic-profiles.html
- S5. kitty — launch (`--type=tab|os-window`): https://sw.kovidgoyal.net/kitty/launch/ ; remote control: https://sw.kovidgoyal.net/kitty/remote-control/
- S6. Terminal.app — mở cửa sổ mới bằng lệnh/AppleScript: https://scriptingosx.com/2020/03/macos-shell-command-to-create-a-new-terminal-window/
- S7. 1Password — SSH agent, `IdentityAgent` trên macOS, duyệt bằng Touch ID: https://www.1password.dev/ssh/get-started/
- S8. Bitwarden — SSH agent (≥ 2025.1.2, bản .dmg hỗ trợ, bản App Store không): https://bitwarden.com/help/ssh-agent/
- S9. Secretive — key SSH trong Secure Enclave: https://github.com/maxgoedjen/secretive
- S10. Secure Enclave qua `/usr/lib/ssh-keychain.dylib` (macOS Tahoe, `sc_auth`, `SecurityKeyProvider`): https://gist.github.com/skeeet/e5a1e6c613bf6bd2b8e53d9a147e85f9 ; https://ewpratten.com/blog/ssh-secure-enclave/
- S11. FIDO2 trên macOS: Yubico https://developers.yubico.com/SSH/Securing_SSH_with_FIDO2.html ; Apple forum https://developer.apple.com/forums/thread/698683 ; https://gist.github.com/BertanT/9d222da115ca2d1274ef34735c4260cf
- S12. HashiCorp Vault — Signed SSH certificates: https://developer.hashicorp.com/vault/docs/v1.20.x/secrets/ssh/signed-ssh-certificates
- S13. Teleport — `tsh config`: https://goteleport.com/docs/ver/17.x/reference/cli/tsh/
- S14. AWS Systems Manager — SSH qua Session Manager (`AWS-StartSSHSession`, ProxyCommand): https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started-enable-ssh-connections.html
- S15. Ansible — `ansible-inventory --list`: https://docs.ansible.com/projects/ansible-core/2.16/cli/ansible-inventory.html
- S16. Termius — tích hợp DigitalOcean, Azure (token chỉ đọc, nhóm tự cập nhật): https://docs.termius.com/integrations/digitalocean ; https://docs.termius.com/integrations/microsoft-azure
- S17. NetBox — REST API: https://netboxlabs.com/docs/v3.7/netbox/integrations/rest-api/
- S18. Proxmox — `/cluster/resources?type=vm`, quyền token (forum): https://forum.proxmox.com/threads/api-list-vms.151033/latest ; https://forum.proxmox.com/goto/post?id=794300
- S19. Royal TS/TSX — chia sẻ document, credential theo tên, Dynamic Folder: https://royalapps.com/ts/mac/features-all ; https://www.royalapps.com/go/help-ts-win-v6-ref-dynamic-folder
- S20. Termius — Vaults (Team/Personal, mã hoá đầu-cuối): https://docs.termius.com/getting-started/learn-about-vaults
- S21. Warp Drive — chia sẻ workflow, notebook trong đội: https://docs.warp.dev/knowledge-and-collaboration/warp-drive
- S22. SwiftCrossUI: https://github.com/moreSwift/swift-cross-ui ; SwiftOpenUI (forum): https://forums.swift.org/t/swiftui-for-linux-windows-and-web-still-experimental/85463
- S23. Raycast — extension Hop (SSH, mở Warp/iTerm/kitty): https://www.raycast.com/danmartuszewski/hop
- S24. App Intents metadata trong build Xcode: https://developer.apple.com/forums/thread/719899 ; https://developer.apple.com/forums/thread/766501
- S25. Prometheus — HTTP API: https://prometheus.io/docs/prometheus/2.53/querying/api ; node_exporter filesystem: https://www.robustperception.io/filesystem-metrics-from-the-node-exporter/
- S26. Zabbix — API (JSON-RPC, token Bearer từ 7.0): https://www.zabbix.com/documentation/7.0/manual/api
- S27. Warp — Security overview (ZDR), Secret Redaction (mặc định tắt): https://docs.warp.dev/enterprise/security-and-compliance ; https://docs.warp.dev/features/secret-redaction
- S28. Foundation Models (thứ cấp): https://createwithswift.com/exploring-the-foundation-models-framework/
- S29. Keychain ACL theo designated requirement: https://developer.apple.com/forums/thread/98484 ; ad-hoc cdhash làm mất quyền sau mỗi build: https://git.bdeshi.space/bdeshi/shannoncoat/src/tag/0.0.8
- S30. notarytool `store-credentials` / API key: https://developer.apple.com/forums/thread/786582
- S31. Sparkle — Basic Setup, EdDSA, upgrading: https://sparkle-project.org/documentation/ ; https://sparkle-project.org/documentation/upgrading/
- S32. Homebrew 5.0.0 — cask phải ký và notarize (thứ cấp): https://workbrew.com/blog/what-homebrew-5-0-0-means-for-your-mac-fleet

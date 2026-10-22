# Kiến trúc & quyết định

Mỗi quyết định: bối cảnh → quyết định → lý do. `Đã chốt` = không tự ý đổi; muốn đổi phải đề xuất cho PM.
Môi trường đã kiểm tra (2026-10-21): macOS 27.0.1 arm64, Swift 6.4 (chỉ Command Line Tools), OpenSSH_10.3p1, Warp 0.2026.10.14.

## ADR-001: Swift 6 + SwiftUI + SwiftPM — Đã chốt
- Không có Xcode.app → SwiftPM là luồng build duy nhất; `.app` đóng gói bằng script (`scripts/build-app.sh`), ký ad-hoc, không notarize.
- Deployment target macOS 14. Không bật App Sandbox (cần đọc `~/.ssh`, chạy `/usr/bin/ssh`).

## ADR-002: Tách SSHDeskCore / SSHDesk — Đã chốt
- Toàn bộ logic trong `SSHDeskCore` (test được), `SSHDesk` chỉ là UI. Module theo mục 5 của prompt:
  HostRepository, SSHConfigurationService, WarpLauncher, OpenSSHProcessRunner, TransferManager, CredentialStore, TransferRepository.

## ADR-003: Swift Testing — Đã chốt
- XCTest không có trong CLT. Swift Testing cần `-plugin-path` (đã gói trong `make test`).

## ADR-004: Secret chỉ trong Keychain — Đã chốt
- DB chỉ lưu `credentialReference`. Password/passphrase/OTP không vào argv, env, log, export, URI, clipboard.

## ADR-005: SQLite hệ thống — Đã chốt
- `import SQLite3`, không dependency ngoài. File: `~/Library/Application Support/SSHDesk/sshdesk.sqlite`, thư mục quyền 0700.
- Có bảng `schema_version` + migration tuần tự. DB lỗi → báo lỗi, không tạo DB rỗng đè lên.

## ADR-006: Một file SSH config do app sở hữu — Đã chốt, đã kiểm chứng (OpenSSH 10.3p1)
- File: `~/Library/Application Support/SSHDesk/ssh/config` (0600), ghi atomically, sinh lại từ DB.
- Bố cục:
  ```
  # Do SSH Desk sinh — không sửa tay
  Host sshdesk-<uuid>
      HostName ... / Port ... / User ... / IdentityFile ... / IdentitiesOnly yes (nếu có key)
      ProxyJump sshdesk-<uuid-bastion>   # hoặc alias bastion có sẵn
  ...
  Match all
  Include <đường dẫn tuyệt đối ~/.ssh/config>
  ```
  Host của app đứng trước để giá trị của app thắng (OpenSSH lấy giá trị đầu tiên); `Match all` reset ngữ cảnh trước Include.
- Mọi kết nối (Warp và truyền file) dùng cùng dạng: `/usr/bin/ssh -F <app config> <alias>` (`scp`/`sftp` cũng `-F` như vậy).
  Hồ sơ imported alias dùng nguyên alias gốc — nhờ Include nên resolve được mà không flatten.
- **Đã kiểm chứng bằng `ssh -G`/`ssh -v` với config tạm:**
  - Host của app thắng `Host *` của user (User/Port của app giữ nguyên); các thiết lập chung (vd ServerAliveInterval) vẫn áp qua Include.
  - Alias trong config user (bastion, web-u...) resolve được qua Include. **Bắt buộc có `Match all` trước Include**: không có thì Include chỉ áp cho Host đứng ngay trước.
  - ProxyJump tự truyền `-F <cùng file>` cho ssh tới bastion (`Setting implicit ProxyCommand ... ssh -F ...`) → **đường dẫn `-F` phải tuyệt đối**.
  - **Newline trong giá trị bị parse thành directive mới** (có thể chèn `ProxyCommand`) → validate cấm `\n`, `\r`, ký tự điều khiển là **bắt buộc**, có test riêng.
  - Quote hợp lệ: `"..."` hoặc backslash (`\ `, `\"`, `\\`); dấu `"` lẻ → lỗi `invalid quotes`. Writer luôn bọc giá trị trong `"..."` và escape `\` và `"`.
- Giá trị trường (host, user, path) được validate: cấm newline/ký tự điều khiển, quote theo cú pháp ssh_config.

## ADR-007: Warp qua Tab Config — Đã chốt
- File: `~/.warp/tab_configs/sshdesk_<uuid>.toml` (chỉ ghi file có tiền tố `sshdesk_`).
- Một pane `terminal`, `shell = "zsh"`, `commands = ["<lệnh ssh đã quote cho zsh>"]`.
- Mở bằng `NSWorkspace.open(URL("warp://tab_config/sshdesk_<uuid>"))`, tuỳ chọn `?new_window=true`.
- App chỉ ghi nhận "đã yêu cầu mở Warp". Warp không có/lỗi → fallback **Copy lệnh SSH**.
- TOML string phải escape đúng (`\"`, `\\`, ký tự điều khiển); tên hồ sơ không bao giờ vào `commands`.

## ADR-008: Truyền file bằng `scp` (giao thức SFTP) qua PTY — Đã chốt
- Backend: `/usr/bin/scp -F <config tuyệt đối>` (OpenSSH ≥ 9.0 mặc định SFTP; **không dùng `-O`**), `-r` cho thư mục, `-p` không dùng mặc định. Không tạo implementation `sftp` song song.
- **Escape đường dẫn remote (kiểm chứng C1, scp thật + fake ssh → sftp-server, 23 tên thử mỗi chiều):**
  - Download (remote là nguồn): chỉ `\ * ? [ ]` bị glob; escape bằng `\` cho đúng literal cả 5 (kể cả trong thành phần thư mục).
  - Upload (remote là đích): **không glob → KHÔNG escape** (escape sẽ tạo tên có thêm `\`).
  - Khoảng trắng, nháy, `$`, Unicode, `;`, `:`, tên bắt đầu `-`... đều literal ở cả hai chiều.
  - Từ chối mọi ký tự điều khiển (NUL, newline, tab, DEL).
- **Symlink:** scp -r theo symlink ra ngoài cây (tải cả nội dung bên ngoài). **MVP: từ chối upload thư mục có symlink**, liệt kê các symlink tìm được (`LocalTreeInspector`); upload trực tiếp một symlink cũng bị từ chối. Download: server tự dereference, app không kiểm soát → ghi KNOWN_LIMITATIONS.
- **Huỷ khi `finalizing`:** không cho (bước local, ngắn) — nút Huỷ bị disable ở trạng thái này.
- **Recovery:** mọi job chưa kết thúc (kể cả queued) → `interrupted` khi khởi động; dọn `.part` của các job đó.
- **Upload `-r` vào thư mục đích đã tồn tại → lồng vào trong** (`dest/proj/...`), không gộp (kiểm chứng C2). UI: người dùng chọn thư mục remote cha, đích = `<remoteDir>/<tên>` (cho sửa tên), hiển thị đường dẫn cuối và cảnh báo "đã tồn tại thì lồng bên trong" (C3+C4).
- Download không xung đột vẫn finalize bằng rename độc quyền (`RENAME_EXCL`), không overwrite ngầm.
- **Remote `~/...` được sftp-server expand** (extension expand-path, kiểm chứng C2 với `sftp-server -d`) → cho phép.
- **Controlling tty (sửa sau C2):** posix_spawn + SETSID + addopen KHÔNG cấp controlling tty trên macOS này (PM tái hiện: `/bin/stty -f /dev/tty` → Device not configured). ssh đọc password từ `/dev/tty` nên bắt buộc sửa tận gốc trong PTYProcess; không dùng trampoline `/bin/sh -c`.
  **Đã sửa (C2b):** SDK không có API public gán controlling tty cho posix_spawn → helper `sshdesk-ctty` (target riêng, nằm cạnh executable chính / trong `Contents/MacOS`): argv `[ttyPath, executable, args...]`, `ioctl(TIOCSCTTY)`, dup2, đóng fd thừa, `execv` (giữ pid → huỷ theo process group không đổi). PM kiểm chứng lại: `stty -f /dev/tty` qua PTYProcess exit 0.
- Local path luôn tuyệt đối (tránh `a:b` bị hiểu là remote). Remote spec dạng `alias:path` với alias do app sinh (an toàn); đường dẫn remote bắt đầu bằng `-` phải đi sau `--`.
- Progress meter của scp chỉ hiện khi stdout là tty → dùng PTY (cũng cần cho prompt xác thực). Không dùng `-B`/BatchMode vì cần prompt tương tác.
- **Ghi đè:** scp không có no-clobber. Download: app tự kiểm tra tồn tại ở local, tải về `.part` rồi rename theo lựa chọn ghi đè/đổi tên/bỏ qua. Upload: không kiểm tra nguyên tử được; UI nói rõ "có thể ghi đè file cùng tên trên server" và cho chọn tên đích duy nhất do người dùng đặt. Không hứa resume.
- Huỷ bằng signal tới process group của job. Concurrency mặc định 1.
- Giới hạn phát hiện: chưa thử `scp -O`, chưa thử qua server thật (xác thực, MFA, host key) — ghi vào KNOWN_LIMITATIONS.

## ADR-009: `@Local` thay `@State` trong UI — Đã chốt
- **Bối cảnh:** SDK macOS 27 khai báo `@State` là macro (`SwiftUIMacros.StateMacro`); Command Line Tools không có plugin này → lỗi build (PM đã tái hiện bằng `swiftc -typecheck`).
- **Quyết định:** dùng property wrapper `@Local` bọc `State<T>` (`Sources/SSHDesk/LocalState.swift`).
- **Hệ quả:** nếu sau này cài Xcode.app có thể quay về `@State`; không cần đổi gì khác.

## ADR-010: Đăng nhập tự động — Đã chốt (người dùng chọn 2026-10-21), làm sau Bước C
- **Ưu tiên SSH key/agent.** Thêm nút "Cài key lên server": chạy `/usr/bin/ssh-copy-id -F <config app> -i <pubkey> <alias>` qua PTY runner; password nhập một lần qua prompt UI, không lưu.
- **Tuỳ chọn lưu password trong Keychain** (người dùng bật từng host). Không tự viết mã hoá — Keychain là kho mã hoá.
- Đưa password cho ssh trong Warp bằng **`SSH_ASKPASS`**: lệnh trong Tab Config dạng
  `SSH_ASKPASS=<helper trong app bundle> SSH_ASKPASS_REQUIRE=force SSHDESK_HOST_REF=<credentialReference> /usr/bin/ssh -F ... <alias>`.
  Env chỉ chứa **tham chiếu**, không chứa password. Helper `sshdesk-askpass` (executable trong bundle) đọc Keychain theo tham chiếu, in password ra stdout cho ssh.
- Với `SSH_ASKPASS_REQUIRE=force`, ssh gửi MỌI prompt qua helper (kể cả host key yes/no, MFA). Vì vậy helper:
  - prompt password của đúng host → trả password Keychain **chỉ 1 lần mỗi tiến trình ssh** (sai thì không lặp lại);
  - mọi prompt khác (host key, MFA/OTP, passphrase, password lần 2) → helper tự hỏi người dùng trên `/dev/tty` của Warp (tắt echo với câu hỏi bí mật), in câu trả lời ra stdout cho ssh.
  - Không có password lưu → helper cũng chỉ hỏi qua `/dev/tty` (hành vi như ssh thường).
- Bắt đầu làm ngay (người dùng yêu cầu 2026-10-21), trước phần còn lại của Bước E.
- **Rủi ro chấp nhận:** process khác chạy dưới cùng user có thể gọi helper. Giảm thiểu: helper kiểm tra process cha là `/usr/bin/ssh` (proc_pidpath), Keychain item có ACL giới hạn ứng dụng. Ghi vào KNOWN_LIMITATIONS.
- Worker truyền file dùng cùng credential qua prompt PTY (không qua askpass), chỉ điền khi prompt là password của đúng host.
- **Đã làm (E2):** helper `sshdesk-askpass` + target thuần `AskpassKit` (logic phân loại dùng chung, có bảng test); lệnh Warp thêm `-o BatchMode=no`; marker "đã dùng" theo ppid + thời điểm khởi động cha (O_EXCL); Keychain item có SecAccess trusted apps (app + helper).
- **Host có bastion (jumpHostID) → KHÔNG dùng askpass** (lệnh thường + thông báo): ssh con của ProxyJump thừa kế env và cũng có cha `/usr/bin/ssh`, có thể trả password đích cho bastion. **Rủi ro còn lại:** host imported mà `~/.ssh/config` có ProxyJump — app không biết → ghi KNOWN_LIMITATIONS.
- **Quy tắc tự điền password qua PTY (truyền file, master của tab duyệt file) — PM chốt sau review E2:** không tự điền nếu host có jumpHostID; host managed chỉ tự điền khi prompt khớp đúng `<user>@<hostName>'s password:` (không phân biệt hoa thường phần host) — prompt của bastion sẽ không khớp; host imported: tự điền lần đầu (rủi ro ProxyJump trong config người dùng, ghi KNOWN_LIMITATIONS). Mỗi job/phiên chỉ tự điền 1 lần.
- Chưa kiểm chứng với ssh thật: prompt `password:` qua askpass, hộp thoại ACL Keychain khi chạy từ .app (ký ad-hoc có thể hỏi lại sau mỗi lần build).

- **ADR-010b (PM chốt 2026-10-22, người dùng báo Project Analyst không tự nhập password):** cả 5 host Ping-Identity đều có password lưu và không có bastion, nhưng vẫn phải nhập tay → server dùng keyboard-interactive (PAM). OpenSSH ≥ 8.4 hiển thị prompt này dạng `(<user>@<host>) Password:`. Mở rộng quy tắc tự điền (PTY lẫn askpass của Warp):
  - Host managed: điền khi prompt khớp `<user>@<hostName>'s password:` **hoặc** `(<user>@<hostName>) Password:` — phần trong ngoặc khớp đúng user và hostName (host không phân biệt hoa thường), phần sau ngoặc sau khi trim phải đúng `password:` (không phân biệt hoa thường). `(...) Verification code:`, `OTP`, `Password for ...`, `Password:` trơn → không điền.
  - Prompt kbd-int của bastion mang user@host của bastion → không khớp; host có jumpHostID vẫn không bao giờ điền.
  - Askpass (Warp): `AskpassDecision` phân loại `(u@h) Password:` là `.password` (vẫn 1 lần mỗi tiến trình ssh, cha phải là `/usr/bin/ssh`).
  - Vẫn chỉ điền 1 lần mỗi phiên/job.
  - **Đã làm (G4, PM duyệt):** `PasswordAutofillPolicy.matchesKeyboardInteractivePrompt` + test bảng; `PromptDetector`/`AskpassDecision` vốn đã phân loại đúng. Chưa kiểm chứng với server PAM thật.

## ADR-011: Local port forward (-L) — Đã chốt (người dùng chọn), làm sau Bước C
- Mỗi host có danh sách forward đã lưu: `localPort` → `remoteHost:remotePort` (mặc định remoteHost `localhost` phía server).
- Sinh vào Host block của app bằng `LocalForward` (bind `127.0.0.1` mặc định, không mở ra LAN), hoặc chạy phiên forward riêng `ssh -N -L ...` qua PTY runner khi người dùng bấm "Mở tunnel" (có trạng thái chạy/dừng, huỷ theo process group).
- Kiểm tra port local đang bận trước khi chạy; validate port 1–65535, không cho port < 1024.
- Không làm remote forward (-R) và không đụng firewall server.
- **Chi tiết chốt cho E3 (PM 2026-10-22, người dùng yêu cầu làm tiếp):**
  - **Chỉ dùng phiên tunnel riêng** `ssh -F <cfg> -N -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none -L 127.0.0.1:<lp>:<rh>:<rp> -- <alias>` qua PTYProcess; KHÔNG sinh `LocalForward` vào Host block (nếu sinh, mỗi lần Mở Warp cũng bind port → xung đột).
  - Lưu: bảng `port_forwards(id, host_id FK CASCADE, name, local_port, remote_host, remote_port, created_at)` (migration mới tiếp theo). `remote_host`: hostname/IPv4/IPv6 literal, cấm khoảng trắng, `:`(trừ IPv6 trong `[]`), ký tự điều khiển; mặc định `localhost`. Local port 1024–65535, không trùng giữa các forward của app.
  - Xác thực: tự điền theo `PasswordAutofillPolicy`; prompt khác qua `AuthPromptCard`. Host Windows không có forward.
  - Trạng thái: Dừng / Đang kết nối / Đang chạy / Lỗi (lý do từ stderr đã làm sạch, vd port bận). Trước khi chạy thử bind 127.0.0.1:<lp> để báo "port đang bận". Dừng = SIGTERM process group của đúng phiên đó. Thoát app → dừng mọi tunnel. Không tự chạy lại khi rớt (hiện Lỗi + nút Chạy lại).
  - UI: mục "Port forward" trong chi tiết host (danh sách, thêm/sửa/xoá, Mở/Dừng, copy `127.0.0.1:<lp>`); chỉ báo số tunnel đang chạy ở status bar.
  - **Đã làm (E3, PM duyệt):** migration **v6** `port_forwards` (local_port UNIQUE), `Sources/SSHDeskCore/Tunnel/`, test tích hợp tunnel thật tới sshd tạm. PM duyệt: "Đang chạy" = cổng local bị ssh giữ (thử bind, không SO_REUSEADDR); timeout kết nối 60 giây; sửa forward phải Dừng trước; host alias import được có forward. **Bổ sung argv:** `-o ServerAliveInterval=30 -o ServerAliveCountMax=3` (phát hiện tunnel chết ngầm; làm cùng D4).

## ADR-012: Logo + giao diện theo mockup — Đã chốt (người dùng yêu cầu 2026-10-21)
- Nguồn: `Resources/AppIcon-source.png` (logo), `Resources/Design/main-window-mockup.png` (mockup cửa sổ chính).
- Icon: sinh `AppIcon.icns` lúc build (`sips` + `iconutil`), `CFBundleIconFile`; logo cũng hiện ở thanh tiêu đề.
- Theo bố cục/phong cách mockup, nhưng: **giữ chữ tiếng Việt** (spec mục 2); **theo sáng/tối của hệ thống** (bản dark giống mockup); nút ⏸ của mockup → **Huỷ** (scp không tạm dừng được); bỏ "Workspace"; "SSH Keys" là "Sắp có" tới E1; môi trường dùng mã sẵn có DEV/UAT/STG/PROD/OTHER.

## ADR-013: Cửa sổ duyệt file kiểu Xftp — Đề xuất (chờ spike R1), người dùng yêu cầu 2026-10-21
- **Vị trí (chốt theo mockup `Resources/Design/file-transfer-mockup.png`, người dùng đồng ý cả hai cách):** màn "Truyền file" trong cửa sổ chính (mục sidebar), thay màn Truyền file + Lịch sử hiện tại; hàng đợi ở đáy với tab Đang chạy / Hoàn tất (+ "Xoá mục đã xong"). Chữ tiếng Việt, nút ⏸ → Huỷ như ADR-012.
- Khung trái = filesystem Mac (back/forward/lên, ô đường dẫn, tìm, làm mới, thư mục mới), khung phải = tab cho từng server (chấm trạng thái kết nối, nút + mở tab, dòng user@host + badge môi trường + "Đã kết nối SFTP", cột Quyền); kéo thả giữa hai khung → tạo job trong TransferManager sẵn có (hàng đợi, huỷ, thử lại, ghi đè như ADR-008).
- Thao tác remote: duyệt, tạo thư mục, đổi tên, xoá. Quyền theo user SSH đó — **không sudo**; lỗi quyền từ server hiển thị nguyên trạng. Xoá luôn hỏi xác nhận (PROD nhấn mạnh). Không có xoá đệ quy ngầm: xoá thư mục không rỗng phải liệt kê và xác nhận.
- **Kỹ thuật — Đã chốt sau R1 (OpenSSH 10.3 + sshd tạm 127.0.0.1, key auth; CHƯA thử server Linux thật):**
  - Mỗi tab = một master: `ssh -F <cfg> -M -N -o ControlPath=<dir>/<hostID 32 hex> -o ControlPersist=no <alias>` (không dùng `%C`: app biết chính xác file socket mà không phải chạy `ssh -G`, vốn có thể kích hoạt `Match exec` trong config người dùng) chạy qua PTYProcess (xác thực qua prompt UI / password Keychain như E2).
  - **Thư mục socket `/tmp/sshdesk-<uid>`** (0700; trước khi dùng `lstat`: không phải symlink, owner == uid, mode 0700, sai → lỗi). Không dùng `$TMPDIR`/Application Support: ControlPath tối đa đo được 86 byte (sun_path 104 + tên tạm).
  - Trước khi start: `ssh -O check`; master chết mà file socket còn → xoá socket cũ rồi mới start (nếu không ssh tắt multiplexing). Đóng tab: `ssh -O exit` rồi kiểm PID master, còn sống thì SIGTERM đúng PID đó.
  - sftp và scp con dùng lại master qua `-o ControlPath=...` (đã chứng minh: đổi tên key sau khi master mở vẫn chạy). Nếu master chết, con **âm thầm xác thực lại** → khi lệnh con lỗi phải `-O check` để phân biệt.
  - Liệt kê: `sftp -F <cfg> -o ControlPath=... -b - <alias>` với stdin `cd "<dir>"` + `ls -la` (tên trần). Cột: quyền | nlink (`?`) | owner | group | size | ngày (`Oct 21 13:40` hoặc `Jan 15  2020`) | tên (phần còn lại). Bỏ `.`/`..`. Symlink: type `l`, không thấy đích. ~12–14 ms/lần qua master.
  - Quote trong batch: bọc `"..."`, `\`→`\\`, `"`→`\"`. Từ chối mọi tên/đường dẫn có ký tự điều khiển (tên có newline làm vỡ output → hiển thị "tên không hỗ trợ", không thao tác).
  - `-b` dừng ở lỗi đầu tiên (exit 1). Exit 255 = lỗi kết nối/xác thực.
  - mkdir/rename/rm/rmdir qua sftp batch. **rename đè im lặng** (posix-rename) → app liệt kê kiểm tra trước, đích tồn tại thì hỏi (có race, ghi KNOWN_LIMITATIONS). `rm` chỉ cho file, `rmdir` chỉ thư mục rỗng (`Failure` khi không rỗng). **Xoá đệ quy do app tự làm**: liệt kê cây, hiển thị danh sách + tổng số mục để xác nhận, xoá file rồi rmdir từ dưới lên; không đi theo symlink (xoá chính link).
  - Không dùng `ssh host -- stat/find` (phụ thuộc shell/coreutils server).
- **Đã làm (F1, PM duyệt):** `SocketDirectory`, `RemoteSession`, `RemoteFileService`, `SftpBatch`, `SftpListingParser`, `LocalFileService` trong `Sources/SSHDeskCore/Remote/`, test tích hợp với sshd tạm. Một tab/host (socket theo hostID; `-O check` sống → `socketInUse`). Lệnh sftp con: `-q -o BatchMode=yes -o PreferredAuthentications=none -o ConnectTimeout=10 -b - -- alias` + `checkAlive()` trước mỗi lệnh (BatchMode một mình chưa đủ: sftp tự xác thực lại bằng key). Đường dẫn remote phải bắt đầu `/` hoặc `~`.
- Upload trong màn duyệt file: dùng listing hiện tại để kiểm tra tên trùng trước (không nguyên tử) → hỏi Ghi đè/Bỏ qua.
- **Đã làm (F2, PM duyệt):** màn Truyền file theo mockup (thay màn Truyền file + Lịch sử cũ); logic thuần trong `Sources/SSHDeskCore/Browser/`; scp dùng master của tab qua `-o ControlPath` (không lưu DB; master chết → chạy trực tiếp); `PasswordAutofillPolicy` dùng chung.
- **Upload thư mục trong màn duyệt file: đích = thư mục cha** (`scp -r src host:<remoteDir>`) → thư mục trùng tên được **gộp** (file trùng bị ghi đè, file khác giữ nguyên; kiểm chứng F2). Hộp thoại xung đột ghi rõ "gộp". (Sheet Tải lên cũ ở màn Máy chủ vẫn dùng đích `<dir>/<tên>` → lồng khi trùng, như ADR-008.)
- Prompt `Password:` trơn (PAM/keyboard-interactive) không khớp mẫu `<user>@<host>'s password:` → không tự điền, người dùng nhập tay. **(Thay bằng ADR-010b.)**
- Đóng tab khi còn job của host đó → hỏi xác nhận. Kéo thả dùng UTType riêng khai báo trong Info.plist (chỉ chạy trong .app, không đảm bảo với `swift run`).

## ADR-014: Màn SSH Keys (E1) — Đã chốt
- Liệt kê key trong `~/.ssh`: chỉ đọc file `*.pub` (tên, loại, comment, fingerprint qua `ssh-keygen -l -f <pub>`); KHÔNG bao giờ đọc nội dung private key. Private key được nhận diện bằng việc tồn tại file cùng tên không có `.pub`.
- Tạo key mới: `/usr/bin/ssh-keygen -t ed25519 -f <đường dẫn mới> -C <comment>` qua PTY runner; passphrase nhập trong prompt của ssh-keygen (UI SecureField, không lưu); không bao giờ ghi đè file đã tồn tại.
- Cài key lên server: `/usr/bin/ssh-copy-id -F <config app> -i <pub> <alias>` qua PTY runner + prompt UI (password tự điền theo PasswordAutofillPolicy nếu đã lưu). Sau khi thành công, đề nghị đổi host sang xác thực bằng key đó (người dùng xác nhận).
- `ssh-copy-id` là script shell của OpenSSH: được chạy như executable (argv), không qua `sh -c`. Bản trên máy hỗ trợ `-F`, `-i`, `-t`, `-f`, `-o`.
- **Đã làm (E1, PM duyệt):** `Sources/SSHDeskCore/Keys/` (Inventory, Naming, KeyTaskSession, Generator, Installer), màn SSH Keys, "Cài key…" trong menu host.
- **`-f` (force) khi host managed đang dùng keyFile:** bước lọc của ssh-copy-id đăng nhập được bằng key cũ và báo nhầm "already exist" → bật `-f`. Hệ quả: key đã có sẵn có thể bị thêm dòng trùng trong authorized_keys (vô hại).
- `-t <path>` chỉ dùng trong test (sshd tạm ở localhost dùng chung home thật). UI không dùng.
- Symlink `.pub` không được copy/cài; cặp thiếu private vẫn cài được nhưng không đề nghị đổi host sang key.
- PromptDetector nhận thêm prompt passphrase của `ssh-keygen` (`Enter passphrase (empty for no passphrase):`, `Enter same passphrase again:`).

## ADR-015: Phản hồi UI của người dùng (2026-10-21) — Đã chốt
- **Xác thực gộp một chỗ:** Picker "Xác thực" có 4 lựa chọn: ssh-agent/mặc định · File khoá riêng · **Mật khẩu (lưu trong Keychain)** · Nhập khi kết nối. Chọn "Mật khẩu" → SecureField hiện ngay dưới. Không còn mục "Mật khẩu" riêng. Lưu trữ không đổi schema: "Mật khẩu" = `authMethod .interactive` + `credentialReference` có item Keychain (ánh xạ trong `HostDraft`).
- **Thư mục server:** dùng lại trường `project`, UI gọi là **"Thư mục"** (một cấp). Sidebar mục "THƯ MỤC" (thay "DỰ ÁN"), bảng máy chủ nhóm theo thư mục (thu gọn được), kéo host vào thư mục ở sidebar để chuyển, nút tạo thư mục.
- **Đã làm (PM duyệt):** migration v3 `host_folders(name)` giữ thư mục rỗng (thư mục chỉ mất khi xoá bằng menu); tên so khớp không phân biệt hoa thường/dấu, dùng cách viết có sẵn; xoá thư mục không xoá host (về "Chưa phân loại"); đổi tên trùng → hỏi gộp; bảng chỉ nhóm ở "Tất cả máy chủ" khi không lọc/tìm; kéo 1 host mỗi lần.
- **Click 1 lần = chọn + hiện chi tiết; double-click / Return = Mở Warp.** Không được để cử chỉ double-click làm mất single-click.

## ADR-016: Project Analyst — bản đồ kết nối giữa các server — Đã chốt (người dùng 2026-10-21)
- Nguồn: `Resources/Design/project-analyst-mockup.png`. **Project = thư mục server** (ADR-015). Chữ tiếng Việt, theo Theme.
- **Chỉ lệnh xem, whitelist cố định**, chạy qua SSH dùng master của RemoteSession (`ssh -F <cfg> -o ControlPath=<sock> -o BatchMode=yes -o PreferredAuthentications=none -- <alias> <lệnh>`):
  - thu thập: `ss -Htanp` (fallback `ss -Htan`), `ip -o addr show` (fallback `hostname -I`), `hostname`.
  - thử kết nối: `timeout 3 bash -c '</dev/tcp/<ip>/<port>'` (fallback `nc -z -w3 <ip> <port>`) chạy trên server **nguồn**; `<ip>` và `<port>` phải qua validate chặt (IPv4/IPv6 literal, 1–65535) trước khi ghép — không ghép chuỗi nào khác từ người dùng/server.
  - Không `sudo`, không cài/sửa gì. Dùng đúng quyền user SSH đó (root thấy được tên process; user thường có thể không thấy → hiển thị "không rõ").
  - Đây là ngoại lệ có chủ đích với ghi chú "không dùng `ssh host -- ...`" của ADR-013 (vốn dành cho duyệt file).
- **Tự phát hiện hoàn toàn:** ánh xạ IP → server trong project (từ `ip addr` + HostName); cạnh A → B:port khi A có kết nối ESTAB tới IP của B tại port mà B đang LISTEN. Kết nối tới IP ngoài project: không vẽ nút, chỉ đếm trong panel chi tiết. Giới hạn: chỉ thấy kết nối đang mở lúc quét.
- **Chạy kiểm tra:** với mỗi cạnh, probe TCP từ nguồn (timeout 3 s) + kiểm tra đích đang LISTEN. Kết quả: Passed / Failed (timeout, refused) / Không kiểm tra được (thiếu công cụ, mất phiên). Nguyên nhân chỉ ghi "chưa xác nhận" + bằng chứng, không suy đoán.
- **Linux only.** Server không có `ss`/`bash`/`timeout` → báo rõ.
- **PROD:** project có server PROD → hộp xác nhận liệt kê đúng các lệnh sẽ chạy trên từng server, mỗi lần.
- Lưu lịch sử các lần chạy (DB migration mới, sau migration thư mục), xuất báo cáo (Markdown/CSV). Không lưu output thô có thể chứa thông tin nhạy cảm ngoài các trường đã parse.
- **Đã làm (G1, PM duyệt):** `Sources/SSHDeskCore/Analyst/`. Quyết định:
  - Lệnh remote thêm `-o ControlMaster=no` (master chết thì không tự dựng master mới).
  - IPv6: chỉ probe qua `nc -6` (chưa chắc bash `/dev/tcp` hỗ trợ IPv6).
  - `nc` exit 1 không có thông điệp → "không phân biệt được timeout hay bị từ chối" (không đoán `refused`).
  - Topology: bỏ ESTAB có cổng local = cổng LISTEN của chính server (kết nối đến); đích không thu thập được vẫn tạo cạnh với `destinationVerified=false`; đích đã thu thập mà không LISTEN khớp → không tạo cạnh; chỉ HostName là IP literal mới dùng để ánh xạ.
  - Báo cáo CSV theo RFC 4180, chặn CSV injection (`= + - @` → thêm `'`); không xuất stderr thô.
  - **Đã kiểm chứng trên Linux thật (người dùng, 2026-10-22, project Ping-Identity 3 server):** phát hiện đúng 3 luồng (Ping-AM→Ping-DS:1636, Ping-IDM→Ping-DS:1389/:1636), probe TCP thông 131–142 ms.
- **Schema lịch sử (G2, migration v4):** `analyst_runs(id, folder_name, started_at, finished_at, status, warnings_json)`, `analyst_servers(run_id FK CASCADE, host_id, display_name, collected, addresses_json, listening_json, external_connections)`, `analyst_flows(run_id FK CASCADE, source_host_id, dest_host_id, port, observed_connections, dest_ips_json, source_processes_json, outcome, outcome_detail (chuỗi chuẩn hoá), latency_ms, dest_check, dest_bind, evidence_json)`. Không FK cứng tới `hosts` (lịch sử đọc được khi xoá server); không lưu stdout/stderr thô.
- **Đã làm (G2, PM duyệt):** migration v4 (+ cột `seq` giữ thứ tự), `AnalystRunRepository` (giữ 50 lần/thư mục), `AnalystCoordinator` (mở phiên → thu thập song song ≤4 → thử → lưu; huỷ không lưu), `GraphLayout` (theo lớp, barycenter), UI theo mockup.
  - **`SessionPool` dùng chung** giữa màn Truyền file và Project Analyst: một master/host. Analyst dùng lại phiên của tab nếu có; phiên Analyst tự mở được đóng sau khi chạy xong (trong lúc đó tab Truyền file cùng host báo "đang dùng").
  - PROJECTS ở sidebar chỉ hiện trong màn Project Analyst (project = thư mục). Bỏ "Edit flows"/DEMO; không có trường vai trò (FE/BE) nên badge = môi trường.
  - Hộp xác nhận PROD liệt kê lệnh thu thập + mẫu lệnh probe (IP đích chỉ biết sau khi thu thập).
  - "Thử lại kết nối" cập nhật chính bản lưu của lần chạy đang xem; lần chạy cũ chỉ đọc. Đổi tên thư mục không đổi tên trong lịch sử cũ.

## ADR-017: Máy Windows mở bằng Windows App (RDP) — Đã chốt (chờ người dùng thử thật), người dùng yêu cầu 2026-10-22
- Windows App trên máy: `/Applications/Windows App.app`, `com.microsoft.rdc.macos` 11.4.0, nhận file `.rdp`/`.rdpw`, URL scheme `rdp`, `ms-rd`.
- **Phạm vi:** máy Windows chỉ khai báo thông tin + **Mở Windows App**. Không truyền file (Windows App tự có kéo thả), không Project Analyst, không SSH Keys, không Mở Warp. Thường kết nối trực tiếp host:3389; RD Gateway là tuỳ chọn ở phần Nâng cao.
- **Mô hình dữ liệu:** thêm loại máy (`ssh` / `windowsRDP`) vào HostProfile (migration mới). RDP: host, port 3389, user (`DOMAIN\user` hoặc `user@domain`), gateway tuỳ chọn, tuỳ chọn hiển thị/chuyển hướng tối thiểu. Dùng chung thư mục, môi trường, yêu thích, nhân bản.
- **Mở kết nối:** app sinh `.rdp` trong `~/Library/Application Support/SSHDesk/rdp/<uuid>.rdp` (0600, ghi atomically), mở bằng `NSWorkspace.open([file], withApplicationAt: Windows App)`. Mọi giá trị cấm newline/ký tự điều khiển (chặn chèn thuộc tính).
- **Password:** `.rdp` trên Mac không mang được password → người dùng nhập/nhớ trong Windows App. SSH Desk không đưa password qua clipboard/URL/file. Không có kênh chính thức nào để đưa password (CLI bookmark của Windows App không có `--password`).
- **Kết quả researcher (chỉ đọc bundle + tài liệu):** Windows App là app sandbox; có chuỗi các thuộc tính `full address`, `gatewayhostname`, `gatewayusagemethod`, `enablecredsspsupport`, `redirectclipboard`, `audiomode`, `dynamic resolution`, `screen mode id`, `use multimon`, `administrative session`; KHÔNG thấy `username:s:` / `password 51`. Tài liệu Microsoft không có cột macOS; URI scheme không có tài liệu cho bản Mac.
- **Chốt:** dùng file `.rdp` UTF-8 (không dùng URI). Thuộc tính MVP: `full address`, `username` (có cờ tắt nếu bản Mac bỏ qua), `screen mode id`, `use multimon`, `dynamic resolution`, `redirectclipboard`, `audiomode`, `enablecredsspsupport:i:1`, `administrative session` (tuỳ chọn), `gatewayhostname` + `gatewayusagemethod` chỉ khi có gateway. Mở bằng `NSWorkspace.urlForApplication(withBundleIdentifier: "com.microsoft.rdc.macos")`. File giữ lại trong thư mục app (ghi đè mỗi lần mở) vì Windows App có thể đọc bất đồng bộ.
- **Người dùng thử thật (2026-10-22, Windows App 11.4.0):** file `.rdp` UTF-8, xuống dòng CRLF, gồm `full address`, `username`, `screen mode id:i:1`, `enablecredsspsupport:i:1` → Windows App mở cửa sổ "sshdesk-test - 172.16.50.85" và đăng nhập vào máy Windows thành công (tên cửa sổ lấy theo tên file).
- `username:s:` **được Windows App điền sẵn** (người dùng xác nhận) → giữ dòng này.
- **Đã làm (H1, PM duyệt):** migration v5 (`kind` + cột `rdp*`), `Windows/RDPFileRenderer`, `Windows/WindowsAppLauncher`. File: `rdp/<uuid>/<tên đã làm sạch>.rdp` (tiêu đề cửa sổ Windows App = tên file). `username` và `domain` ghi riêng, không ghép. Host Windows không làm bastion, không có Keychain, bị loại khỏi Truyền file / SSH Keys / Project Analyst.
- Chưa kiểm chứng: Windows App có nhớ password cho file mở ngoài không, SSH tunnel (lệch tên chứng chỉ).

## ADR-018: Mật khẩu máy Windows — copy tự động khi mở — Đã chốt (người dùng chọn 2026-10-22)
- **Bối cảnh:** Windows App không có kênh nhận password từ app khác (`.rdp` trên Mac không mang password; `--script bookmark write` không có `--username/--password`; credential nằm trong Keychain sandbox riêng của nó). Người dùng cho biết Windows App không nhớ password cho kết nối mở từ file.
- **Quyết định (ngoại lệ có chủ đích với spec mục 8/11 "không đưa password qua clipboard"):** host Windows có lựa chọn "Mật khẩu (lưu trong Keychain)". Khi bấm Mở Windows App: mở kết nối như ADR-017 rồi đặt password lên clipboard để người dùng ⌘V vào ô đăng nhập.
- **Giảm rủi ro:**
  - Clipboard item đánh dấu `org.nspasteboard.ConcealedType` + `org.nspasteboard.TransientType` (trình quản lý clipboard tuân chuẩn sẽ không lưu lịch sử).
  - Tự xoá sau 30 giây **chỉ khi clipboard vẫn là giá trị app đặt** (so `changeCount`); thoát app trước hạn → xoá ngay.
  - Không bao giờ copy cho host SSH; không ghi password vào `.rdp`, log, DB.
  - Thông báo rõ: "Đã copy mật khẩu — dán (⌘V) vào Windows App. Tự xoá sau 30 giây."
- **Rủi ro chấp nhận (ghi KNOWN_LIMITATIONS):** trong 30 giây app khác trên Mac đọc được clipboard; nếu bật chia sẻ clipboard của RDP, password có thể đồng bộ vào clipboard của máy Windows sau khi kết nối.
- Không tự gõ bằng Accessibility (vẫn cấm).

## ADR-019: Monitor tài nguyên server — Đã chốt (người dùng yêu cầu 2026-10-22)
- **Vị trí:** mục "Monitor" trong WORKSPACE ở sidebar, dưới Project Analyst. Dùng chung danh sách PROJECTS (thư mục) như Analyst: chọn thư mục → lưới thẻ, mỗi thẻ là một host SSH của thư mục (bỏ qua máy Windows). Chỉ hỗ trợ Linux; host khác hoặc thiếu `/proc` → thẻ báo "Không hỗ trợ".
- **Chỉ số mỗi thẻ:** CPU % (cả máy), load 1/5/15 + số nhân, RAM dùng/tổng (MemTotal − MemAvailable), swap, đĩa (mỗi mount thật: bỏ tmpfs/devtmpfs/overlay/squashfs, tối đa 4, ưu tiên `/`), uptime, thời điểm cập nhật. Ngưỡng màu: ≥ 80% vàng, ≥ 90% đỏ. Sparkline CPU/RAM 60 mẫu gần nhất (chỉ trong bộ nhớ, không lưu DB).
- **Lệnh (whitelist cố định, chỉ-xem, không sudo, không input người dùng):** `cat /proc/stat /proc/meminfo /proc/loadavg /proc/uptime` (một lệnh), `nproc`, `df -P -k`. CPU % tính từ hiệu hai lần đọc `/proc/stat` liên tiếp (lần đầu hiện "—"). Thêm vào `AnalystCommand` hoặc enum lệnh riêng cùng cơ chế `RemoteCommandRunner` (ControlMaster=no, BatchMode=yes, timeout, cắt stdout).
- **Kết nối:** `SessionPool` + `SessionConnector` (owner mới `.monitor`), tự điền password theo ADR-010b. Dùng lại phiên đang mở của Truyền file/Analyst. Phiên Monitor tự mở được đóng khi rời màn Monitor, đổi thư mục hoặc bấm Dừng.
- **Làm mới:** mỗi 5 giây (chọn 5/10/30 giây), chỉ khi màn Monitor đang hiện; có nút Dừng/Tiếp tục. Mỗi host chạy độc lập, tối đa 4 host song song; một host lỗi không chặn host khác. Không chồng vòng: vòng trước chưa xong thì bỏ lượt.
- **PROD:** hỏi xác nhận một lần khi bắt đầu theo dõi thư mục có host PROD (liệt kê lệnh), có hiệu lực tới khi Dừng/rời màn/đổi thư mục.
- **Ngoài phạm vi v1:** top tiến trình, lịch sử dài hạn, cảnh báo/thông báo, mạng/IO.
- **Đã làm (I1+I2, PM duyệt):** `Sources/SSHDeskCore/Monitor/` (MonitorCommand whitelist 3 lệnh, parser, MonitorMath/History/Level, MonitorCoordinator + owner `.monitor`), màn Monitor. PM duyệt các lựa chọn của coder: host **kết nối thất bại/không hỗ trợ không tự thử lại** mỗi chu kỳ (tránh khoá tài khoản khi sai password) — người dùng bấm "Thử lại"; lỗi lệnh (timeout, mất phiên) thử lại vòng sau. Huỷ prompt xác thực = dừng Monitor. df bỏ trùng theo filesystem; thiếu `nproc` → đếm `cpuN`; thiếu `MemAvailable` → `MemFree+Buffers+Cached`. Đổi thư mục/Tiếp tục hỏi lại PROD.
- Chưa kiểm chứng: chạy thật với server Linux, giao diện.

## ADR-020: Xuất / nhập danh sách máy chủ (D1) — Đã chốt (người dùng yêu cầu làm 2026-10-22)
- File JSON `*.sshdesk.json`: `{format: "sshdesk-hosts", version: 1, exportedAt, folders: [...], hosts: [...]}`. Host mang mọi metadata (tên, thư mục, môi trường, tag, ghi chú, yêu thích, loại máy, host/port/user, auth method, identity file path, jump host theo **id trong file**, bookmark, thư mục mặc định, tuỳ chọn RDP, port forward). **Không bao giờ** có password, credentialReference, lịch sử truyền/Analyst. Imported alias (`~/.ssh/config`) xuất kèm alias + path.
- Xuất qua NSSavePanel, ghi atomically, quyền 0600. Có lựa chọn "chỉ thư mục đang chọn" hoặc tất cả.
- Nhập qua NSOpenPanel: parse + validate bằng đúng validator của form (cấm newline/ký tự điều khiển, port…), file > 5 MB hoặc version lạ → từ chối. Màn xem trước: số host mới / trùng (cùng host+port+user+loại) / lỗi. Trùng: chọn Bỏ qua (mặc định) hoặc Nhập thành bản sao. Luôn sinh UUID mới; ánh xạ lại jump host; jump host thiếu → bỏ trống + cảnh báo. Host dùng password → giữ auth method, ghi chú "cần nhập lại mật khẩu".
- Nhập trong một transaction SQLite; lỗi → không ghi gì. Sau nhập: sinh lại SSH config của app.

## ADR-021: Màn Cài đặt (D4) — Đã chốt (người dùng đồng ý danh sách PM đề xuất 2026-10-22)
- Mở bằng mục "Cài đặt" ở sidebar và ⌘, (Settings scene). Lưu bảng `settings(key TEXT PRIMARY KEY, value TEXT)` (migration mới); đọc qua `AppSettings` (Core, có giá trị mặc định + kẹp phạm vi; key lạ/giá trị hỏng → mặc định, không crash).
- Nhóm và mặc định:
  - **Chung:** thư mục local mặc định (mặc định ~/Downloads); khi đóng cửa sổ chính: Thoát app (mặc định) / Giữ chạy nền.
  - **Warp:** mở Tab mới (mặc định) / Cửa sổ mới.
  - **Truyền file:** số tác vụ đồng thời 1–4 (mặc định 1); giữ lịch sử 100/500/1000/không giới hạn (mặc định 500).
  - **SSH config:** đường dẫn config người dùng được Include (mặc định `~/.ssh/config`, phải là đường dẫn tuyệt đối, tồn tại, không có ký tự điều khiển; đổi → sinh lại config app); đường dẫn config app (chỉ xem) + nút Mở thư mục trong Finder.
  - **Bảo mật:** tự điền mật khẩu đã lưu (bật mặc định; tắt → PTY, askpass và Windows clipboard đều không dùng password lưu, askpass hỏi qua tty); thời gian tự xoá clipboard password Windows 10/30/60/90 giây (mặc định 30); "Xoá mọi mật khẩu đã lưu" (liệt kê số mục, xác nhận, xoá item Keychain service `local.sshdesk.credentials` theo tham chiếu của host, gỡ tham chiếu khỏi host).
  - **Project Analyst:** số lần chạy giữ mỗi thư mục 10–200 (mặc định 50); timeout thử kết nối 1–10 giây (mặc định 3, chèn vào lệnh probe dưới dạng số nguyên đã kẹp).
  - **Monitor:** chu kỳ mặc định 5/10/30 giây; ngưỡng vàng 50–95 (mặc định 80), đỏ > vàng, ≤ 99 (mặc định 90).
  - **Windows App:** mặc định cho máy mới: toàn màn hình, nhiều màn hình, chia sẻ clipboard (chỉ áp dụng khi tạo máy mới).
  - **Dữ liệu:** Xuất / Nhập (ADR-020), mở thư mục dữ liệu, phiên bản app + schema, đường dẫn SQLite.
- Không có: tắt kiểm tra host key, lưu password ra file, chọn sáng/tối (theo hệ thống).
- **Đã làm (D4, PM duyệt + QA đạt):** migration **v7** `settings`, `Settings/AppSettings.swift`, `SettingsRepository` + `SettingsStore` (đọc mỗi lần dùng), `AutofillGatedCredentialStore` bọc Keychain cho mọi đường tự điền (QA lần theo từng chỗ gọi). Tắt tự điền áp dụng cho kết nối mở sau đó; tab Warp đang mở giữ askpass tới khi đóng. Ô đường dẫn Include lưu khi Return hoặc rời ô.

## ADR-022: Vòng đời app & hoàn thiện UI (D2) — Đã chốt
- Thoát app (⌘Q, đóng cửa sổ khi cài đặt là Thoát) khi còn job truyền đang chạy/tunnel/Monitor/Analyst đang chạy → hộp xác nhận liệt kê từng loại. Đồng ý: huỷ job (đánh dấu Bị gián đoạn), dừng tunnel, đóng mọi master (`-O exit`), xoá clipboard password (ADR-018) rồi thoát.
- Empty state cho mọi màn còn thiếu (danh sách rỗng, tìm không thấy, thư mục rỗng, chưa có key, chưa có lịch sử).
- Phím tắt: ⌘N máy chủ mới, ⌘F tìm, ⌘D nhân bản, ⌘Return mở (Warp/Windows App), ⌘E sửa, ⌫ xoá (có xác nhận), ⌘, Cài đặt, ⌘1…⌘6 chuyển mục sidebar. Liệt kê trong menu để thấy được.
- Đồng bộ Theme cho form hồ sơ, màn import, AuthPromptCard, màn lỗi DB (phần còn lại của UI1).
- **Đã làm (D2, PM duyệt + QA đạt):** `App/QuitActivity.swift` (thêm loại thứ 5: tác vụ SSH Keys). Khi thoát: job **đang chạy → Đã huỷ**, job **đang chờ → Bị gián đoạn** (PM duyệt lệch so với câu chữ ban đầu). Xoá host là ⌘⌫ ở menu + ⌫ trần khi bảng có focus; mỗi phím tắt chỉ một nguồn (menu). "Giữ chạy nền": đóng cửa sổ thì Monitor dừng, job/tunnel vẫn chạy. Thoát bằng SIGTERM/crash không dọn được master (KNOWN_LIMITATIONS).


---
# Hướng mở rộng chiến lược (người dùng chọn 2026-10-22, xem `docs/ideas.md` mục "Hướng mở rộng")
Thứ tự làm (cập nhật sau khi thêm ADR-029/030): ADR-023 → 024 → 025 → 030 (bộ đăng nhập) → 026 phần khung + Excel/CSV → 029 → 026 phần JSON/Ansible → 027 → 028. Migration: v8 (ADR-024), v9 (ADR-030), v10 (ADR-026), v11 (ADR-028). Nếu thứ tự làm đổi thì số migration theo thứ tự thực tế.

## ADR-023: Ký app bằng chứng chỉ ổn định (H-9a) — Đã chốt
- **Bối cảnh:** ký ad-hoc làm cdhash đổi sau mỗi lần build. ACL Keychain (SecAccess trusted apps, ADR-010) gắn với designated requirement nên mỗi lần `make install` có thể bị hỏi quyền lại.
- **Quyết định:**
  - `scripts/build-app.sh` đọc tên identity từ biến môi trường `SSHDESK_SIGN_IDENTITY`. Makefile có biến `SIGN_IDENTITY ?=` và truyền xuống (`make install SIGN_IDENTITY="SSH Desk Local"` hoặc export biến môi trường).
  - Có identity: kiểm tra tồn tại bằng `security find-identity -p codesigning` (chỉ đọc), rồi ký từng helper trước (`sshdesk-ctty`, `sshdesk-askpass`, CLI ở ADR-025) rồi tới app: `codesign --force --sign "<identity>" --identifier <id cố định>`. Không dùng `--deep`. In ra `codesign -d -r-` để người dùng thấy DR. Không bật hardened runtime/timestamp (không cần cho bản cá nhân).
  - Không có identity, hoặc identity không tìm thấy: ký ad-hoc như cũ và in **cảnh báo** ra stderr (không làm build lỗi).
  - Tên identity: từ chối nếu có ký tự điều khiển/newline; luôn truyền như một argv đã quote, không `eval`.
  - Identifier cố định: app `local.sshdesk.app`, helper `local.sshdesk.ctty`, `local.sshdesk.askpass`, CLI `local.sshdesk.cli`.
- **App không tạo chứng chỉ, không sửa Keychain.** Người dùng tự tạo chứng chỉ "Code Signing" tự ký (Keychain Access → Certificate Assistant → Create a Certificate…, loại Code Signing). doc-writer ghi các bước vào README/TESTING.
- **Rủi ro chấp nhận:** item Keychain tạo khi app còn ký ad-hoc vẫn mang ACL cũ → lần đầu sau khi đổi sang chứng chỉ có thể hỏi quyền một lần (chọn "Luôn cho phép" hoặc lưu lại password). Chứng chỉ tự ký không được Gatekeeper công nhận; app build tại máy không bị quarantine nên không ảnh hưởng. Mất/xoá chứng chỉ → quay về ad-hoc.
- **Đã làm (K1, QA chặn → sửa → PM duyệt):** Makefile export `SSHDESK_SIGN_IDENTITY` qua môi trường (không nội suy vào dòng lệnh shell; tên chứa `$` thì đặt bằng biến môi trường); script từ chối ký tự điều khiển C0/C1; `security` lỗi → cảnh báo riêng rồi ad-hoc; trùng tên → cảnh báo, chấp nhận SHA-1 40 hex; codesign lỗi với identity → hướng dẫn + exit lỗi (không lặng lẽ hạ ad-hoc). Đổi identifier helper sang `local.sshdesk.*` → item Keychain cũ có thể hỏi quyền thêm một lần.
- **Kiểm chứng (người dùng thử):** build hai lần với cùng identity, so `codesign -d -r-` giống nhau; askpass đọc Keychain sau `make install` lần hai không hỏi lại.

## ADR-024: Agent ngoài qua `IdentityAgent` (H-2a) — Đã chốt
- **Model:** `HostProfile.identityAgent: String?` (cột `identity_agent TEXT NULL`, migration **v8**). `nil` = theo mặc định trong Cài đặt. Cài đặt có key `ssh.default_identity_agent` (rỗng = hệ thống, tức không ghi directive).
- **Lựa chọn trong form (chỉ host managed, loại SSH):** Theo mặc định / Hệ thống (`SSH_AUTH_SOCK`) / 1Password (`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`) / Bitwarden / Secretive / Tuỳ chỉnh (đường dẫn). Đường dẫn mẫu (researcher K5r): Bitwarden bản .dmg `~/.bitwarden-ssh-agent.sock` (https://bitwarden.com/help/ssh-agent/; bản App Store dùng `~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock` — không làm preset, dùng Tuỳ chỉnh); Secretive `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh` (**chưa có nguồn chính thức**, ghi rõ trong comment và KNOWN_LIMITATIONS). Chưa cài agent nào trên máy → chưa thử thật.
- **Sinh config:** `SSHConfigWriter` ghi `IdentityAgent "<giá trị>"` trong Host block của app (giá trị hiệu lực = host ?? mặc định). Giá trị `SSH_AUTH_SOCK` (chữ) ghi nguyên văn — dùng khi host muốn bỏ mặc định của Cài đặt. Host imported (`existingSSHConfigAlias`) và Windows: không áp dụng (app không sinh block cho họ), UI ẩn/disable.
- **Validate (Core, có test riêng):** không rỗng; tối đa 1024 byte; cấm `\n`, `\r`, NUL, mọi ký tự điều khiển (Unicode Cc) và DEL; phải bắt đầu bằng `/` hoặc `~/`, hoặc đúng chữ `SSH_AUTH_SOCK`; cấm `%` và `$` (ssh mở rộng token/biến môi trường trong IdentityAgent — chặn để giá trị là literal). Quote/escape bằng đúng hàm quote của writer. **Test chống chèn directive:** giá trị chứa newline + `ProxyCommand ...` bị từ chối; `"` và `\` được escape đúng (kiểm bằng `ssh -G` với config tạm như các test writer hiện có nếu có sẵn hạ tầng).
- Socket không tồn tại → chỉ cảnh báo trong form ("agent chưa chạy?"), không chặn lưu. Đường dẫn sau khi mở rộng `~` dài hơn 104 byte → cảnh báo.
- **Màn SSH Keys (tuỳ chọn trong task):** liệt kê public key của agent đã chọn bằng `/usr/bin/ssh-add -L` với `SSH_AUTH_SOCK=<đường dẫn đã mở rộng>` trong env của process con (đường dẫn socket, không phải secret). Chỉ đọc public key; **không bao giờ đọc private key**, không `ssh-add` thêm/xoá key.
- Ghi chú dùng: với agent ngoài nên để IdentityFile trống, hoặc trỏ tới file `.pub` của key trong agent (kèm `IdentitiesOnly yes`) — doc-writer ghi vào README.
- Analyst/Monitor/Truyền file/Warp đều dùng `-F` config app nên tự hưởng IdentityAgent. **Chưa kiểm chứng:** hộp duyệt Touch ID của agent khi BatchMode=yes (Analyst/Monitor) — có thể hết timeout nếu duyệt chậm.

## ADR-025: CLI `sshdesk` + URL scheme `sshdesk://` (H-6a) — Đã chốt
- **CLI:** executable SwiftPM tên **`sshdesk-cli`** (không đặt `sshdesk`: APFS không phân biệt hoa thường, trùng với `SSHDesk` trong `.build/release` và `Contents/MacOS`). `build-app.sh` copy vào `Contents/Helpers/sshdesk` và ký (ADR-023). Người dùng tự tạo symlink (vd `ln -s "/Applications/SSH Desk.app/Contents/Helpers/sshdesk" ~/bin/sshdesk`); app/Makefile không sửa PATH, không ghi `/usr/local`.
- Lệnh: `sshdesk list [--folder <tên>] [--json]`, `sshdesk open <id|alias|tên>`, `sshdesk help`. Không có lệnh nào nhận password, lệnh từ xa, hay tham số ssh tuỳ ý. Argv lạ → lỗi, exit 2.
- **DB chỉ đọc:** mở SQLite `SQLITE_OPEN_READONLY`, `busy_timeout` 2000 ms; schema_version khác bản CLI biết → báo lỗi, không đọc. CLI không ghi SSH config, Tab Config hay DB; không đọc Keychain.
- `list --json`: mảng `{id, name, alias, folder, environment, kind, hostName, port, user}`; không có credentialReference hay ghi chú.
- **Giải host (Core, có test):** khớp chính xác theo thứ tự: UUID → alias imported (`sshConfigAlias`) → tên hiển thị (không phân biệt hoa thường/dấu). Nhiều host khớp → lỗi liệt kê id, không chọn bừa. Không fuzzy. Chỉ host SSH (Windows → "chưa hỗ trợ" ở v1).
- **`open` đi qua app (không tự mở Warp):** CLI ghi file yêu cầu `~/Library/Application Support/SSHDesk/requests/<uuid>.json` (0600, thư mục 0700; nội dung chỉ `{hostID, createdAt}`) rồi mở `sshdesk://cli?request=<uuid>` bằng `NSWorkspace`. App đọc file, **xoá ngay**, bỏ nếu quá 30 giây hoặc không tồn tại. Lý do: trang web gọi được URL nhưng không tạo được file trong thư mục app → app phân biệt được yêu cầu từ CLI. Mở host như nút Mở Warp (cùng ConnectionService, cùng quy tắc askpass/tự điền).
  - CLI: host PROD → **hộp xác nhận trong app**; host khác mở ngay.
  - Request id lạ/hết hạn → coi như URL từ bên ngoài (xác nhận như dưới) nếu có host, hoặc bỏ qua.
- **URL scheme** `sshdesk://open?id=<uuid>` hoặc `sshdesk://open?name=<tên|alias>`: khai báo `CFBundleURLTypes` trong Info.plist. **Luôn hiện hộp xác nhận** (tên, môi trường, user@host) trước khi mở, kể cả host không PROD. Chỉ nhận đúng một tham số `id` hoặc `name`; tham số khác, giá trị > 256 ký tự, ký tự điều khiển → từ chối và báo. Không bao giờ nhận lệnh, secret, tham số ssh.
- Alfred/Raycast: chỉ viết hướng dẫn (Alfred Script Filter gọi `sshdesk list --json`). Không làm extension.
- **Rủi ro chấp nhận:** process cục bộ cùng user ghi được file request → bỏ qua xác nhận cho host không PROD; process đó vốn đã chạy được `ssh` trực tiếp nên không mở thêm quyền.

## ADR-026: Nguồn máy chủ đồng bộ một chiều (H-1) — Đã chốt
- **Nguồn đợt này, theo ưu tiên:** (1) **Excel `.xlsx` / CSV** (khách hàng thường gửi Excel — người dùng 2026-10-22), (2) file JSON `*.sshdesk.json` (ADR-020), (3) Ansible inventory tĩnh INI/YAML. **Để sau:** "lệnh xuất JSON", NetBox/Proxmox/AWS/Zabbix host.get.
- **DB (migration v9):** bảng `inventory_sources(id, name, kind ('excel'|'csv'|'json'|'ansible'), path, folder, default_environment, config_json, last_synced_at, last_fingerprint)`; cột host `source_id TEXT NULL`, `external_id TEXT NULL`, `source_missing INTEGER 0`, `autofill_hold INTEGER 0`, `autofill_hold_reason TEXT NULL` (chỉ chứa giá trị cũ → mới của HostName/Port/User/jump, không secret).
- **Đồng bộ một chiều, luôn qua màn xem trước:** thêm / đổi (từng trường cũ → mới) / không còn trong nguồn / lỗi. Người dùng bấm Áp dụng → một transaction; lỗi → không ghi gì; sau đó sinh lại SSH config. App phát hiện file nguồn đổi (mtime + fingerprint SHA-256) khi mở app và khi app được kích hoạt → hiện "Nguồn có thay đổi" + nút Xem trước; **không tự áp dụng**. Không bao giờ tự xoá host: host biến mất được đánh dấu `source_missing`.
- **Trường do nguồn quản lý:** tên, HostName, Port, User, môi trường (nếu nguồn có), thư mục (cột thư mục hoặc thư mục mặc định của nguồn), tag nguồn, jump host (chỉ JSON, ánh xạ trong cùng nguồn). Các trường này chỉ đọc trong form; có "Tách khỏi nguồn" (gỡ `source_id`). **Trường của app luôn giữ:** ghi chú (trừ khi nguồn có cột ghi chú được ghép), yêu thích, forward, credentialReference, auth method, IdentityFile, IdentityAgent, bookmark.
- **BẮT BUỘC — tắt tự điền khi địa chỉ đổi:** khi đồng bộ làm đổi `hostName`, `port`, `user` (hoặc `jumpHostID`) của một host, đặt `autofill_hold = 1`. Khi hold: PasswordAutofillPolicy trả false (PTY), ConnectionService không đặt askpass/SSHDESK_HOST_REF (Warp), không copy clipboard (Windows), mọi đường đọc password qua `AutofillGatedCredentialStore` đều bị chặn cho host đó. Chi tiết host hiện banner "Địa chỉ đổi từ nguồn: cũ → mới. Đã tạm tắt tự điền mật khẩu" + nút **Xác nhận địa chỉ** (xoá hold). Sửa tay HostName/Port/User qua form cũng không tự xoá hold — chỉ nút xác nhận. Test bắt buộc: đổi từng trường → hold; trường khác đổi → không hold; hold → policy/askpass/clipboard không dùng password; xác nhận → dùng lại.
- **Không bao giờ nhập password:** nguồn không mang password vào DB/log/ghi chú. Ansible: bỏ qua `ansible_password`, `ansible_ssh_pass`, `ansible_become_pass`, `ansible_become_password`, giá trị `!vault`; cảnh báo "đã bỏ qua biến mật khẩu". Excel/CSV: xem dưới.
- Giá trị từ nguồn qua đúng validator của form/ADR-020 (cấm newline/ký tự điều khiển, port 1–65535...). Tối đa 5000 host mỗi nguồn. File > giới hạn → từ chối.
- **Excel/CSV:**
  - Người dùng chọn file → chọn sheet (xlsx) và dòng tiêu đề → **ghép cột** vào: tên, HostName/IP, Port, User, môi trường, thư mục/dự án, ghi chú, cột khoá. App đoán sẵn theo tiêu đề (tiếng Việt có/không dấu + tiếng Anh, không phân biệt hoa thường), vd `IP|Địa chỉ|Address|Host|HostName` → HostName; `Tên|Tên server|Server name|Name` → tên; `Port|Cổng`; `User|Username|Tài khoản|Login`; `Môi trường|Env|Environment`; `Dự án|Project|Thư mục|Nhóm|Folder`; `Ghi chú|Mô tả|Note|Description`.
  - **Cột khoá** (`external_id`): mặc định cột tên (đổi IP vẫn nhận ra là cùng host → kích hoạt hold); không có cột tên → HostName.
  - Giá trị môi trường: `prod|production|prd` → PROD, `uat`, `stg|staging`, `dev|development|test` → DEV, còn lại OTHER. Port dạng `22.0` → 22. Thiếu tên → dùng HostName.
  - Lưu cách ghép (`config_json`: sheet, dòng tiêu đề, map theo **văn bản tiêu đề**, cột khoá) theo từng nguồn → lần sau "Đồng bộ lại" hoặc "Chọn file mới cho nguồn" (khách gửi bản mới) là một chạm; tiêu đề đổi → mở lại màn ghép cột.
  - **Cột giống password** (`password|pass|pwd|passwd|mật khẩu|mat khau|mk|secret|passphrase|otp`, so sau khi bỏ dấu/hoa thường, khớp cả từ trong tiêu đề): cảnh báo "Phát hiện cột mật khẩu — sẽ bỏ qua" và **không ghép được vào bất kỳ trường nào** (kể cả ghi chú) — Core chặn, có test. Giá trị cột đó không được đọc vào model, không log, không vào preview. Việc có cho lưu vào Keychain hay không: **chờ người dùng quyết** (xem câu hỏi trong progress.md); chưa làm.
  - **CSV:** UTF-8 (có/không BOM), UTF-16 có BOM; tự nhận dấu phân cách `,` `;` tab; quote kiểu RFC 4180; ≤ 5 MB.
  - **XLSX (không dependency):** đọc bằng `/usr/bin/unzip -p <file> <entry>` qua executable + argv (không `sh -c`), stdout qua pipe, parse bằng `XMLParser`. Chi tiết chốt sau khi researcher kiểm chứng (mục "Kết quả kiểm chứng XLSX" bên dưới). Giới hạn: file nén ≤ 20 MB; mỗi entry giải nén đọc tối đa 50 MB, tổng 100 MB — vượt thì kill process và từ chối (chống zip bomb, không tin kích thước khai báo trong header); timeout 15 giây; ≤ 5000 dòng dữ liệu, ≤ 200 cột. Tên entry chỉ lấy từ danh sách cố định (`xl/workbook.xml`, `xl/_rels/workbook.xml.rels`, `xl/sharedStrings.xml`) hoặc khớp regex `^xl/worksheets/[A-Za-z0-9_]+\.xml$` (không wildcard, không `..`). XMLParser: `shouldResolveExternalEntities = false`; gặp DOCTYPE/khai báo entity → từ chối file. **Không tính công thức**: ô có `<f>` chỉ lấy giá trị cache `<v>` nếu có (là dữ liệu tĩnh), đếm và cảnh báo. Không đọc `xl/externalLinks/*`, hyperlink, `vbaProject.bin`; chỉ nhận đuôi `.xlsx` (từ chối `.xlsm`/`.xls`).
- **File Excel mẫu — luồng chính (người dùng yêu cầu 2026-10-22, xếp trước ghép cột tự do):**
  - Sheet "Máy chủ", tiêu đề dòng 1 cố định: `Tên`, `IP/Hostname`, `Port`, `User`, `Môi trường`, `Thư mục/Dự án`, `Loại`, `Jump host`, `Bộ đăng nhập`, `Ghi chú`. **Không có cột password.** `Bộ đăng nhập` chỉ là **tên** bộ (ADR-030); tên chưa có → xem trước báo "sẽ tạo bộ rỗng", người dùng nhập password sau. Port trống → 22 (SSH) / 3389 (Windows). Môi trường: DEV/UAT/STG/PROD (trống → OTHER). Loại: SSH/Windows (trống → SSH). Jump host = **tên** host khác (trong cùng file trước, rồi host đã có theo tên chính xác; không thấy → cảnh báo, để trống; Windows không có jump host). Với Windows, `User` → `rdpUsername`.
  - Sheet "Hướng dẫn": giải thích từng cột, giá trị hợp lệ, dòng ví dụ; ô A1 chứa dấu phiên bản `sshdesk-template v1`.
  - Data validation (dropdown) cho Môi trường và Loại bằng `<dataValidations>` trong XML sheet (không dependency).
  - **Cách tạo (PM chọn cách 2):** Core sinh các entry XML (`[Content_Types].xml`, `_rels/.rels`, `xl/workbook.xml`, `xl/_rels/workbook.xml.rels`, `xl/styles.xml`, 2 sheet, chuỗi inline `inlineStr` để khỏi cần sharedStrings) vào thư mục tạm của app, nén bằng `/usr/bin/zip -X -r` qua executable + argv (cwd = thư mục tạm, không `sh -c`), rồi chuyển tới đường dẫn người dùng chọn (NSSavePanel), xoá thư mục tạm. Lý do: có test round-trip (sinh → đọc lại bằng chính reader XLSX → đúng tiêu đề/validation), không phải giữ file nhị phân bị lệch với code. Bản trong repo `docs/templates/sshdesk-hosts-template.xlsx` sinh bằng `make template` (gọi `sshdesk-cli template <đường dẫn>`, chỉ ghi file mới, không ghi đè).
  - Nút **"Tải file mẫu…"** ở màn nhập/nguồn.
  - Nhận ra file đúng mẫu khi dòng 1 của sheet đầu khớp đúng bộ tiêu đề (không phân biệt hoa thường/khoảng trắng thừa) hoặc có dấu `sshdesk-template v1` → **bỏ qua bước ghép cột**, vào thẳng xem trước. Khoá (`external_id`) = cột Tên.
  - **Lỗi theo dòng:** mỗi lỗi có số dòng Excel, cột, lý do (IP/Hostname sai, Port ngoài 1–65535, Môi trường/Loại không hợp lệ, thiếu Tên/IP, trùng tên với dòng N, jump host trỏ chính nó...). Dòng lỗi bị bỏ qua, dòng hợp lệ vẫn nhập được; lỗi một dòng không làm hỏng cả file. Dòng trống hoàn toàn bỏ qua im lặng.
  - Màn xem trước có lựa chọn "Lưu làm nguồn để đồng bộ lại" (mặc định bật) — áp dụng đúng quy tắc đồng bộ/hold ở trên.
- **Kết quả kiểm chứng XLSX (researcher K4r, 2026-10-22; UnZip 6.00 / Zip 3.0 của Apple):**
  - `unzip -p` in ra stdout, không ghi file. Tên entry là **wildcard** (`[ ] * ?`), không có `-W`/`--` → chỉ dùng tên cố định hoặc khớp regex không có ký tự wildcard (regex trên đã đảm bảo). Không cần đọc `[Content_Types].xml`.
  - Chạy unzip với **env rỗng** (unzip đọc biến `UNZIP`). **Exit ≠ 0 → bỏ toàn bộ dữ liệu** (CRC hỏng vẫn in dữ liệu ra stdout, exit 2; entry thiếu exit 11; không phải zip exit 9).
  - Trước khi đọc: `unzip -Z1 <file>` liệt kê tên; **từ chối nếu tên trùng** (`-p` nối nội dung hai entry trùng tên, exit 0), có `..` hoặc đường dẫn tuyệt đối.
  - Zip bomb: 200 MB số 0 nén còn ~0,9 MB (229:1), kích thước khai báo không đáng tin → cap theo byte thực khi stream là lớp bảo vệ chính; vượt cap → app tự terminate process.
  - XMLParser: `shouldResolveExternalEntities` mặc định false nhưng **không có callback cho DOCTYPE** → quét byte, từ chối nếu có `<!DOCTYPE` hoặc `<!ENTITY` trước khi parse; đặt false tường minh; chỉ nhận UTF-8.
  - Kiểu ô cần xử lý: `s` (sharedStrings, `<si>` gồm `<t>` hoặc nhiều `<r><t>`, bỏ `<rPh>`), `inlineStr`, `str`, `n` (mặc định khi thiếu `t`), `b`, `e` (lỗi → trống + cảnh báo), `d`. Ô có `<f>` chỉ lấy `<v>` (có thể thiếu → trống). Ô định vị theo thuộc tính `r` (có thể bỏ qua ô trống). `sharedStrings.xml` có thể không có.
  - Target trong `workbook.xml.rels`: tương đối (`worksheets/sheet1.xml`, gốc `xl/`) hoặc tuyệt đối (`/xl/worksheets/sheet1.xml`); `TargetMode="External"` → từ chối. Thứ tự sheet theo `<sheets>`; sheet ẩn (`state="hidden"`/`veryHidden`) không hiện trong danh sách chọn.
  - CSV: bỏ BOM UTF-8 `EF BB BF`; nhận UTF-16 LE BOM `FF FE`.
  - Tạo file mẫu: `zip -X -D -r` (không entry thư mục), argv, cwd = thư mục tạm; thứ tự phần tử worksheet `sheetData → dataValidations → pageMargins`; XML tối thiểu đã thử (Spotlight/QuickLook nhận đúng là workbook, hiện đúng dữ liệu) nằm ở `scratchpad/k4r/xlsx/pkg/` của phiên PM — coder dùng lại cấu trúc này. **Chưa kiểm chứng:** mở trong Excel/Numbers và dropdown → người dùng thử file mẫu.
- **JSON:** đúng định dạng `sshdesk-hosts` v1 (ADR-020); `external_id` = `id` trong file.
- **Ansible tĩnh (tự parse, KHÔNG gọi `ansible-inventory` hay bất kỳ process nào):** INI (`[group]`, `[group:vars]`, `[group:children]`, `[all:vars]`, khoảng `web[01:03]` mở rộng có giới hạn) và YAML tập con (`all/hosts/children/vars`, mapping, scalar, quote, comment; anchor/alias/tag `!` khác ngoài `!vault` → báo lỗi dòng). Lấy `ansible_host`/`ansible_ssh_host`, `ansible_port`/`ansible_ssh_port`, `ansible_user`/`ansible_ssh_user` (biến host > group > all); tên group → tag. Không đọc `host_vars/`, `group_vars/`. `external_id` = tên host trong inventory.
- UI: menu thư mục "Nguồn…" (thêm/sửa/xoá nguồn, Đồng bộ, Xem trước); host từ nguồn có huy hiệu nguồn và "Không còn trong nguồn".

## ADR-027: Khoá Secure Enclave có sẵn của macOS (H-2b) — Đã chốt (kiểm chứng K5r 2026-10-22)
- **Kiểm chứng (researcher, macOS 27.0.1, OpenSSH_10.3p1):** `/usr/lib/ssh-keychain.dylib` có `sk_api_version/sk_enroll/sk_sign/sk_load_resident_keys`; `sc_auth create-ctk-identity -l <label> -k p-256-ne -t none -N <label>` (không sudo) → `ssh-keygen -w /usr/lib/ssh-keychain.dylib -K` (trong thư mục tạm) tạo handle `id_ecdsa_sk_rk_<label>` + `.pub` (loại `sk-ecdsa-sha2-nistp256@openssh.com`) → `ssh -o SecurityKeyProvider=/usr/lib/ssh-keychain.dylib -i <handle>` đăng nhập được sshd tạm 127.0.0.1. Thiếu `SecurityKeyProvider` → `Permission denied`. `sc_auth delete-ctk-identity -h <SHA1>` xoá được nhưng **exit 0 cả khi lỗi** → phải kiểm output và `list-ctk-identities` sau khi xoá. **Chưa kiểm chứng:** `-t bio` (Touch ID mỗi lần ký), hành vi prompt PIN/passphrase của `-K` khi chạy từ app.
- **Quyết định (K5):**
  - Màn SSH Keys: nút "Tạo khoá Secure Enclave…": nhãn `[A-Za-z0-9._-]{1,64}`, chưa trùng với identity có sẵn (`sc_auth list-ctk-identities`); lựa chọn bảo vệ **Touch ID (`-t bio`, mặc định)** / Không (`-t none`). Chạy `/usr/sbin/sc_auth create-ctk-identity -l <label> -k p-256-ne -t <bio|none> -N <label>` (argv), rồi `/usr/bin/ssh-keygen -w /usr/lib/ssh-keychain.dylib -K` qua PTYProcess với **cwd là thư mục tạm của app** (vì `-K` xuất mọi resident key); PIN để trống (Enter), passphrase cho file handle để trống (file chỉ là tham chiếu, key không rời chip). Chỉ chuyển cặp file của đúng nhãn mới sang `~/.ssh/` (tên `id_ecdsa_sk_rk_<label>`), **không ghi đè** file đã có (có thì báo lỗi), quyền 0600/0644; xoá thư mục tạm. Không đụng `~/.ssh/config`.
  - Khoá SE nhận diện bằng `.pub` loại `sk-ecdsa-sha2-nistp256@openssh.com` (chỉ đọc .pub). Host (hoặc set, ADR-030) dùng identityFile là khoá SE → SSHConfigWriter ghi thêm `SecurityKeyProvider "/usr/lib/ssh-keychain.dylib"` vào Host block. Không ghi toàn cục.
  - Cài lên server: dùng E1 (`ssh-copy-id -i <handle>.pub`).
  - Xoá: "Xoá khoá Secure Enclave" (xác nhận, cảnh báo không khôi phục được) → `sc_auth delete-ctk-identity -h <SHA1>` lấy từ `list-ctk-identities` theo nhãn; kiểm lại bằng list; rồi xoá cặp file handle trong `~/.ssh` chỉ khi đúng tên `id_ecdsa_sk_rk_<label>`.
  - Test: dùng `-t none` + sshd tạm 127.0.0.1 + thư mục tạm (không ghi `~/.ssh` thật trong test: tham số hoá thư mục đích), dọn identity trong `defer`. Test SE chạy có điều kiện (bỏ qua nếu thiếu dylib/sc_auth).

## ADR-028: Monitor đọc từ Prometheus/Zabbix (H-7) — Đã chốt
- **Bổ sung, không thay thế** Monitor qua SSH (ADR-019). Mỗi thư mục trong Monitor chọn nguồn số liệu: SSH (mặc định) / một nguồn metrics đã cấu hình.
- **DB (migration v10):** `metric_sources(id, name, kind ('prometheus'|'zabbix'), base_url, auth_kind ('none'|'bearer'|'basic'), basic_user, credential_ref, instance_template, allow_insecure_http INTEGER 0, created_at)`; bảng/khoá cài đặt gán thư mục → nguồn. Token/password **chỉ trong Keychain** (`credential_ref`, qua `CredentialStore` (ADR-004b, account `metrics-<uuid>`)), không vào DB/log/URL/argv/env; gửi qua header `Authorization` trên URLSession.
- **Chỉ API đọc:** Prometheus `GET /api/v1/query` (instant) với bộ truy vấn node_exporter cố định (CPU %, RAM, swap, load, đĩa theo `mountpoint`, uptime); nhãn ghép host theo mẫu `instance_template` (mặc định `{{hostName}}:9100`), giá trị nhãn escape theo cú pháp chuỗi PromQL và cấm ký tự điều khiển. Zabbix JSON-RPC `api_jsonrpc.php` chỉ whitelist `apiinfo.version`, `host.get`, `item.get` (key `system.cpu.util`, `vm.memory.utilization`, `system.cpu.load[all,avg1]`, `vfs.fs.size[<mount>,pused]`, `system.uptime`); token API: Zabbix ≥ 7.0 qua header Bearer, bản cũ qua trường `auth`. Không hỗ trợ `user.login` bằng password.
- **TLS:** không bao giờ tắt kiểm tra chứng chỉ (không custom `URLSessionDelegate` chấp nhận mọi cert). CA nội bộ → người dùng tự tin cậy trong macOS. `http://` → **cảnh báo** đỏ trong form và trên Monitor; nếu có token/password và host không phải loopback → phải tick "Tôi hiểu token gửi không mã hoá" (`allow_insecure_http`) mới lưu được. Info.plist thêm `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`; **không** `NSAllowsArbitraryLoads`. Theo tài liệu Apple (K5r), khoá này chỉ mở http tới **IP literal, tên không có dấu chấm và `.local`** — http tới FQDN (kể cả FQDN nội bộ như `prom.corp.example.com`) vẫn bị ATS chặn → app báo lỗi rõ "ATS chặn http tới tên miền; dùng https hoặc IP". Mở rộng hơn cần người dùng quyết (câu hỏi trong progress.md).
- Làm mới mỗi 30 giây (15/30/60), chỉ khi màn Monitor đang hiện; timeout 10 giây; phản hồi > 5 MB → bỏ. Lỗi hiện trên thẻ, không lộ header. Log chỉ có URL không query, mã lỗi.
- Test: `URLProtocol` giả (không mạng) cho parser/escape/header; có thể thêm HTTP server giả trên 127.0.0.1. Không gọi server thật.
- **Không làm đợt này:** nhật ký phiên cục bộ (tuỳ chọn trong H-7), cảnh báo/thông báo macOS, Grafana link.

## ADR-029: Hỏi mật khẩu lần đầu + "Lưu vào Keychain" — Đã chốt (người dùng đề xuất 2026-10-22, làm ngay sau K4a)
- **Bối cảnh:** host nhập từ Excel/nguồn chưa có password; askpass hỏi qua `/dev/tty` mỗi lần, không có cách lưu ngay.
- **Khi nào hiện sheet (Core `MissingPasswordPrompt.decide`, có test bảng):** tất cả điều kiện: host loại SSH; `authMethod == .interactive`; chưa có `credentialReference` (hoặc item Keychain không tồn tại); `jumpHostID == nil`; không `autofill_hold` (ADR-026); Cài đặt "Tự điền mật khẩu đã lưu" bật; Cài đặt mới **"Hỏi mật khẩu khi máy chưa lưu"** (`security.prompt_missing_password`, mặc định bật) bật. Thiếu một điều kiện → luồng cũ (askpass/PTY hỏi như hiện nay).
- **Sheet "Nhập mật khẩu cho user@host":** SecureField, checkbox **"Lưu vào Keychain"** (mặc định bật), nút "Tiếp tục", "Bỏ qua, nhập trong terminal" (Warp) / "Huỷ". Host PROD: xác nhận PROD trước, rồi mới hiện sheet.
- **Có tích lưu → kiểm tra trước khi lưu:** kết nối thử ngắn qua PTY dùng `SessionConnector`/`RemoteSession` (mở master `ControlMaster` rồi `-O exit`) với credential **trong bộ nhớ** (CredentialStore tạm, không Keychain), tự điền đúng một lần theo `PasswordAutofillPolicy`. Không `StrictHostKeyChecking=no`; `BatchMode=no`; timeout 20 giây.
  - Thành công → `ConnectionService.savePassword` (Keychain, ADR-010) → mở Warp như bình thường (askpass tự điền). Master thử được đóng; Analyst/Monitor/Truyền file có thể dùng lại master qua SessionPool thay vì đóng.
  - Sai mật khẩu (prompt password lần hai hoặc `Permission denied`) → "Sai mật khẩu", cho nhập lại; không lưu.
  - Gặp prompt host key (máy mới/đổi key) → dừng thử, báo "Chưa xác nhận host key — hãy mở terminal lần đầu (Bỏ qua, nhập trong terminal)"; không tự trả lời yes. Prompt khác (OTP/MFA) → dừng thử, cùng thông báo.
  - Lỗi mạng/timeout → hỏi "Không kiểm tra được. Vẫn lưu?" — mặc định **Không**.
- **Không tích lưu:** Warp → không giữ password, mở Warp như hiện nay, người dùng gõ trong terminal (password không qua env/argv/file tạm/Tab Config). Analyst/Monitor/Truyền file → password chỉ trong bộ nhớ cho đúng phiên/job đó (CredentialStore trong bộ nhớ gắn với phiên), bỏ khi phiên đóng; không ghi đâu cả.
- **Windows (ADR-018):** host Windows chưa có password và bấm Mở → sheet SecureField + "Lưu vào Keychain" (không kiểm tra được) → copy clipboard theo ADR-018; không tích → copy một lần, không lưu.
- **Rủi ro chấp nhận:** password nằm trong bộ nhớ app (String Swift không xoá được chủ động) trong thời gian phiên — giống luồng PTY hiện có.

## ADR-030: Bộ đăng nhập dùng chung (credential set) — Đã chốt (người dùng đề xuất 2026-10-22)
- **Model (migration v9):** bảng `credential_sets(id TEXT PK, name TEXT UNIQUE COLLATE NOCASE, user TEXT NULL, identity_file TEXT NULL, identity_agent TEXT NULL, note TEXT, created_at, updated_at)`; cột host `credential_set_id TEXT NULL` (xoá set → gỡ khỏi host, không xoá host). Password của set chỉ trong Keychain (service hiện có), account = **tham chiếu tất định `set-<uuid set>`** — không lưu ref riêng trong DB.
- **Quy tắc nguồn password (rõ ràng, một chỗ):** `HostProfile.effectiveCredentialReference` (thuần) = `credentialReference` riêng nếu có (không rỗng) → **ưu tiên riêng**; không thì `set-<credentialSetID>` nếu có set; không thì nil. **Mọi chỗ** đang đọc `host.credentialReference` để lấy password (ConnectionService/askpass `SSHDESK_HOST_REF`, PasswordAutofillPolicy, SessionConnector, TransferManager, TunnelManager, SSHKeyInstaller, Windows clipboard, AutofillGatedCredentialStore) chuyển sang `effectiveCredentialReference`. Chỗ ghi/xoá password riêng giữ `credentialReference`. UI chi tiết host ghi rõ nguồn: "Mật khẩu riêng" / "Bộ đăng nhập: <tên>" / "Mật khẩu riêng (ưu tiên hơn bộ <tên>)" + nút "Xoá mật khẩu riêng".
- **Set chứa cả key (người dùng yêu cầu 2026-10-22):** mỗi phần đều tuỳ chọn: user, password (Keychain `set-<uuid>`), **IdentityFile** (chỉ lưu đường dẫn, chọn bằng NSOpenPanel hoặc từ danh sách key E1; KHÔNG đọc nội dung private key), **passphrase của key** (Keychain, account tất định `setkey-<uuid>`), **IdentityAgent** (ADR-024). E1 chưa có cơ chế lưu passphrase → đây là cơ chế mới, chỉ dùng cho set.
- **Một bộ giải quyết duy nhất** `CredentialResolution.resolve(host:set:settings:)` (Core, thuần, có test) trả `user`, `identityFile`, `identityAgent`, `passwordRef`, `passphraseRef`, `passphraseKeyPath`. **Quy tắc ưu tiên nhất quán: giá trị riêng của host > set > mặc định Cài đặt (chỉ IdentityAgent).** Cụ thể: user = host.user nếu không rỗng, không thì set.user; identityFile = host.identityFile nếu có, không thì set.identityFile; identityAgent = host.identityAgent nếu khác nil, không thì set.identityAgent, không thì mặc định Cài đặt; passwordRef như dưới. Host `.keyFile` hợp lệ khi identityFile hiệu lực có (từ host hoặc set). SSHConfigWriter, ConnectionService, PTY/askpass, Analyst/Monitor/Truyền file/Tunnel/E1 đều lấy từ bộ giải quyết này — không đọc thẳng trường của host/set.
- **Sinh config:** host có identityFile hiệu lực → `IdentityFile "<path>"` + `IdentitiesOnly yes`; identityAgent hiệu lực → `IdentityAgent "<path>"`. Validate đường dẫn key của set bằng đúng validator IdentityFile hiện có (cấm newline/CR/NUL/ký tự điều khiển, quote/escape của writer) và IdentityAgent theo ADR-024 — kiểm khi lưu set **và** khi sinh config. Đổi key/agent của set → sinh lại config ngay khi lưu set, mọi host dùng set nhận giá trị mới.
- **Tự điền passphrase:** chỉ khi prompt đúng dạng `Enter passphrase for key '<path>':` và `<path>` (sau khi mở rộng `~` của giá trị trong set) **trùng chính xác** identityFile hiệu lực lấy từ set; tối đa 1 lần mỗi tiến trình ssh/phiên; mọi chặn của tự điền (tắt tự điền, `autofill_hold`, jumpHost) áp dụng như password. Askpass (Warp): env thêm `SSHDESK_KEY_REF=setkey-<uuid>` và `SSHDESK_KEY_PATH=<đường dẫn>` (tham chiếu + đường dẫn, không phải secret); helper chỉ trả passphrase khi prompt khớp đúng path. PTY: PromptDetector `.passphrase` + kiểm tra path. Passphrase không bao giờ vào config, argv, env (chỉ ref), log, DB. Dạng prompt chính xác của OpenSSH 10.3 (path đã mở rộng hay nguyên văn) phải kiểm chứng bằng sshd tạm trong test.
- **File key mất/đổi chỗ:** kiểm `fileExists` (không đọc nội dung) khi mở màn set, chi tiết host và trước khi kết nối → cảnh báo "Không thấy file key <path>". Không tự tìm, không quét `~/.ssh`.
- Màn quản lý hiện **loại set**: Password / Key / Password + Key / Agent (kết hợp theo phần đã có) và số host đang dùng.
- **Quy tắc tự điền KHÔNG đổi:** chỉ điền khi prompt khớp `user@hostName` của chính host (ADR-010/010b), không jumpHost, `autofill_hold` và "tắt tự điền" vẫn chặn. Set chỉ đổi nguồn password. `set.user` chỉ là gợi ý: khi gán, user của host khác `set.user` → cảnh báo, không tự sửa.
- **Chống chuyển password sang máy lạ qua file:** gán set đến từ **nhập/đồng bộ** (Excel, JSON, nguồn ADR-026) — kể cả host mới — đặt `autofill_hold` cho host đó (lý do "Bộ đăng nhập <tên> được gán từ file") tới khi người dùng xác nhận. Gán bằng tay trong app (form, gán hàng loạt) không hold.
- **Quản lý:** Cài đặt → Bảo mật → "Bộ đăng nhập": tạo (tên, user tuỳ chọn, ghi chú, password tuỳ chọn), đổi tên, đặt/đổi password (áp dụng cho mọi host dùng set), xem danh sách host dùng set, xoá (hiện số host bị ảnh hưởng, xác nhận, gỡ khỏi host, xoá item Keychain). Tên: 1–100 ký tự, không ký tự điều khiển, duy nhất (không phân biệt hoa thường).
- **Gán:** picker "Bộ đăng nhập" trong form host (chỉ SSH + `.interactive`, và Windows có mật khẩu); "Gán bộ đăng nhập…" cho cả thư mục (menu thư mục) và cho nhiều host chọn cùng lúc nếu bảng hỗ trợ chọn nhiều (không có thì chỉ làm theo thư mục). Gán hàng loạt hiện xem trước số host và các host có mật khẩu riêng (vẫn ưu tiên riêng).
- **Sheet hỏi password lần đầu (ADR-029):** thêm lựa chọn lưu: "Chỉ lưu cho máy này" / "Dùng bộ đăng nhập có sẵn" (picker) / "Lưu thành bộ mới: [tên]". Luôn kiểm tra đăng nhập trước khi lưu. Chọn bộ có sẵn: kiểm tra bằng password của bộ (không nhập lại); đúng → gán; sai → báo "Mật khẩu của bộ không đúng với máy này", **không ghi đè password của set** trừ khi người dùng nhập password mới và xác nhận rõ "Cập nhật mật khẩu của bộ (ảnh hưởng N máy)".
- **Xuất/nhập (ADR-020):** xuất chỉ tên set (`credentialSet`), không password, không passphrase, không ref, **không đường dẫn key/agent của set** (định nghĩa set là cấu hình của máy này; IdentityFile riêng của host vẫn xuất như ADR-020 hiện làm). Nhập: tên set chưa có → tạo set rỗng; host dùng set chưa có password → `needsReauth` (ghi chú/badge "cần nhập mật khẩu"). Gán set qua nhập → hold như trên.
- **"Xoá mọi mật khẩu đã lưu" (ADR-021)** xoá cả item Keychain của mọi set (giữ set và việc gán, set thành rỗng); số mục liệt kê gồm cả set.
- **Test bắt buộc:** effectiveCredentialReference (riêng > set > nil); CredentialResolution (set chỉ có key, set có cả password + key, host ghi đè set từng trường, agent host > set > Cài đặt); writer với path set chứa newline/CR/ký tự điều khiển → từ chối, `"`/`\\` escape đúng; passphrase chỉ điền khi path khớp, không lọt vào config/argv/env/log; đọc password theo set qua mọi đường (policy, askpass command, PTY); prompt không khớp → không điền dù set có password; hold/tắt tự điền chặn set; xoá set gỡ host + xoá Keychain; đổi password set áp cho mọi host; export không chứa password/ref; nhập gán set → hold; "Xoá mọi mật khẩu" xoá item set.

## ADR-004b: Một kho secret duy nhất qua `CredentialStore` — Đã chốt (người dùng chốt 2026-10-22)
- Password và passphrase **chỉ lưu ở MỘT kho**. Hiện là Keychain (service `local.sshdesk.credentials`). Không thêm kho thứ hai; không lấy password từ `op`/`bw` CLI (H-2d bỏ). Token Prometheus/Zabbix (ADR-028) cũng đi qua cùng abstraction (cùng backend, account/tiền tố riêng `metrics-<uuid>`, không service riêng).
- **Mọi** đọc/ghi/xoá password, passphrase (host, bộ đăng nhập ADR-030, passphrase key, Windows ADR-018, token metrics) đi qua protocol `CredentialStore` (bọc bởi `AutofillGatedCredentialStore` cho đường tự điền). Không chỗ nào gọi `SecItem*` trực tiếp ngoài backend. Helper `sshdesk-askpass` (target riêng) phải dùng **cùng mã backend** (tách backend vào target nhỏ dùng chung nếu cần), không tự viết truy vấn Keychain riêng — coder K4s xử lý khi đụng askpass.
- Tham chiếu dạng chuỗi (`<uuid>`, `set-<uuid>`, `setkey-<uuid>`, `metrics-<uuid>`) là account trong backend; DB chỉ giữ tham chiếu.
- **Backend Secure Enclave cho password: CHƯA chốt** — chờ kết quả nghiên cứu (ECIES bằng khoá SE, ciphertext trong Keychain, entitlement khi ký tự ký, askpass dùng chung). Nếu đổi: chỉ thay backend + migration chuyển item cũ, không đổi nơi gọi.
- QA: grep `SecItem`/`kSecClass` chỉ được xuất hiện trong file backend.

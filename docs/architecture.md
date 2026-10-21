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

## ADR-011: Local port forward (-L) — Đã chốt (người dùng chọn), làm sau Bước C
- Mỗi host có danh sách forward đã lưu: `localPort` → `remoteHost:remotePort` (mặc định remoteHost `localhost` phía server).
- Sinh vào Host block của app bằng `LocalForward` (bind `127.0.0.1` mặc định, không mở ra LAN), hoặc chạy phiên forward riêng `ssh -N -L ...` qua PTY runner khi người dùng bấm "Mở tunnel" (có trạng thái chạy/dừng, huỷ theo process group).
- Kiểm tra port local đang bận trước khi chạy; validate port 1–65535, không cho port < 1024.
- Không làm remote forward (-R) và không đụng firewall server.

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
- Prompt `Password:` trơn (PAM/keyboard-interactive) không khớp mẫu `<user>@<host>'s password:` → không tự điền, người dùng nhập tay.
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
- **Click 1 lần = chọn + hiện chi tiết; double-click / Return = Mở Warp.** Không được để cử chỉ double-click làm mất single-click.

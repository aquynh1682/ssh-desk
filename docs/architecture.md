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


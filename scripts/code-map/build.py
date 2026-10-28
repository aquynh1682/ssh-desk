"""Sinh docs/code-map/index.html: bản đồ code SSH Desk — bấm một khối để xem đúng đoạn code của nó.

Chạy: make code-map. Không cần công cụ ngoài (chỉ python3).
Mỗi khối có danh sách ref (file hoặc glob, regex anchor | None = cả file). Anchor là regex của dòng khai báo;
script tự lấy cả khối { … } (Swift), cả mục (Markdown) hoặc cả đoạn (Makefile). Anchor không khớp → báo lỗi,
để biết bản đồ đã lệch với code.
"""
import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "code-map" / "index.html"

S, D, CORE = "Sources/", "Sources/SSHDesk/", "Sources/SSHDeskCore/"
INV = CORE + "Inventory/"
CONN = CORE + "App/ConnectionService.swift"
WRITER = CORE + "SSHConfig/SSHConfigWriter.swift"
LAUNCHER = CORE + "Warp/WarpLauncher.swift"
ZSH = CORE + "Warp/ZshQuoting.swift"
ASKPASS = S + "sshdesk-askpass/main.swift"
DECISION = S + "AskpassKit/AskpassDecision.swift"
SEB = S + "CredentialBackend/SecureEnclaveBackend.swift"
SEAL = S + "CredentialBackend/CredentialSealing.swift"
IM = D + "InventoryModel.swift"
SKILL = ".claude/skills/ssh-desk-delivery/SKILL.md"


def N(id, lane, col, title, sub, desc, refs, row=0):
    return {"id": id, "lane": lane, "col": col, "row": row, "title": title, "sub": sub, "desc": desc, "refs": refs}


VIEWS = [
    {
        "id": "kien-truc",
        "title": "Kiến trúc",
        "hint": "UI chỉ gọi vào ConnectionService; Core không import SwiftUI. Mọi ssh/scp/sftp chạy bằng "
                "executable + argv với -F config của app, không qua sh -c.",
        "lanes": ["Lối vào", "Giao diện · SSHDesk", "Điều phối · SSHDeskCore", "Dịch vụ · SSHDeskCore",
                  "Helper · bí mật · khoá"],
        "nodes": [
            N("app", 0, 0, "App SwiftUI", "SSHDeskApp.swift",
              "Điểm vào của app: tạo AppModel, cửa sổ chính và màn Cài đặt.", [(D + "SSHDeskApp.swift", None)]),
            N("appmodel", 0, 1, "AppModel", "AppModel.swift",
              "Model @Observable trung tâm của UI: giữ danh sách host, lựa chọn, banner. Mọi thao tác kết nối "
              "đều gọi xuống ConnectionService.", [(D + "AppModel.swift", r"final class AppModel")]),
            N("url", 0, 2, "URL sshdesk://", "AppModel+URL.swift",
              "Nhận sshdesk://open?id=|name= và sshdesk://cli?request=. URL từ ngoài luôn hỏi xác nhận; request "
              "hợp lệ từ CLI chỉ hỏi với máy PROD (ADR-025).",
              [(D + "AppModel+URL.swift", None), (CORE + "CLI/AppURLRequest.swift", None)]),
            N("cli", 0, 3, "CLI sshdesk", "sshdesk-cli/main.swift",
              "sshdesk list / open. Mở DB chỉ đọc, giải host theo UUID → alias → tên; open ghi file request "
              "rồi mở URL để app xử lý, CLI không tự mở Warp.",
              [(S + "sshdesk-cli/main.swift", None), (CORE + "CLI/HostResolver.swift", None),
               (CORE + "CLI/CLIOpenRequest.swift", None)]),
            N("v_hosts", 1, 0, "Máy chủ", "HostDetailView.swift",
              "Danh sách theo thư mục, chi tiết host (Mở trong Warp, Copy lệnh SSH), form thêm/sửa.",
              [(D + "HostDetailView.swift", None), (D + "HostListView.swift", None), (D + "HostFormView.swift", None)]),
            N("v_inv", 1, 1, "Nguồn máy chủ", "InventoryModel.swift",
              "Hub nguồn, wizard ghép cột, màn xem trước, thông báo tự thêm máy kèm Hoàn tác.",
              [(IM, None), (D + "InventoryViews.swift", None)]),
            N("v_files", 1, 2, "Duyệt file · truyền", "FileBrowserModel.swift",
              "Cửa sổ hai khung kiểu Xftp và hàng đợi truyền file.",
              [(D + "FileBrowserModel.swift", None), (D + "BrowserTab.swift", None), (D + "TransferQueueView.swift", None)]),
            N("v_mon", 1, 3, "Monitor · Analyst", "MonitorModel.swift",
              "Màn theo dõi tài nguyên server và bản đồ kết nối giữa các server.",
              [(D + "MonitorModel.swift", None), (D + "AnalystModel.swift", None)]),
            N("v_settings", 1, 4, "Cài đặt · Keys", "SettingsView · KeysModel",
              "Màn Cài đặt (ADR-021), SSH Keys và bộ đăng nhập dùng chung.",
              [(D + "SettingsView.swift", None), (D + "KeysModel.swift", None), (D + "CredentialSetViews.swift", None)]),
            N("repo", 2, 0, "HostRepository", "HostRepository.swift",
              "Actor đọc/ghi host, thư mục, bộ đăng nhập, nguồn trên SQLite (import SQLite3, migration tuần tự, "
              "DB lỗi thì báo chứ không tạo DB rỗng đè lên).",
              [(CORE + "Hosts/HostRepository.swift", r"public actor HostRepository"), (CORE + "Hosts/Database.swift", None),
               (CORE + "Hosts/HostProfile.swift", None)]),
            N("conn", 2, 1, "ConnectionService", "App/ConnectionService.swift",
              "Actor điều phối: kiểm host, sinh lại SSH config, dựng lệnh (askpass hay thường), mở Warp/Windows App, "
              "lưu/xoá mật khẩu, áp dụng nhập và đồng bộ.", [(CONN, r"public actor ConnectionService")]),
            N("writer", 2, 2, "SSHConfigWriter", "SSHConfigWriter.swift",
              "Sinh ssh/config của app từ DB: Host sshdesk-<uuid>, rồi Match all + Include ~/.ssh/config. Cấm "
              "newline/ký tự điều khiển, bọc mọi giá trị trong \"…\" (ADR-006).", [(WRITER, None)]),
            N("cred", 2, 3, "CredentialStore", "CredentialStore.swift",
              "Protocol kho bí mật duy nhất (ADR-004b). AutofillGatedCredentialStore chặn đọc khi host bị hold "
              "hoặc đã tắt tự điền.",
              [(CORE + "Credentials/CredentialStore.swift", r"public protocol CredentialStore"),
               (CORE + "**/*.swift", r"struct AutofillGatedCredentialStore"),
               (CORE + "Credentials/PasswordAutofillPolicy.swift", None)]),
            N("inv", 2, 4, "InventorySync", "InventorySync.swift",
              "Lập kế hoạch đồng bộ một chiều từ nguồn: thêm, đổi từng trường, không còn trong nguồn, lỗi dòng.",
              [(INV + "InventorySync.swift", r"public enum InventorySync")]),
            N("warp", 3, 0, "WarpLauncher", "Warp/WarpLauncher.swift",
              "Ghi ~/.warp/tab_configs/sshdesk_<uuid>.toml (chỉ file sshdesk_*) rồi mở warp://tab_config/… (ADR-007).",
              [(LAUNCHER, r"public struct WarpLauncher"), (CORE + "Warp/WarpTabConfigRenderer.swift", None)]),
            N("pty", 3, 1, "PTYProcess", "Process/PTYProcess.swift",
              "Chạy ssh/scp/sftp trong pseudo-terminal bằng executable + argv. PromptDetector nhận prompt; chỉ điền "
              "mật khẩu khi khớp đúng user@host.",
              [(CORE + "Process/PTYProcess.swift", r"public final class PTYProcess"),
               (CORE + "Process/PromptDetector.swift", None)]),
            N("transfer", 3, 2, "TransferManager", "Transfer/TransferManager.swift",
              "Hàng đợi upload/download; mỗi job là một scp chạy qua PTY, đọc tiến độ từ output.",
              [(CORE + "Transfer/TransferManager.swift", None), (CORE + "Transfer/ScpCommandBuilder.swift", None)]),
            N("session", 3, 3, "Phiên duyệt file", "Remote/SessionConnector.swift",
              "Master ssh -M với ControlPath trong /tmp/sshdesk-<uid> (kiểm owner, mode 0700, không symlink); "
              "sftp/scp con dùng lại master.",
              [(CORE + "Remote/SessionConnector.swift", None), (CORE + "Remote/SocketDirectory.swift", None),
               (CORE + "Remote/SftpBatch.swift", None)]),
            N("xlsx", 3, 4, "Đọc Excel / CSV", "Inventory/XLSXReader.swift",
              "Đọc .xlsx bằng /usr/bin/unzip (argv, env rỗng, cap dung lượng), chặn DOCTYPE/ENTITY; CSV tự nhận BOM "
              "và dấu phân cách.",
              [(INV + "XLSXReader.swift", r"public enum XLSXReader"), (INV + "CSVReader.swift", None),
               (INV + "ZipProcess.swift", None)]),
            N("tunnel", 3, 1, "TunnelManager", "Tunnel/TunnelManager.swift",
              "Mỗi port forward là một ssh -N -L 127.0.0.1:<port> riêng, ControlMaster=no (ADR-011).",
              [(CORE + "Tunnel/TunnelManager.swift", None), (CORE + "Tunnel/PortForward.swift", None)], row=1),
            N("monitor", 3, 2, "Monitor · Analyst", "MonitorCoordinator.swift",
              "Chạy lệnh chỉ đọc qua phiên ssh để lấy CPU/RAM/disk và dựng bản đồ kết nối. ProdGuard liệt kê máy "
              "và lệnh sẽ chạy để xác nhận trước khi quét máy PROD.",
              [(CORE + "Monitor/MonitorCoordinator.swift", None), (CORE + "Analyst/AnalystCoordinator.swift", None),
               (CORE + "Analyst/ProdGuard.swift", None)], row=1),
            N("metrics", 3, 3, "Metrics", "MetricsTransport.swift",
              "Đọc Prometheus/Zabbix qua URLSession: TLS ≥ 1.2, không theo redirect, http chỉ khi người dùng cho "
              "phép (ADR-028, 028b).",
              [(CORE + "Metrics/MetricsTransport.swift", r"tlsMinimumSupportedProtocolVersion"),
               (CORE + "Metrics/PrometheusClient.swift", None), (CORE + "Metrics/ZabbixClient.swift", None)], row=1),
            N("windows", 3, 4, "Windows App", "WindowsAppLauncher.swift",
              "Sinh file .rdp và mở bằng Windows App; mật khẩu copy tạm vào clipboard (ADR-017, 018).",
              [(CORE + "Windows/WindowsAppLauncher.swift", None), (CORE + "Windows/RDPFileRenderer.swift", None),
               (CORE + "Windows/SecretClipboard.swift", None)], row=1),
            N("askpass", 4, 0, "sshdesk-askpass", "sshdesk-askpass/main.swift",
              "ssh gọi qua SSH_ASKPASS khi chạy trong Warp. Kiểm cha là /usr/bin/ssh, trả mật khẩu đúng host một "
              "lần; prompt khác thì hỏi trên /dev/tty (ADR-010).", [(ASKPASS, None)]),
            N("kit", 4, 1, "AskpassDecision", "AskpassKit/AskpassDecision.swift",
              "Logic thuần phân loại prompt (password, passphrase, host key, OTP…), dùng chung cho helper và test.",
              [(DECISION, None)]),
            N("se", 4, 2, "Secure Enclave", "SecureEnclaveBackend.swift",
              "Backend của CredentialStore: khoá P-256 trong Secure Enclave, ciphertext ECIES (HKDF + AES-GCM, AAD "
              "theo tham chiếu) lưu trong Keychain (ADR-004c).",
              [(SEB, r"public final class SecureEnclaveBackend"), (SEAL, r"public enum CredentialSealing")]),
            N("ctty", 4, 3, "sshdesk-ctty", "sshdesk-ctty/main.swift",
              "Helper nhỏ cho PTYProcess: biến slave PTY thành controlling tty rồi exec chương trình đích, để ssh "
              "hỏi mật khẩu trên PTY của app.",
              [(S + "sshdesk-ctty/main.swift", None), (CORE + "Process/ControllingTTYHelper.swift", None)]),
            N("keys", 4, 4, "SSH keys", "Keys/AgentKeyLister.swift",
              "Liệt kê public key của agent (ssh-add -L, không đọc private key), tạo key, cài key lên server bằng "
              "ssh-copy-id.",
              [(CORE + "Keys/AgentKeyLister.swift", None), (CORE + "Keys/SSHKeyGenerator.swift", None),
               (CORE + "Keys/SSHKeyInstaller.swift", None)]),
        ],
        "edges": [
            ("app", "appmodel", ""), ("url", "appmodel", ""), ("cli", "url", "mở URL"),
            ("appmodel", "v_hosts", ""), ("v_hosts", "conn", "openInWarp"), ("v_inv", "conn", "applyInventory"),
            ("conn", "repo", ""), ("conn", "writer", "sinh lại"), ("conn", "cred", "mật khẩu"),
            ("conn", "inv", "đồng bộ"), ("conn", "warp", "launch"), ("inv", "xlsx", "đọc"),
            ("transfer", "pty", "scp"), ("tunnel", "pty", ""), ("session", "pty", "sftp"),
            ("warp", "askpass", "SSH_ASKPASS"), ("askpass", "kit", ""), ("askpass", "se", "đọc kho"),
        ],
    },
    {
        "id": "mo-warp",
        "title": "Mở SSH trong Warp",
        "hint": "Bấm \"Mở trong Warp\" → kiểm host, sinh lại config → chọn lệnh askpass hay lệnh thường → ghi Tab "
                "Config → Warp chạy ssh → askpass trả mật khẩu một lần (ADR-006, 007, 010).",
        "lanes": ["Giao diện", "ConnectionService", "Sinh file", "Warp + ssh", "sshdesk-askpass · kho"],
        "nodes": [
            N("ui_open", 0, 0, "Mở trong Warp", "AppModel · openInWarp",
              "Nút trong chi tiết host. Gọi ConnectionService.openInWarpReport, hiện banner nếu Warp không mở được "
              "hoặc phải nhập mật khẩu tay.", [(D + "AppModel.swift", r"func openInWarp\(")]),
            N("ui_copy", 0, 3, "Copy lệnh SSH", "AppModel · copySSHCommand",
              "Dự phòng khi không có Warp: copy lệnh ssh thường (không askpass) để chạy ở terminal khác.",
              [(D + "AppModel.swift", r"func copySSHCommand"), (D + "HostDetailView.swift", r"Copy lệnh SSH")]),
            N("report", 1, 0, "openInWarpReport", "ConnectionService.swift",
              "Chỉ host SSH. Kiểm host + bộ đăng nhập, sinh lại config, lấy lệnh, báo thiếu file key, rồi nhờ "
              "WarpLauncher mở; thành công thì ghi thời điểm mở.", [(CONN, r"public func openInWarpReport")]),
            N("regen", 1, 1, "regenerateSSHConfig", "ConnectionService.swift",
              "Lấy spec mọi host từ DB (kèm IdentityAgent mặc định) và ghi lại ssh/config của app.",
              [(CONN, r"public func regenerateSSHConfig")]),
            N("cmd", 1, 2, "warpSSHCommand", "ConnectionService.swift",
              "Chọn lệnh: có mật khẩu/passphrase lưu và không hold, không tắt tự điền, có helper, không bastion → "
              "lệnh askpass; ngược lại lệnh thường kèm lý do.", [(CONN, r"public func warpSSHCommand")]),
            N("plain", 1, 3, "copyableSSHCommand", "ConnectionService.swift",
              "Lệnh ssh thường: /usr/bin/ssh -F <config tuyệt đối> <alias>, không biến môi trường nào.",
              [(CONN, r"public func copyableSSHCommand"), (CONN, r"public func sshArguments")]),
            N("launch", 1, 4, "WarpLauncher.launch", "Warp/WarpLauncher.swift",
              "Chuẩn bị file Tab Config rồi mở URI; Warp không có hoặc mở lỗi → trả kết quả để UI hiện dự phòng.",
              [(LAUNCHER, r"public func launch\("), (LAUNCHER, r"static func uri")]),
            N("validate", 2, 0, "Kiểm giá trị", "SSHConfigWriter · validate",
              "Newline trong giá trị ssh_config bị parse thành directive mới → cấm \\n, \\r, mọi ký tự điều khiển; "
              "kiểm vòng ProxyJump.",
              [(WRITER, r"static func validate\("), (WRITER, r"static func rejectControl"),
               (WRITER, r"static func checkJumpCycles")]),
            N("render", 2, 1, "SSHConfigWriter.render", "SSHConfigWriter.swift",
              "Host của app đứng trước để thắng; Match all reset ngữ cảnh rồi Include ~/.ssh/config. Ghi atomically, "
              "quyền 0600.", [(WRITER, r"public static func render"), (WRITER, r"static func quote")]),
            N("zsh", 2, 2, "ZshQuoting", "Warp/ZshQuoting.swift",
              "Quote lệnh cho zsh. Bản askpass thêm SSH_ASKPASS=<helper>, SSH_ASKPASS_REQUIRE=force, "
              "SSHDESK_HOST_REF=<tham chiếu> — env chỉ chứa tham chiếu, không chứa mật khẩu.", [(ZSH, None)]),
            N("toml", 2, 3, "Tab Config TOML", "WarpTabConfigRenderer.swift",
              "Một pane terminal, shell zsh, commands = [lệnh]. Escape chuỗi TOML; tên hồ sơ chỉ vào name, không "
              "bao giờ vào commands.", [(CORE + "Warp/WarpTabConfigRenderer.swift", None)]),
            N("prepare", 2, 4, "WarpLauncher.prepare", "Warp/WarpLauncher.swift",
              "Ghi ~/.warp/tab_configs/sshdesk_<uuid>.toml bằng atomic write; chỉ đụng file có tiền tố sshdesk_.",
              [(LAUNCHER, r"public func prepare"), (LAUNCHER, r"static func isOwnedFileName"),
               (LAUNCHER, r"private func atomicWrite")]),
            N("invoc", 3, 3, "ssh -F <config>", "SSHConfigWriter · sshInvocation",
              "Dạng gọi chung cho mọi kết nối: /usr/bin/ssh -F <đường dẫn tuyệt đối> <alias>. Đường dẫn phải tuyệt "
              "đối vì ProxyJump truyền lại -F.", [(WRITER, r"public static func sshInvocation")]),
            N("handler", 3, 4, "Mở warp://", "WarpLauncher · SystemWarpURLHandler",
              "Kiểm Warp có cài không và mở URL bằng NSWorkspace.",
              [(LAUNCHER, r"public struct SystemWarpURLHandler")]),
            N("tty", 4, 0, "Hỏi trên /dev/tty", "askpass · askOnTTY",
              "Prompt không phải mật khẩu của đúng host (host key, OTP, passphrase, mật khẩu lần 2) → hỏi người "
              "dùng ngay trong Warp, tắt echo với câu hỏi bí mật.", [(ASKPASS, r"func askOnTTY")]),
            N("claim", 4, 1, "Một lần mỗi ssh", "askpass · claimSecretUse",
              "Đánh dấu đã dùng theo ppid + thời điểm khởi động cha (O_EXCL): sai mật khẩu thì không lặp lại.",
              [(ASKPASS, r"func claimSecretUse")]),
            N("decide", 4, 2, "Phân loại prompt", "AskpassDecision",
              "Quyết định trả mật khẩu đã lưu hay hỏi người dùng, theo loại prompt và tham chiếu có trong env.",
              [(DECISION, r"public enum AskpassDecision")]),
            N("main", 4, 3, "Kiểm cha", "askpass · parentExecutablePath",
              "Helper chỉ làm việc khi process cha là /usr/bin/ssh (proc_pidpath).",
              [(ASKPASS, r"func parentExecutablePath")]),
            N("read", 4, 4, "Đọc kho", "askpass · readKeychainSecret",
              "Đọc theo tham chiếu qua cùng backend Secure Enclave với app, in mật khẩu ra stdout cho ssh.",
              [(ASKPASS, r"func readKeychainSecret"), (SEB, r"public func read\(account")]),
            N("open", 4, 4, "Giải mã ECIES", "CredentialSealing.open",
              "Version lạ, độ dài sai, tag sai → undecryptable; không bao giờ quay về đọc plaintext.",
              [(SEAL, r"public static func open")], row=1),
        ],
        "edges": [
            ("ui_open", "report", ""), ("report", "regen", ""), ("regen", "render", "ghi"),
            ("render", "validate", ""), ("report", "cmd", "lệnh"), ("cmd", "plain", "hold / bastion"),
            ("cmd", "zsh", "askpass"), ("plain", "zsh", ""), ("ui_copy", "plain", ""), ("report", "launch", "launch"),
            ("launch", "prepare", ""), ("prepare", "toml", ""), ("prepare", "handler", "warp://"),
            ("handler", "invoc", "zsh chạy"), ("invoc", "main", "SSH_ASKPASS"), ("main", "decide", ""),
            ("decide", "claim", "mật khẩu"), ("decide", "tty", "prompt khác"), ("claim", "read", ""),
            ("read", "open", ""),
        ],
    },
    {
        "id": "nhap-excel",
        "title": "Nhập Excel / CSV",
        "hint": "Đọc file an toàn → nhận file mẫu hoặc ghép cột → chặn cột mật khẩu → kiểm từng dòng → lập kế hoạch "
                "→ một transaction (ADR-026, 026b, 031).",
        "lanes": ["Giao diện · InventoryModel", "Đọc file", "Ghép cột · kiểm", "Kế hoạch", "Ghi DB · kho"],
        "nodes": [
            N("pick", 0, 0, "Chọn file", "InventoryModel · open",
              "NSOpenPanel chọn .xlsx/.csv (hoặc mở lại nguồn) rồi nạp file vào wizard.",
              [(IM, r"private func pickFile"), (IM, r"func open\(url")]),
            N("keep", 0, 1, "Lưu cột mật khẩu?", "InventoryModel · setKeepPassword",
              "Công tắc mặc định TẮT, phải bật lại mỗi lần nhập; không lưu vào config_json (ADR-031).",
              [(IM, r"func setKeepPassword")]),
            N("preview", 0, 2, "Màn xem trước", "InventoryModel · showPreview",
              "Dựng kế hoạch từ wizard; mật khẩu chỉ hiện ••••, có số host sẽ được lưu và đã có mật khẩu.",
              [(IM, r"func showPreview\(from wizard")]),
            N("apply", 0, 3, "Áp dụng", "InventoryModel · apply",
              "Hỏi xác nhận khi có lưu mật khẩu, gọi ConnectionService, rồi lưu mật khẩu và xoá buffer.",
              [(IM, r"func apply\(_ preview")]),
            N("auto", 0, 4, "Tự thêm máy mới", "InventoryModel · autoApply…",
              "Nguồn đổi mà kế hoạch chỉ có thêm mới → tự áp dụng, hiện thông báo kèm Xem / Hoàn tác (ADR-026b).",
              [(IM, r"private func autoApplyIfAdditionsOnly"), (IM, r"func undoAutoAdded")]),
            N("load", 1, 0, "InventoryFile.load", "Inventory/InventoryFile.swift",
              "Nhận loại file theo đuôi, kiểm giới hạn dung lượng, gọi reader tương ứng.",
              [(INV + "InventoryFile.swift", r"public static func load"),
               (INV + "InventoryFile.swift", r"public static func sizeLimit")]),
            N("xlsx", 1, 1, "XLSXReader.read", "Inventory/XLSXReader.swift",
              "Liệt kê entry, đọc workbook → sheet → sharedStrings; mọi entry đọc qua unzip -p có cap byte.",
              [(INV + "XLSXReader.swift", r"public static func read\(")]),
            N("entries", 1, 2, "Kiểm tên entry", "XLSXReader · validateEntryNames",
              "Từ chối tên trùng (unzip -p sẽ nối nội dung), có .. hoặc đường dẫn tuyệt đối.",
              [(INV + "XLSXReader.swift", r"static func listEntries"),
               (INV + "XLSXReader.swift", r"static func validateEntryNames")]),
            N("guard", 1, 3, "Chặn DOCTYPE", "XLSXReader · guardXML",
              "Quét byte trước khi đưa vào XMLParser: có <!DOCTYPE hoặc <!ENTITY, hoặc không phải UTF-8 → từ chối.",
              [(INV + "XLSXReader.swift", r"static func guardXML")]),
            N("zip", 1, 4, "BoundedProcess", "Inventory/ZipProcess.swift",
              "Chạy /usr/bin/unzip bằng argv, env rỗng; vượt cap byte hoặc quá giờ thì terminate (chống zip bomb).",
              [(INV + "ZipProcess.swift", r"static func run\(")]),
            N("csv", 1, 1, "CSVReader", "Inventory/CSVReader.swift",
              "UTF-8 (có/không BOM), UTF-16 có BOM; tự nhận , ; hoặc tab; quote kiểu RFC 4180.",
              [(INV + "CSVReader.swift", r"static func decode"), (INV + "CSVReader.swift", r"static func detectDelimiter")],
              row=1),
            N("recog", 2, 0, "Nhận file mẫu", "ColumnMapping · recognize",
              "Dòng 1 khớp bộ tiêu đề mẫu hoặc có dấu sshdesk-template v1 → bỏ bước ghép cột, khoá là cột Tên.",
              [(INV + "ColumnMapping.swift", r"public enum InventoryTemplateFormat")]),
            N("guess", 2, 1, "Đoán cột", "ColumnMapping · guess",
              "Ghép tiêu đề tiếng Việt có/không dấu và tiếng Anh vào trường; lưu cách ghép theo văn bản tiêu đề.",
              [(INV + "ColumnMapping.swift", r"public static func guess"),
               (INV + "ColumnMapping.swift", r"public struct TableMapping")]),
            N("pwhdr", 2, 2, "Cột giống mật khẩu", "TableData · PasswordHeader",
              "password, pass, pwd, mật khẩu, mk, secret, otp… (bỏ dấu, khớp cả từ). Core chặn ghép cột này vào "
              "bất kỳ trường nào.", [(INV + "TableData.swift", r"public enum PasswordHeader")]),
            N("secret", 2, 3, "SecretColumnValues", "Inventory/SecretColumn.swift",
              "Giữ giá trị cột mật khẩu riêng theo (sheet, dòng); description/Mirror đều che; ghi 0 bằng memset_s.",
              [(INV + "SecretColumn.swift", r"public final class SecretColumnValues"),
               (INV + "SecretColumn.swift", r"final class SecretBytes")]),
            N("validator", 2, 4, "Kiểm từng dòng", "InventoryTableParser.swift",
              "Lỗi theo dòng Excel: IP/Hostname, Port 1–65535, môi trường, trùng tên… Dòng lỗi bị bỏ, dòng tốt vẫn "
              "nhập.", [(INV + "InventoryTableParser.swift", r"public static func check"),
                       (INV + "InventoryTableParser.swift", r"public enum InventoryTableParser")]),
            N("detect", 3, 0, "Nguồn có thay đổi", "InventoryFile · detectChange",
              "So mtime + SHA-256 khi mở app và khi app được kích hoạt.",
              [(INV + "InventoryFile.swift", r"public static func detectChange"),
               (INV + "InventoryFile.swift", r"public static func fingerprint")]),
            N("plan", 3, 2, "InventorySync.plan", "Inventory/InventorySync.swift",
              "So bản ghi với host đang có theo external_id: thêm / đổi từng trường / không còn trong nguồn. Đổi "
              "địa chỉ thì đánh dấu hold.", [(INV + "InventorySync.swift", r"public static func plan\(")]),
            N("secplan", 3, 3, "Kế hoạch mật khẩu", "InventorySecretImport.plan",
              "Dòng nào sẽ được lưu mật khẩu; host đã có mật khẩu riêng thì bỏ qua trừ khi bật ghi đè; ô trống "
              "không đụng.", [(INV + "SecretColumn.swift", r"public static func plan\(")]),
            N("addonly", 3, 4, "isAdditionsOnly", "Inventory/InventoryAutoAdd.swift",
              "Chỉ đúng khi không có sửa, biến mất, lỗi hay cảnh báo nào.",
              [(INV + "InventoryAutoAdd.swift", r"public static func isAdditionsOnly")]),
            N("repoapply", 4, 1, "Một transaction", "InventoryRepository · applyInventory",
              "Thêm và cập nhật host trong một transaction SQLite; lỗi thì không ghi gì.",
              [(INV + "InventoryRepository.swift", r"public func applyInventory")]),
            N("capply", 4, 2, "applyInventory", "ConnectionService.swift",
              "Áp dụng kế hoạch rồi sinh lại SSH config.", [(CONN, r"public func applyInventory")]),
            N("save", 4, 3, "Lưu mật khẩu", "InventorySecretImport.save",
              "Sau khi transaction thành công: lưu từng mật khẩu qua ConnectionService.savePassword (Secure Enclave) "
              "rồi ghi 0 buffer.", [(INV + "SecretColumn.swift", r"public static func save\(")]),
            N("cauto", 4, 4, "applyAutoInventory", "ConnectionService.swift",
              "Từ chối nếu kế hoạch không phải chỉ-thêm-mới; không bao giờ đụng kho mật khẩu.",
              [(CONN, r"public func applyAutoInventory")]),
            N("undodb", 4, 4, "Hoàn tác", "HostRepository · undoAutoAdd",
              "Xoá đúng các host vừa thêm nếu chưa bị sửa, chưa có mật khẩu/forward; tắt Tự thêm máy mới của nguồn.",
              [(INV + "InventoryAutoAdd.swift", r"public func undoAutoAdd"), (CONN, r"public func undoAutoAdd")],
              row=1),
        ],
        "edges": [
            ("pick", "load", ""), ("keep", "preview", ""), ("preview", "apply", ""),
            ("load", "xlsx", ""), ("load", "csv", ""), ("xlsx", "entries", ""), ("xlsx", "guard", "XML"),
            ("xlsx", "zip", "unzip -p"), ("load", "recog", ""), ("recog", "guess", "không đúng mẫu"),
            ("guess", "pwhdr", ""), ("pwhdr", "secret", "nếu bật"), ("recog", "validator", "đúng mẫu"),
            ("validator", "plan", ""), ("detect", "plan", "đồng bộ lại"), ("plan", "secplan", ""),
            ("secret", "secplan", ""), ("plan", "addonly", ""), ("plan", "capply", ""),
            ("capply", "repoapply", ""), ("secplan", "save", ""), ("addonly", "cauto", "tự áp dụng"),
            ("cauto", "capply", ""), ("cauto", "undodb", "Hoàn tác"),
        ],
    },
    {
        "id": "quy-trinh",
        "title": "Quy trình agent",
        "hint": "Ý tưởng → người dùng chọn → pm ghi ADR → coder → qa-reviewer → make check + PM duyệt → commit. "
                "Mỗi lúc một coder, làm thẳng trên nhánh.",
        "lanes": ["Người dùng · agent chính", "Điều phối", "Thực thi", "Kiểm tra · chốt"],
        "nodes": [
            N("claude", 0, 0, "Quy tắc dự án", "CLAUDE.md",
              "Stack, lệnh make, những điều không được làm (secret, sh -c, sửa ~/.ssh/config…).", [("CLAUDE.md", None)]),
            N("main", 0, 1, "Agent chính (PM)", "CLAUDE.md · Đội và quy trình",
              "Chốt quyết định, chia task, review diff, approve; không tự viết code tính năng.",
              [("CLAUDE.md", r"^## Đội và quy trình")]),
            N("advisor", 0, 2, "product-advisor", ".claude/agents/product-advisor.md",
              "Đề xuất ý tưởng, so sánh công cụ cùng loại, ghi docs/ideas.md; người dùng chọn rồi mới làm.",
              [(".claude/agents/product-advisor.md", None)]),
            N("pm", 1, 0, "pm (Opus)", ".claude/agents/pm.md",
              "Nhận việc đã chọn, chốt ADR, giao coder → qa-reviewer → doc-writer, duyệt và commit.",
              [(".claude/agents/pm.md", None)]),
            N("skill", 1, 1, "Skill giao việc", "ssh-desk-delivery/SKILL.md",
              "Các bước 0–4 và cách xử lý lỗi khi agent báo đỏ hoặc bỏ dở.", [(SKILL, None)]),
            N("adr", 1, 2, "ADR", "docs/architecture.md",
              "Quyết định đã chốt. Quyết định mới phải ghi ở đây trước khi giao code.", [("docs/architecture.md", None)]),
            N("research", 1, 3, "researcher", ".claude/agents/researcher.md",
              "Tra tài liệu, kiểm chứng hành vi công cụ bằng lệnh chỉ đọc.", [(".claude/agents/researcher.md", None)]),
            N("coder", 2, 0, "coder", ".claude/agents/coder.md",
              "Viết code + test theo task; mỗi lúc một coder, không worktree, không commit.",
              [(".claude/agents/coder.md", None), (SKILL, r"^## 1\. Code")]),
            N("doc", 2, 1, "doc-writer", ".claude/agents/doc-writer.md",
              "Chỉ đụng file .md, chạy song song với coder được.",
              [(".claude/agents/doc-writer.md", None), (SKILL, r"^## 2\. Tài liệu")]),
            N("qa", 3, 0, "qa-reviewer", ".claude/agents/qa-reviewer.md",
              "Đối chiếu ADR và checklist bảo mật, chỉ đọc. Mục \"Chặn\" → giao lại coder rồi QA lại.",
              [(".claude/agents/qa-reviewer.md", None), (SKILL, r"^## 3\. QA")]),
            N("checklist", 3, 1, "QA checklist", "references/qa-checklist.md",
              "Danh sách kiểm: secret, argv, SQL, file ghi ra, test thiếu, nối UI ↔ Core.",
              [(".claude/skills/ssh-desk-delivery/references/qa-checklist.md", None)]),
            N("check", 3, 2, "make check", "Makefile",
              "lint + build + test. Phải xanh trước khi báo xong.", [("Makefile", r"^check:")]),
            N("commit", 3, 3, "PM duyệt · commit", "SKILL.md · 4. PM duyệt",
              "Xem diff nhạy cảm, ghi \"Đã làm\" vào ADR, cập nhật plan.md / progress.md, commit có Co-Authored-By.",
              [(SKILL, r"^## 4\. PM duyệt")]),
        ],
        "edges": [
            ("claude", "main", ""), ("main", "advisor", "ý tưởng"), ("main", "pm", "việc đã chọn"),
            ("pm", "skill", ""), ("pm", "adr", "ghi ADR"), ("research", "adr", ""), ("pm", "coder", "giao task"),
            ("pm", "doc", ""), ("coder", "qa", "báo xong"), ("qa", "checklist", ""), ("checklist", "check", ""),
            ("check", "commit", "xanh"),
        ],
    },
]

GROUP_NAMES = {"SSHDesk": "Giao diện"}


def group_of(path):
    parts = path.split("/")
    if parts[0] == "Sources":
        if parts[1] == "SSHDeskCore":
            return "Core · " + parts[2]
        return GROUP_NAMES.get(parts[1], "Helper · " + parts[1])
    return "Tài liệu · cấu hình"


def resolve(pattern):
    if "*" not in pattern:
        return [pattern]
    return sorted(str(p.relative_to(ROOT)) for p in ROOT.glob(pattern) if p.is_file())


def block_end(lines, start, path):
    """Dòng cuối (0-based) của khối bắt đầu ở `start`."""
    if path.endswith(".md"):
        level = len(lines[start]) - len(lines[start].lstrip("#"))
        for i in range(start + 1, len(lines)):
            m = re.match(r"^(#+) ", lines[i])
            if m and len(m.group(1)) <= max(level, 1):
                return i - 1
        return len(lines) - 1
    if path == "Makefile":
        i = start
        while i + 1 < len(lines) and lines[i + 1].strip():
            i += 1
        return i
    depth, opened = 0, False
    for i in range(start, len(lines)):
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[i].split("//")[0])
        for ch in code:
            if ch == "{":
                depth, opened = depth + 1, True
            elif ch == "}":
                depth -= 1
        if opened and depth <= 0:
            return i
        if not opened and i - start > 40:
            return start
    return start


def doc_start(lines, start):
    i = start
    while i > 0 and lines[i - 1].strip().startswith(("///", "@", "//")):
        i -= 1
    return i


def main():
    texts, errors = {}, []

    def load(rel):
        if rel not in texts:
            texts[rel] = (ROOT / rel).read_text(encoding="utf-8")
        return texts[rel].split("\n")

    for view in VIEWS:
        ids = {n["id"] for n in view["nodes"]}
        for a, b, _ in view["edges"]:
            if a not in ids or b not in ids:
                errors.append(f"{view['id']}: cạnh {a} → {b} trỏ tới khối không có")
        seen = set()
        for n in view["nodes"]:
            slot = (n["lane"], n["row"], n["col"])
            if slot in seen:
                errors.append(f"{view['id']}/{n['id']}: trùng ô {slot}")
            seen.add(slot)
            refs = []
            for pattern, anchor in n.pop("refs"):
                hit = None
                for rel in resolve(pattern):
                    lines = load(rel)
                    if anchor is None:
                        hit = {"file": rel, "range": None}
                        break
                    for i, line in enumerate(lines):
                        if re.search(anchor, line):
                            hit = {"file": rel, "range": [doc_start(lines, i) + 1, block_end(lines, i, rel) + 1]}
                            break
                    if hit:
                        break
                if hit:
                    refs.append(hit)
                else:
                    errors.append(f"{view['id']}/{n['id']}: không khớp {pattern} ~ {anchor}")
            n["refs"] = refs
    if errors:
        sys.exit("Bản đồ lệch với code:\n  " + "\n  ".join(errors))

    used = {r["file"] for v in VIEWS for n in v["nodes"] for r in n["refs"]}
    files = {p: {"group": group_of(p), "text": texts[p]} for p in sorted(used)}
    data = {"root": str(ROOT), "date": datetime.date.today().isoformat(), "views": VIEWS, "files": files}
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = Path(__file__).with_name("template.html").read_text(encoding="utf-8").replace("/*__DATA__*/null", payload)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    n = sum(len(v["nodes"]) for v in VIEWS)
    print(f"Đã ghi {OUT.relative_to(ROOT)}: {len(VIEWS)} view, {n} khối, {len(files)} file, {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()

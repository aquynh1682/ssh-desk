"""Sinh 4 sơ đồ draw.io cho SSH Desk vào docs/diagrams/."""
import html
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)

FONT = "fontFamily=Helvetica;fontSize=12;"
C = {
    "ui": "fillColor=#dae8fc;strokeColor=#6c8ebf;",
    "core": "fillColor=#d5e8d4;strokeColor=#82b366;",
    "helper": "fillColor=#e1d5e7;strokeColor=#9673a6;",
    "store": "fillColor=#fff2cc;strokeColor=#d6b656;",
    "ext": "fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;",
    "secret": "fillColor=#f8cecc;strokeColor=#b85450;",
    "user": "fillColor=#ffe6cc;strokeColor=#d79b00;",
    "note": "fillColor=#ffffff;strokeColor=#999999;dashed=1;align=left;spacingLeft=8;",
}
BOX = "rounded=1;whiteSpace=wrap;html=1;arcSize=12;" + FONT
DIAMOND = "rhombus;whiteSpace=wrap;html=1;" + FONT
CYL = "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;size=8;" + FONT
GROUP = ("rounded=1;whiteSpace=wrap;html=1;arcSize=3;verticalAlign=top;align=left;"
         "spacingLeft=10;spacingTop=4;fontStyle=1;container=1;collapsible=0;" + FONT)
LANE = ("swimlane;html=1;startSize=30;horizontal=1;fontStyle=1;collapsible=0;"
        "swimlaneLine=1;" + FONT)
EDGE = ("edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;html=1;"
        "endArrow=block;endFill=1;fontSize=11;labelBackgroundColor=#ffffff;")
DASH = EDGE + "dashed=1;"
TITLE = "text;html=1;fontSize=20;fontStyle=1;align=left;verticalAlign=middle;"


def label(text):
    return html.escape(text, quote=False).replace("\n", "<br>")


class Page:
    def __init__(self, name):
        self.name = name
        self.cells = []

    def node(self, id, text, x, y, w, h, style, parent="1"):
        self.cells.append(
            f'<mxCell id="{id}" value={quoteattr(label(text))} style="{style}" '
            f'vertex="1" parent="{parent}"><mxGeometry x="{x}" y="{y}" '
            f'width="{w}" height="{h}" as="geometry"/></mxCell>')
        return id

    def edge(self, id, src, tgt, text="", style=EDGE, points=()):
        pts = ""
        if points:
            pts = "<Array as=\"points\">" + "".join(
                f'<mxPoint x="{x}" y="{y}"/>' for x, y in points) + "</Array>"
        self.cells.append(
            f'<mxCell id="{id}" value={quoteattr(label(text))} style="{style}" '
            f'edge="1" parent="1" source="{src}" target="{tgt}">'
            f'<mxGeometry relative="1" as="geometry">{pts}</mxGeometry></mxCell>')

    def write(self, filename):
        body = "".join(self.cells)
        xml = (
            '<mxfile host="drawio" type="device">'
            f'<diagram id="{filename}" name={quoteattr(self.name)}>'
            '<mxGraphModel grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
            'arrows="1" fold="1" page="0" pageScale="1" math="0" shadow="0">'
            '<root><mxCell id="0"/><mxCell id="1" parent="0"/>'
            f'{body}</root></mxGraphModel></diagram></mxfile>\n')
        (OUT / f"{filename}.drawio").write_text(xml, encoding="utf-8")


# ---------------------------------------------------------------- 1. Kiến trúc
def architecture():
    p = Page("Kiến trúc tổng thể")
    p.node("title", "SSH Desk — kiến trúc tổng thể", 40, 0, 900, 40, TITLE)
    OY = 60
    row = lambda i: OY + 45 + 72 * i  # noqa: E731
    H = 56

    # Lối vào
    p.node("user", "Người dùng", 40, row(1), 160, H, BOX + C["user"])
    p.node("url", "URL sshdesk://open\n(Alfred, Raycast, trình duyệt)", 40, row(4), 160, H + 8,
           BOX + C["user"])

    # UI
    ui = p.node("ui", "SSHDesk — UI SwiftUI (@Local, view mỏng)", 250, OY, 260, 600,
                GROUP + C["ui"] + "fillColor=#eef4fc;")
    ui_items = [
        ("ui_app", "AppModel (@Observable)"),
        ("ui_hosts", "Danh sách · Chi tiết · Form máy chủ"),
        ("ui_inv", "Nguồn máy chủ · Nhập Excel/CSV"),
        ("ui_browser", "Duyệt file kiểu Xftp · Hàng đợi"),
        ("ui_tunnel", "Port forward (-L)"),
        ("ui_monitor", "Monitor · Project Analyst"),
        ("ui_keys", "SSH Keys · Bộ đăng nhập"),
        ("ui_settings", "Cài đặt"),
    ]
    for i, (id, t) in enumerate(ui_items):
        p.node(id, t, 20, 45 + 66 * i, 220, 50, BOX + C["ui"], parent=ui)
    p.node("cli", "sshdesk-cli\nlist · open (DB chỉ đọc)", 270, row(8), 220, H, BOX + C["helper"])

    # Core
    CX = 570
    core = p.node("core", "SSHDeskCore — logic thuần, không import SwiftUI, có test", CX, OY,
                  520, 750, GROUP + C["core"] + "fillColor=#f1f8ef;")
    left = [
        ("c_conn", "ConnectionService\n(App: điều phối kết nối)"),
        ("c_transfer", "Transfer · TransferManager\nhàng đợi, scp qua PTY"),
        ("c_browser", "Browser · master ssh -M\nControlPath /tmp/sshdesk-<uid>"),
        ("c_tunnel", "Tunnel · ssh -N -L\n127.0.0.1 only"),
        ("c_monitor", "Monitor · Analyst\nlệnh chỉ đọc, BatchMode"),
        ("c_keys", "Keys · AgentKeyLister\nssh-add -L (chỉ public key)"),
        ("c_exchange", "Exchange\nxuất/nhập sshdesk-hosts JSON"),
        ("c_settings", "Settings"),
        ("c_cli", "CLI · HostResolver\nCLIOpenRequest"),
    ]
    right = [
        ("c_hosts", "Hosts · HostRepository\nDatabase (SQLite3, migration)"),
        ("c_sshcfg", "SSHConfig · SSHConfigWriter\nvalidate, quote, IdentityAgent"),
        ("c_warp", "Warp · WarpLauncher\nTabConfigRenderer, ZshQuoting"),
        ("c_proc", "Process · PTYProcess\nPromptDetector, AutofillPolicy"),
        ("c_cred", "Credentials · CredentialStore\nAutofillGatedCredentialStore"),
        ("c_inv", "Inventory · XLSX/CSV/JSON/Ansible\nInventorySync, AutoAdd"),
        ("c_metrics", "Metrics\nPrometheus / Zabbix client"),
        ("c_windows", "Windows · RDPFileRenderer\nSecretClipboard"),
    ]
    for i, (id, t) in enumerate(left):
        p.node(id, t, 15, 45 + 72 * i, 240, H, BOX + C["core"], parent=core)
    for i, (id, t) in enumerate(right):
        p.node(id, t, 265, 45 + 72 * i, 240, H, BOX + C["core"], parent=core)
    p.node("c_note",
           "Transfer, Browser, Tunnel, Monitor, Analyst, Keys đều chạy ssh/scp/sftp qua Process\n"
           "bằng executable + argv (không sh -c), luôn với -F <config app>.",
           15, 45 + 72 * 9 - 6, 490, 44, BOX + C["note"] + "fontSize=10;", parent=core)

    # Dữ liệu trên máy
    SX = 1150
    p.node("s_db", "sshdesk.sqlite\nApplication Support, 0700", SX, row(0) - 6, 240, H + 12,
           CYL + C["store"])
    p.node("s_sshcfg", "ssh/config (0600)\nsinh lại từ DB, ghi atomically", SX, row(1), 240, H,
           BOX + C["store"])
    p.node("s_tab", "~/.warp/tab_configs/\nsshdesk_<uuid>.toml", SX, row(2), 240, H,
           BOX + C["store"])
    p.node("s_kc", "Keychain\nlocal.sshdesk.sekey · .sealed", SX, row(4), 240, H,
           BOX + C["secret"])
    p.node("s_req", "requests/<uuid>.json (0600)\nhết hạn 30 giây", SX, row(8), 240, H,
           BOX + C["store"])

    # Công cụ ngoài
    EX = 1460
    p.node("e_usercfg", "~/.ssh/config của người dùng\n(chỉ Include, không sửa)", EX, row(1),
           240, H, BOX + C["ext"])
    p.node("e_warp", "Warp", EX, row(2), 240, H, BOX + C["ext"] + "fontStyle=1;")
    p.node("e_ssh", "/usr/bin/ssh · scp · sftp\nOpenSSH 10.3", EX, row(3), 240, H,
           BOX + C["ext"] + "fontStyle=1;")
    p.node("e_se", "Secure Enclave\n(khoá P-256, ECIES)", EX, row(4), 240, H, BOX + C["secret"])
    p.node("e_zip", "/usr/bin/unzip · zip\nenv rỗng, cap dung lượng", EX, row(5), 240, H,
           BOX + C["ext"])
    p.node("e_prom", "Prometheus / Zabbix\nHTTPS (TLS ≥ 1.2) / http nội bộ", EX, row(6), 240, H,
           BOX + C["ext"])
    p.node("e_rdp", "Windows App (RDP)", EX, row(7), 240, H, BOX + C["ext"])

    HX = 1790
    p.node("e_server", "Máy chủ từ xa", HX, row(3), 220, H, BOX + C["ext"] + "fontStyle=1;")
    helpers = p.node("helpers", "Target phụ (cùng package)", HX - 10, row(5) - 40, 240, 290,
                     GROUP + C["helper"] + "fillColor=#f5f0f8;")
    p.node("h_askpass", "sshdesk-askpass (ssh gọi qua\nSSH_ASKPASS, env chỉ tham chiếu)\nkiểm cha = /usr/bin/ssh", 10, 35,
           220, 64, BOX + C["helper"], parent=helpers)
    p.node("h_ctty", "sshdesk-ctty\nđặt controlling tty cho PTY", 10, 110, 220, 50,
           BOX + C["helper"], parent=helpers)
    p.node("h_kit", "AskpassKit · CredentialBackend\n(SE + ECIES, dùng chung)", 10, 172, 220,
           56, BOX + C["helper"], parent=helpers)

    # Cạnh
    p.edge("e1", "user", "ui", "dùng app")
    p.edge("e2", "url", "ui", "luôn hỏi xác nhận")
    p.edge("e3", "ui", "core", "chỉ gọi vào Core")
    p.edge("e4", "cli", "c_cli", "dùng Core")
    p.edge("e5", "cli", "ui", "mở sshdesk://cli?request=", DASH + "exitX=0.5;exitY=0;entryX=0.5;entryY=1;")
    p.edge("e6", "c_hosts", "s_db", "đọc / ghi")
    p.edge("e7", "c_sshcfg", "s_sshcfg", "ghi")
    p.edge("e8", "s_sshcfg", "e_usercfg", "Match all + Include", DASH)
    p.edge("e9", "c_warp", "s_tab", "ghi")
    p.edge("e10", "s_tab", "e_warp", "warp://tab_config/…")
    p.edge("e11", "e_warp", "e_ssh", "zsh chạy ssh -F")
    p.edge("e12", "c_proc", "e_ssh", "PTY, argv")
    p.edge("e13", "e_ssh", "e_server", "SSH / SFTP")
    p.edge("e14", "c_cred", "s_kc", "seal / open")
    p.edge("e15", "s_kc", "e_se", "ECDH", DASH)
    p.edge("e16", "c_inv", "e_zip", "đọc .xlsx")
    p.edge("e17", "c_metrics", "e_prom", "URLSession")
    p.edge("e18", "c_windows", "e_rdp", ".rdp + copy mật khẩu")
    p.edge("e19", "c_cli", "s_req", "CLI ghi · app đọc rồi xoá")
    p.edge("e20", "e_ssh", "h_askpass", "", DASH + "exitX=1;exitY=0.8;",
           points=[(1745, row(3) + 45), (1745, row(5) + 32)])

    # Chú thích màu
    lx, ly = 40, OY + 690
    p.node("lg", "Chú thích", lx, ly, 160, 20, "text;html=1;fontStyle=1;" + FONT)
    for i, (k, t) in enumerate([("ui", "UI"), ("core", "Core"), ("helper", "Executable phụ"),
                                ("store", "File app sở hữu"), ("secret", "Bí mật"),
                                ("ext", "Ngoài app")]):
        p.node(f"lg{i}", t, lx + (i % 2) * 90, ly + 26 + (i // 2) * 34, 84, 26,
               BOX + C[k] + "fontSize=10;")
    p.write("01-kien-truc")


# ---------------------------------------------------------- 2. Mở SSH trong Warp
def warp_flow():
    p = Page("Luồng mở SSH trong Warp")
    p.node("title", "Luồng mở SSH trong Warp (ADR-006, 007, 010)", 0, 0, 900, 40, TITLE)
    lanes = [("SSH Desk (app)", 520), ("File app sở hữu", 300), ("Warp + OpenSSH", 300),
             ("sshdesk-askpass", 520)]
    x = 0
    lx = []
    for i, (name, w) in enumerate(lanes):
        p.node(f"lane{i}", name, x, 50, w, 1460, LANE + ["fillColor=#eef4fc;",
               "fillColor=#fffbea;", "fillColor=#f5f5f5;", "fillColor=#f5f0f8;"][i])
        lx.append(x)
        x += w

    def cx(lane, w):
        return lx[lane] + (lanes[lane][1] - w) / 2

    W = 260
    p.node("a1", "Người dùng chọn hồ sơ\n→ \"Mở trong Warp\"", cx(0, W), 100, W, 56,
           BOX + C["user"])
    p.node("a2", "ConnectionService\nkiểm tra autofill_hold, jumpHost,\nmật khẩu đã lưu", cx(0, W),
           190, W, 70, BOX + C["core"])
    p.node("a3", "SSHConfigWriter sinh lại config\nvalidate: cấm newline, ký tự điều khiển",
           cx(0, W), 300, W, 60, BOX + C["core"])
    p.node("f1", "ssh/config (0600)\nHost sshdesk-<uuid> …\nMatch all\nInclude ~/.ssh/config",
           cx(1, 240), 285, 240, 90, BOX + C["store"])
    p.node("d1", "Có mật khẩu lưu,\nkhông bastion,\nkhông hold?", cx(0, 220), 400, 220, 120,
           DIAMOND + C["core"])
    p.node("a4y", "Lệnh kèm\nSSH_ASKPASS=<helper>\nSSH_ASKPASS_REQUIRE=force\n"
           "SSHDESK_HOST_REF=<ref>\n-o BatchMode=no", 20, 570, 230, 100, BOX + C["core"])
    p.node("a4n", "Lệnh ssh thường\n/usr/bin/ssh -F <config> <alias>\n(bastion → báo nhập tay)",
           270, 570, 230, 100, BOX + C["core"])
    p.node("a5", "WarpTabConfigRenderer\nquote cho zsh + escape TOML\n(tên hồ sơ không vào lệnh)",
           cx(0, W), 720, W, 66, BOX + C["core"])
    p.node("f2", "~/.warp/tab_configs/\nsshdesk_<uuid>.toml", cx(1, 240), 723, 240, 60,
           BOX + C["store"])
    p.node("a6", "NSWorkspace.open\nwarp://tab_config/sshdesk_<uuid>", cx(0, W), 830, W, 56,
           BOX + C["core"])
    p.node("d2", "Warp mở được?", cx(0, 180), 930, 180, 90, DIAMOND + C["core"])
    p.node("a7", "Fallback:\nnút \"Copy lệnh SSH\"", cx(0, 220), 1080, 220, 56, BOX + C["note"]
           + "align=center;spacingLeft=0;")
    p.node("w1", "Warp mở tab mới\nzsh chạy commands", cx(2, 240), 947, 240, 56, BOX + C["ext"])
    p.node("w2", "/usr/bin/ssh -F <đường dẫn tuyệt đối>\n<alias>", cx(2, 240), 1060, 240, 60,
           BOX + C["ext"] + "fontStyle=1;")
    p.node("k1", "sshdesk-askpass\nkiểm tra cha = /usr/bin/ssh\nAskpassDecision phân loại prompt",
           cx(3, 300), 1053, 300, 74, BOX + C["helper"])
    p.node("d3", "Prompt mật khẩu\nđúng host,\nlần đầu?", cx(3, 200), 1160, 200, 110,
           DIAMOND + C["helper"])
    p.node("k2", "Đọc kho qua CredentialStore\nSecure Enclave mở ciphertext\n→ in ra stdout cho ssh",
           lx[3] + 20, 1310, 230, 80, BOX + C["secret"])
    p.node("k3", "Hỏi người dùng trên /dev/tty\n(host key, OTP, passphrase,\nmật khẩu lần 2)",
           lx[3] + 270, 1310, 230, 80, BOX + C["helper"])
    p.node("f3", "Keychain\nlocal.sshdesk.sealed/<ref>", lx[3] + 20, 1430, 230, 60,
           BOX + C["secret"])
    p.node("w3", "Phiên SSH trên máy chủ", cx(2, 240), 1430, 240, 50,
           BOX + C["ext"] + "fontStyle=1;")

    p.edge("x1", "a1", "a2")
    p.edge("x2", "a2", "a3")
    p.edge("x3", "a3", "f1", "ghi atomically")
    p.edge("x4", "a3", "d1")
    p.edge("x5", "d1", "a4y", "Có", EDGE + "exitX=0;exitY=0.5;")
    p.edge("x6", "d1", "a4n", "Không", EDGE + "exitX=1;exitY=0.5;")
    p.edge("x7", "a4y", "a5")
    p.edge("x8", "a4n", "a5")
    p.edge("x9", "a5", "f2", "ghi (chỉ sshdesk_*)")
    p.edge("x10", "a5", "a6")
    p.edge("x11", "a6", "d2")
    p.edge("x12", "d2", "w1", "Có")
    p.edge("x13", "d2", "a7", "Không")
    p.edge("x14", "f2", "w1", "Warp đọc", DASH)
    p.edge("x15", "w1", "w2")
    p.edge("x17", "w2", "k1", "prompt")
    p.edge("x18", "k1", "d3")
    p.edge("x19", "d3", "k2", "Có")
    p.edge("x20", "d3", "k3", "Không")
    p.edge("x21", "k2", "f3", "đọc theo tham chiếu", DASH)
    p.edge("x22", "w2", "w3", "đăng nhập")
    p.write("02-luong-mo-warp")


# --------------------------------------------------------- 3. Nhập Excel / CSV
def excel_flow():
    p = Page("Luồng nhập Excel/CSV")
    p.node("title", "Luồng nhập máy chủ từ Excel / CSV (ADR-026, 026b, 031)", 0, 0, 1000, 40,
           TITLE)
    MX, MW = 380, 300
    mid = MX + MW / 2
    p.node("s1", "Chọn file .xlsx / .csv\nhoặc nguồn có thay đổi (mtime + SHA-256)", MX, 70, MW,
           56, BOX + C["user"])
    p.node("s2", "Đọc an toàn\nXLSX: unzip -Z1 kiểm tên, unzip -p (argv, env rỗng),\n"
           "cap 50/100 MB, chặn <!DOCTYPE>\nCSV: BOM UTF-8/UTF-16, ≤ 5 MB", MX - 20, 160,
           MW + 40, 90, BOX + C["core"])
    p.node("d1", "Đúng file mẫu?\n(sshdesk-template v1)", mid - 125, 290, 250, 100,
           DIAMOND + C["core"])
    p.node("s3", "Ghép cột\nđoán theo tiêu đề Việt/Anh,\nchọn cột khoá (external_id)", 780, 305,
           260, 70, BOX + C["ui"])
    p.node("d2", "Có cột giống\nmật khẩu?", mid - 110, 430, 220, 100, DIAMOND + C["core"])
    p.node("s4", "Mặc định BỎ QUA cột\nTuỳ chọn \"Lưu mật khẩu từ cột X\"\n(TẮT, phải bật lại mỗi lần)"
           "\n→ SecretColumnValues (che mọi mô tả)", 20, 435, 290, 90, BOX + C["secret"])
    p.node("s5", "Validate từng dòng\n(IP, Port 1–65535, Môi trường, trùng tên…)\n"
           "dòng lỗi bị bỏ, dòng tốt vẫn nhập", MX, 570, MW, 70, BOX + C["core"])
    p.node("s6", "InventorySync lập kế hoạch\nthêm · đổi (cũ → mới) · không còn trong nguồn · lỗi",
           MX - 20, 675, MW + 40, 56, BOX + C["core"])
    p.node("d3", "Phát hiện tự động\n+ chỉ có thêm mới\n+ \"Tự thêm máy mới\" bật?", mid - 140,
           770, 280, 120, DIAMOND + C["core"])
    p.node("s7", "Tự áp dụng\n(không lưu mật khẩu)", 40, 795, 220, 70, BOX + C["core"])
    p.node("s8", "Thông báo \"Đã thêm N máy\"\n[Xem]  [Hoàn tác]", 40, 920, 220, 56,
           BOX + C["ui"])
    p.node("s8b", "Hoàn tác: xoá host chưa bị sửa,\nchưa có mật khẩu/forward;\ntắt \"Tự thêm máy mới\"",
           25, 1020, 250, 70, BOX + C["core"])
    p.node("s9", "Màn xem trước\nmật khẩu chỉ hiện ••••\nsố host sẽ lưu / đã có mật khẩu", MX,
           930, MW, 70, BOX + C["ui"])
    p.node("s10", "Áp dụng → hộp xác nhận\n\"Lưu mật khẩu cho N máy vào kho mã hoá?\"", MX, 1040,
           MW, 60, BOX + C["user"])
    p.node("s11", "Một transaction SQLite (lỗi → không ghi gì)\nđịa chỉ đổi → autofill_hold = 1",
           MX - 20, 1140, MW + 40, 60, BOX + C["store"])
    p.node("s12", "Lưu mật khẩu qua CredentialStore → Secure Enclave\nghi 0 buffer (memset_s)",
           MX - 20, 1240, MW + 40, 60, BOX + C["secret"])
    p.node("s13", "Sinh lại ssh/config\nnhắc xoá / bảo vệ file Excel gốc", MX, 1340, MW, 56,
           BOX + C["core"])
    p.node("note", "Không bao giờ:\n• tự xoá host (chỉ đánh dấu \"không còn trong nguồn\")\n"
           "• đưa mật khẩu vào DB, log, preview, config_json\n"
           "• tự áp dụng khi có sửa / biến mất / lỗi\n• lưu mật khẩu khi đồng bộ tự động",
           760, 1030, 330, 110, BOX + C["note"])

    p.edge("y1", "s1", "s2")
    p.edge("y2", "s2", "d1")
    p.edge("y3", "d1", "d2", "Có — bỏ ghép cột")
    p.edge("y4", "d1", "s3", "Không")
    p.edge("y5", "s3", "d2", "", EDGE + "exitX=0.5;exitY=1;entryX=1;entryY=0.5;")
    p.edge("y6", "d2", "s4", "Có")
    p.edge("y7", "d2", "s5", "Không")
    p.edge("y8", "s4", "s5", "", EDGE + "exitX=0.5;exitY=1;entryX=0;entryY=0.5;")
    p.edge("y9", "s5", "s6")
    p.edge("y10", "s6", "d3")
    p.edge("y11", "d3", "s7", "Có")
    p.edge("y12", "d3", "s9", "Không")
    p.edge("y13", "s7", "s11", "", EDGE + "exitX=1;exitY=0.75;entryX=0;entryY=0.5;",
           points=[(310, 848), (310, 1170)])
    p.edge("y14", "s7", "s8", "sau khi áp dụng", DASH)
    p.edge("y15", "s8", "s8b", "Hoàn tác", DASH)
    p.edge("y16", "s9", "s10")
    p.edge("y17", "s10", "s11")
    p.edge("y18", "s11", "s12", "nếu bật lưu mật khẩu")
    p.edge("y19", "s12", "s13")
    p.write("03-luong-nhap-excel")


# ------------------------------------------------------------- 4. Đội agent
def team_flow():
    p = Page("Quy trình đội agent")
    p.node("title", "Quy trình đội agent (skill ssh-desk-delivery)", 0, 0, 900, 40, TITLE)
    W, H = 210, 64
    p.node("user", "Người dùng\nyêu cầu · chọn ý tưởng · thử app", 0, 200, 190, H, BOX + C["user"])
    p.node("main", "Agent chính (Opus)\nPM: chốt quyết định,\nreview diff, approve", 250, 195,
           W, H + 10, BOX + C["core"] + "fontStyle=1;")
    p.node("advisor", "product-advisor (Fable)\ný tưởng, roadmap\n→ docs/ideas.md", 250, 50, W,
           H, BOX + C["helper"])
    p.node("research", "researcher (Haiku)\ntra tài liệu, lệnh chỉ đọc", 250, 380, W, H - 8,
           BOX + C["ext"])
    p.node("pm", "pm (Opus)\nđiều phối bước 0–4", 520, 200, W, H, BOX + C["core"])
    p.node("adr", "docs/architecture.md\nghi ADR trước khi giao code", 520, 50, W, H,
           BOX + C["store"])
    p.node("coder", "coder (Sonnet)\ncode + test trên nhánh,\nmỗi lúc 1 coder", 790, 200, W, H,
           BOX + C["ui"])
    p.node("doc", "doc-writer (Sonnet)\nchỉ file .md,\nchạy song song coder", 790, 480, W, H,
           BOX + C["ui"])
    p.node("qa", "qa-reviewer (Sonnet)\nchecklist bảo mật / ADR,\nchỉ đọc", 1050, 200, W, H,
           BOX + C["secret"])
    p.node("dqa", "QA \"Chặn\"?", 1320, 187, 160, 90, DIAMOND + C["secret"])
    p.node("dcheck", "make check xanh\n+ PM duyệt diff?", 1310, 330, 180, 110, DIAMOND + C["core"])
    p.node("commit", "Commit (Co-Authored-By)\ncập nhật ADR \"Đã làm\",\nplan.md, progress.md",
           1295, 480, W, H + 6, BOX + C["store"])
    p.node("rules", "Quy tắc\n• Worktree tạo từ main → coder làm thẳng trên nhánh\n"
           "• Agent không nói chuyện với nhau; PM chuyển tiếp\n"
           "• Push / mở PR chỉ khi người dùng yêu cầu\n"
           "• Hết hạn mức / bị từ chối quyền → ghi progress.md, báo người dùng",
           0, 600, 520, 100, BOX + C["note"])

    p.edge("t1", "user", "main", "yêu cầu")
    p.edge("t2", "main", "advisor", "xin ý tưởng", EDGE + "exitX=0.3;exitY=0;entryX=0.3;entryY=1;")
    p.edge("t3", "advisor", "user", "đề xuất để chọn", DASH + "exitX=0;exitY=0.5;entryX=0.5;entryY=0;",
           points=[(95, 82)])
    p.edge("t4", "main", "pm", "việc đã chọn")
    p.edge("t5", "pm", "adr", "ghi ADR")
    p.edge("t6", "pm", "coder", "giao task")
    p.edge("t7", "adr", "coder", "đọc ADR", DASH + "entryX=0.25;entryY=0;",
           points=[(842, 82)])
    p.edge("t8", "coder", "qa", "báo xong")
    p.edge("t9", "qa", "dqa")
    p.edge("t10", "dqa", "coder", "Có → sửa", EDGE + "exitX=0.5;exitY=0;entryX=0.75;entryY=0;",
           points=[(1400, 150), (947, 150)])
    p.edge("t11", "dqa", "dcheck", "Không")
    p.edge("t12", "dcheck", "coder", "Không", EDGE + "exitX=0;exitY=0.5;entryX=0.5;entryY=1;",
           points=[(895, 385)])
    p.edge("t13", "dcheck", "commit", "Có")
    p.edge("t14", "pm", "doc", "giao tài liệu", DASH + "exitX=0.5;exitY=1;entryX=0;entryY=0.5;",
           points=[(625, 512)])
    p.edge("t15", "doc", "commit")
    p.edge("t16", "research", "pm", "kết quả kiểm chứng", DASH + "exitX=1;exitY=0.5;entryX=0.3;entryY=1;",
           points=[(583, 408)])
    p.edge("t17", "commit", "user", "báo kết quả, nhờ thử", DASH + "exitX=0.5;exitY=1;entryX=0;entryY=0.5;",
           points=[(1400, 740), (-30, 740), (-30, 232)])
    p.write("04-quy-trinh-agent")


architecture()
warp_flow()
excel_flow()
team_flow()
print("ok")

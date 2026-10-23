#!/usr/bin/env bash
# Đóng gói SSH Desk thành app bundle và ký (chứng chỉ ổn định nếu có SSHDESK_SIGN_IDENTITY, không thì ad-hoc).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/SSH Desk.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SSHDesk" "$APP/Contents/MacOS/SSHDesk"
# Helper gán controlling tty cho PTYProcess; phải nằm cạnh executable chính.
cp "$BIN_DIR/sshdesk-ctty" "$APP/Contents/MacOS/sshdesk-ctty"
# Helper SSH_ASKPASS (đăng nhập bằng password đã lưu trong Keychain); ConnectionService tìm cạnh executable chính.
cp "$BIN_DIR/sshdesk-askpass" "$APP/Contents/MacOS/sshdesk-askpass"

# CLI `sshdesk` (ADR-025): target SwiftPM tên sshdesk-cli, cài thành Contents/Helpers/sshdesk (không đặt cạnh
# SSHDesk trong MacOS vì APFS không phân biệt hoa thường). Người dùng tự tạo symlink vào PATH.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/sshdesk-cli" "$APP/Contents/Helpers/sshdesk"

# Resource bundle của SwiftPM (logo ở thanh tiêu đề). AppLogo.swift tìm ở Contents/Resources.
mkdir -p "$APP/Contents/Resources"
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# AppIcon.icns: sinh từ Resources/AppIcon.png (nguồn đã trong suốt, xem scripts/make-app-icon.swift).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
make_icon() { # <kích thước px> <tên file>
    sips -z "$1" "$1" Resources/AppIcon.png --out "$ICONSET/$2" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.sshdesk.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>SSH Desk</string>
    <key>CFBundleExecutable</key>
    <string>SSHDesk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- URL scheme sshdesk:// (ADR-025). App chỉ nhận open?id|name và cli?request, luôn qua kiểm tra trong Core. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>local.sshdesk.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>sshdesk</string>
            </array>
        </dict>
    </array>
    <!-- ADR-028b: cho http tới tên miền nội bộ (nguồn số liệu). NSAllowsArbitraryLoads chỉ có tác dụng khi KHÔNG có
         NSAllowsLocalNetworking / NSAllowsArbitraryLoadsInWebContent / ForMedia (macOS 10.12+ bỏ qua nó nếu có các khoá đó)
         nên chỉ khai báo đúng một khoá này. Tài liệu Apple:
         https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads
         (https vẫn kiểm chứng chỉ; TLS tối thiểu 1.2 do MetricsTransport tự đặt vì ATS không còn ép.) -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <!-- Kiểu kéo thả nội bộ giữa hai khung của màn Truyền file (BrowserDragPayload.typeIdentifier). -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>local.sshdesk.browser-items</string>
            <key>UTTypeDescription</key>
            <string>Mục kéo thả của SSH Desk</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ký (ADR-023). SSHDESK_SIGN_IDENTITY = tên chứng chỉ Code Signing do người dùng tự tạo.
# Có chứng chỉ ổn định thì designated requirement không đổi giữa các lần build (ACL Keychain không hỏi lại).
# Không có/không tìm thấy -> ký ad-hoc kèm cảnh báo. Không --deep, không hardened runtime.
SIGN_ID="${SSHDESK_SIGN_IDENTITY:-}"
if [ -n "$SIGN_ID" ]; then
    # Cấm ký tự điều khiển C0/DEL (tr) và C1 U+0080–U+009F (UTF-8 C2 80..9F).
    if [ "$(printf '%s' "$SIGN_ID" | LC_ALL=C tr -cd '[:cntrl:]' | wc -c)" -ne 0 ] ||
        printf '%s' "$SIGN_ID" | LC_ALL=C grep -q $'\xc2[\x80-\x9f]'; then
        echo "LỖI: SSHDESK_SIGN_IDENTITY chứa ký tự điều khiển/xuống dòng." >&2
        exit 1
    fi
    # Chỉ đọc. Không dùng -v: chứng chỉ tự ký hiện kèm CSSMERR_TP_NOT_TRUSTED nhưng codesign vẫn ký được.
    # Giá trị có thể là tên chính xác hoặc SHA-1 (40 hex, khớp cột hash) khi có nhiều chứng chỉ trùng tên.
    MATCHES=0
    LIST_OK=1
    IDENTITIES="$(security find-identity -p codesigning 2>/dev/null)" || LIST_OK=0
    if [ "$LIST_OK" -eq 1 ]; then
        IS_SHA=0
        case "$SIGN_ID" in
        *[!0-9A-Fa-f]*) ;;
        *) [ "${#SIGN_ID}" -eq 40 ] && IS_SHA=1 ;;
        esac
        SIGN_ID_UP="$(printf '%s' "$SIGN_ID" | LC_ALL=C tr 'a-f' 'A-F')"
        while IFS= read -r line; do
            name="${line#*\"}"
            [ "$name" = "$line" ] && continue
            name="${name%\"*}"
            read -r _idx hash _rest <<<"$line"
            if [ "$name" = "$SIGN_ID" ] || { [ "$IS_SHA" -eq 1 ] && [ "$hash" = "$SIGN_ID_UP" ]; }; then
                MATCHES=$((MATCHES + 1))
            fi
        done <<<"$IDENTITIES"
    fi
    if [ "$LIST_OK" -ne 1 ]; then
        echo "CẢNH BÁO: không đọc được danh sách chứng chỉ (Keychain khoá?) — ký ad-hoc; Keychain có thể hỏi quyền lại sau mỗi lần build." >&2
        SIGN_ID=""
    elif [ "$MATCHES" -gt 1 ]; then
        echo "CẢNH BÁO: có $MATCHES chứng chỉ trùng tên \"$SIGN_ID\" — đặt SSHDESK_SIGN_IDENTITY bằng SHA-1 (security find-identity -p codesigning) — ký ad-hoc." >&2
        SIGN_ID=""
    elif [ "$MATCHES" -eq 0 ]; then
        echo "CẢNH BÁO: không tìm thấy chứng chỉ ký \"$SIGN_ID\" (security find-identity -p codesigning) — ký ad-hoc; Keychain có thể hỏi quyền lại sau mỗi lần build." >&2
        SIGN_ID=""
    fi
else
    echo "CẢNH BÁO: chưa đặt SSHDESK_SIGN_IDENTITY — ký ad-hoc; cdhash đổi mỗi lần build nên Keychain có thể hỏi quyền lại." >&2
fi

sign() { # <đường dẫn> <identifier cố định>
    if [ -n "$SIGN_ID" ]; then
        codesign --force --sign "$SIGN_ID" --identifier "$2" "$1" || {
            echo "LỖI: codesign thất bại với chứng chỉ đã chọn. Kiểm tra quyền truy cập khoá riêng (Keychain Access → chứng chỉ → Always Allow) và trạng thái tin cậy (Always Trust cho Code Signing)." >&2
            exit 1
        }
    else
        codesign --force --sign - --identifier "$2" "$1"
    fi
}
# Helper trước, app sau.
sign "$APP/Contents/MacOS/sshdesk-ctty" local.sshdesk.ctty
sign "$APP/Contents/MacOS/sshdesk-askpass" local.sshdesk.askpass
sign "$APP/Contents/Helpers/sshdesk" local.sshdesk.cli
sign "$APP" local.sshdesk.app
if [ -n "$SIGN_ID" ]; then
    echo "Designated requirement:"
    codesign -d -r- "$APP"
fi
echo "Đã tạo $APP"

#!/usr/bin/env bash
# Đóng gói SSH Desk thành app bundle và ký ad-hoc.
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

codesign --force --sign - "$APP/Contents/MacOS/sshdesk-ctty"
codesign --force --sign - "$APP/Contents/MacOS/sshdesk-askpass"
codesign --force --sign - "$APP"
echo "Đã tạo $APP"

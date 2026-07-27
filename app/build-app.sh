#!/bin/bash
# Build ShellShot.app and install to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# self-contained Python sidecar (PyInstaller)
SIDECAR_DIST="../prototype/dist/shellshot-sidecar"
# Rebuild when the source is newer, or the app ships a stale sidecar.
if [ ! -x "$SIDECAR_DIST/shellshot-sidecar" ] \
   || [ ../prototype/shellshot.py -nt "$SIDECAR_DIST/shellshot-sidecar" ]; then
    echo "Building sidecar with PyInstaller..."
    ../prototype/.venv/bin/pyinstaller --onedir --name shellshot-sidecar \
        --noconfirm --log-level WARN \
        --distpath ../prototype/dist --workpath ../prototype/build \
        --specpath ../prototype ../prototype/shellshot.py
fi

APP=".build/ShellShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ShellShot</string>
    <key>CFBundleDisplayName</key>     <string>ShellShot</string>
    <key>CFBundleIdentifier</key>      <string>com.apiant.shellshot</string>
    <key>CFBundleExecutable</key>      <string>ShellShot</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.2.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
</dict>
</plist>
EOF

mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SIDECAR_DIST" "$APP/Contents/Resources/sidecar"
cp .build/release/ShellShot "$APP/Contents/MacOS/ShellShot"
codesign --force --sign - "$APP"

rm -rf /Applications/ShellShot.app
cp -R "$APP" /Applications/ShellShot.app
echo "Installed /Applications/ShellShot.app"

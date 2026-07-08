#!/bin/bash
# swift build → 包成 LiveSubtitle.app(Info.plist + ad-hoc 签名),供真机运行/授权
set -e
cd "$(dirname "$0")/.."
CONF="${1:-debug}"
swift build -c "$CONF"
BIN=".build/$CONF/LiveSubtitle"
APP="build/LiveSubtitle.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LiveSubtitle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LiveSubtitle</string>
  <key>CFBundleIdentifier</key><string>com.livesubtitle.app</string>
  <key>CFBundleName</key><string>LiveSubtitle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>LiveSubtitle 采集系统音频用于实时中文字幕(仅音频)。</string>
  <key>NSMicrophoneUsageDescription</key><string>LiveSubtitle 采集麦克风用于识别你的发言。</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built: $APP"

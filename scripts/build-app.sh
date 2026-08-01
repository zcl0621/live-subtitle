#!/bin/bash
# swift build → 包成 LiveSubtitle.app(Info.plist + ad-hoc 签名),供真机运行/授权
set -e
cd "$(dirname "$0")/.."
CONF="${1:-debug}"
swift build -c "$CONF"
BIN=".build/$CONF/LiveSubtitle"
APP="build/LiveSubtitle.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveSubtitle"

# 应用图标:缺失时用 scripts/make-icon.swift 现画(bars / cjk / mixed)
# 换风格: rm build/AppIcon.icns && ICON_STYLE=bars bash scripts/build-app.sh
ICON_STYLE="${ICON_STYLE:-cjk}"
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build "$ICON_STYLE" >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LiveSubtitle</string>
  <key>CFBundleIdentifier</key><string>com.livesubtitle.app</string>
  <key>CFBundleName</key><string>LiveSubtitle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSScreenCaptureUsageDescription</key><string>LiveSubtitle 采集系统音频用于实时中文字幕(仅音频)。</string>
  <key>NSMicrophoneUsageDescription</key><string>LiveSubtitle 采集麦克风用于识别你的发言。</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built: $APP"

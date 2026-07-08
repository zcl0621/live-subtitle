#!/bin/bash
# 把 P3 探针打成 .app bundle(带屏录权限描述)+ ad-hoc 签名
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/tmp/P3Probe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Info.plist(关键:NSScreenCaptureUsageDescription + 稳定 bundle id 让 TCC 记住授权)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>P3Probe</string>
  <key>CFBundleIdentifier</key><string>com.livesubtitle.p3probe</string>
  <key>CFBundleName</key><string>P3Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSScreenCaptureUsageDescription</key><string>LiveSubtitle 探针:采集系统音频以做实时字幕(仅音频)。</string>
</dict>
</plist>
PLIST

echo "编译..."
swiftc -target arm64-apple-macos26.0 -parse-as-library \
  "$DIR/main.swift" -o "$APP/Contents/MacOS/P3Probe"

echo "ad-hoc 签名..."
codesign --force --sign - "$APP"

echo "构建完成:$APP"
echo "运行:$APP/Contents/MacOS/P3Probe"

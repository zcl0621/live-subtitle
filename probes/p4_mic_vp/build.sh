#!/bin/bash
# 把 P4 探针打成 .app bundle(带麦克风权限描述)+ ad-hoc 签名
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/../p4_mic_vp.swift"
APP="/tmp/P4Probe.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>P4Probe</string>
  <key>CFBundleIdentifier</key><string>com.livesubtitle.p4probe</string>
  <key>CFBundleName</key><string>P4Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSMicrophoneUsageDescription</key><string>LiveSubtitle 探针:采集麦克风做实时字幕并验证回声消除。</string>
</dict>
</plist>
PLIST

echo "编译..."
swiftc -target arm64-apple-macos26.0 -parse-as-library "$SRC" -o "$APP/Contents/MacOS/P4Probe"
echo "ad-hoc 签名..."
codesign --force --sign - "$APP"
echo "构建完成:$APP"

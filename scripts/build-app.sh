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
# 签名:优先用固定的自签名证书,退回 ad-hoc。
#
# 为什么要在意:ad-hoc 签名的 designated requirement **就是二进制的 CDHash**
# (`codesign -d -r-` 可见),每次重新打包 CDHash 都变 → TCC 认为换了个程序 →
# 麦克风/屏幕录制授权全部作废、下次启动重新弹窗。开发期每天重打十几次包,就会
# "每次启动弹很多次"。换成固定证书后 designated requirement 锚在证书上,重打包不影响授权。
#
# 造证书(一次性,需要你自己在 GUI 里做,脚本不碰你的钥匙串):
#   钥匙串访问 → 菜单「证书助理」→「创建证书…」
#   名称 LiveSubtitle Dev / 身份类型 自签名根证书 / 证书类型 代码签名 → 创建
SIGN_ID="${LS_SIGN_ID:-LiveSubtitle Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1
  echo "signed: $SIGN_ID(固定身份,重打包不会掉授权)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "signed: ad-hoc ⚠️ 每次重打包都会掉 TCC 授权、重新弹权限框"
  echo "        造一个「$SIGN_ID」代码签名证书可免除(做法见 scripts/build-app.sh 注释)"
fi
echo "built: $APP"

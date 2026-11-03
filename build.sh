#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ZoomDraw"
BUNDLE_ID="com.zoomdraw.app"
VERSION="2.6.0"
ARCH=$(uname -m)

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> 1/5 清理旧产物"
rm -rf "$DIST_DIR"/*.app "$DIST_DIR"/*.dmg "$DIST_DIR/_stage" "$DIST_DIR/AppIcon.iconset"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> 2/5 编译 release"
cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"
EXEC_PATH="$DIST_DIR/$APP_NAME"
xcrun swiftc -O \
    -framework AppKit -framework Carbon -framework ScreenCaptureKit \
    -framework AVFoundation -framework CoreMedia -framework ImageIO \
    -framework QuickLookThumbnailing \
    -o "$EXEC_PATH" \
    Sources/ZoomDraw/*.swift

echo "==> 3/5 组装 .app bundle"
cp "$EXEC_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# 生成简易图标（PDF 矢量符号）转 icns（如有 sips & iconutil）
ICONSET="$DIST_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
PNG_TMP="$DIST_DIR/_icon.png"
# 用 SF Symbol 风格的简单 PNG（通过 Swift 一行生成）—— 画笔图标
/usr/bin/swift - <<EOF || true
import AppKit
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// 1) 圆角背景（紫到粉的渐变）
let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 220, yRadius: 220)
bg.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.97, alpha: 1),
    NSColor(calibratedRed: 0.99, green: 0.36, blue: 0.55, alpha: 1)
])!
grad.draw(in: NSRect(origin: .zero, size: size), angle: -45)

// 2) 倾斜的画笔（45° 从左下到右上）
let ctx = NSGraphicsContext.current!.cgContext
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: .pi / 4) // 45°
ctx.translateBy(x: -512, y: -512)

// 笔杆（深色金属圆角矩形）
let body = NSBezierPath(roundedRect: NSRect(x: 290, y: 470, width: 360, height: 90), xRadius: 18, yRadius: 18)
NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
body.fill()
// 笔杆高光
let hi = NSBezierPath(roundedRect: NSRect(x: 300, y: 540, width: 340, height: 14), xRadius: 7, yRadius: 7)
NSColor.white.withAlphaComponent(0.18).setFill()
hi.fill()
// 金属箍
let ferrule = NSBezierPath(roundedRect: NSRect(x: 640, y: 462, width: 50, height: 106), xRadius: 8, yRadius: 8)
NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
ferrule.fill()

// 笔尖（三角形，带颜色）
let tip = NSBezierPath()
tip.move(to: NSPoint(x: 690, y: 462))
tip.line(to: NSPoint(x: 690, y: 568))
tip.line(to: NSPoint(x: 800, y: 515))
tip.close()
NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.20, alpha: 1).setFill()
tip.fill()
// 笔尖暗角
let tipDark = NSBezierPath()
tipDark.move(to: NSPoint(x: 690, y: 462))
tipDark.line(to: NSPoint(x: 690, y: 488))
tipDark.line(to: NSPoint(x: 800, y: 515))
tipDark.close()
NSColor.black.withAlphaComponent(0.18).setFill()
tipDark.fill()

ctx.restoreGState()

// 3) 笔触墨迹（随手画一条波浪线，强化"标注"语义）
let stroke = NSBezierPath()
stroke.move(to: NSPoint(x: 220, y: 280))
stroke.curve(to: NSPoint(x: 520, y: 320),
             controlPoint1: NSPoint(x: 320, y: 380),
             controlPoint2: NSPoint(x: 420, y: 220))
stroke.curve(to: NSPoint(x: 800, y: 300),
             controlPoint1: NSPoint(x: 620, y: 420),
             controlPoint2: NSPoint(x: 720, y: 220))
stroke.lineWidth = 36
stroke.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.92).setStroke()
stroke.stroke()

img.unlockFocus()
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: "$PNG_TMP"))
EOF

if [[ -f "$PNG_TMP" ]] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
    for sz in 16 32 64 128 256 512 1024; do
        sips -z "$sz" "$sz" "$PNG_TMP" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    done
    # 复制 @2x
    cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
    iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns" || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist"
fi
rm -rf "$ICONSET" "$PNG_TMP"

# 临时签名（ad-hoc），让 Gatekeeper 第一次能够运行
codesign --force --deep --sign - "$APP_DIR" || true

echo "==> 4/5 验证 .app"
ls -la "$APP_DIR/Contents/MacOS"
plutil -lint "$CONTENTS/Info.plist"

echo "==> 5/5 制作 DMG"
DMG_TMP="$DIST_DIR/_tmp.dmg"
DMG_VOL="$APP_NAME"
STAGE="$DIST_DIR/_stage"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$DMG_VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE" "$DMG_TMP"

echo ""
echo "✅ 构建完成"
echo "  App : $APP_DIR"
echo "  DMG : $DMG_PATH"

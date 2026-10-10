#!/bin/zsh
set -eu
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/work/module-cache"
mkdir -p outputs work/module-cache
if [ -f Assets/AppLogo-source.png ]; then
    swift -module-cache-path "$TASK_ROOT/work/module-cache" scripts/build-icon.swift Assets/AppLogo-source.png Assets/AppIcon.icns
fi
swift build -c release --disable-sandbox --cache-path work/swift-cache --config-path work/swift-config --security-path work/swift-security
APP_DIR="$TASK_ROOT/outputs/AI转SVG.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Samples"
cp .build/release/StickSVG "$APP_DIR/Contents/MacOS/StickSVG"
cp Fixtures/p0941.ai "$APP_DIR/Contents/Resources/Samples/p0941.ai"
cp Fixtures/readme_en.html Fixtures/readme_japanese.html "$APP_DIR/Contents/Resources/Samples/"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"
cp Assets/AppIcon.png "$APP_DIR/Contents/Resources/AppLogo.png"
if [ -f Assets/AppIcon.icns ]; then cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$TASK_ROOT/outputs/AI转SVG-Mac.zip"
print "App ready: $APP_DIR"

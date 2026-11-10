#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR="$PWD/target"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache/swift"
cargo build --release --offline
swift build --package-path apps/macos --disable-sandbox --configuration release --scratch-path "$PWD/.build-cache/package"
app="$PWD/dist/CLOUDSWAP.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
cp .build-cache/package/release/CloudSwap "$app/Contents/MacOS/CLOUDSWAP"
cp target/release/cloudswap-lab "$app/Contents/Helpers/"
cp .build-cache/package/release/R2Lab "$app/Contents/Helpers/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.emotiveimpact.cloudswap</string>
<key>CFBundleName</key><string>CLOUDSWAP</string>
<key>CFBundleExecutable</key><string>CLOUDSWAP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/cloudswap-lab"
codesign --force --sign - "$app/Contents/Helpers/R2Lab"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"

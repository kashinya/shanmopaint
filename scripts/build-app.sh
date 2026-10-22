#!/bin/bash
# Paint98.app を組み立てて dist/Paint98.zip を作る（macOS + Xcode / Command Line Tools が必要）。
#   ./scripts/build-app.sh            → Apple シリコン + Intel 両対応
#   ARCHS=arm64 ./scripts/build-app.sh → 自分の Mac 用だけ（速い）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
args=()
for a in $ARCHS; do args+=(--arch "$a"); done

swift build -c release "${args[@]}"
BIN_DIR="$(swift build -c release "${args[@]}" --show-bin-path)"

APP=dist/Paint98.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Paint98" "$APP/Contents/MacOS/Paint98"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

swift scripts/make-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf dist/AppIcon.iconset

# 署名なしだと Apple シリコンで起動できないので、アドホック署名だけしておく
codesign --force --deep --sign - "$APP"

(cd dist && ditto -c -k --keepParent Paint98.app Paint98.zip)
echo "できた: dist/Paint98.app / dist/Paint98.zip"

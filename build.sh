#!/bin/zsh
# Builds build/screentime-archiver and build/ScreenTimeBar.app using swiftc from Xcode or the Command Line Tools.
set -euo pipefail
cd "${0:A:h}"

mkdir -p build
ARCH=${ARCH:-$(uname -m)}   # arm64 or x86_64
SWIFTC_FLAGS=(-O -target $ARCH-apple-macos14.0)

# Some Command Line Tools releases ship a stray usr/include/swift/module.modulemap that clashes with the
# SDK's copy ("redefinition of module 'SwiftBridging'"). Shadow it with an empty file via a VFS overlay.
STRAY=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STRAY ]]; then
    mkdir -p build/vfs
    : > build/vfs/empty.modulemap
    cat > build/vfs/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false",
  "roots": [ { "type": "file", "name": "$STRAY", "external-contents": "$PWD/build/vfs/empty.modulemap" } ] }
EOF
    SWIFTC_FLAGS+=(-vfsoverlay build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs/overlay.yaml)
fi

echo "Building screentime-archiver…"
swiftc $SWIFTC_FLAGS -o build/screentime-archiver Sources/Archiver/*.swift
codesign --force --sign - --identifier io.github.tobias-x.screentime-archiver build/screentime-archiver

echo "Building ScreenTimeBar.app…"
APP=build/ScreenTimeBar.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp Resources/Info.plist $APP/Contents/Info.plist
swiftc $SWIFTC_FLAGS -parse-as-library -o $APP/Contents/MacOS/ScreenTimeBar Sources/MenuBar/*.swift
codesign --force --sign - $APP

echo "Built: build/screentime-archiver, $APP"

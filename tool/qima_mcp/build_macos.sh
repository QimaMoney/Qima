#!/bin/bash
# Builds the Mac helper as an unsigned bundle:
#
#     build_macos.sh <QimaMCP.app> <version+build> [<archs>] [<deployment target>]
#
#   Contents/MacOS/qima-mcp          macos/main.swift
#   Contents/Resources/qima_mcp.js   bin/qima_mcp_js.dart, Qima's MCP server
#
# embed_macos.sh calls this from the Runner build and signs the result;
# test/mcp/mac_helper_test.dart calls it to check the helper's answers.
set -euo pipefail

bundle="${1:?bundle path}"
version="${2:?version}"
archs="${3:-$(uname -m)}"
target="${4:-12.0}"

pkg="$(cd "$(dirname "$0")" && pwd)"
dart="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/}dart"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

(cd "$pkg" && { "$dart" pub get --offline >/dev/null 2>&1 || "$dart" pub get >/dev/null; })
js="$bundle/Contents/Resources/qima_mcp.js"
"$dart" compile js -O2 -DQIMA_VERSION="$version" -o "$js" "$pkg/bin/qima_mcp_js.dart" >/dev/null
rm -f "$js.deps" "$js.map"

slices=()
for arch in $archs; do
  slice="$bundle/Contents/MacOS/qima-mcp.$arch"
  xcrun -sdk macosx swiftc -O -target "$arch-apple-macos$target" "$pkg/macos/main.swift" -o "$slice"
  slices+=("$slice")
done
lipo -create "${slices[@]}" -output "$bundle/Contents/MacOS/qima-mcp"
rm -f "${slices[@]}"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.devlabtechnologies.qima.mcp</string>
	<key>CFBundleExecutable</key>
	<string>qima-mcp</string>
	<key>CFBundleName</key>
	<string>Qima MCP</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version%%+*}</string>
	<key>CFBundleVersion</key>
	<string>${version##*+}</string>
	<key>LSMinimumSystemVersion</key>
	<string>$target</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

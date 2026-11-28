#!/bin/bash
# Builds qima-mcp and embeds it, signed, as
# Qima.app/Contents/Helpers/QimaMCP.app/Contents/MacOS/qima-mcp.
# Runs as a Runner build phase, after Flutter embeds its frameworks and before
# Xcode signs the app (which seals the already-signed helper).
#
# - The helper is macos/main.swift: it runs the app's own Dart (`mcpMain`) on
#   the embedded Flutter engine. A `dart compile exe` binary can't ship in
#   the Mac App Store: Dart's standalone runtime links the private
#   `__dyld_find_unwind_sections`, which App Review rejects (2.5.1).
# - It is a tiny app bundle, not a bare tool, because a sandboxed process
#   needs an Info.plist with a bundle id; a bare sandboxed tool traps at launch.
# - Mac App Store build (the app's entitlements have an App Group): sandboxed
#   and in the same group, where the app writes the shared copy. Any other
#   build: not sandboxed, so it reads the copy in Qima's own container
#   (macOS asks the person once).
set -euo pipefail

: "${SRCROOT:?}" "${TARGET_BUILD_DIR:?}" "${WRAPPER_NAME:?}" "${ARCHS:?}" "${SDKROOT:?}"

repo="$SRCROOT/.."
source="$repo/tool/qima_mcp/macos/main.swift"
contents="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents"
bundle="$contents/Helpers/QimaMCP.app"
version="$(sed -n 's/^version: *//p' "$repo/pubspec.yaml" | head -1)"
target="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
work="${DERIVED_FILE_DIR:-$TARGET_TEMP_DIR}/qima-mcp"

# The copy embedded in the app has its headers stripped; Flutter's build
# leaves the full framework beside the app, which is the one to compile against.
engine="${BUILT_PRODUCTS_DIR:?}"
if [ ! -d "$engine/FlutterMacOS.framework/Headers" ] || [ ! -d "$contents/Frameworks/FlutterMacOS.framework" ]; then
  echo "error: qima-mcp: FlutterMacOS.framework is not built and embedded yet; this phase must run after Flutter's." >&2
  exit 1
fi

rm -rf "$bundle" "$work"
mkdir -p "$bundle/Contents/MacOS" "$work"
slices=()
for arch in $ARCHS; do
  # The helper loads the engine from the app's Frameworks folder, four
  # levels above its own executable.
  xcrun swiftc -O -module-name QimaMCP \
    -target "$arch-apple-macos$target" -sdk "$SDKROOT" \
    -F "$engine" -framework FlutterMacOS \
    -Xlinker -rpath -Xlinker "@executable_path/../../../../Frameworks" \
    -o "$work/qima-mcp-$arch" "$source"
  slices+=("$work/qima-mcp-$arch")
done
lipo -create "${slices[@]}" -output "$bundle/Contents/MacOS/qima-mcp"

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

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$identity" ] || [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  echo "qima-mcp: embedded unsigned (code signing is off for this build)"
  exit 0
fi

entitlements="$work/qima-mcp.entitlements"
app_entitlements="$SRCROOT/${CODE_SIGN_ENTITLEMENTS:-}"
sandbox=""
if [ -f "$app_entitlements" ] && grep -q "com.apple.security.application-groups" "$app_entitlements"; then
  sandbox="	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${DEVELOPMENT_TEAM:?}.com.devlabtechnologies.qima</string>
	</array>"
fi
# A debug engine compiles Dart as it runs, as the app's own debug
# entitlements allow; profile and release builds run compiled code.
jit=""
if [ "${CONFIGURATION:-}" = "Debug" ]; then
  jit="	<key>com.apple.security.cs.allow-jit</key>
	<true/>"
fi
cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$jit
$sandbox
</dict>
</plist>
PLIST

# Notarization needs a secure timestamp; local debug builds skip the round trip.
timestamp="--timestamp=none"
if [ "$identity" != "-" ] && [ "${CONFIGURATION:-}" = "Release" ]; then timestamp="--timestamp"; fi
# The hardened runtime only loads libraries signed by the same team, and an
# ad-hoc build ("Sign to Run Locally") has none, so the helper could not load
# the engine. Such a build is never distributed; leave the runtime off there.
runtime=(--options runtime)
if [ "$identity" = "-" ]; then runtime=(); fi
codesign --force ${runtime[@]+"${runtime[@]}"} "$timestamp" \
  --entitlements "$entitlements" --sign "$identity" "$bundle"
echo "qima-mcp: embedded and signed${sandbox:+ (sandboxed, App Group)}"

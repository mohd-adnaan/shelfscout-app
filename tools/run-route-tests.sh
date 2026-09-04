#!/bin/bash
#
# Run SemanticRouteNavigatorTests natively on macOS, without Xcode or a device.
#
# ── Why this exists ────────────────────────────────────────────────────────
# The route logic is the part of this app a blind user is trusting with their
# body, and until now the only way to exercise it was a full iOS build. So it
# was reviewed by reading diffs, and `swiftc -parse` was mistaken for
# verification — it checks syntax, not types, and never runs a line.
#
# `SemanticRouteNavigator.swift` imports only Foundation / CoreImage /
# CoreVideo / ImageIO / simd, and its three dependencies (Localization,
# NavigationTrace, ARKitNavigationModels) are Foundation / simd / Combine.
# All of that exists on macOS. So the whole route brain — start resolution,
# cue cadence, step advance, arrival, route belief — compiles and RUNS here in
# under a second.
#
# The only iOS-only piece it needs is ARVisualFingerprint / ARFrameFingerprinter,
# which live inside ARMappingManager.swift (ARKit). They are sliced out below
# by declaration name — the REAL implementations, not stubs — because they use
# CoreImage and Vision, both of which are macOS-native too.
#
# ── What it does NOT cover ─────────────────────────────────────────────────
# Anything touching ARKit, UIKit, SwiftUI or the RN bridge: ARMappingManager,
# ARMappingView, the reaching view controllers, TTSManager. Those still need a
# real build. This covers the navigator and its tests, which is where the
# guidance decisions are made.
#
# Usage:  tools/run-route-tests.sh            # run against the working tree
#         tools/run-route-tests.sh <commit>   # run against any commit
#
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
REF="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$REF" ]; then
  echo "▶ Route tests @ $REF ($(git log -1 --format=%s "$REF"))"
  git archive "$REF" ios | tar -x -C "$WORK"
  SRC="$WORK/ios"
else
  echo "▶ Route tests @ working tree"
  SRC="$REPO/ios"
fi

# XCTest cannot see internal symbols without a host app, so the tests are
# compiled INTO the same module as the sources and the @testable import is
# dropped. Same effect, no bundle plumbing.
sed 's/@testable import shelfscout//' "$SRC/shelfscoutTests/SemanticRouteNavigatorTests.swift" > "$WORK/Tests.swift"

# The real fingerprint types, lifted out of the ARKit-importing file.
{
  echo "import Foundation"; echo "import CoreImage"; echo "import CoreVideo"
  echo "import Vision"; echo "import simd"; echo
  awk '/^struct ARVisualFingerprint/,/^}/' "$SRC/ARMappingManager.swift"; echo
  awk '/^final class ARFrameFingerprinter/,/^}/' "$SRC/ARMappingManager.swift"
} > "$WORK/Fingerprint.swift"

BUNDLE="$WORK/RouteTests.xctest"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.shelfscout.routetests</string>
<key>CFBundleExecutable</key><string>RouteTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

PLATFORM="$(xcode-select -p)/Platforms/MacOSX.platform"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc -emit-library -Xlinker -bundle \
  -o "$BUNDLE/Contents/MacOS/RouteTests" \
  -sdk "$SDK" -target "$(uname -m)-apple-macos13.0" -DDEBUG \
  -F "$PLATFORM/Developer/Library/Frameworks" \
  -I "$PLATFORM/Developer/usr/lib" -L "$PLATFORM/Developer/usr/lib" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Developer/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Developer/usr/lib" \
  "$SRC/SemanticRouteNavigator.swift" \
  "$SRC/Localization.swift" \
  "$SRC/NavigationTrace.swift" \
  "$SRC/ARKitNavigationModels.swift" \
  "$WORK/Fingerprint.swift" \
  "$WORK/Tests.swift"

cd "$WORK"
set +e
xcrun xctest RouteTests.xctest 2>&1 | tee "$WORK/out.txt" | grep -E "error:.*\] :|Executed .* tests"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "── Failing tests ──"
grep -E "error:.*\] :" "$WORK/out.txt" 2>/dev/null \
  | sed -E 's/.*SemanticRouteNavigatorTests ([a-zA-Z]+)\].*/\1/' | sort -u \
  || true
grep -qE "error:.*\] :" "$WORK/out.txt" || echo "(none)"
exit "$STATUS"

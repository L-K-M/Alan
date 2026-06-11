#!/usr/bin/env bash
#
# build.sh — build Alan.app from the command line, no Xcode UI needed.
#
# Mirrors the release workflow's xcodebuild invocation (Release configuration,
# ad-hoc signed — fine for running on this Mac; no quarantine applies to locally
# built apps), so a local build is the same thing CI ships. The app reports the
# committed MARKETING_VERSION (releases get theirs stamped from the tag by CI).
#
#   scripts/build.sh             # build → build/Build/Products/Release/Alan.app
#   scripts/build.sh --run       # …then launch the built app
#   scripts/build.sh --install   # …then copy to /Applications (and launch with --run)
#   scripts/build.sh --debug     # Debug configuration instead of Release
#
# Usage: scripts/build.sh [--debug] [--run] [--install]
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Alan.xcodeproj"
SCHEME="Alan"
APP_NAME="Alan"

# --- Parse args --------------------------------------------------------------------
CONFIG="Release"
RUN=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG="Debug" ;;
    --run)     RUN=true ;;
    --install) INSTALL=true ;;
    *)         echo "error: unknown option '$arg'" >&2; exit 1 ;;
  esac
done

APP="build/Build/Products/${CONFIG}/${APP_NAME}.app"

# --- Build (same flags as .github/workflows/release.yml, minus the version stamp) ---
echo "==> Building ${APP_NAME} (${CONFIG}, ad-hoc signed)…"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  -quiet \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM=

if [[ ! -d "$APP" ]]; then
  echo "error: build finished but ${APP} is missing." >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo "Built ${APP} (version ${VERSION})."

# --- Install / run (optional) -------------------------------------------------------
TARGET="$APP"
if $INSTALL; then
  echo "==> Installing to /Applications/${APP_NAME}.app…"
  rm -rf "/Applications/${APP_NAME}.app"
  ditto "$APP" "/Applications/${APP_NAME}.app"
  TARGET="/Applications/${APP_NAME}.app"
  echo "Installed ${TARGET}."
fi

if $RUN; then
  echo "==> Launching ${TARGET}…"
  open "$TARGET"
fi

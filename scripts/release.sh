#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags "v<version>", and with --push
# pushes branch + tag — which triggers .github/workflows/release.yml to build
# Alan.app (ad-hoc signed), zip it, and publish the GitHub Release. CI derives the
# released version from the tag and stamps it into MARKETING_VERSION at build time,
# so the tag is the source of truth — this just keeps the committed
# MARKETING_VERSION (and the README, if it grows a version marker) in step so
# local/dev builds report the same number. (release.yml can also be run by hand via
# workflow_dispatch with a version input; this script is the tag-push path.)
#
#   scripts/release.sh 2.3            # bump MARKETING_VERSION, commit, tag v2.3
#   scripts/release.sh 2.3 --push     # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current MARKETING_VERSION as-is
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export RELEASE_APP_NAME="Alan"
export RELEASE_KIND="xcode"
export RELEASE_XCODE_PROJECT="Alan.xcodeproj"
export RELEASE_XCODE_SCHEME="Alan"
export RELEASE_CI_NOTE="CI (release.yml) will now build Alan.app (stamping <version> into MARKETING_VERSION), zip it, and publish the GitHub Release <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"

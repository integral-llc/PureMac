#!/usr/bin/env bash
#
# Build a Release PureMac.app with the project's Apple Development signing and
# install it into /Applications, quitting any running copy first. This is for
# running your own build day to day; scripts/release-local.sh produces the
# Developer ID, notarized artifacts.
#
# Usage: just deploy
#        scripts/deploy-local.sh
#
set -euo pipefail

BUNDLE_ID="com.puremac.app"
APP_NAME="PureMac.app"
DERIVED="build/deploy"
BUILT_APP="${DERIVED}/Build/Products/Release/${APP_NAME}"
INSTALL_DIR="/Applications"
DEST="${INSTALL_DIR}/${APP_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$(dirname "$0")/.."

[[ -w "${INSTALL_DIR}" ]] || { echo "ERROR: ${INSTALL_DIR} is not writable by $(whoami)" >&2; exit 1; }

echo "==> build"
# Native arch only: this copy runs on this machine, the universal binary is a release concern.
xcodebuild \
  -project PureMac.xcodeproj \
  -scheme PureMac \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  -quiet \
  ONLY_ACTIVE_ARCH=YES \
  build

echo "==> verify codesign"
codesign --verify --deep --strict "${BUILT_APP}"
codesign -dvv "${BUILT_APP}" 2>&1 | grep -E "^(Authority=Apple Development|TeamIdentifier)" \
  || { echo "ERROR: ${BUILT_APP} is not signed with an Apple Development identity" >&2; exit 1; }

if pgrep -xq PureMac; then
  echo "==> quit running PureMac"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null
  for _ in {1..20}; do
    pgrep -xq PureMac || break
    sleep 0.5
  done
  if pgrep -xq PureMac; then
    echo "ERROR: PureMac is still running, quit it and retry" >&2
    exit 1
  fi
fi

echo "==> install ${DEST}"
# Copy next to the destination first so a failed copy never leaves /Applications without the app.
STAGE=$(mktemp -d "${INSTALL_DIR}/.PureMac-deploy.XXXXXX")
trap 'rm -rf "${STAGE}"' EXIT
ditto "${BUILT_APP}" "${STAGE}/${APP_NAME}"
rm -rf "${DEST}"
mv "${STAGE}/${APP_NAME}" "${DEST}"
"${LSREGISTER}" -f "${DEST}"

echo "==> launch"
open "${DEST}"

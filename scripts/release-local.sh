#!/usr/bin/env bash
#
# Local mirror of .github/workflows/release.yml for producing and validating
# release artifacts. The tag-triggered CI workflow remains the canonical
# publisher. Requires:
#   - Developer ID Application identity in your login keychain
#   - notarytool keychain profile already stored, e.g.:
#       xcrun notarytool store-credentials AC_NOTARY \
#         --key ~/.appstoreconnect/private_keys/AuthKey_5G7R52L8RK.p8 \
#         --key-id 5G7R52L8RK --issuer 5de3898a-cd31-4061-850f-ae17b389e46a
#   - xcodegen + create-dmg installed (brew install xcodegen create-dmg)
#
# Usage: scripts/release-local.sh <version> [notary_profile]
#        scripts/release-local.sh 2.2.0
#        scripts/release-local.sh 2.2.0 AC_NOTARY
#
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary_profile]}"
NOTARY_PROFILE="${2:-AC_NOTARY}"
TEAM_ID="Z427697N2Y"
SIGN_ID="Developer ID Application: KARINA RATA (${TEAM_ID})"
SCHEME="PureMac"
PROJECT="PureMac.xcodeproj"
APP="build/export/PureMac.app"
DMG="build/PureMac-${VERSION}.dmg"
ZIP="build/PureMac-${VERSION}.zip"

cd "$(dirname "$0")/.."

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "${VERSION}" =~ ${SEMVER_RE} ]]; then
  echo "ERROR: version must be strict SemVer core (for example, 2.9.8; no leading zeroes): ${VERSION}" >&2
  exit 1
fi

BUILD_SHA=$(git rev-parse 'HEAD^{commit}')
TAG="v${VERSION}"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: tracked release inputs must be committed before building artifacts" >&2
  exit 1
fi
UNTRACKED_INPUTS=$(git ls-files --others --exclude-standard -- PureMac project.yml PureMac.xcodeproj)
if [[ -n "${UNTRACKED_INPUTS}" ]]; then
  echo "ERROR: untracked release inputs must be committed before building artifacts:" >&2
  printf '%s\n' "${UNTRACKED_INPUTS}" >&2
  exit 1
fi

git fetch --no-tags origin main
REMOTE_MAIN_SHA=$(git rev-parse 'origin/main^{commit}')
if [[ "${BUILD_SHA}" != "${REMOTE_MAIN_SHA}" ]]; then
  echo "ERROR: current commit ${BUILD_SHA} is not the latest origin/main commit ${REMOTE_MAIN_SHA}" >&2
  exit 1
fi

if LOCAL_TAG_SHA=$(git rev-parse "${TAG}^{commit}" 2>/dev/null) && [[ "${LOCAL_TAG_SHA}" != "${BUILD_SHA}" ]]; then
  echo "ERROR: local tag ${TAG} resolves to ${LOCAL_TAG_SHA}, not current commit ${BUILD_SHA}" >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  git fetch --force origin "refs/tags/${TAG}:refs/tags/${TAG}"
  TAG_SHA=$(git rev-parse "${TAG}^{commit}")
  if [[ "${TAG_SHA}" != "${BUILD_SHA}" ]]; then
    echo "ERROR: remote tag ${TAG} resolves to ${TAG_SHA}, not current commit ${BUILD_SHA}" >&2
    exit 1
  fi
fi

PROJ_VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml)
if [[ "${PROJ_VERSION}" != "${VERSION}" ]]; then
  echo "ERROR: project.yml MARKETING_VERSION (${PROJ_VERSION}) != ${VERSION}" >&2
  exit 1
fi

rm -rf build
mkdir -p build

echo "==> xcodegen"
xcodegen generate

echo "==> archive"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/PureMac.xcarchive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_ID}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  archive

echo "==> export"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/PureMac.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

echo "==> verify codesign"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dvv "${APP}" 2>&1 | grep -E "Identifier|TeamIdentifier|flags|Authority"
codesign -dvv "${APP}" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "Hardened runtime missing"; exit 1; }
APP_ARCHS=$(lipo -archs "${APP}/Contents/MacOS/PureMac")
grep -qw arm64 <<< "${APP_ARCHS}" || { echo "arm64 slice missing" >&2; exit 1; }
grep -qw x86_64 <<< "${APP_ARCHS}" || { echo "x86_64 slice missing" >&2; exit 1; }
echo "Architectures: ${APP_ARCHS}"

echo "==> notarize app zip (profile: ${NOTARY_PROFILE})"
NOTARY_ZIP="build/PureMac-app-notary.zip"
ditto -c -k --keepParent --sequesterRsrc "${APP}" "${NOTARY_ZIP}"
xcrun notarytool submit "${NOTARY_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"
spctl --assess --type execute --verbose=4 "${APP}"
rm -f "${NOTARY_ZIP}"

echo "==> dmg from stapled app"
create-dmg \
  --volname "PureMac ${VERSION}" \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "PureMac.app" 140 180 \
  --hide-extension "PureMac.app" \
  --app-drop-link 400 180 \
  --no-internet-enable \
  "${DMG}" \
  build/export/PureMac.app
codesign --sign "${SIGN_ID}" --timestamp "${DMG}"
codesign --verify --verbose=2 "${DMG}"

echo "==> notarize dmg"
xcrun notarytool submit "${DMG}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait --timeout 30m
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type install --verbose=4 "${DMG}"

echo "==> final zip with stapled app"
ditto -c -k --keepParent --sequesterRsrc "${APP}" "${ZIP}"

DMG_SHA=$(shasum -a 256 "${DMG}" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "${ZIP}" | awk '{print $1}')

echo ""
echo "===================="
echo "PureMac ${VERSION} signed + notarized"
echo "===================="
echo "DMG: ${DMG}"
echo "  sha256: ${DMG_SHA}"
echo "ZIP: ${ZIP}"
echo "  sha256: ${ZIP_SHA}"
echo ""
echo "Canonical publish: push ${TAG} at commit ${BUILD_SHA}; the tag-triggered CI workflow uploads assets and updates both Homebrew casks."
echo "This local script does not create tags, publish a GitHub release, or update Homebrew."

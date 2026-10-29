#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [notary_profile]}"
NOTARY_PROFILE="${2:-AC_NOTARY}"
SIGN_ID="Developer ID Application: KARINA RATA (Z427697N2Y)"
cd "$(dirname "$0")/.."

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "${VERSION}" =~ ${SEMVER_RE} ]] || { echo 'Invalid version' >&2; exit 1; }
[[ "$(awk -F '"' '/^let puremacVersion = / {print $2}' cli/Sources/puremac/PureMac.swift)" == "${VERSION}" ]] || {
  echo 'CLI source version does not match requested release' >&2
  exit 1
}
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard -- cli scripts/release-cli-local.sh)" ]]; then
  echo 'Commit release inputs before building' >&2
  exit 1
fi
git fetch --no-tags origin main
BUILD_SHA=$(git rev-parse 'HEAD^{commit}')
[[ "${BUILD_SHA}" == "$(git rev-parse 'origin/main^{commit}')" ]] || {
  echo 'Release commit must equal origin/main' >&2
  exit 1
}
OUTPUT="${PWD}/_work/cli-release/${VERSION}/${BUILD_SHA}"
[[ ! -e "${OUTPUT}" ]] || { echo "Output already exists: ${OUTPUT}" >&2; exit 1; }
mkdir -p "${OUTPUT}/stage"

swift test --package-path cli --scratch-path "${OUTPUT}/tests"
for ARCH in arm64 x86_64; do
  swift build --package-path cli -c release --arch "${ARCH}" --scratch-path "${OUTPUT}/build-${ARCH}"
  BIN_DIR=$(swift build --package-path cli -c release --arch "${ARCH}" --scratch-path "${OUTPUT}/build-${ARCH}" --show-bin-path)
  cp "${BIN_DIR}/puremac" "${OUTPUT}/puremac-${ARCH}"
done
lipo -create "${OUTPUT}/puremac-arm64" "${OUTPUT}/puremac-x86_64" -output "${OUTPUT}/stage/puremac"
chmod 755 "${OUTPUT}/stage/puremac"
codesign --sign "${SIGN_ID}" --timestamp --options runtime --identifier com.puremac.cli "${OUTPUT}/stage/puremac"
codesign --verify --strict --verbose=2 "${OUTPUT}/stage/puremac"
ARCHS=$(lipo -archs "${OUTPUT}/stage/puremac")
[[ " ${ARCHS} " == *' arm64 '* && " ${ARCHS} " == *' x86_64 '* ]]
[[ "$("${OUTPUT}/stage/puremac" --version)" == "${VERSION}" ]]
cp LICENSE "${OUTPUT}/stage/LICENSE"
ditto -c -k "${OUTPUT}/stage" "${OUTPUT}/notary.zip"
xcrun notarytool submit "${OUTPUT}/notary.zip" --keychain-profile "${NOTARY_PROFILE}" --wait --timeout 30m --output-format json > "${OUTPUT}/notarization.json"
jq -e '.status == "Accepted"' "${OUTPUT}/notarization.json" >/dev/null
NOTARY_ID=$(jq -r '.id' "${OUTPUT}/notarization.json")
xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" "${OUTPUT}/notarization-log.json"
codesign --verify --strict --verbose=2 "${OUTPUT}/stage/puremac"
NOTARY_SHA=$(shasum -a 256 "${OUTPUT}/notary.zip" | awk '{print $1}')
ARM_HASH=$(codesign -d --arch arm64 --verbose=4 "${OUTPUT}/stage/puremac" 2>&1 | awk -F= '$1 == "CDHash" {print $2}')
INTEL_HASH=$(codesign -d --arch x86_64 --verbose=4 "${OUTPUT}/stage/puremac" 2>&1 | awk -F= '$1 == "CDHash" {print $2}')
jq -e --arg archive "${NOTARY_SHA}" --arg arm "${ARM_HASH}" --arg intel "${INTEL_HASH}" '
  .status == "Accepted" and .sha256 == $archive
  and any(.ticketContents[]; .arch == "arm64" and .cdhash == $arm)
  and any(.ticketContents[]; .arch == "x86_64" and .cdhash == $intel)
' "${OUTPUT}/notarization-log.json" >/dev/null
COPYFILE_DISABLE=1 tar -czf "${OUTPUT}/puremac-cli-${VERSION}.tar.gz" -C "${OUTPUT}/stage" puremac LICENSE
mkdir "${OUTPUT}/verified"
tar -xzf "${OUTPUT}/puremac-cli-${VERSION}.tar.gz" -C "${OUTPUT}/verified"
cmp "${OUTPUT}/stage/puremac" "${OUTPUT}/verified/puremac"
codesign --verify --strict --verbose=2 "${OUTPUT}/verified/puremac"
[[ "$(lipo -archs "${OUTPUT}/verified/puremac")" == "${ARCHS}" ]]
[[ "$("${OUTPUT}/verified/puremac" --version)" == "${VERSION}" ]]
BINARY_SHA=$(shasum -a 256 "${OUTPUT}/verified/puremac" | awk '{print $1}')
(
  cd "${OUTPUT}"
  shasum -a 256 "puremac-cli-${VERSION}.tar.gz" > SHA256SUMS
)
jq -n --arg version "${VERSION}" --arg commit "${BUILD_SHA}" --arg binary_sha256 "${BINARY_SHA}" \
  --arg arm64_cdhash "${ARM_HASH}" --arg x86_64_cdhash "${INTEL_HASH}" --arg notarization_id "${NOTARY_ID}" \
  '{version:$version,commit:$commit,binary_sha256:$binary_sha256,arm64_cdhash:$arm64_cdhash,x86_64_cdhash:$x86_64_cdhash,notarization_id:$notarization_id}' \
  > "${OUTPUT}/release-verification.json"
printf 'Commit: %s\nArchitectures: %s\nApple notarization: %s\nArchive: %s\n' "${BUILD_SHA}" "${ARCHS}" "${NOTARY_ID}" "${OUTPUT}/puremac-cli-${VERSION}.tar.gz"
printf '%s\n' 'Signed command-line executables cannot carry a stapled ticket. Apple acceptance is recorded in notarization.json.'
printf '%s\n' 'This script prepares artifacts. It does not publish a release or update Homebrew.'

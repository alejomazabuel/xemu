#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${APPLE_SIGNING_CERT_BASE64:-}" ]]; then
  echo "APPLE_SIGNING_CERT_BASE64 is required." >&2
  exit 1
fi

if [[ -z "${APPLE_SIGNING_CERT_PASSWORD:-}" ]]; then
  echo "APPLE_SIGNING_CERT_PASSWORD is required." >&2
  exit 1
fi

if [[ -z "${APPLE_MOBILEPROVISION_BASE64:-}" ]]; then
  echo "APPLE_MOBILEPROVISION_BASE64 is required." >&2
  exit 1
fi

if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "APPLE_TEAM_ID is required." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="${1:-${RUNNER_TEMP:-/tmp}/x1box-apple-signing.env}"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/x1box-apple-signing"
KEYCHAIN_PASSWORD="${APPLE_KEYCHAIN_PASSWORD:-$(uuidgen)}"
KEYCHAIN_PATH="${WORK_ROOT}/x1box-signing.keychain-db"
CERT_PATH="${WORK_ROOT}/apple-signing-cert.p12"
PROFILE_RAW_PATH="${WORK_ROOT}/x1box.mobileprovision"
PROFILE_PLIST_PATH="${WORK_ROOT}/x1box.mobileprovision.plist"

mkdir -p "${WORK_ROOT}" "$(dirname "${OUTPUT_PATH}")" "${HOME}/Library/MobileDevice/Provisioning Profiles"

printf '%s' "${APPLE_SIGNING_CERT_BASE64}" | base64 --decode > "${CERT_PATH}"
printf '%s' "${APPLE_MOBILEPROVISION_BASE64}" | base64 --decode > "${PROFILE_RAW_PATH}"

security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security import "${CERT_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${APPLE_SIGNING_CERT_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/xcodebuild
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

security list-keychains -d user -s "${KEYCHAIN_PATH}"
security default-keychain -d user -s "${KEYCHAIN_PATH}"

security cms -D -i "${PROFILE_RAW_PATH}" > "${PROFILE_PLIST_PATH}"

profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print UUID' "${PROFILE_PLIST_PATH}")"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print Name' "${PROFILE_PLIST_PATH}")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "${PROFILE_PLIST_PATH}")"
profile_team_prefix="$(/usr/libexec/PlistBuddy -c 'Print TeamIdentifier:0' "${PROFILE_PLIST_PATH}")"
bundle_id="${APPLE_BUNDLE_ID:-com.alejomazabuel.x1boxios}"
expected_app_id="${APPLE_TEAM_ID}.${bundle_id}"

if [[ "${profile_team_prefix}" != "${APPLE_TEAM_ID}" ]]; then
  echo "Provisioning profile team '${profile_team_prefix}' does not match APPLE_TEAM_ID '${APPLE_TEAM_ID}'." >&2
  exit 1
fi

if [[ "${profile_app_id}" != "${expected_app_id}" ]] && [[ "${profile_app_id}" != "${APPLE_TEAM_ID}.*" ]]; then
  echo "Provisioning profile app id '${profile_app_id}' does not match '${expected_app_id}' or wildcard '${APPLE_TEAM_ID}.*'." >&2
  exit 1
fi

installed_profile_path="${HOME}/Library/MobileDevice/Provisioning Profiles/${profile_uuid}.mobileprovision"
cp "${PROFILE_RAW_PATH}" "${installed_profile_path}"

cat > "${OUTPUT_PATH}" <<EOF
APPLE_KEYCHAIN_PATH=${KEYCHAIN_PATH}
APPLE_KEYCHAIN_PASSWORD=${KEYCHAIN_PASSWORD}
APPLE_PROFILE_UUID=${profile_uuid}
APPLE_PROFILE_NAME=${profile_name}
APPLE_PROFILE_PATH=${installed_profile_path}
APPLE_BUNDLE_ID=${bundle_id}
APPLE_TEAM_ID=${APPLE_TEAM_ID}
EOF

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "keychain_path=${KEYCHAIN_PATH}"
    echo "profile_uuid=${profile_uuid}"
    echo "profile_name=${profile_name}"
    echo "profile_path=${installed_profile_path}"
    echo "bundle_id=${bundle_id}"
    echo "team_id=${APPLE_TEAM_ID}"
    echo "env_file=${OUTPUT_PATH}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Prepared Apple signing assets."
echo "Profile: ${profile_name} (${profile_uuid})"
echo "Env file: ${OUTPUT_PATH}"

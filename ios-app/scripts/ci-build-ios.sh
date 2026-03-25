#!/usr/bin/env bash
set -euo pipefail

PROJECT="ios-app/X1BoxiOS.xcodeproj"
SCHEME="X1BoxiOS"
SIM_DESTINATION="${SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=latest}"
BUILD_ROOT="${BUILD_ROOT:-build/ios-ci}"
RUN_DEVICE_BUILD="${RUN_DEVICE_BUILD:-true}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.alejomazabuel.x1boxios}"
ENABLE_SIGNED_EXPORT="${ENABLE_SIGNED_EXPORT:-false}"
APPLE_EXPORT_METHOD="${APPLE_EXPORT_METHOD:-development}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_PROFILE_NAME="${APPLE_PROFILE_NAME:-}"
APPLE_KEYCHAIN_PATH="${APPLE_KEYCHAIN_PATH:-}"
APPLE_SIGNED_BUNDLE_ID="${APPLE_SIGNED_BUNDLE_ID:-${APP_BUNDLE_ID}}"

mkdir -p "${BUILD_ROOT}/logs" "${BUILD_ROOT}/results"

echo "Using project: ${PROJECT}"
echo "Using scheme: ${SCHEME}"
echo "Using simulator destination: ${SIM_DESTINATION}"
echo "Run generic iOS device build: ${RUN_DEVICE_BUILD}"
echo "Signed IPA export enabled: ${ENABLE_SIGNED_EXPORT}"

run_step() {
  local name="$1"
  shift

  echo
  echo "==> ${name}"
  set -o pipefail
  "$@" 2>&1 | tee "${BUILD_ROOT}/logs/${name}.log"
}

find_simulator_app() {
  find "${BUILD_ROOT}/DerivedData-simulator/Build/Products" \
    -path "*Debug-iphonesimulator/X1BoxiOS.app" \
    | head -n 1
}

smoke_launch_simulator() {
  local app_path="$1"
  local simulator_udid

  if [[ -z "${app_path}" ]] || [[ ! -d "${app_path}" ]]; then
    echo "Simulator app bundle not found for smoke launch." >&2
    return 1
  fi

  simulator_udid="$(python3 - "${SIM_DESTINATION}" <<'PY'
import json
import subprocess
import sys

destination = sys.argv[1]
desired_name = ""
desired_os = ""

for part in destination.split(","):
    if "=" not in part:
        continue
    key, value = part.split("=", 1)
    key = key.strip()
    value = value.strip()
    if key == "name":
        desired_name = value
    elif key == "OS":
        desired_os = value

data = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    text=True,
))

matches = []
for runtime, devices in data.get("devices", {}).items():
    runtime_os = runtime.split(".SimRuntime.iOS-")[-1].replace("-", ".")
    for device in devices:
        if desired_name and device.get("name") != desired_name:
            continue
        if desired_os and desired_os != "latest" and runtime_os != desired_os:
            continue
        matches.append((device.get("state") == "Booted", runtime_os, device.get("udid", "")))

if not matches:
    sys.exit(1)

matches.sort(reverse=True)
print(matches[0][2])
PY
)"

  if [[ -z "${simulator_udid}" ]]; then
    echo "Failed to resolve a simulator UDID for ${SIM_DESTINATION}." >&2
    return 1
  fi

  xcrun simctl boot "${simulator_udid}" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "${simulator_udid}" -b
  xcrun simctl install "${simulator_udid}" "${app_path}"
  xcrun simctl launch "${simulator_udid}" "${APP_BUNDLE_ID}"
}

package_unsigned_ipa() {
  local archive_path="$1"
  local app_path="${archive_path}/Products/Applications/X1BoxiOS.app"
  local package_root="${BUILD_ROOT}/packages"
  local payload_root="${package_root}/Payload"
  local ipa_path="${package_root}/X1BoxiOS-unsigned.ipa"

  if [[ ! -d "${app_path}" ]]; then
    echo "Archived iOS app bundle not found at ${app_path}" >&2
    return 1
  fi

  rm -rf "${payload_root}" "${ipa_path}"
  mkdir -p "${payload_root}"
  /usr/bin/ditto "${app_path}" "${payload_root}/X1BoxiOS.app"
  (
    cd "${package_root}"
    /usr/bin/zip -qry "$(basename "${ipa_path}")" Payload
  )
  rm -rf "${payload_root}"
  echo "Created unsigned IPA at ${ipa_path}"
}

archive_signed_ipa() {
  local signed_archive_path="$1"
  local signed_export_path="$2"
  local export_options_path="${BUILD_ROOT}/packages/ExportOptions.plist"

  if [[ -z "${APPLE_TEAM_ID}" || -z "${APPLE_PROFILE_NAME}" ]]; then
    echo "APPLE_TEAM_ID and APPLE_PROFILE_NAME are required for signed IPA export." >&2
    return 1
  fi

  bash "ios-app/scripts/write-export-options-plist.sh" \
    "${export_options_path}" \
    "${APPLE_EXPORT_METHOD}" \
    "${APPLE_TEAM_ID}" \
    "${APPLE_SIGNED_BUNDLE_ID}" \
    "${APPLE_PROFILE_NAME}"

  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "${signed_archive_path}" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    PRODUCT_BUNDLE_IDENTIFIER="${APPLE_SIGNED_BUNDLE_ID}" \
    CODE_SIGN_STYLE=Manual \
    PROVISIONING_PROFILE_SPECIFIER="${APPLE_PROFILE_NAME}" \
    archive

  xcodebuild \
    -exportArchive \
    -archivePath "${signed_archive_path}" \
    -exportOptionsPlist "${export_options_path}" \
    -exportPath "${signed_export_path}"
}

run_step show-build-settings \
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -showBuildSettings

run_step build-simulator \
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "${SIM_DESTINATION}" \
    -derivedDataPath "${BUILD_ROOT}/DerivedData-simulator" \
    CODE_SIGNING_ALLOWED=NO \
    build

run_step test-simulator \
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "${SIM_DESTINATION}" \
    -derivedDataPath "${BUILD_ROOT}/DerivedData-tests" \
    -resultBundlePath "${BUILD_ROOT}/results/X1BoxiOS-SimulatorTests.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test

SIMULATOR_APP_PATH="$(find_simulator_app)"
run_step smoke-launch-simulator \
  smoke_launch_simulator \
  "${SIMULATOR_APP_PATH}"

if [[ "${RUN_DEVICE_BUILD}" == "true" ]]; then
  run_step build-device \
    xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -configuration Debug \
      -destination "generic/platform=iOS" \
      -derivedDataPath "${BUILD_ROOT}/DerivedData-device" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      build

  DEVICE_ARCHIVE_PATH="${BUILD_ROOT}/packages/X1BoxiOS.xcarchive"
  mkdir -p "${BUILD_ROOT}/packages"

  run_step archive-device \
    xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -configuration Debug \
      -destination "generic/platform=iOS" \
      -archivePath "${DEVICE_ARCHIVE_PATH}" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      archive

  run_step package-unsigned-ipa \
    package_unsigned_ipa \
    "${DEVICE_ARCHIVE_PATH}"

  if [[ "${ENABLE_SIGNED_EXPORT}" == "true" ]]; then
    SIGNED_ARCHIVE_PATH="${BUILD_ROOT}/signed/X1BoxiOS-signed.xcarchive"
    SIGNED_EXPORT_PATH="${BUILD_ROOT}/signed/export"
    mkdir -p "${BUILD_ROOT}/signed"

    if [[ -n "${APPLE_KEYCHAIN_PATH}" ]]; then
      export OTHER_CODE_SIGN_FLAGS="--keychain ${APPLE_KEYCHAIN_PATH}"
    fi

    run_step archive-and-export-signed-ipa \
      archive_signed_ipa \
      "${SIGNED_ARCHIVE_PATH}" \
      "${SIGNED_EXPORT_PATH}"
  fi
fi

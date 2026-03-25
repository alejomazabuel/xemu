#!/usr/bin/env bash
set -euo pipefail

PROJECT="ios-app/X1BoxiOS.xcodeproj"
SCHEME="X1BoxiOS"
SIM_DESTINATION="${SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=latest}"
BUILD_ROOT="${BUILD_ROOT:-build/ios-ci}"
RUN_DEVICE_BUILD="${RUN_DEVICE_BUILD:-true}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.alejomazabuel.x1boxios}"

mkdir -p "${BUILD_ROOT}/logs" "${BUILD_ROOT}/results"

echo "Using project: ${PROJECT}"
echo "Using scheme: ${SCHEME}"
echo "Using simulator destination: ${SIM_DESTINATION}"
echo "Run generic iOS device build: ${RUN_DEVICE_BUILD}"

run_step() {
  local name="$1"
  shift

  echo
  echo "==> ${name}"
  set -o pipefail
  "$@" | tee "${BUILD_ROOT}/logs/${name}.log"
}

find_simulator_app() {
  find "${BUILD_ROOT}/DerivedData-simulator/Build/Products" \
    -path "*Debug-iphonesimulator/X1BoxiOS.app" \
    | head -n 1
}

smoke_launch_simulator() {
  local app_path="$1"

  if [[ -z "${app_path}" ]] || [[ ! -d "${app_path}" ]]; then
    echo "Simulator app bundle not found for smoke launch." >&2
    return 1
  fi

  if ! xcrun simctl list devices | grep -q "(Booted)"; then
    echo "No booted simulator was available after the test run." >&2
    return 1
  fi

  xcrun simctl install booted "${app_path}"
  xcrun simctl launch booted "${APP_BUNDLE_ID}"
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
fi

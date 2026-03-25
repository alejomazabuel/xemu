#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-}"
export_method="${2:-development}"
team_id="${3:-}"
bundle_id="${4:-}"
profile_name="${5:-}"

if [[ -z "${output_path}" || -z "${team_id}" || -z "${bundle_id}" || -z "${profile_name}" ]]; then
  echo "Usage: write-export-options-plist.sh <output-path> <method> <team-id> <bundle-id> <profile-name>" >&2
  exit 1
fi

mkdir -p "$(dirname "${output_path}")"

cat > "${output_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>compileBitcode</key>
  <false/>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>${export_method}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${bundle_id}</key>
    <string>${profile_name}</string>
  </dict>
  <key>signingStyle</key>
  <string>manual</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>${team_id}</string>
  <key>thinning</key>
  <string>&lt;none&gt;</string>
</dict>
</plist>
EOF

echo "Wrote export options plist to ${output_path}"

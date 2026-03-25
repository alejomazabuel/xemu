# iPhone and iPad Sideload

This project can now produce two kinds of iOS packages in CI:

- `X1BoxiOS-unsigned.ipa`: useful for inspection and packaging validation
- `x1box-ios-signed-ipa`: exported from GitHub Actions when Apple signing secrets are configured

## Apple secrets expected by the workflow

Configure these repository secrets in your fork:

- `APPLE_SIGNING_CERT_BASE64`: base64-encoded `.p12` development or ad-hoc certificate
- `APPLE_SIGNING_CERT_PASSWORD`: password for that `.p12`
- `APPLE_MOBILEPROVISION_BASE64`: base64-encoded `.mobileprovision`
- `APPLE_TEAM_ID`: your Apple team identifier

The workflow verifies that the provisioning profile matches:

- the same Apple team
- the bundle identifier `com.alejomazabuel.x1boxios`, or a wildcard profile under the same team

## Producing a signed IPA in GitHub Actions

1. Open `Build iOS Full Stack` or `Build iOS App` with `Run workflow`.
2. Set:
   - `sign_ipa = true`
   - `export_method = development` for normal sideload testing
3. Start the workflow.
4. Download the artifact:
   - `x1box-ios-signed-ipa`

Expected output paths inside the artifact:

- `build/ios-ci/signed/export/X1BoxiOS.ipa`
- `build/ios-ci/signed/X1BoxiOS-signed.xcarchive`

## Running the signed export from this workspace

If your fork already has the Apple secrets configured, you can dispatch the signed workflow from this repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\ios-app\scripts\fork-workflow-bridge.ps1" `
  -Mode Full `
  -Repo "alejomazabuel/xemu" `
  -Ref "codex/ios-reactive-workflow" `
  -Workflow "build-ios-full-stack.yml" `
  -ArtifactName "x1box-ios-ci" `
  -SignIpa $true `
  -ExportMethod development
```

If signing succeeds, the bridge will also download:

- `x1box-ios-signed-ipa`

## Installing on a real device

You can install the signed IPA using any workflow you already trust for your own devices, for example:

- Xcode / Organizer
- Apple Configurator
- Sideloadly
- AltStore / SideStore

Use the signed IPA from the workflow artifact, not the unsigned one.

## Real-device functional checklist

After installation on iPhone or iPad:

1. Launch the app once and open `Settings`.
2. Confirm the embedded core status reports a loaded dynamic image.
3. Import:
   - MCPX
   - flash / BIOS
   - HDD
   - EEPROM if needed
   - a game image or test disc
4. Start once without a disc to verify dashboard / HDD boot flow.
5. Start once with a disc to verify disc boot flow.
6. Check touch overlay visibility and controller input.
7. Verify the app still relaunches after a clean stop.

## Important scope note

The signed IPA gets us to installable device builds, but real emulation on iPhone or iPad can still depend on your chosen JIT-capable sideload workflow and the assets you provide.

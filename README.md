# DisplayHarbor

[简体中文](README.zh-CN.md) · [Homepage](https://mitaraifail.github.io/displayharbor/en/)

DisplayHarbor is a native macOS menu bar utility that remembers where your app windows belong. It detects the current display setup, stores per-app window rules, and restores those rules when an app launches or your connected displays change.

## Features

- Detect the active app and its standard windows from the menu bar.
- Save window display, position, size, and full-screen state.
- Restore multiple windows for the same app in one operation.
- Keep rules separate for different physical display setups.
- Create named workspaces (scenarios) inside each display setup.
- Fork, rename, switch, and delete workspaces.
- Automatically re-apply rules after displays connect, disconnect, or change arrangement.
- Open and restore all currently unopened apps in the active workspace.
- Configure apps that should receive a normal quit request when entering each workspace.
- Inspect and maintain display setups and app rules in the management window.
- Follow the macOS preferred language (English and Simplified Chinese are included).

## Requirements

- macOS 14 or later.
- Apple Silicon (the current release workflow produces an arm64 build).
- Accessibility permission for DisplayHarbor.

On first launch, allow DisplayHarbor to control your windows in:

`System Settings → Privacy & Security → Accessibility`

If permission is missing when you open the menu bar panel, DisplayHarbor opens this settings page once for guidance and keeps an **Open Accessibility Settings** button available as a fallback.

## Install from GitHub Release (recommended)

For normal use, download the latest arm64 **DMG** from the [GitHub Releases page](https://github.com/mitaraifail/displayharbor/releases/latest). The ZIP is kept as a fallback for scripted or manual installs. Do not use `swift run` or `build-app.sh` unless you are developing DisplayHarbor.

1. Download the `.dmg` asset and its matching `.sha256` file. The checksum file is not an installer.
2. Verify the DMG from Terminal (optional):

   ```bash
   archive="DisplayHarbor-v0.1.4-macos-arm64.dmg"
   shasum -a 256 -c "$archive.sha256"
   ```

3. Open the DMG and drag `DisplayHarbor.app` to the `Applications` shortcut.
4. GitHub Releases are built with a Developer ID signature and submitted to Apple for notarization by Actions. After launching DisplayHarbor, grant it access under **System Settings → Privacy & Security → Accessibility**.

ZIP fallback:

   ```bash
   archive="DisplayHarbor-v0.1.4-macos-arm64.zip"
   shasum -a 256 -c "$archive.sha256"
   ditto -x -k "$archive" .
   mv DisplayHarbor.app /Applications/
   ```

If Finder shows a generic placeholder icon, relaunch Finder after installation. If macOS reports that the app is damaged, download the Release again and verify its checksum before trying anything else.

## Updating

DisplayHarbor uses Sparkle to check the signed appcast periodically. When a newer version is available, Sparkle verifies the update archive and presents an in-app update flow that can download, install, and relaunch DisplayHarbor.

If Sparkle is unavailable or you prefer a manual install, download the newer DMG from the [GitHub Releases page](https://github.com/mitaraifail/displayharbor/releases/latest), verify its checksum, quit DisplayHarbor, and drag the new app to `/Applications`. Your rules stay in `~/Library/Application Support/DisplayHarbor/environments.json` and are not removed when the app is replaced.

## Run from source

```bash
swift run
```

To build a double-clickable app bundle:

```bash
zsh build-app.sh
open dist/DisplayHarbor.app
```

`build-app.sh` requires a locally installed Developer ID Application certificate and produces a hardened-runtime-signed app. The GitHub Release workflow additionally notarizes the release; if its signing or notarization Secrets are missing, it fails instead of publishing an unsigned or unnotarized release.

## Usage

1. Launch DisplayHarbor and grant Accessibility permission.
2. Arrange your app windows on the desired displays.
3. Open DisplayHarbor from the menu bar.
4. Save the current layout for the active app.
5. Open **Manage Setups & App Rules** to inspect rules and workspaces.
6. Use **Apply Current Workspace** to open unopened apps and restore their saved windows.
7. Add work apps to **Exit Apps when entering** below the selected workspace's saved App rules.

## Digital license

DisplayHarbor supports Zhuankuai's `mbd-license-v1` software license protocol. Without activation, the default workspace remains available; creating, renaming, or deleting named workspaces requires a valid license.

The first activation stores the installation private key in the macOS Keychain and submits only the installation public key to Zhuankuai. After activation, the device certificate is verified locally, so the app can run offline. Activation codes and certificates are not stored in the layout rules file.

Before a production release, fill the public license configuration in `Resources/Info.plist`:

- `MBDLicenseAppID`: the `app_id` generated for the license product.
- `MBDLicensePublicKey`: the license product's Ed25519 public key.
- `MBDLicenseAPIBaseURL`: the license API origin, defaulting to `https://ai.mbd.pub`.
- `MBDLicensePurchaseURL`: the Zhuankuai license product URL.

For CI builds, the same values can be injected with `DISPLAYHARBOR_LICENSE_APP_ID`, `DISPLAYHARBOR_LICENSE_PUBLIC_KEY`, `DISPLAYHARBOR_LICENSE_API_BASE_URL`, and `DISPLAYHARBOR_LICENSE_PURCHASE_URL` when running `build-app.sh`.

The GitHub Release workflow reads these values from repository Variables. Configure them after the license product has been created and before pushing a production tag.

The public key may be distributed with the app. Never commit the platform signing key, a buyer activation code, or an installation private key.

Exit rules request a normal quit from configured apps when switching into the workspace; they never force-terminate a process. If an app has unsaved content, macOS continues through that app's own save flow. An app cannot have both a saved layout rule and an exit rule in the same workspace.

Rules are stored at:

`~/Library/Application Support/DisplayHarbor/environments.json`

User-defined display setup names, workspace names, and app rule data are preserved as entered. Built-in labels are localized at runtime, so changing the macOS preferred language takes effect after restarting the app.

## GitHub Releases

Releases are built automatically by [`.github/workflows/release.yml`](.github/workflows/release.yml) whenever a `v*` tag is pushed:

```bash
git tag v0.1.4
git push origin v0.1.4
```

The workflow builds, verifies, and uploads:

- `DisplayHarbor-<version>-macos-arm64.zip`
- `DisplayHarbor-<version>-macos-arm64.zip.sha256`
- `appcast.xml` (Sparkle automatic update feed)
- `DisplayHarbor-<version>-macos-arm64.dmg` (recommended installer)
- `DisplayHarbor-<version>-macos-arm64.dmg.sha256`

### GitHub Actions signing and notarization setup

The Release workflow requires these repository Secrets under **Settings → Secrets and variables → Actions**:

- `DISPLAYHARBOR_SIGNING_P12_BASE64`: base64 contents of a Developer ID Application `.p12` exported from Keychain Access.
- `DISPLAYHARBOR_SIGNING_P12_PASSWORD`: password used when exporting the `.p12`.
- `DISPLAYHARBOR_NOTARY_APPLE_ID`: Apple ID email for the Apple Developer Program membership.
- `DISPLAYHARBOR_NOTARY_APP_SPECIFIC_PASSWORD`: app-specific password generated for that Apple ID, not the normal Apple ID password.
- `DISPLAYHARBOR_NOTARY_TEAM_ID`: Apple Developer Team ID, for example `6ABLTPWC78`.
- `DISPLAYHARBOR_SPARKLE_EDDSA_PRIVATE_KEY`: private EdDSA key exported from Sparkle's `generate_keys` tool. Keep this only in GitHub Secrets.

Do not commit the private key, `.p12` password, API key, or EdDSA key. The workflow imports the certificate into a temporary keychain on the GitHub runner, then signs, notarizes, staples, checksums, and publishes the Sparkle appcast.

## Display setups and workspaces

DisplayHarbor identifies a display setup from the connected physical displays, their arrangement, resolutions, and main-display relationship. Rules from one setup do not overwrite rules from another setup.

Each setup starts with a built-in **Default** workspace. You can create a new workspace by copying the current one, then rename, switch, or delete it. The built-in Default workspace is always presented in the current interface language.

## Current limitations

- Multi-window matching uses window title, saved size, and window order; a changed window ID alone does not prevent restoration.
- Automatic restoration moves windows that already exist. It does not create missing windows.
- DisplayHarbor does not actively switch macOS Spaces or create native full-screen Spaces.
- The current release is arm64-only.

## License

No license has been selected yet.

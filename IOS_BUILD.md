# Building WildDex for iPhone

Apple requires the iOS build to run on macOS with Xcode. This project includes
a GitHub Actions workflow at `.github/workflows/build-ios.yml` so you can build
on a cloud Mac instead of buying or borrowing one.

## Quick Build Artifact

1. Push this project to GitHub.
2. Open the repo on GitHub.
3. Go to **Actions** > **Build iOS** > **Run workflow**.
4. Leave **signed** unchecked.
5. Download the `WildDex-unsigned-ios-app` artifact.

That artifact proves the Apple build compiles, but it will not install on an
iPhone because iOS apps must be code signed.

## Installable iPhone Build

To make an installable `.ipa`, you need an Apple Developer account and either an
Ad Hoc provisioning profile for your friend's device UDID or TestFlight/App
Store signing.

Add these repository secrets in GitHub:

- `IOS_CERTIFICATE_BASE64`: base64 of your `.p12` signing certificate.
- `IOS_CERTIFICATE_PASSWORD`: password for that `.p12`.
- `IOS_PROVISIONING_PROFILE_BASE64`: base64 of your `.mobileprovision` file.
- `KEYCHAIN_PASSWORD`: any temporary password for the CI keychain.
- `DEVELOPMENT_TEAM`: your Apple team id.

Then run **Actions** > **Build iOS** with **signed** checked. Use:

- `development` for your own registered test device.
- `ad-hoc` for a small set of registered friend devices.
- `app-store` for TestFlight/App Store distribution.

The workflow uploads `WildDex-signed-ipa` when signing succeeds.

## Base64 Commands

On macOS:

```bash
base64 -i certificate.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

On Windows PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("profile.mobileprovision")) | Set-Clipboard
```

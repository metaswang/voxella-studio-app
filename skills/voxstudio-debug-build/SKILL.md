---
name: voxstudio-debug-build
description: Build, sign, verify, launch, or troubleshoot local VoxStudio debug apps for either direct Developer ID or Mac App Store modes. Use for a local debug build, signed debug app, MAS or StoreKit sandbox build, native Keychain or macOS TCC testing, and Screen Recording cases where permission looks enabled but Display or Region capture is denied.
---

# VoxStudio Debug Build

Choose the distribution channel before building. The two signed debug modes share
the bundle identifier but intentionally use different traits, profiles,
entitlements, and signing requirements; never treat their profiles as
interchangeable.

Read [Signing and TCC](references/signing-and-tcc.md) before changing signing
configuration or diagnosing Keychain, microphone, Screen Recording, Display, or
Region behavior.

## Scope

- Work from `/Users/adamwang/Project/subdub/voxella-studio-app`.
- Preserve unrelated worktree changes. A debug build does not require a clean
  worktree and must not pull, commit, push, bump versions, notarize, or upload.
- The local artifact is `.build/VoxStudio.app`. A TestFlight `.pkg` belongs to
  `$voxstudio-testflight-release`; a notarized DMG belongs to
  `$voxstudio-release`.
- Do not print `.env`, `.env.prod`, provisioning-profile contents, private keys,
  tokens, or passwords. It is safe to report certificate common names, Team ID,
  bundle ID, profile type, and expiration.

## Select one mode

| Goal | Command | Actual app identity | Traits / behavior |
| --- | --- | --- | --- |
| Normal local debug, TCC, Keychain, microphone, Display/Region, browser login | `./scripts/bundle.sh debug --sign` | `Developer ID Application` from `DEVELOPER_ID_PROVISIONING_PROFILE` | `BundledSpeech,SparkleUpdates`; non-sandboxed direct build |
| Local Mac App Store UI, native Apple sign-in, StoreKit sandbox | `./scripts/bundle.sh debug --mas` | Apple Development certificate embedded in the selected development profile | `BundledSpeech,MacAppStore`; sandboxed; no Sparkle |
| Fast compile/UI iteration that does not need persistent identity or production credentials | `./scripts/bundle.sh debug --fast` | ad-hoc | Isolated in-memory credential store; unsuitable for TCC/Keychain acceptance |

Default to signed non-MAS mode. Use MAS mode only when the requested behavior is
specific to App Store, StoreKit, or the `MAC_APP_STORE` code path. Do not use an
ad-hoc build to accept or reject authentication, Keychain, or privacy behavior.

## Preflight

1. Inspect `git status --short` and `git diff -- scripts/bundle.sh`; preserve all
   existing changes.
2. Confirm the selected Xcode has the Metal toolchain. Let `bundle.sh` perform its
   authoritative preflight; if missing, follow its exact
   `xcodebuild -downloadComponent MetalToolchain` remediation.
3. For non-MAS, require a Developer ID Application identity and a matching
   Developer ID provisioning profile through
   `DEVELOPER_ID_PROVISIONING_PROFILE`. Never fall back to generic
   `PROVISIONING_PROFILE`, an Apple Development profile, or an MAS distribution
   profile. The repository-local expected profile is
   `.secrets/VoxStudio_Developer_ID.provisionprofile` when configured for this
   machine.
4. For local MAS, use an Apple Development provisioning profile through
   `PROVISIONING_PROFILE`. The current script initially requires
   `MAS_SIGNING_IDENTITY` to name the configured `3rd Party Mac Developer
   Application` identity, then intentionally replaces the actual debug signer
   with the Apple Development certificate bound to that profile. Do not use the
   MAS distribution profile as evidence of local StoreKit behavior.
5. In both signed modes, require Team ID, application identifier, Keychain access
   group, installed certificate, and provisioning-profile certificate to match.
   Stop on a mismatch; do not weaken the checks in `bundle.sh`.

## Build and launch

For the normal non-MAS debug app, use the repository startup sequence exactly:

```bash
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"
```

For an explicitly requested local MAS build:

```bash
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --mas && open "$PWD/.build/VoxStudio.app"
```

`pkill` is optional when there is no running instance. Never launch an older app
after a successful rebuild. Do not replace either signed command with
`swift run` when validating identity-dependent behavior.

## Verify the artifact

After every signed build:

```bash
codesign --verify --deep --strict --verbose=2 .build/VoxStudio.app
codesign -dv --verbose=4 .build/VoxStudio.app
codesign -dr - .build/VoxStudio.app
codesign -d --entitlements :- .build/VoxStudio.app
test -f .build/VoxStudio.app/Contents/embedded.provisionprofile
```

For non-MAS, verify Developer ID authority, the expected Team ID, microphone and
Keychain entitlements, absence of `com.apple.developer.applesignin`, and embedded
Sparkle. For MAS, verify the Apple Development authority, app sandbox, Apple
sign-in, microphone and Keychain entitlements, and absence of Sparkle and its
Info.plist keys. A debug `--sign` app is intentionally not notarized; do not use
`spctl` rejection as proof that its code signature is wrong.

## Runtime acceptance

- For TCC work, test the requested capture path itself. Window capture succeeding
  does not prove Display or Region authorization.
- For credential work, test the real signed app rather than the ad-hoc store.
- Record the command, selected mode, effective signing authority, Team ID,
  designated requirement, verification results, launch result, and any runtime
  behavior tested. Do not claim untested modes or permissions.

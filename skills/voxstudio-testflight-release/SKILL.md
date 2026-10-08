---
name: voxstudio-testflight-release
description: Prepare, version, build, validate, upload, and verify the macOS VoxStudio Mac App Store package in App Store Connect TestFlight. Use for a TestFlight build or update, MAS distribution package, App Store Connect upload, processing-status check, or internal tester-group rollout; do not use for the Developer ID DMG channel.
---

# VoxStudio TestFlight Release

Use this skill only for the macOS Mac App Store/TestFlight channel. Read
[TestFlight runbook](references/testflight-runbook.md) before changing a version,
building a release package, validating with Apple, uploading, or assigning a
build to testers.

## Authorization and boundaries

- Local preflight, build, and validation are allowed when the user asks to
  prepare or check a TestFlight build.
- Upload only when the user explicitly asks to publish, upload, release, or
  update TestFlight. A local build request alone does not authorize upload.
- For a requested TestFlight update, reuse the existing internal tester group(s)
  containing the preceding valid build when the match is unambiguous. Do not
  create groups, add individual or external testers, change beta-review data,
  submit an app version or IAP for App Review, or release to the Mac App Store
  unless separately requested.
- TestFlight uses `.build/VoxStudio.pkg`; it does not use Developer ID,
  notarization, stapling, a DMG, Sparkle signing, or Cloudflare R2. Use
  `$voxstudio-release` for the direct-distribution DMG.
- Preserve unrelated changes. Never stash, discard, commit, push, or print
  `.env`/`.env.prod`, private keys, passwords, tokens, or full provisioning
  profiles unless explicitly authorized.

## Release invariants

- Work from `/Users/adamwang/Project/subdub/voxella-studio-app`.
- Build with `./scripts/bundle-mas.sh`. It selects the `BundledSpeech` and
  `MacAppStore` traits, removes Sparkle, signs the app with the configured
  `3rd Party Mac Developer Application` identity, and signs the package with
  `3rd Party Mac Developer Installer`.
- Require `TEAM_IDENTIFIER`, `MAS_SIGNING_IDENTITY`,
  `MAS_INSTALLER_IDENTITY`, and `MAS_PROVISIONING_PROFILE` from `.env.prod` when
  present, otherwise `.env`. The app identity, profile certificate, Team ID,
  app identifier, Keychain group, and expiration must agree.
- Require `APP_STORE_CONNECT_API_KEY_ID`,
  `APP_STORE_CONNECT_API_ISSUER_ID`, and an existing
  `APP_STORE_CONNECT_API_PRIVATE_KEY_PATH`. Configure
  `API_PRIVATE_KEYS_DIR` for `altool`; the private-key path variable is not
  consumed by `altool` automatically.
- `CFBundleVersion` must be unused for the macOS app in App Store Connect. Never
  retry an upload with the same build number after Apple has accepted it.
- When a DMG and TestFlight build are intentionally paired, use the exact same
  `CFBundleShortVersionString` and `CFBundleVersion` and record both channel
  artifacts separately.
- The uploaded app's signature is not the installed TestFlight signature. This
  repository's installed TestFlight app was signed by `TestFlight Beta
  Distribution`. TestFlight, local MAS debug, and Developer ID can have different
  TCC requirements despite sharing `com.voxella.studio`. Both packaging channels
  also replace `.build/VoxStudio.app`; verify the actual artifact and running
  executable before local capture acceptance. For an enabled permission row
  beside a denial, use [Signing and TCC](../voxstudio-debug-build/references/signing-and-tcc.md).
- The current first non-consumable IAP may require a later app-version review
  submission. A TestFlight upload does not authorize or complete that review
  submission.

## Workflow

1. Inspect `git status --short`, the source Info.plist version/build, relevant
   signing-script diffs, and the selected environment without printing secrets.
   For a formal upload, sync with the intended branch first; if local changes
   prevent that, stop instead of stashing or overwriting them.
2. Check App Store Connect for the highest existing macOS build and confirm the
   intended build number is unused. Decide and set the marketing version/build
   before building. Do not let another release wrapper bump them afterward.
3. Validate both signing identities, the MAS profile, App Store Connect API key
   file, StoreKit product ID, deployment target, and `MacAppStore` source
   boundary as described in the runbook.
4. Run `./scripts/bundle-mas.sh` and verify `.build/VoxStudio.app` and
   `.build/VoxStudio.pkg` locally, including the external-billing scan,
   entitlements, embedded profile, absence of Sparkle, app signature, installer
   signature, version, and build.
5. Run Apple validation. Fix and rebuild on any validation error; do not upload
   an artifact different from the validated package.
6. If upload was explicitly requested, upload that exact package with `--wait`.
   Record the delivery/request ID and returned state.
7. Wait for App Store Connect processing. Distinguish uploaded, processing,
   invalid, ready for internal testing, and actually assigned to tester groups.
8. Reuse the preceding build's unambiguous internal groups and verify the new
   build appears in each group. Use the visible App Store Connect UI if group
   association is unsupported by the API. Stop for sign-in rather than changing
   group membership or tester scope.

## Completion report

Report the source commit or worktree state, marketing version, build number,
exact build and validation commands, MAS application and installer identities,
Team ID, profile validation, app and package signatures, entitlement and billing
checks, package byte count and SHA-256, Apple upload/delivery ID, processing
state, internal groups assigned, and every remaining manual or review step.

Never call an uploaded or processing build “available to testers.”

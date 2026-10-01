---
name: voxstudio-release
description: Build, sign, notarize, verify, and publish the macOS VoxStudio Developer ID DMG to Cloudflare R2. Use for a direct-download release, Sparkle/appcast or notarization work, DMG packaging/signing diagnosis, or R2 promotion; do not use for local debug builds or Mac App Store/TestFlight packages.
---

# VoxStudio Release

Use this project skill for the complete direct-distribution macOS release flow.
It keeps the Developer ID build, signing, notarization, verification, Sparkle,
and Cloudflare R2 publication parameters together so a release is reproducible.
Use `$voxstudio-debug-build` for local debug apps and
`$voxstudio-testflight-release` for the MAS `.pkg` channel.

Read references/release-runbook.md before performing a release. Use `scripts/r2_release.py` for prepare → upload → verify → cache-check → promote → postcheck. Do not upload to Hugging Face.

For shader packaging or hardware/OS qualification, read [Metal compatibility](references/metal-compatibility.md). Use physical Apple silicon Macs as release evidence. A build-host check covers only that host; do not infer M1–M4 or older-macOS coverage from it.

## Scope and authorization

- Build and local verification are allowed when the user asks for a DMG or release check.
- Upload to Cloudflare R2 only when the user explicitly asks to publish or update it.
- Do not build or upload a Mac App Store/TestFlight package through this skill;
  that flow has independent identities, profiles, entitlements, validation, and
  authorization in `$voxstudio-testflight-release`.
- Do not upload to Hugging Face, and do not delete existing Hugging Face files.
- Never commit, push, create a release, or modify unrelated repositories unless the user explicitly requests it.
- Preserve unrelated worktree changes, including changes outside this release skill.
- Do not print .env files, tokens, private keys, certificate passwords, or browser/session data.
- If the user requests a commit or push, show the final diff and verification results before the requested confirmation gate.

## Release invariants

- Work from the repository root: /Users/adamwang/Project/subdub/voxella-studio-app.
- The supported deployment range is macOS 15.0 or later on arm64. Package.swift and the app Info.plist must declare 15.0; bundle.sh must confirm the Mach-O value matches, and release.sh must copy the plist value into new Sparkle items.
- Keep macOS 26-only APIs behind availability checks with a functional macOS 15 fallback. Do not raise the deployment target to avoid compatibility work.
- The Convex 0.8.1 binary target contains vendor objects stamped with the build host's newer macOS version even though its package declares macOS 10.15. Preserve linker warnings and record macOS 15 launch, sign-in, and backend-query results when available. If that device coverage is unavailable, mark it unverified; it does not block a requested publication.
- The final distribution command is:

      ./scripts/bundle.sh release --dist

- Formal releases must start with `./scripts/release.sh` without a version argument. It reads the current `CFBundleShortVersionString` and the published Cloudflare appcast, then automatically increments the semantic-version patch component (`X.Y.Z` → `X.Y.(Z+1)`) before building. Do not manually reuse the previous release version. The first Cloudflare publication requires `RELEASE_BOOTSTRAP=1`.
- Every release record must include the previous version, new version, new `CFBundleVersion`, and the exact artifact version used for notarization and R2 publication.
- `SUFeedURL` must be `https://assets.voxstudio.me/downloads/voxstudio/appcast.xml`. Developer ID builds use the `SparkleUpdates` trait and the embedded Sparkle updater to read that feed and install updates in-app. Keep the full DMG enclosure in every appcast as the fallback when no matching delta is available. `chunks/` objects are separate legacy artifacts; Sparkle does not assemble them. Old builds still pointing at Hugging Face cannot be rewritten server-side and must install once from the website.
- R2 releases support Sparkle binary `.delta` artifacts. The normal `release.sh` path enables archive retention; delta generation defaults to `auto` and requires macOS plus at least two retained DMGs. Read the “Sparkle binary deltas” section in [the release runbook](references/release-runbook.md) for R2 keys, signing-key prerequisites, and verification. A successful generator run can still yield zero deltas; inspect the generated appcast and staged files, report that result without inventing a cause, and confirm the full-DMG fallback remains. Sparkle can apply a delta only when the installed build matches a published delta base and signature checks pass.

- The release build must use the BundledSpeech trait because the app includes speech and MLX resources.
- `scripts/build_metal.py` owns the macOS 15.0 / Metal 3.2 shader baseline for both MLX and Core Image. Package one arm64 app and one MLX library for M1–M4, without host-specific GPU specialization or duplicate shader variants. Do not call the dependency's unqualified Metal builder or accept a cached library merely because it exists.
- `bundle.sh` verifies source/toolchain/target cache receipts, packages `Contents/Resources/metal-build.json`, checks library hashes, and runs a local Metal/Core Image load probe before signing. The manifest is small provenance metadata; AIR files, compiler caches, and verification tools stay outside the app. Shader loading is not proof of model inference, video rendering, or compatibility on other Macs.
- scripts/bundle.sh loads .env.prod for release when present, otherwise .env.
- SIGNING_IDENTITY must identify a Developer ID Application certificate.
- TEAM_IDENTIFIER must match the Team ID in that certificate. The bundle script can derive it from the certificate when omitted.
- NOTARY_PROFILE must name an existing xcrun notarytool Keychain profile.
- If NOTARY_PROFILE is missing, recover it before building by following the API-key or app-specific-password procedure in the runbook.
- Developer ID builds embed Sparkle for in-app update checks and installation. Sparkle Ed25519 signing also signs the appcast and DMG. `SUPublicEDKey` must match the private key used by `sign_update`; do not publish an unsigned appcast or an artifact signed by an unrelated key.
- If the existing Sparkle private key is unavailable, recover it before publishing. If key rotation is intentional, generate a new Ed25519 key, export a backup to the ignored `.secrets/` directory with mode 600, update `SUPublicEDKey`, and ship a transition release deliberately. Existing Sparkle installations that trust the old public key will not accept updates signed only by the new key.
- App Store Connect API keys are managed at https://appstoreconnect.apple.com/access/integrations/api.
- A Team API key uses an `AuthKey_<KEY_ID>.p8` private key; a `.provisionprofile` is never a notarization credential.
- Keep local notarization private keys under `.secrets/`, which is ignored by Git, with restrictive file permissions. Never print, commit, or upload the key.
- The current working-tree Developer ID packaging path requires a provisioning profile. It must authorize `com.apple.application-identifier`, `com.apple.developer.team-identifier`, and `keychain-access-groups` for `TEAMID.com.voxella.studio`; set `DEVELOPER_ID_PROVISIONING_PROFILE` for `--sign` / `--dist`. Never substitute generic `PROVISIONING_PROFILE`, an Apple Development profile, or an MAS profile. Missing or certificate-mismatched profiles must fail before publication.
- This repository's confirmed Developer ID Distribution profile is `.secrets/VoxStudio_Developer_ID.provisionprofile`. When `DEVELOPER_ID_PROVISIONING_PROFILE` is not already configured, check this path before reporting that the profile is missing, and pass its absolute path to the release command. Validate its metadata and certificate match without printing the binary profile or other secrets.
- Historical releases before the profile-bound signing changes could package a Developer ID app without embedding a provisioning profile. Do not infer from an older successful DMG that the current profile is present, and do not silently restore the historical path. Before diagnosing a missing profile, inspect `git diff -- scripts/bundle.sh` and follow the behavior of the current script; report the historical-vs-current signing-path difference explicitly.
- Keep the Developer ID designated requirement stable across signed debug and
  distribution builds. macOS TCC grants are code-requirement-bound, not
  path-bound: silently signing `com.voxella.studio` with Apple Development can
  leave System Settings showing Screen Recording enabled while Display/Region
  preflight fails with a `tccd` requirement mismatch. Fix the identity/profile
  pairing before resetting permissions.
- Developer ID microphone recording requires `com.apple.security.device.audio-input=true` in the signed app. `scripts/bundle.sh release --sign` and `release --dist` must use `scripts/VoxStudio.developer-id.entitlements` for this capability.
- Keep `NSMicrophoneUsageDescription` in the final app `Contents/Info.plist`; an entitlement without the usage description is not sufficient for TCC authorization.
- The signed app must embed `Contents/embedded.provisionprofile` and carry the matching Keychain access group. Do not fall back to the login keychain.
- Developer ID builds must not carry `com.apple.developer.applesignin`.
- Local debug acceptance belongs to `$voxstudio-debug-build`. Ad-hoc builds use
  an isolated in-memory credential store; identity-dependent acceptance uses
  `./scripts/bundle.sh debug --sign` with the Developer ID profile.
- Google and Apple account login use the browser OAuth/PKCE flow in the current app. Do not reintroduce native GoogleSignIn SDK configuration or restricted entitlements into this release.
- Expected outputs are .build/VoxStudio.app and .build/VoxStudio.dmg.

## 14-day trial behavior

In the current checkout, the normal client trial is enabled by `DeviceTrialClock.durationDays = 14` in `Sources/VoxstudioPro/Account/DeviceTrialClock.swift`. Build the requested trial-enabled artifact without adding a trial-bypass environment variable. Verify the compiled source and the relevant trial tests before publication.

Do not claim that `VOXSTUDIO_DISABLE_14_DAY_TRIAL_LIMIT` changes the build: that variable is not implemented by the current source or packaging scripts. If a future release needs a temporary bypass, add and test an explicit feature flag first, then document its scope here; never infer a bypass from an environment variable that the build does not consume.

## Sparkle key and public appcast

- Keep the Sparkle private-key backup under the Git-ignored `.secrets/` directory with mode 600. The backup filename can vary by machine; check `SPARKLE_ED_KEY_FILE`, the configured default, and existing `.secrets/` backups before declaring the key unavailable. Never print, commit, upload, or include the private key in a DMG.
- Check the current key before changing `SUPublicEDKey`:

      SPARKLE_ROOT='.build/sparkle-tools'
      "$SPARKLE_ROOT/bin/generate_keys" -p
      /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/VoxstudioPro/Resources/Info.plist
      "$SPARKLE_ROOT/bin/sign_update" -p .build/VoxStudio.dmg

- If `generate_keys -p` does not return the public key in `Info.plist`, stop and recover the original private key. Do not silently generate a replacement for an established release stream.
- When a new key is explicitly authorized, generate it in the macOS Keychain, export a protected backup, and verify Git ignores it:

      mkdir -p .secrets
      "$SPARKLE_ROOT/bin/generate_keys"
      "$SPARKLE_ROOT/bin/generate_keys" -x .secrets/sparkle-ed25519-private.key
      chmod 600 .secrets/sparkle-ed25519-private.key
      git check-ignore -v .secrets/sparkle-ed25519-private.key

- Copy the new public key printed by `generate_keys` into `SUPublicEDKey`, then verify the appcast item and DMG with `sign_update` before publication. Import an existing backup on another machine with `generate_keys -f`; never pass private-key material on a command line.
- The public Cloudflare feed is `https://assets.voxstudio.me/downloads/voxstudio/appcast.xml`. The latest installer is `https://assets.voxstudio.me/downloads/voxstudio/VoxStudio.dmg`, which 302s to an immutable version URL. Appcast enclosure URLs must use that immutable version URL, never the latest redirect. Do not copy Hugging Face history into the Cloudflare feed.

## Standard workflow

1. Before a formal release's version selection, build, signing, notarization, or DMG creation, run `git pull` from the repository root. If `git pull` is blocked by local changes or produces conflicts, stop and report the blocker; never automatically stash, commit, discard, or overwrite worktree changes. After a successful pull, perform all remaining preflight checks against the pulled checkout. Editing this skill or locally validating packaging changes is not a formal release: test the current working tree without pulling, bumping, or publishing.
2. Check the worktree and release configuration without exposing secret values.
3. Read the runbook and confirm the exact certificate, notary profile, output paths, and R2 credentials. Confirm which provisioning-profile mode the current `scripts/bundle.sh` implements; if that mode requires a profile and it is unavailable or mismatched, stop before building or uploading.
4. If physical-device qualification is desired before publication, run `RELEASE_TARGET=dmg ./scripts/release.sh` to select the version and produce a signed/notarized local DMG. Publish the same artifact with the runbook's separate `scripts/r2_release.py` invocation; do not invoke the wrapper again and bump/rebuild it. Pending physical-device checks do not block a requested publication; record them as unverified. The default `./scripts/release.sh` publishes immediately. The first Cloudflare publication needs `RELEASE_BOOTSTRAP=1`. `RELEASE_PROMOTE=0` still uploads, and `RELEASE_DRY_RUN=1` still bumps/builds locally; neither is a build-only substitute. Use `RELEASE_RESUME=1` to continue an existing failed publication without rebuilding.
5. Verify the app, mounted DMG app, macOS 15 deployment metadata, staple tickets, Developer ID signatures, microphone entitlement, restricted entitlements, Gatekeeper assessments, and packaged Metal manifest. Follow the physical-device matrix in [Metal compatibility](references/metal-compatibility.md) when devices are available; record actual results and untested combinations separately. Pending physical-device results do not block publication, and must remain marked unverified.
6. Record the previous version, new version, build number, DMG byte count, and SHA-256 before reporting publication.
7. Verify the public version URL, latest redirect, Cloudflare appcast enclosure, and that Check for Updates opens the immutable version URL.
8. If the user also requests TestFlight, freeze and record this channel's selected
   marketing version/build, then follow `$voxstudio-testflight-release` for the
   separate MAS artifact. Do not reuse Developer ID identities, profiles,
   entitlements, notarization, or Sparkle checks for that package.

## Cloudflare R2 defaults

The production Cloudflare R2 target is fixed to the EU jurisdiction and must not
be inferred from a generic or non-jurisdictional endpoint:

- Account ID: `830eacc6f0bf33e7119b6c71ed13e03d`
- Bucket: `vox`
- Bucket jurisdiction: `eu`
- S3-compatible endpoint: `https://830eacc6f0bf33e7119b6c71ed13e03d.eu.r2.cloudflarestorage.com`
- Object prefix: `app-releases/voxstudio`
- Stable pointer: `app-releases/voxstudio/channels/stable.json`
- Release metadata source on this machine: `../voxella-docker-deploy/.env.prod.myvps2`

The release object layout is:

```text
app-releases/voxstudio/releases/<version>-<build>/<sha256>/VoxStudio.dmg
app-releases/voxstudio/releases/<version>-<build>/<sha256>/manifest.json
app-releases/voxstudio/releases/<version>-<build>/<sha256>/appcast.xml
app-releases/voxstudio/releases/<version>-<build>/<sha256>/chunks/000000.bin
app-releases/voxstudio/releases/<version>-<build>/<sha256>/deltas/<from-build>-to-<to-build>.delta  # when generated
```

The public Worker maps that prefix to `/downloads/voxstudio/`. The immutable
DMG URL is therefore:
`https://assets.voxstudio.me/downloads/voxstudio/releases/<version>-<build>/<sha256>/VoxStudio.dmg`.

The project publication defaults are:

- Bucket: vox
- Prefix: app-releases/voxstudio
- Local file: .build/VoxStudio.dmg
- Latest URL: https://assets.voxstudio.me/downloads/voxstudio/VoxStudio.dmg
- Appcast: https://assets.voxstudio.me/downloads/voxstudio/appcast.xml
- Worker delivery rollback: RELEASE_DELIVERY_MODE=origin; keep RELEASE_DOWNLOAD_MODE=origin

The publisher reads R2 credentials from the environment (`R2__ACCOUNT_ID`, `R2__ACCESS_KEY_ID`, `R2__SECRET_ACCESS_KEY`, `R2__BUCKET`) without printing them. It never accepts a token argument. Do not promote `stable.json` until artifact-scoped public verify and cache-check have passed. Cache-check requires an actual HIT on the verified cache deployment, or an explicitly recorded origin downgrade. A conditional-write conflict must stop the switch; it must not retry with a forced overwrite.

## Completion report

Report:

- previous release version, new automatically selected patch version, and `CFBundleVersion`;
- build command and whether it completed;
- signing identity and Team ID, without secret material;
- notarization/stapling status;
- app and mounted-DMG Gatekeeper results;
- Package.swift, Info.plist, Mach-O, and Sparkle minimum-system-version checks;
- restricted-entitlement and embedded-profile checks;
- `com.apple.security.device.audio-input=true`, `NSMicrophoneUsageDescription`,
  and installed-app microphone/Display/Region TCC checks;
- DMG size and SHA-256;
- R2 identity, versioned URL, latest URL, appcast URL, and whether promote completed;
- whether Sparkle deltas were generated, uploaded, and verified, or the specific reason they were skipped; report full-DMG fallback availability;
- confirmation that the Developer ID app's Sparkle updater uses the immutable Cloudflare appcast, and that old Hugging Face builds are not claimed to migrate automatically;
- anything not verified or requiring manual UI confirmation.

Do not claim that account login works from packaging checks alone; login remains a manual end-to-end verification.

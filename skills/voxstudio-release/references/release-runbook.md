# VoxStudio Release Runbook

This runbook describes the complete Developer ID DMG and Cloudflare R2 publication flow for this repository.

## 1. Preflight

Run from the repository root:

      cd /Users/adamwang/Project/subdub/voxella-studio-app
      git pull
      git status --short
      test -x scripts/bundle.sh
      test -f Package.swift
      test -f scripts/VoxStudio.developer-id.entitlements

The `git pull` above is mandatory before a formal release's version selection, build, signing,
notarization, or DMG creation. Local packaging development and validation use the
current worktree and do not require a pull or version bump. If local changes prevent a release pull or it produces
conflicts, stop and report the blocker. Do not automatically stash, commit,
discard, or overwrite local worktree changes. After a successful pull, repeat
the remaining preflight checks against the pulled checkout.

Confirm the supported deployment target remains macOS 15.0 across build and release metadata:

      rg -n 'platforms: \[\.macOS\(\.v15\)\]' Package.swift
      /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Sources/VoxstudioPro/Resources/Info.plist | rg -q '^15\.0$'
      rg -n 'MINIMUM_SYSTEM_VERSION.*LSMinimumSystemVersion|minimum_system_version' scripts/release.sh

The complete release includes Textual and bundled speech, both of which require macOS 15. Keep macOS 26-only APIs behind availability checks and preserve the macOS 15 fallback instead of raising the target. The Convex binary target may emit warnings for vendor objects stamped with the build host's newer macOS version; preserve those warnings in the release record. Run the macOS 15 runtime smoke test below when a suitable device is available. If it is unavailable, record that coverage as unverified; it does not block publication.

Read [Metal compatibility](metal-compatibility.md) for the macOS 15 / Metal 3.2
packaging policy, cache invalidation, and M1–M4 physical-device qualification.
Run `python3 scripts/build_metal.py preflight` before a costly distribution build.
Do not compile shaders with implicit host defaults or patch SwiftPM dependency checkouts.

Inspect release variables without printing values:

      for name in SIGNING_IDENTITY TEAM_IDENTIFIER NOTARY_PROFILE DEVELOPER_ID_PROVISIONING_PROFILE; do
        if grep -q "^$name=" .env.prod 2>/dev/null || grep -q "^$name=" .env 2>/dev/null; then
          echo "$name is configured"
        else
          echo "$name is not configured"
        fi
      done

The script gives .env.prod precedence for release builds. Do not source either file into a command transcript, and do not paste its contents into a report.

Confirm the signing mode in the actual checkout before interpreting a missing profile:

      git diff -- scripts/bundle.sh
      rg -n 'DEVELOPER_ID_PROVISIONING_PROFILE|embedded\.provisionprofile|profile_certificate' scripts/bundle.sh

The current working-tree packaging path is profile-bound for Developer ID signing. A Developer ID profile must be bound to the selected `Developer ID Application` certificate and must authorize the app identifier and keychain access group. Generic `PROVISIONING_PROFILE`, an Apple Development profile, or an MAS profile is not a substitute. Older releases used a historical Developer ID path that did not embed a provisioning profile, so older successful artifacts do not prove that the current checkout has a usable Developer ID profile. If the current script requires one and none is available, stop and report the mismatch before building or publishing.

This repository has a confirmed Developer ID Distribution profile at:

      .secrets/VoxStudio_Developer_ID.provisionprofile

If `DEVELOPER_ID_PROVISIONING_PROFILE` is absent from the selected release environment, check this file before reporting a missing profile and pass its absolute path for the release invocation:

      test -f .secrets/VoxStudio_Developer_ID.provisionprofile
      DEVELOPER_ID_PROVISIONING_PROFILE="$PWD/.secrets/VoxStudio_Developer_ID.provisionprofile" ./scripts/release.sh

Inspect the decoded profile metadata and certificate match without printing the binary profile or unrelated secret values. The expected profile is Developer ID Distribution for `com.voxella.studio`, Team ID `4DMAQ32SNU`, and the `Developer ID Application: GREATWAY GLOBAL PTE. LTD. (4DMAQ32SNU)` certificate.

Check that the signing identity is a Developer ID certificate:

      security find-identity -v -p codesigning | rg 'Developer ID Application'

If SIGNING_IDENTITY is set, verify its certificate metadata without exposing unrelated environment values:

      security find-certificate -a -c "$SIGNING_IDENTITY" -Z 2>/dev/null || true

The expected Team ID is the ten-character identifier associated with the selected Developer ID certificate. If TEAM_IDENTIFIER is configured, it must match that certificate.

For notarization, NOTARY_PROFILE must already exist in the local Keychain. Read only the profile name from the selected release environment:

      RELEASE_ENV='.env'
      if [ -f .env.prod ]; then RELEASE_ENV='.env.prod'; fi
      NOTARY_PROFILE="$(sed -n 's/^NOTARY_PROFILE=//p' "$RELEASE_ENV" | tail -n 1 | tr -d "\"'")"
      test -n "$NOTARY_PROFILE"
      xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"

This command may return an empty history and still prove that the profile is usable. A missing profile must be fixed before building the distribution artifact. Do not print the environment file or any credential value.

### Recover a missing profile with an App Store Connect Team API key

Open [App Store Connect API Keys](https://appstoreconnect.apple.com/access/integrations/api), create or select a Team API key, and download its private key. The private key is an `AuthKey_<KEY_ID>.p8` file; it is not a `.provisionprofile`. Individual API keys cannot be used with `notarytool`.

Keep the private key local to this repository only in the ignored `.secrets/` directory. For this checkout, the expected path is:

      /Users/adamwang/Project/subdub/voxella-studio-app/.secrets/AuthKey_46AK8UQ7G7.p8

Set restrictive permissions and verify that Git ignores it without printing its contents:

      chmod 600 .secrets/AuthKey_46AK8UQ7G7.p8
      git check-ignore -v .secrets/AuthKey_46AK8UQ7G7.p8

The interactive recovery flow is:

      xcrun notarytool store-credentials "$NOTARY_PROFILE"

Enter the `.p8` path, the matching API Key ID (`46AK8UQ7G7` for the file above), and the Issuer ID shown in App Store Connect. Do not enter a provisioning profile path. Alternatively, use explicit arguments without putting secrets in shell history:

      xcrun notarytool store-credentials "$NOTARY_PROFILE" \
        --key "$NOTARY_API_KEY_PATH" \
        --key-id "$NOTARY_API_KEY_ID" \
        --issuer "$NOTARY_API_ISSUER"

Set `NOTARY_API_KEY_PATH`, `NOTARY_API_KEY_ID`, and `NOTARY_API_ISSUER` only in the current shell or an ignored local environment file; never commit them with a private key or print their values.

### Recover a missing profile with an Apple app-specific password

If an App Store Connect Team API key is unavailable, use an app-specific password instead:

      xcrun notarytool store-credentials "$NOTARY_PROFILE" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_IDENTIFIER"

notarytool prompts for the app-specific password when `--password` is omitted.

Set NOTARY_PROFILE in the local release environment to the profile name. Never commit the password, API key, or a populated environment file.

After either recovery path, verify the profile before building:

      xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"

The command must no longer report `No Keychain password item found`. Use the same profile name in `.env` or `.env.prod` that the release wrapper loads.

## 1A. Recover or rotate the Sparkle Ed25519 key

Sparkle appcast signing is independent of Developer ID signing and Apple notarization. The public key in `Sources/VoxstudioPro/Resources/Info.plist` must match the private key used for every published appcast enclosure. Developer ID builds embed Sparkle and use it to check the Cloudflare feed and install updates in-app; Mac App Store builds omit Sparkle.

Check the existing key without printing private material:

      SPARKLE_ROOT='.build/sparkle-tools'
      "$SPARKLE_ROOT/bin/generate_keys" -p
      /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/VoxstudioPro/Resources/Info.plist
      "$SPARKLE_ROOT/bin/sign_update" -p .build/VoxStudio.dmg

If the Keychain lookup fails or the public key differs, stop and recover the original Sparkle private key before publishing. A newly generated key cannot update already-installed apps that trust the old `SUPublicEDKey`.

Only when key rotation is explicitly intended:

      mkdir -p .secrets
      "$SPARKLE_ROOT/bin/generate_keys"
      "$SPARKLE_ROOT/bin/generate_keys" -x .secrets/sparkle-ed25519-private.key
      chmod 600 .secrets/sparkle-ed25519-private.key
      git check-ignore -v .secrets/sparkle-ed25519-private.key

Copy the newly generated public key into `SUPublicEDKey`, retain the private backup only under `.secrets/`, and verify `generate_keys -p` matches the plist before building. On another machine, import the protected backup with `generate_keys -f .secrets/sparkle-ed25519-private.key`. Never print, commit, upload, or place the private key in a DMG or command-line argument.

For the Cloudflare distribution path, set the appcast feed and latest installer to:

      https://assets.voxstudio.me/downloads/voxstudio/appcast.xml
      https://assets.voxstudio.me/downloads/voxstudio/VoxStudio.dmg

The appcast enclosure must be the immutable version URL under `/downloads/voxstudio/releases/<version>-<build>/<sha256>/VoxStudio.dmg`. Do not point enclosure metadata at the latest redirect. Do not copy Hugging Face history into this feed. Old apps that still embed the Hugging Face `SUFeedURL` cannot be migrated by this server change; those users must install once from the website.

## 2. Select and record the release version

Formal releases must use the release wrapper with no manually supplied version:

      ./scripts/release.sh

To stage locally for optional physical-device qualification before publication:

      RELEASE_TARGET=dmg ./scripts/release.sh

This still selects the next version and notarizes the DMG, but does not upload it.
When device coverage is pending, publication may proceed on the user's explicit
request after the package checks below; record the untested combinations in the
release record. If testing the artifact first, use that same DMG with section 9's
separate publisher and its recorded version/build/signature. Do not rerun the
wrapper after testing: that would select a different version and rebuild.
`RELEASE_PROMOTE=0` uploads before stopping and is not build-only.

Before it changes `Info.plist`, the wrapper reads the current
`CFBundleShortVersionString` and the highest version in the published
Cloudflare appcast, then selects the next semantic-version patch
(`X.Y.Z` becomes `X.Y.(Z+1)`). It also plans a new `CFBundleVersion`.
The first Cloudflare publication must set `RELEASE_BOOTSTRAP=1` and use
the local version plus recorded release metadata; it must not invent
versions from the retired Hugging Face feed. A release must never reuse
the prior marketing version, and the release record must contain the
previous version, new version, build number, DMG hash, and the exact
version uploaded.

The wrapper performs the version bump before invoking the distribution build;
do not invoke `bundle.sh release --dist` directly for a formal release unless
the version has already been selected and recorded by the wrapper.

## 3. Build and distribute

The formal release wrapper invokes the distribution build after selecting and
recording the next patch version. The build step is:

      ./scripts/bundle.sh release --dist

This command:

1. builds the Swift package with the BundledSpeech trait;
2. assembles .build/VoxStudio.app;
3. injects the configured backend values into the app bundle;
4. copies the MLX metallib, speech resources, and other required resources;
5. signs the app with Developer ID Application;
6. creates a ZIP and submits it to Apple notarization;
7. staples the app ticket;
8. creates .build/VoxStudio.dmg with the Applications alias and volume icon;
9. signs the DMG;
10. submits the DMG to Apple notarization; and
11. staples the DMG ticket.

For microphone capture, the Developer ID signing path must include
`com.apple.security.device.audio-input=true` from
`scripts/VoxStudio.developer-id.entitlements`. This is a Hardened Runtime
resource-access entitlement and is separate from the Mac App Store sandbox
entitlement. Do not replace it with a provisioning profile or add restricted
Apple sign-in entitlements to the Developer ID app.

release --sign signs without completing the final notarized distribution flow. Use release --dist for the artifact intended for users. debug --fast and swift run are development checks, not release packaging.

## 4. Recover a network-interrupted notarization

If xcrun notarytool submit --wait prints a submission ID and then loses network connectivity, do not submit the same artifact again. Query the exact submission:

      xcrun notarytool info SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE"

If the result is Accepted, continue with stapling and the remaining package steps. Query the DMG submission separately if the later DMG upload was the interrupted operation.

## 5. Verify the app before upload

Run these checks after release --dist:

      set -e
      APP='.build/VoxStudio.app'
      DMG='.build/VoxStudio.dmg'

      test -d "$APP"
      test -f "$DMG"
      codesign --verify --deep --strict --verbose=2 "$APP"
      codesign -dv --verbose=4 "$APP" 2>&1 | rg 'Identifier=|Authority=|TeamIdentifier='
      codesign -d --entitlements :- "$APP" 2>/dev/null
      codesign -d --entitlements :- "$APP" 2>/dev/null \
        | plutil -extract com.apple.security.device.audio-input raw -o - - \
        | rg -q '^true$'
      /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist" >/dev/null
      test -e "$APP/Contents/embedded.provisionprofile"
      /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" | rg -q '^15\.0$'
      otool -l "$APP/Contents/MacOS/VoxStudio" \
        | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}' \
        | rg -q '^15\.0$'
      test -d "$APP/Contents/Frameworks/Sparkle.framework"
      otool -L "$APP/Contents/MacOS/VoxStudio" | rg -q Sparkle

      codesign -d --entitlements :- "$APP" 2>/dev/null | rg -q 'keychain-access-groups'
      codesign -d --entitlements :- "$APP" 2>/dev/null | rg -q 'com.apple.application-identifier'
      if codesign -d --entitlements :- "$APP" 2>/dev/null | rg -q 'com\.apple\.developer\.applesignin'; then
        echo 'Developer ID Apple sign-in entitlement found'
        exit 1
      fi

      xcrun stapler validate "$APP"
      spctl --assess --type execute --verbose=4 "$APP"

The expected spctl result is accepted with a notarized Developer ID source. Under the current profile-bound path, a missing or certificate-mismatched profile, a missing Keychain access group, or the presence of the restricted Apple sign-in entitlement is a release blocker.

When an Apple Silicon Mac running macOS 15 is available, launch the notarized app from the mounted DMG, sign in, and perform one authenticated backend read. This provides runtime coverage for the prebuilt Convex Rust archive. If the test is not run, record macOS 15 runtime coverage as unverified; publication can proceed after the package checks in this runbook pass.

## 6. Verify the DMG and the app inside it

Verify the DMG signature and ticket:

      codesign --verify --strict --verbose=2 "$DMG"
      xcrun stapler validate "$DMG"
      spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

Mount the DMG read-only and repeat the executable checks against the copy users will install:

      ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG")"
      MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print substr($0,index($0,"/Volumes/")); exit}')"
      test -n "$MOUNT_POINT"
      MOUNTED_APP="$MOUNT_POINT/VoxStudio.app"
      test -d "$MOUNTED_APP"
      codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
      codesign -d --entitlements :- "$MOUNTED_APP" 2>/dev/null \
        | plutil -extract com.apple.security.device.audio-input raw -o - - \
        | rg -q '^true$'
      /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$MOUNTED_APP/Contents/Info.plist" >/dev/null
      test -e "$MOUNTED_APP/Contents/embedded.provisionprofile"
      test -d "$MOUNTED_APP/Contents/Frameworks/Sparkle.framework"
      otool -L "$MOUNTED_APP/Contents/MacOS/VoxStudio" | rg -q Sparkle
      if codesign -d --entitlements :- "$MOUNTED_APP" 2>/dev/null | rg -q 'com\.apple\.developer\.applesignin'; then
        echo 'Apple sign-in entitlement found in mounted DMG app'
        hdiutil detach "$MOUNT_POINT"
        exit 1
      fi
      codesign -d --entitlements :- "$MOUNTED_APP" 2>/dev/null | rg -q 'keychain-access-groups'
      xcrun stapler validate "$MOUNTED_APP"
      spctl --assess --type execute --verbose=4 "$MOUNTED_APP"
      hdiutil detach "$MOUNT_POINT"

If any check fails, keep the artifact local, inspect the signing output, fix the packaging configuration, and rebuild. Do not upload an unverified or partially stapled DMG.

## 7. Post-install microphone and Screen Recording checks

After installing the DMG, launch `/Applications/VoxStudio.app` and test
`Voice Library -> New reference -> Start recording`. The expected result is a
macOS microphone prompt on first use, followed by an active recording state;
the app must not remain on `Microphone access is denied` when the current app
is enabled in System Settings.

Also test Display and Region capture against the installed app. A successful
Window capture through the ScreenCaptureKit picker does not prove that the
global Display/Region preflight is authorized.

If System Settings shows access enabled but the app still reports denial, first
quit every VoxStudio/Voxella Studio process, confirm the test path, and inspect
the installed app's authority and designated requirement:

      codesign -dv --verbose=4 /Applications/VoxStudio.app
      codesign -dr - /Applications/VoxStudio.app

TCC grants are bound to that requirement, not just the visible path or bundle
identifier. A grant recorded for Developer ID will not match a build silently
signed with Apple Development; `tccd` may report `Failed to match existing code
requirement` and OSStatus `-67050`. Correct the signing identity/profile and
rebuild before resetting any permission.

Only after the signature is correct may stale decisions be cleared with the
user's authorization. Quit and relaunch the app before requesting again:

      tccutil reset Microphone com.voxella.studio
      tccutil reset ScreenCapture com.voxella.studio

Do not delete an older app bundle as part of release packaging unless the user
explicitly requests cleanup. The release evidence must identify the tested
bundle path, display name, bundle identifier, signature, and microphone
and Display/Region permission results.

## 8. Record the exact artifact

Include the packaged `metal-build.json`, the current-machine result from
`scripts/verify_metal.py`, shader byte count, and physical-device results from
[Metal compatibility](metal-compatibility.md). Re-run the verifier against the
mounted DMG app as well as the source app. An available GPU on the build host
does not establish compatibility with older OS versions or lower-memory Macs.

Record these values immediately before upload:

      stat -f 'DMG bytes=%z' .build/VoxStudio.dmg
      shasum -a 256 .build/VoxStudio.dmg

The local SHA-256 is the comparison value for the uploaded file. The DMG byte count must also match the remote response.

## 9. Publish to Cloudflare R2

Production publication uses the EU Cloudflare R2 bucket `vox`:

      R2__ACCOUNT_ID=830eacc6f0bf33e7119b6c71ed13e03d
      R2__BUCKET=vox
      R2__API_BASE_URL=https://830eacc6f0bf33e7119b6c71ed13e03d.eu.r2.cloudflarestorage.com
      R2__REGION=auto

Load the access key and secret from the local
`../voxella-docker-deploy/.env.prod.myvps2` file; never print or commit them.
The Worker binding must remain `RELEASE_BUCKET=vox` with the EU jurisdiction.
The publisher writes under `app-releases/voxstudio`:

      app-releases/voxstudio/releases/<version>-<build>/<sha256>/VoxStudio.dmg
      app-releases/voxstudio/releases/<version>-<build>/<sha256>/manifest.json
      app-releases/voxstudio/releases/<version>-<build>/<sha256>/appcast.xml
      app-releases/voxstudio/releases/<version>-<build>/<sha256>/chunks/000000.bin
      app-releases/voxstudio/releases/<version>-<build>/<sha256>/deltas/<filename>  # only when generated
      app-releases/voxstudio/channels/stable.json

These objects are served publicly through `https://assets.voxstudio.me/downloads/voxstudio/`.
Do not switch to another bucket or to the non-EU endpoint without coordinating
the Worker binding and confirming the bucket jurisdiction.

The default wrapper already runs this path after a verified local artifact exists. To run the publisher separately:

      uv run --no-project --with boto3 python scripts/r2_release.py run \
        --dmg .build/VoxStudio.dmg \
        --version "$VERSION" \
        --build "$BUILD" \
        --signature "$SPARKLE_SIGNATURE" \
        --enable-archives

Equivalent staged invocation:

      uv run --no-project --with boto3 python scripts/r2_release.py prepare --dmg .build/VoxStudio.dmg --version "$VERSION" --build "$BUILD" --signature "$SPARKLE_SIGNATURE" --enable-archives
      uv run --no-project --with boto3 python scripts/r2_release.py upload --staging-dir .build/r2-release/$VERSION-$BUILD/$SHA256
      uv run --no-project --with boto3 python scripts/r2_release.py verify --staging-dir .build/r2-release/$VERSION-$BUILD/$SHA256
      uv run --no-project --with boto3 python scripts/r2_release.py cache-check --staging-dir .build/r2-release/$VERSION-$BUILD/$SHA256
      uv run --no-project --with boto3 python scripts/r2_release.py promote --staging-dir .build/r2-release/$VERSION-$BUILD/$SHA256

`prepare` hashes the stapled DMG and writes immutable metadata and legacy chunk artifacts. Downloads use the original R2 DMG stream, not JS chunk assembly. `upload` refuses to overwrite an existing identity with different content.

### Sparkle binary deltas

The Developer ID app embeds Sparkle and can install a binary `.delta` when its installed build matches a delta base listed in `<sparkle:deltas>`. This is separate from the legacy `chunks/` objects above; Sparkle does not assemble those chunks. Keep the full-DMG enclosure in the appcast as the fallback for builds without a matching delta.

- `scripts/release.sh` passes `--enable-archives` on its normal R2 path. For a direct `r2_release.py run` or `prepare` invocation, pass `--enable-archives` explicitly or no DMG history is retained for delta generation.
- `RELEASE_ENABLE_DELTAS=auto` is the default. After archiving the current DMG, `prepare` generates deltas only on macOS and when at least two DMGs are retained in `.build/release-archives/`. It keeps at most five DMGs; Sparkle's `generate_appcast` determines eligible base builds from the staged release and retained archives.
- `RELEASE_ENABLE_DELTAS=0` forces a full-DMG-only appcast. `RELEASE_ENABLE_DELTAS=1` requires macOS and at least two retained DMGs; unmet prerequisites fail `prepare`.
- Delta generation requires `.build/sparkle-tools/bin/generate_appcast` and the Sparkle EdDSA private key. `SPARKLE_ED_KEY_FILE` selects the key file; otherwise the script looks for `~/.config/sparkle/sparkle_eddsa_priv.pem`. Before reporting the key unavailable, also check for a configured path and protected backups under the ignored `.secrets/` directory, then verify the candidate against `SUPublicEDKey` without printing key material. Do not print, copy into the artifact, or upload the private key. If automatic delta generation is eligible but the tool or key is unavailable, `prepare` fails before the upload stages; fix the prerequisite or explicitly choose `RELEASE_ENABLE_DELTAS=0`.
- Eligibility does not guarantee that Sparkle emits a delta. If `prepare` reports `Generated 0 delta(s)`, inspect the generated appcast, retained archive list, matching build metadata, and staged `deltas/` directory to determine whether no base was eligible or whether packaging/parsing needs investigation. Do not label this as an intentional skip or claim a cause without evidence. Continue with the full-DMG enclosure only when it is present and verified; report zero deltas generated/uploaded and that the DMG fallback remains available.
- Generated `.delta` files are staged under `.build/r2-release/<version>-<build>/<sha256>/deltas/`, uploaded to `app-releases/voxstudio/releases/<version>-<build>/<sha256>/deltas/<filename>`, and referenced by immutable public URLs under `/downloads/voxstudio/releases/<version>-<build>/<sha256>/deltas/<filename>`.
- `verify` checks every delta URL in the prepared appcast with HTTP HEAD and checks its `Content-Length`. Do not promote unless the normal artifact verify and cache-check gates also pass.
- Developer ID builds include `SparkleUpdates`, embed `Sparkle.framework`, and use Sparkle for in-app checks and installation. A delta is usable only for an installed build that matches its `sparkle:deltaFrom` build and passes Sparkle signature validation. Mac App Store builds omit Sparkle. Always retain the full-DMG enclosure for full-update fallback.

The release sequence is `prepare → upload → verify → cache-check → promote → postcheck`. `verify` captures the current stable identity/ETag, fully downloads the immutable public URL, checks size/SHA-256/ETag, and records the serving cache deployment. This also warms the cache. `cache-check` checks actual range bytes, range headers, and an internal cache `HIT` on the same deployment, with at most three attempts. Persistent `DYNAMIC`, `BYPASS`, `UNKNOWN`, `FALLBACK`, or a changed cache deployment fails the normal cache release gate. Repeat verify after a cache deployment change.

`promote` requires this artifact's verification and cache-check, repeats the cache check, and conditionally updates stable using the ETag observed before verification. A concurrent stable change or HTTP 412 stops publication. Already-current releases are idempotent. The subsequent `postcheck` verifies latest's no-store 302 and the appcast's immutable enclosure/length.

Publication state is stored beside the staged artifact in `publish-state.json`, bound to the artifact, public origin, and R2 target. The staging root's `state.json` only locates the artifact for resume; historical root-level verification flags do not authorize a new promote. A failed postcheck preserves the successful promote and reports that stable has already switched. Retry with `postcheck --staging-dir ...` or `RELEASE_RESUME=1 ./scripts/release.sh`; resume uses the staged signed DMG without bumping the version or rebuilding it.

Credentials come from `R2__ACCOUNT_ID`, `R2__ACCESS_KEY_ID`, `R2__SECRET_ACCESS_KEY`, and `R2__BUCKET`. Never print those values. `RELEASE_DRY_RUN=1` performs no remote writes and does not record simulated verify/promote success. `RELEASE_PROMOTE=0` stops after cache-check. `RELEASE_BOOTSTRAP=1` is required only for initial publication.

Normal publication uses `RELEASE_DELIVERY_MODE=cache`. For an explicit degraded release, first set the public Worker's delivery mode to origin, then use `RELEASE_DELIVERY_MODE=origin RELEASE_ORIGIN_REASON="reason" ./scripts/release.sh` (or `--delivery-mode origin --origin-reason ...` in the Python CLI). Integrity checks remain mandatory; the probe must confirm `ORIGIN`, not incidental cache fallback. DMGs above the conservative 512,000,000-byte cache limit require this explicit mode. HTTP/3 settings are unchanged by this workflow.

Do not upload this artifact to Hugging Face. Existing Hugging Face files stay in place and are no longer updated.

## 10. Public download checks

After promote, verify:

      curl -fsSIL 'https://assets.voxstudio.me/downloads/voxstudio/VoxStudio.dmg'
      curl -fsS 'https://assets.voxstudio.me/downloads/voxstudio/appcast.xml'
      curl -C - -o /tmp/VoxStudio-resume.dmg "$VERSIONED_URL"

Ordinary latest GET/HEAD must 302 to the immutable URL with `private, no-store`; HEAD ignores Range. A latest GET with Range only returns a partial body when `If-Range` exactly matches the current strong SHA-256 ETag. Missing/mismatched/weak/date validators get a full 200 without Content-Range so a different version cannot be appended. Versioned URLs can resume without If-Range; a supplied invalid validator forces a full 200. Do not use “delete the partial file and start over” as evidence that resume works.

The public gateway's Workers Cache is disabled. Only the private `voxstudio-release-cache` Worker caches complete immutable DMGs; it is called by Service Binding. The `X-VoxStudio-Release-Cache` response header reports its status, and `X-VoxStudio-Cache-Version` identifies its deployment. Public HEAD is metadata-only and reports ORIGIN; use a GET range for cache checks. A latest response may expose an internal HIT while its external response remains no-store. No Zone Cache Rule is needed for this architecture.

Run the worker repository's `scripts/verify-release-download.py --mode cache --output /tmp/VoxStudio-resume.dmg`. It checks HTTP contracts, interrupts a real download at 20 MiB, resumes it, verifies the combined SHA-256/size, and checks warm range bytes/HIT. Also test Safari pause/restart/old failures and the actual Developer ID Sparkle update flow. When the appcast has a delta for the installed build, verify that update path; also verify the full-DMG fallback. Record device/browser versions and network/POP; curl alone is not browser acceptance.

Rollback download delivery by setting the public Worker's `RELEASE_DELIVERY_MODE=origin` and redeploying. Keep `RELEASE_DOWNLOAD_MODE=origin`. This bypasses the private cache while retaining safe validators; do not roll back to the date-If-Range bug. Default cache entries are isolated per cache-Worker deployment, so warm and verify current stable after redeploying that Worker. Public gateway deployments do not redeploy the cache Worker.

Do not routinely purge immutable files or remove old R2 releases. Keep targeted emergency invalidation for incorrect cached content/headers, using the Workers Cache purge mechanism rather than assuming a zone purge controls this cache. HTTP/3 experiments require actual h2/h3 evidence and a separate zone-scoped change/rollback; no path-level HTTP/3 rule is configured.

## 11. TestFlight channel boundary

TestFlight is a separate release workflow. Use
`skills/voxstudio-testflight-release/SKILL.md` and its runbook for MAS
application/installer identities, the distribution profile, App Store Connect
validation and upload, processing, and internal tester groups.

When the user requests both channels, record the exact marketing version and
build selected here before starting the MAS build. The artifacts may share those
two values, but they must not share profiles, entitlements, signing identities,
Sparkle/notarization steps, or acceptance results.

## 12. Final report

Include:

- exact build command;
- signing identity and Team ID;
- notarization and stapling results for app and DMG;
- mounted-DMG verification result;
- confirmation that the expected Developer ID provisioning profile is embedded and no disallowed restricted entitlement remains;
- confirmation that `com.apple.security.device.audio-input=true` and `NSMicrophoneUsageDescription` are present in both the source app and mounted-DMG app;
- local DMG bytes and SHA-256;
- R2 identity, versioned URL, latest URL, appcast URL, and promote result;
- confirmation that in-app updates use the Cloudflare feed and that old Hugging Face installs are not claimed to migrate automatically;
- any manual UI test that remains for the user.

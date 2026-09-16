# VoxStudio Release Runbook

This runbook describes the complete Developer ID DMG and Hugging Face publication flow for this repository.

## 1. Preflight

Run from the repository root:

      cd /Users/adamwang/Project/subdub/voxella-studio-app
      git status --short
      test -x scripts/bundle.sh
      test -f Package.swift
      test -f scripts/VoxStudio.developer-id.entitlements

Confirm the supported deployment target remains macOS 15.0 across build and release metadata:

      rg -n 'platforms: \[\.macOS\(\.v15\)\]' Package.swift
      /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Sources/PalmierPro/Resources/Info.plist | rg -q '^15\.0$'
      rg -n 'MINIMUM_SYSTEM_VERSION.*LSMinimumSystemVersion|minimum_system_version' scripts/release.sh

The complete release includes Textual and bundled speech, both of which require macOS 15. Keep macOS 26-only APIs behind availability checks and preserve the macOS 15 fallback instead of raising the target. The Convex binary target may emit warnings for vendor objects stamped with the build host's newer macOS version; preserve those warnings in the release record and complete the macOS 15 runtime smoke test below.

Inspect release variables without printing values:

      for name in SIGNING_IDENTITY TEAM_IDENTIFIER NOTARY_PROFILE PROVISIONING_PROFILE; do
        if grep -q "^$name=" .env.prod 2>/dev/null || grep -q "^$name=" .env 2>/dev/null; then
          echo "$name is configured"
        else
          echo "$name is not configured"
        fi
      done

The script gives .env.prod precedence for release builds. Do not source either file into a command transcript, and do not paste its contents into a report.

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

Sparkle update signing is independent of Developer ID signing and Apple notarization. The public key in `Sources/PalmierPro/Resources/Info.plist` must match the private key used for every published appcast enclosure.

Check the existing key without printing private material:

      SPARKLE_ROOT='.build/artifacts/sparkle/Sparkle'
      "$SPARKLE_ROOT/bin/generate_keys" -p
      /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/PalmierPro/Resources/Info.plist
      "$SPARKLE_ROOT/bin/sign_update" -p .build/VoxStudio.dmg

If the Keychain lookup fails or the public key differs, stop and recover the original Sparkle private key before publishing. A newly generated key cannot update already-installed apps that trust the old `SUPublicEDKey`.

Only when key rotation is explicitly intended:

      mkdir -p .secrets
      "$SPARKLE_ROOT/bin/generate_keys"
      "$SPARKLE_ROOT/bin/generate_keys" -x .secrets/sparkle-ed25519-private.key
      chmod 600 .secrets/sparkle-ed25519-private.key
      git check-ignore -v .secrets/sparkle-ed25519-private.key

Copy the newly generated public key into `SUPublicEDKey`, retain the private backup only under `.secrets/`, and verify `generate_keys -p` matches the plist before building. On another machine, import the protected backup with `generate_keys -f .secrets/sparkle-ed25519-private.key`. Never print, commit, upload, or place the private key in a DMG or command-line argument.

For the Hugging Face distribution path, set the appcast feed and latest enclosure to public URLs:

      https://huggingface.co/hfadam/VoxStudio.app/resolve/main/appcast.xml
      https://huggingface.co/hfadam/VoxStudio.app/resolve/main/VoxStudio.dmg?download=true

Upload both `appcast.xml` and `VoxStudio.dmg`, and verify the remote appcast contains the exact artifact version, byte count, and valid `sparkle:edSignature` before reporting the release.

## 2. Select and record the release version

Formal releases must use the release wrapper with no manually supplied version:

      ./scripts/release.sh

Before it changes `Info.plist`, the wrapper reads the current
`CFBundleShortVersionString` and the highest version in the published appcast,
then selects the next semantic-version patch (`X.Y.Z` becomes `X.Y.(Z+1)`).
It also plans a new `CFBundleVersion`. A release must never reuse the prior
marketing version, and the release record must contain the previous version,
new version, build number, DMG hash, and the exact version uploaded.

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
      test ! -e "$APP/Contents/embedded.provisionprofile"
      /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" | rg -q '^15\.0$'
      otool -l "$APP/Contents/MacOS/VoxStudio" \
        | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}' \
        | rg -q '^15\.0$'

      if codesign -d --entitlements :- "$APP" 2>/dev/null | rg -q 'com\.apple\.developer\.applesignin|com\.apple\.developer\.team-identifier|keychain-access-groups'; then
        echo 'Restricted Developer ID entitlements found'
        exit 1
      fi

      xcrun stapler validate "$APP"
      spctl --assess --type execute --verbose=4 "$APP"

The expected spctl result is accepted with a notarized Developer ID source. A profile or one of the restricted entitlements is a release blocker.

On an Apple Silicon Mac running macOS 15, launch the notarized app from the mounted DMG, sign in, and perform one authenticated backend read. This smoke test is required because compile-time availability checks cannot prove that the prebuilt Convex Rust archive avoids newer runtime symbols.

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
      test ! -e "$MOUNTED_APP/Contents/embedded.provisionprofile"
      if codesign -d --entitlements :- "$MOUNTED_APP" 2>/dev/null | rg -q 'com\.apple\.developer\.applesignin|com\.apple\.developer\.team-identifier|keychain-access-groups'; then
        echo 'Restricted entitlements found in mounted DMG app'
        hdiutil detach "$MOUNT_POINT"
        exit 1
      fi
      xcrun stapler validate "$MOUNTED_APP"
      spctl --assess --type execute --verbose=4 "$MOUNTED_APP"
      hdiutil detach "$MOUNT_POINT"

If any check fails, keep the artifact local, inspect the signing output, fix the packaging configuration, and rebuild. Do not upload an unverified or partially stapled DMG.

## 7. Post-install microphone/TCC check

After installing the DMG, launch `/Applications/VoxStudio.app` and test
`Voice Library -> New reference -> Start recording`. The expected result is a
macOS microphone prompt on first use, followed by an active recording state;
the app must not remain on `Microphone access is denied` when the current app
is enabled in System Settings.

If System Settings still shows an older `Voxella Studio.app` entry, first quit
all VoxStudio/Voxella Studio processes and confirm that the test is using
`/Applications/VoxStudio.app`. A stale TCC decision can be cleared for this
bundle ID with the user-authorized command below, then the app must be quit
and relaunched before requesting permission again:

      tccutil reset Microphone com.voxella.studio

Do not delete an older app bundle as part of release packaging unless the user
explicitly requests cleanup. The release evidence must identify the tested
bundle path, display name, bundle identifier, signature, and microphone
permission result.

## 8. Record the exact artifact

Record these values immediately before upload:

      stat -f 'DMG bytes=%z' .build/VoxStudio.dmg
      shasum -a 256 .build/VoxStudio.dmg

The local SHA-256 is the comparison value for the uploaded file. The DMG byte count must also match the remote response.

## 9. Publish to Hugging Face with the helper

The helper defaults to the verified local artifact and the project repository:

      ./skills/voxstudio-release/scripts/upload_dmg_to_huggingface.sh

Equivalent explicit invocation:

      ./skills/voxstudio-release/scripts/upload_dmg_to_huggingface.sh \
        --dmg .build/VoxStudio.dmg \
        --repo-id hfadam/VoxStudio.app \
        --repo-type model \
        --revision main \
        --remote-path VoxStudio.dmg \
        --commit-message 'Upload verified VoxStudio DMG'

The helper selects hf or huggingface-cli, supports the project Python 3.12.12 fallback when configured through pyenv, checks CLI authentication, uploads without a token argument, and verifies the remote file by HTTP HEAD. It compares the local size and SHA-256 with Hugging Face Xet metadata when available and prints the remote commit and download URL.

The helper's --repo-type option is accepted for clarity even though this project defaults to model. Keep the repository ID and revision explicit when publishing a different destination.

## 10. Browser fallback

Use this only when the user explicitly requested the upload and the CLI is unavailable, but an authenticated browser session is available:

1. Open https://huggingface.co/hfadam/VoxStudio.app/upload/main.
2. Choose the verified .build/VoxStudio.dmg.
3. Keep the destination path as VoxStudio.dmg.
4. Keep Commit directly to main selected unless the user requested another branch.
5. Commit the change and wait until the file and latest commit are visible.
6. Verify the download URL:

       https://huggingface.co/hfadam/VoxStudio.app/resolve/main/VoxStudio.dmg?download=true

7. Verify the response and hash from a terminal:

       curl -fsSIL 'https://huggingface.co/hfadam/VoxStudio.app/resolve/main/VoxStudio.dmg?download=true'

The response should expose x-repo-commit, a byte count matching the local DMG, and, for the current Xet-backed repository, x-linked-etag matching the local SHA-256. If the hash header is absent, verify the file size and the repository tree/API before reporting completion.

## 11. Final report

Include:

- exact build command;
- signing identity and Team ID;
- notarization and stapling results for app and DMG;
- mounted-DMG verification result;
- confirmation that no embedded provisioning profile or restricted Developer ID entitlement remains;
- confirmation that `com.apple.security.device.audio-input=true` and `NSMicrophoneUsageDescription` are present in both the source app and mounted-DMG app;
- local DMG bytes and SHA-256;
- Hugging Face repository, revision, remote commit, remote size/hash, and download URL;
- any manual UI test that remains for the user.

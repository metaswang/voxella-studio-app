---
name: voxstudio-release
description: Build, sign, notarize, verify, and publish a macOS VoxStudio DMG for Developer ID distribution. Use when preparing a user-downloadable release, diagnosing packaging/signing omissions, or updating the VoxStudio DMG on Hugging Face.
---

# VoxStudio Release

Use this project skill for the complete macOS release flow. It keeps the build, signing, notarization, verification, and Hugging Face publication parameters together so a release is reproducible.

Read references/release-runbook.md before performing a release. Use scripts/upload_dmg_to_huggingface.sh for authenticated CLI publication and remote verification.

## Scope and authorization

- Build and local verification are allowed when the user asks for a DMG or release check.
- Upload to Hugging Face only when the user explicitly asks to publish or update it.
- Never commit, push, create a release, or modify unrelated repositories unless the user explicitly requests it.
- Preserve unrelated worktree changes, including changes outside this release skill.
- Do not print .env files, tokens, private keys, certificate passwords, or browser/session data.
- If the user requests a commit or push, show the final diff and verification results before the requested confirmation gate.

## Release invariants

- Work from the repository root: /Users/adamwang/Project/subdub/voxella-studio-app.
- The final distribution command is:

      ./scripts/bundle.sh release --dist

- The release build must use the BundledSpeech trait because the app includes speech and MLX resources.
- scripts/bundle.sh loads .env.prod for release when present, otherwise .env.
- SIGNING_IDENTITY must identify a Developer ID Application certificate.
- TEAM_IDENTIFIER must match the Team ID in that certificate. The bundle script can derive it from the certificate when omitted.
- NOTARY_PROFILE must name an existing xcrun notarytool Keychain profile.
- PROVISIONING_PROFILE is for the Mac App Store path only. Do not use MacDevelopment.provisionprofile for the Developer ID distribution path.
- Developer ID microphone recording requires `com.apple.security.device.audio-input=true` in the signed app. `scripts/bundle.sh release --sign` and `release --dist` must use `scripts/VoxStudio.developer-id.entitlements` for this capability.
- Keep `NSMicrophoneUsageDescription` in the final app `Contents/Info.plist`; an entitlement without the usage description is not sufficient for TCC authorization.
- The Developer ID app must not contain Contents/embedded.provisionprofile.
- The Developer ID app must not carry com.apple.developer.applesignin, com.apple.developer.team-identifier, or keychain-access-groups.
- Google and Apple account login use the browser OAuth/PKCE flow in the current app. Do not reintroduce native GoogleSignIn SDK configuration or restricted entitlements into this release.
- Expected outputs are .build/VoxStudio.app and .build/VoxStudio.dmg.

## Standard workflow

1. Check the worktree and release configuration without exposing secret values.
2. Read the runbook and confirm the exact certificate, notary profile, output paths, and target Hugging Face repository.
3. Run ./scripts/bundle.sh release --dist.
4. Verify the app, mounted DMG app, staple tickets, Developer ID signatures, microphone entitlement, restricted entitlements, and Gatekeeper assessments.
5. Record the DMG byte count and SHA-256 before publication.
6. If explicitly requested, upload exactly that verified DMG to the target Hugging Face repository.
7. Verify the remote commit, byte count, and content hash before reporting the download URL.

## Hugging Face defaults

The project publication defaults are:

- Repository: hfadam/VoxStudio.app
- Repository type: model
- Revision: main
- Remote file: VoxStudio.dmg
- Local file: .build/VoxStudio.dmg
- Download URL: https://huggingface.co/hfadam/VoxStudio.app/resolve/main/VoxStudio.dmg?download=true

The helper requires an existing Hugging Face CLI login. It never accepts a token argument and never prints a token. If CLI authentication is unavailable but the user has an authenticated browser session, use the browser upload procedure in the runbook and still perform the remote HEAD verification.

## Completion report

Report:

- build command and whether it completed;
- signing identity and Team ID, without secret material;
- notarization/stapling status;
- app and mounted-DMG Gatekeeper results;
- restricted-entitlement and embedded-profile checks;
- `com.apple.security.device.audio-input=true` and `NSMicrophoneUsageDescription` checks;
- DMG size and SHA-256;
- Hugging Face repository, revision, remote commit, and download URL when uploaded;
- anything not verified or requiring manual UI confirmation.

Do not claim that account login works from packaging checks alone; login remains a manual end-to-end verification.

# Signing identity and macOS TCC

## Why a visible permission toggle can still fail

macOS privacy grants are bound to the app's code requirement, not merely its
display name, bundle identifier, or path. With bundle ID `com.voxella.studio`, a
System Settings row can remain enabled for a Developer ID build while an Apple
Development-signed or ad-hoc build at the same path fails the recorded
requirement. `tccd` commonly reports a code-requirement mismatch with OSStatus
`-67050` in this case.

The confirmed failure mode in this repository was:

- the existing Screen Recording grant required the Developer ID certificate for
  Team ID `4DMAQ32SNU`;
- `.build/VoxStudio.app` had silently been signed with an Apple Development
  certificate because a generic development profile was used;
- System Settings still showed VoxStudio enabled;
- Window capture worked through the ScreenCaptureKit picker/session path, but
  Display and Region failed the global `CGPreflightScreenCaptureAccess` check.

The confirmed repair was to build `debug --sign` with the matching Developer ID
Application identity and
`DEVELOPER_ID_PROVISIONING_PROFILE=.secrets/VoxStudio_Developer_ID.provisionprofile`.
Both Display and Region then produced frames and system audio without resetting
the grant.

## Compare identity before touching TCC

Inspect the current artifact:

```bash
codesign -dv --verbose=4 .build/VoxStudio.app
codesign -dr - .build/VoxStudio.app
codesign -d --entitlements :- .build/VoxStudio.app
```

Decode only the metadata required from the selected profile into a temporary
file, then remove it:

```bash
PROFILE_PLIST="$(mktemp -t voxstudio-profile)"
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST"
rm -f "$PROFILE_PLIST"
```

Do not dump the complete profile or environment. `bundle.sh` additionally
extracts the embedded signing certificate and fails when its common name differs
from the selected signing identity.

## Diagnose a permission mismatch

1. Quit every VoxStudio process so the next launch cannot reuse an old binary.
2. Rebuild in the intended channel and inspect its authority and designated
   requirement.
3. Observe `tccd` while reproducing the exact operation:

   ```bash
   log stream --style compact --info \
     --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "com.voxella.studio"'
   ```

4. Treat `Failed to match existing code requirement`, `-67050`, or a denied
   preflight beside an enabled UI toggle as a signing/TCC identity problem first.
5. Correct the identity/profile pairing, rebuild, quit, and relaunch. Only after
   the identity is correct should the user toggle or remove/re-add the permission
   row if macOS still caches a denial.

Do not begin with `tccutil reset`. Resetting permissions does not repair a wrong
signature and unnecessarily discards valid user consent. Never edit the TCC
database directly.

## Channel invariants

### Direct signed debug

- Authority begins with `Developer ID Application:`.
- Profile certificate is Developer ID Application and matches the authority.
- Team ID, `com.apple.application-identifier`, and
  `keychain-access-groups` all resolve to `TEAMID.com.voxella.studio`.
- `com.apple.security.device.audio-input=true` is present.
- `com.apple.developer.applesignin` is absent.
- Sparkle is linked and embedded.

### Local MAS debug

- Profile certificate begins with `Apple Development:` and is installed.
- The final app is signed with that profile-bound Apple Development certificate.
- App sandbox, Apple sign-in, microphone, application identifier, Team ID, and
  Keychain group entitlements are present.
- Sparkle framework, linkage, and updater Info.plist keys are absent.

### Ad-hoc debug

- Authority is ad-hoc and the app uses the debug entitlements.
- It deliberately uses an isolated in-memory credential store.
- Its privacy grants and Keychain behavior are not release acceptance evidence.


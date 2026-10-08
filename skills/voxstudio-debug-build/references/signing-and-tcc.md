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

## TestFlight and Developer ID can also conflict

The 2026-10-07 incident had a correct Developer ID signature. `tccd` rejected
ScreenCapture at 13:25 because the existing grant required the installed
TestFlight app's signature. The observed designated requirements differed:

- `/Applications/VoxStudio.app`: `TestFlight Beta Distribution`, with leaf
  certificate OID `1.2.840.113635.100.6.1.25.1`;
- `.build/VoxStudio.app`: `Developer ID Application`, with leaf certificate OID
  `1.2.840.113635.100.6.1.13` and Team ID `4DMAQ32SNU`.

The two apps shared `com.voxella.studio` and were running simultaneously. Later,
the grant matched Developer ID and rejected the TestFlight app instead. After
quitting both instances and rebuilding `debug --sign`, Display, App, and Region
all exported playable video with the reverted capture code; no TCC reset was
performed during that acceptance run.

A valid signature does not make consent recorded for another channel match.
Compare the grant requirement in `tccd` with the actual running artifact before
changing capture code. When switching channels, verify the intended app's
permission; an enabled VoxStudio row alone is insufficient evidence. If the
correctly signed intended channel remains denied, re-authorize that artifact
through System Settings with the user's authorization. Keep local acceptance
on one channel and quit other instances.

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

1. Inspect running executable paths, including `/Applications/VoxStudio.app`
   and `.build/VoxStudio.app`. Quit every VoxStudio process so the next launch
   cannot reuse an old binary. Confirm they actually exited; `pkill ... || true`
   can hide a process-access failure in a restricted execution environment.
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
   row if the grant belongs to a different channel or macOS still caches a
   denial. If the pairing is already correct, do not change it merely to match
   consent for another channel.

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

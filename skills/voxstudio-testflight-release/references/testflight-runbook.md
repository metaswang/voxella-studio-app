# VoxStudio macOS TestFlight runbook

## 1. Establish the source and version

Read the current source values:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/VoxstudioPro/Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/VoxstudioPro/Resources/Info.plist
git status --short --branch
git diff -- scripts/bundle.sh scripts/bundle-mas.sh Sources/VoxstudioPro/Resources/Info.plist
```

Before an upload, inspect the app's macOS builds in App Store Connect. The
selected `CFBundleVersion` must not already exist. If the build exists, choose a
new integer build number, update the source plist, rebuild, and repeat every
validation. Never edit only the packaged plist or attempt to overwrite an
accepted build.

If this TestFlight build accompanies a direct-distribution release, record and
reuse that release's exact marketing version and build. `scripts/release.sh`
auto-bumps the DMG channel, so do not run it after freezing the TestFlight
artifact and assume the versions still match.

Do not commit or push a version change unless the user requests it.

## 2. Read configuration without exposing secrets

`scripts/bundle-mas.sh` loads `.env.prod` when present, otherwise `.env`. Check
that these variable names are populated without printing their values:

- `TEAM_IDENTIFIER`
- `MAS_SIGNING_IDENTITY`
- `MAS_INSTALLER_IDENTITY`
- `MAS_PROVISIONING_PROFILE`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY_PATH`
- `VOXSTUDIO_APP_STORE_LIFETIME_PRODUCT_ID`

The expected product ID in this repository is
`com.voxella.studio.lifetime`. Confirm the built Info.plist value rather than
blindly rewriting configuration.

For the later `altool` commands, load the same trusted environment into the
current shell without echoing it:

```bash
ASC_ENV_FILE=.env
if [ -f .env.prod ]; then ASC_ENV_FILE=.env.prod; fi
set -a
. "$ASC_ENV_FILE"
set +a
```

Keep validation/upload and the API-key directory export below in that same
shell session. Merely running `bundle-mas.sh` does not export its variables back
to the caller.

Check installed distribution identities:

```bash
security find-identity -v -p codesigning | \
  rg '3rd Party Mac Developer (Application|Installer)'
```

Decode the MAS profile to a temporary plist and inspect only its name, UUID,
Team ID, application identifier, expiration, entitlements, and embedded
certificate common name. The certificate must match `MAS_SIGNING_IDENTITY`, and
the application identifier must be `TEAMID.com.voxella.studio`. Delete the
temporary file after inspection. Do not print the binary profile.

## 3. Make the API key discoverable to altool

`APP_STORE_CONNECT_API_PRIVATE_KEY_PATH` is repository configuration;
`xcrun altool` does not read that variable. It searches for
`AuthKey_<KEY_ID>.p8` in its standard directories or in
`API_PRIVATE_KEYS_DIR`.

Expand `~`, confirm the file exists and its basename matches the configured key
ID, and export only its directory:

```bash
ASC_KEY_PATH="${APP_STORE_CONNECT_API_PRIVATE_KEY_PATH/#\~/$HOME}"
test -f "$ASC_KEY_PATH"
test "$(basename "$ASC_KEY_PATH")" = "AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
test "$(stat -f '%Lp' "$ASC_KEY_PATH")" = "600"
export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"
```

The permission check may be stricter than necessary on an existing machine; if
it fails, use `chmod 600` only on the exact verified key path. Never print or
copy private-key contents.

## 4. Build the MAS package

```bash
./scripts/bundle-mas.sh
```

This calls `./scripts/bundle.sh release --mas`, writes
`.build/VoxStudio.app`, then creates `.build/VoxStudio.pkg` with
`productbuild`. It does not notarize the package.

The release MAS profile must be bound to the configured
`3rd Party Mac Developer Application` certificate. Do not use the local debug
Apple Development profile or `PROVISIONING_PROFILE` for this flow. The package
must use the separate `3rd Party Mac Developer Installer` identity.

## 5. Verify locally

```bash
./scripts/check-mas-billing.sh .build/VoxStudio.app
codesign --verify --deep --strict --verbose=2 .build/VoxStudio.app
codesign -dv --verbose=4 .build/VoxStudio.app
codesign -d --entitlements :- .build/VoxStudio.app
pkgutil --check-signature .build/VoxStudio.pkg
shasum -a 256 .build/VoxStudio.pkg
stat -f '%z' .build/VoxStudio.pkg
```

Also verify:

- source app and packaged app versions equal the intended version/build;
- `LSMinimumSystemVersion` is `15.0` and the Mach-O deployment target agrees;
- app sandbox, microphone, Apple sign-in, application identifier, Team ID, and
  Keychain access group entitlements are present;
- `Contents/embedded.provisionprofile` exists and matches the release MAS
  profile;
- Sparkle is neither linked nor embedded and Sparkle Info.plist keys are absent;
- the package contains the expected `/Applications/VoxStudio.app` payload;
- the external-billing scan reports no Stripe checkout or billing endpoints.

Do not infer StoreKit purchase success from packaging checks. Purchase, restore,
and account-link behavior require a processed TestFlight build and a real
sandbox account.

## 6. Validate with App Store Connect

Use the installed `altool` syntax and keep the result:

```bash
xcrun altool --validate-app .build/VoxStudio.pkg \
  --api-key "$APP_STORE_CONNECT_API_KEY_ID" \
  --api-issuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
  --output-format json
```

Validation is a network call but does not upload a TestFlight build. Treat every
error or warning according to the returned severity. If the package changes for
any reason, recalculate its hash and validate again.

## 7. Upload the validated package

Only after an explicit upload/TestFlight release request:

```bash
xcrun altool --upload-package .build/VoxStudio.pkg \
  --api-key "$APP_STORE_CONNECT_API_KEY_ID" \
  --api-issuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
  --wait \
  --output-format json
```

Save the returned delivery/request ID and state. If connectivity is lost after
Apple returns an ID, inspect that delivery in App Store Connect before retrying.
Do not create a second upload blindly. A duplicate-build response requires a new
source build number and complete rebuild/validation.

## 8. Processing and tester groups

After upload:

1. Wait for App Store Connect to finish processing and inspect compliance or
   invalid-binary messages.
2. Locate the preceding valid macOS TestFlight build and record its existing
   internal tester groups.
3. Associate the new build only with those unambiguous existing internal groups.
4. Verify the build appears in each group's Builds view.

If the API reports `Cannot add internal group to a build`, use the visible App
Store Connect UI. If the session is expired, leave the build page ready for the
user to sign in. Do not work around the limitation by adding individuals,
creating groups, or enabling external testing.

“Uploaded,” “Processing,” “Ready to Submit,” and “Ready to Test” are distinct.
Report the exact observed state. A TestFlight build does not submit the Mac App
Store version or the first non-consumable IAP for App Review; those are separate,
explicitly authorized actions.

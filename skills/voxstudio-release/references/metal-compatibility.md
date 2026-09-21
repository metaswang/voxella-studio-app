# Metal packaging and physical-device qualification

## Supported baseline

- One arm64 app for Apple silicon M1, M2, M3 and M4 families on macOS 15.0+.
- Keep `Package.swift`, `LSMinimumSystemVersion`, the executable's Mach-O minimum,
  and Sparkle minimum-system metadata aligned. A new SDK is not a reason to raise
  the user-facing minimum.
- All bundled shaders use `-mmacosx-version-min=15.0 -std=metal3.2`. This specifies
  the compatible language/OS baseline; it does not select a particular M chip or
  disable GPU acceleration. Do not build only for the host's GPU or use Metal 4
  features without a separately reviewed compatibility path.
- Retain one MLX library and the existing individual Core Image effect libraries.
  No per-chip library copies, CPU-only fallback, or runtime shader downloads are
  needed for this packaging fix. Performance and RAM limits still need testing.

The upstream MLX build passes its deployment target to the Metal compiler:
[MLX CMake](https://github.com/ml-explore/mlx/blob/main/CMakeLists.txt).
Apple documents the language baseline in
[Metal language version 3.2](https://developer.apple.com/documentation/metal/mtllanguageversion/version3_2).

## Build and cache behavior

`scripts/build_metal.py` is the maintained entry point. Do not edit files inside
`.build/checkouts` or invoke the old speech-swift builder from packaging.

```sh
python3 scripts/build_metal.py preflight
python3 scripts/build_metal.py prepare --output .build/metal/release
python3 Tests/MetalBuildTests.py
```

`bundle.sh` calls prepare on every build and copies only the libraries and the
small `metal-build.json` manifest. The cache key includes source paths/content,
headers, compiler flags, deployment/language policy, builder version, Xcode,
Metal compiler identity and SDK identity. A cache hit also verifies the output
hash. Missing receipts, changed inputs, or damaged output trigger recompilation;
failures leave the last completed library intact but fail the current build.
Temporary AIR files are cleaned up; receipts and caches stay under `.build`.
No user model weights are copied into the app by these scripts.

The SwiftPM Core Image plugin uses the same builder. Packaging also rechecks all
CI shaders independently, preventing a stale SwiftPM resource cache from leaking
an old shader into the signed artifact. Do not suppress a failed probe merely
because code signing or notarization succeeded.

## Local packaging verification

```sh
./scripts/bundle.sh debug --sign
python3 scripts/verify_metal.py .build/VoxStudio.app --report .build/metal-host-check.json
```

The verifier checks the arm64 executable, declared minimum, complete library
inventory and hashes, then loads the MLX library through Metal and every effect
kernel through Core Image. It records OS, GPU, memory, app version/build, binary
hash and manifest hash. This needs Xcode Command Line Tools to compile the small
probe; it is a developer/release tool, not something shipped to customers.
Results stay outside the signed app. Repeat against the mounted DMG app using
the same script. Loading checks do not execute model inference or render a video.

## Real-Mac acceptance

Use the same signed DMG SHA-256 on all test machines, installed into Applications.
Use actual supported OS/device combinations rather than assuming every chip can
boot every old OS point release. Prefer this practical coverage:

| Coverage | Purpose |
| --- | --- |
| M1 with macOS 15, preferably 8 GB | Oldest chip, oldest supported OS, memory pressure |
| M2 on an available supported macOS | Additional GPU generation |
| M3 on an available supported macOS | Additional GPU generation |
| M4 on the newest stable macOS supported by the release | Newer GPU/runtime |
| Each other macOS major in the supported user population | OS runtime coverage on any suitable M-series Mac |

This is a coverage plan, not measured user distribution or a claimed complete
chip/OS cross-product. Record exact OS build, base/Pro/Max/Ultra chip, RAM and free
disk space. Treat beta OS results separately from stable release acceptance.
For a shader/toolchain/MLX change, prioritize both the M1/macOS 15 baseline and
the newest-system machine, and cover M2/M3 before claiming all four generations.
If devices are unavailable, mark their tests pending; users may supply results.

On each tested machine:

1. Cold-launch, remain open through background model prewarming (at least 60 s),
   close/reopen the main window, quit normally and relaunch.
2. Run local transcription, VAD/speaker identification and search embedding with
   existing weights; exercise at least one fresh download separately. Record the
   exact model/quantization and whether its memory footprint fits that machine.
3. Preview and export a short clip with representative bundled effects; check
   the output visually, not just whether the shader library loads.
4. Test recording permission, sign-in and a backend query, especially on macOS 15
   because vendor binary deployment warnings require runtime confirmation.
5. Record success/failure, launch/inference/export time, peak memory or memory
   pressure, and exit/log evidence. An 8 GB model OOM is distinct from a shader
   incompatibility and does not imply the entire chip generation is unsupported.

## Release record

Keep version/build, final DMG SHA-256, shader manifest SHA-256, aggregate shader
bytes and per-machine test results together. Compare shader bytes with the prior
release; a compatible rebuild replaces the old library rather than adding a
second copy. Report actual size changes and remaining coverage honestly.

When device testing is pending, use `RELEASE_TARGET=dmg ./scripts/release.sh` to
prepare the final local artifact. After testing and when publication is requested,
sign that same DMG's appcast metadata and run the existing separate R2 publication
flow in the runbook. Never rebuild between qualification and publication without
invalidating the corresponding artifact-specific test record.

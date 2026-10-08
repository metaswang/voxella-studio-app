---
name: start-voxella-studio
description: Build and start the signed local VoxStudio app while preserving the existing local model cache. Use when the user asks to start, launch, reopen, or run VoxStudio; use the dedicated debug-build skill for detailed MAS/non-MAS signing or TCC diagnosis.
---

# Start VoxStudio

Default to the signed non-MAS debug app so its Developer ID requirement remains
stable for Keychain and macOS privacy grants. Use `$voxstudio-debug-build` when
the user requests MAS, StoreKit, ad-hoc iteration, signing diagnosis, or TCC
acceptance.

## Startup command

From the repository root, quit the previous app when needed, rebuild, and open
the exact artifact that was just produced:

```bash
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"
```

`pkill` is optional when no previous instance is running. This command requires
the Developer ID Application identity and matching
`DEVELOPER_ID_PROVISIONING_PROFILE` configured in `.env`. Do not replace it with
`swift run` for normal startup; an ad-hoc identity can invalidate Keychain/TCC
acceptance even when the bundle path and identifier are unchanged.

## Startup procedure

1. Check the current worktree without modifying unrelated changes.
2. Run the command above from the repository root.
3. Confirm `.build/VoxStudio.app` is Developer ID signed and that the app opened.
   Verify the running executable is the artifact just built, for example with
   `ps -axo pid=,command= | rg '/VoxStudio.app/Contents/MacOS/VoxStudio'`.
   Check for a concurrently running `/Applications/VoxStudio.app`, especially a
   TestFlight installation. If process inspection or quitting is blocked by the
   execution environment, resolve that limitation rather than treating
   `pkill ... || true` or a successful `open` as proof of a fresh launch.
4. Keep the launched process running and report the launch result. Mention build
   warnings only if startup fails.

MAS and non-MAS packaging both replace `.build/VoxStudio.app`. A path previously
used for a signed build does not identify its current channel. When Screen
Recording looks enabled but capture is denied, compare the current signature
and `tccd` requirement using the debug-build skill's
[Signing and TCC reference](../voxstudio-debug-build/references/signing-and-tcc.md).

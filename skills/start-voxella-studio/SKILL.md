---
name: start-voxella-studio
description: Start Voxella Studio in local, native-login, or web-fallback mode while preserving the existing local model cache. Use when the user asks to start, launch, or run the app.
---

# Start Voxella Studio

Use the login mode requested by the user. If no mode is specified, use `local`.

## Modes

### `local`

Use for fast development and web OAuth fallback. Native Apple login is unavailable because `swift run` is ad-hoc signed.

```bash
VOXELLA_RUN_LOCAL_FIXTURES=1 swift run --traits BundledSpeech VoxellaStudio
```

### `native`

Use for native Sign in with Apple or native Google Sign-In. Build the provisioned app first, then launch it:

```bash
./scripts/bundle.sh debug --sign
open ".build/Voxella Studio.app"
```

This requires the paid-team signing identity and provisioning profile configured in `.env`. Do not replace this with `swift run`.

### `web`

Use when explicitly testing the browser OAuth flow, or when native credentials are unavailable. Start with `local`; the app will use `ASWebAuthenticationSession` and the VoxStudio web login page.

```bash
VOXELLA_RUN_LOCAL_FIXTURES=1 swift run --traits BundledSpeech VoxellaStudio
```

Do not force the app to open the web login page when native mode is requested. Native mode should attempt Apple or Google first and only use the app's existing fallback behavior when native authorization is unavailable.

## Startup procedure

1. Check for an existing `VoxellaStudio` or `swift run` process and avoid duplicate instances.
2. Run the command for the selected mode from the repository root.
3. Keep the launched process running and report the selected mode and launch result.
4. Mention build warnings only if startup fails.

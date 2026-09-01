---
name: start-voxella-studio
description: Start VoxStudio in local, native-login, or web-fallback mode while preserving the existing local model cache. Use when the user asks to start, launch, or run the app.
---

# Start VoxStudio

Use the login mode requested by the user. If no mode is specified, use `local`.

## Modes

### `local`

Use for fast development and web OAuth fallback. Native Apple login is unavailable because `swift run` is ad-hoc signed.

```bash
VOXELLA_RUN_LOCAL_FIXTURES=1 swift run --traits BundledSpeech VoxStudio
```

### `native`

Use for native Sign in with Apple or native Google Sign-In. Build the provisioned app first, then launch it:

```bash
./scripts/bundle.sh debug --sign
open ".build/VoxStudio.app"
```

This requires the paid-team signing identity and provisioning profile configured in `.env`. Do not replace this with `swift run`.

### `web`

Use when explicitly testing the browser OAuth flow, or when native credentials are unavailable. Start with `local`; the app will use `ASWebAuthenticationSession` and the VoxStudio web login page.

```bash
VOXELLA_RUN_LOCAL_FIXTURES=1 swift run --traits BundledSpeech VoxStudio
```

Do not force the app to open the web login page when native mode is requested. Native mode should attempt Apple or Google first and only use the app's existing fallback behavior when native authorization is unavailable.

## Startup procedure

1. Check for an existing `VoxStudio` or `swift run` process and avoid duplicate instances.
2. Run the command for the selected mode from the repository root.
3. Keep the launched process running and report the selected mode and launch result.
4. Mention build warnings only if startup fails.

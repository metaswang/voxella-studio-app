---
name: voxella-local-docker-debug
description: Build and run VoxStudio against the local Voxella Docker environment for API, Stripe test checkout, or webhook debugging. Use for local integration work; production builds and deployments must keep the live API.
---

# Voxella local Docker debugging

Use this skill when the user wants the signed macOS app to exercise the local Voxella web/API stack, including Stripe test-mode billing and webhook delivery.

## Local endpoints and configuration

- The web app at `http://localhost:5173/` proxies API requests to the local API container on port `8000`. The macOS app must use the web origin `http://localhost:5173` so web redirects and Stripe return URLs resolve locally.
- The Docker configuration and test Stripe credentials live in `../voxella-docker-deploy/.env.dev`. Never print, copy into the app, or commit values from that file. Confirm `STRIPE__MODE` is `test`, the API key has a test-key prefix, and a webhook secret is present before payment debugging.
- The API container and billing worker must be running. Check the Docker container status and verify `http://localhost:5173/` and `http://localhost:8000/openapi.json` respond successfully. The API may not provide a `/health` route; use `/openapi.json` for this check.
- Anonymous Lifetime also requires `MAC_ACCESS_ANONYMOUS_LIFETIME_CHECKOUT_ENABLED=true`, a configured `MAC_ACCESS_LICENSE_RECOVERY_KEY`, and the device-trial, anonymous-checkout, and license migrations in the local database. API and billing must use the same recovery key. Preserve existing keys; after an authorized local configuration fix, recreate the affected containers to reload `.env.dev`.
- Set `VITE_DEV_PROXY_CHANGE_ORIGIN=false` for the local Docker web service. This preserves `localhost:5173` in the request Host used by the API to generate Checkout return URLs. Inspect the new session's success/cancel URLs; `http://api:8000` is a Docker-internal address and cannot serve as a browser return URL.
- Stripe's sandbox webhook endpoint reaches the local API through the public ngrok API tunnel. Check the ngrok local inspector at `http://127.0.0.1:4040/api/tunnels`; the `api` tunnel must forward to `http://localhost:8000`, and its public URL must respond at `/openapi.json`. If the tunnel is absent, start `ngrok start api` in a persistent terminal and check the inspector again. Keep that process running while exercising webhooks.

## Build and launch

From the app repository root, stop any existing `VoxStudio` process before launching. Launch Services can reuse an already-running app, in which case a new `open --env` value does not replace that process's environment.

```bash
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --sign && open --env VOXELLA_API_BASE_URL=http://localhost:5173 "$PWD/.build/VoxStudio.app"
```

After launch, confirm the app log reports `account configured host=localhost` in `~/Library/Logs/Voxella Studio/app.log`. If Launch Services returns an error or does not leave the app running, launch the signed app executable directly with the same process-scoped override:

```bash
VOXELLA_API_BASE_URL=http://localhost:5173 "$PWD/.build/VoxStudio.app/Contents/MacOS/VoxStudio"
```

Keep that terminal process running and verify the same log entry before opening Checkout. Stop if the log reports `host=voxstudio.me`; that process would use production. The override applies only to the launched process. Keep it out of `.env`, `Info.plist`, source defaults, and release configuration. `VoxellaAPIConfiguration` otherwise defaults to `https://voxstudio.me`; production builds and deployments must continue to use that live origin.

The app isolates Keychain credentials, pending Checkout records, and offline licenses by API base URL. Production keeps its existing Keychain namespace. A local purchase must create or resume a session owned by the local backend; a cached `cs_live_` URL from an older build must never count as local checkout evidence.

Before a Stripe test checkout, reconfirm the local Stripe mode and test-key classification without displaying the credential. Confirm the actual session opened by the app is `cs_test_`, uses `price_1UKTAQE6DH8QTo1zHOCjkilY`, and Stripe reports `livemode=false`. Do not run a real/live payment flow as part of local debugging. When end-to-end verification is requested, correlate this new session through Stripe payment, ngrok webhook ingress, `billing_events`, the billing worker, the durable Lifetime purchase/license, and the app's unlocked UI. A launch log or an older successful test session is insufficient.

Report whether Docker, ngrok, the signed build, and app launch succeeded, the API origin used by the app, and the outcome of the actual Checkout session.

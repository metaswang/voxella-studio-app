# OpenAI plugin ZIP distribution

The app's Settings → MCP screen links to an immutable package for
`voxstudio@voxstudio-local` version `0.1.1` and
`voxstudio-knowledge@voxstudio-local` version `0.1.0`. Both plugins are
independently installable from one download. The package is a local marketplace
directory inside a ZIP, not a ZIP-import connector. Users extract it and run its
installer; the same instructions appear in `openai-plugin-install.md`, shipped
as `README.md` at the marketplace root.

The verified package is 15,368 bytes and contains 20 files. SHA-256:

```text
edbe20b7921d0e69200356ea5804417e9ce430a59a9d94ebe5f56833e78eed93
```

[Download the verified ZIP](https://assets.voxstudio.me/downloads/voxstudio/plugins/voxstudio/0.1.1/edbe20b7921d0e69200356ea5804417e9ce430a59a9d94ebe5f56833e78eed93/VoxStudio-OpenAI-Plugin.zip).

## Build and publish an update

```bash
python3 scripts/package-openai-plugin.py
python3 -m unittest discover -s Tests/scripts -p test_openai_plugin_package.py -v
uv run --no-project --with boto3 python scripts/r2_plugin_release.py upload
python3 scripts/r2_plugin_release.py verify --evidence .build/openai-plugin/cdn-verified.json
```

The packager publishes only explicitly selected manifests, icon and skill files.
Compatibility manifests are derived from portable sources. ZIP timestamps,
permissions and ordering are deterministic; `FILES.sha256` verifies extracted
contents. The installer supports a CLI path override and quotes paths containing
spaces. Local tests use a stub CLI and do not change the user's plugin settings.

The publisher uses the existing EU `vox` R2 bucket and credentials loading
helpers from `r2_release.py`. It conditionally creates the immutable object,
refuses changed bytes at an existing identity, and verifies the R2 round trip.
Public verification downloads all bytes, compares SHA-256/size, and checks ZIP
Content-Type, attachment disposition, ETag, immutable caching and HEAD.

Object layout:

```text
app-releases/voxstudio/plugins/voxstudio/<version>/<sha256>/VoxStudio-OpenAI-Plugin.zip
```

Its public URL is the same suffix under
`https://assets.voxstudio.me/downloads/voxstudio/`. No mutable latest pointer is
used. After verifying an update, change `pluginDownloadURL` and the displayed
version in `MCPInstructionsPane.swift` to the verified release values, then build
and sign the app. Do not change the DMG stable pointer or Sparkle appcast.

## CDN route and rollback

The existing CDN Worker repository is `../voxella-cloudflare-worker/lucky-lake-21e6`.
`src/plugin-downloads.ts` is called from `src/releases.ts` after path decoding and
existing host/method guards. It only serves the expected ZIP name at a semantic
version + 64-character SHA-256 path, requires matching R2 hash metadata and a
nonempty package ≤2 MiB. It supports HEAD, conditional GET and full-body GET;
ranges return a complete 200 because these packages are small.

The baseline Wrangler bundle matched the deployed script before the narrow
addition. All 52 Worker tests passed (5 cover ZIP downloads). The deployed Worker
version is `71e5dbef-bd54-42df-ae3a-6eebab27f66a`; the preceding version is
`5a5b16e9-a818-45c8-8c5f-e2cab5b5950e`. Restoring that preceding Worker version
removes ZIP support but preserves the preceding DMG/media behavior. Prefer
restoring the previous app package URL for a plugin content regression: do not
overwrite or delete an immutable ZIP to replace it with different bytes.

Machine-readable evidence is in
`docs/testing/knowledge-purpose-qa-2026-10-03/plugin-cdn-verification.json`
for this update; the original publication record remains in
`docs/testing/openai-mcp/plugin-cdn-verification.json`. This package/download
verification does not imply complete ChatGPT Work/Codex business-flow acceptance.

## Knowledge plugin update

Settings → MCP → ChatGPT Work / Codex defaults to Knowledge QA. Users can
choose Media workflows, copy the corresponding `--plugin` install command,
and enable either or both plugins. The endpoint and example prompts follow
the selection. The QA option does not remove media/frame indexes or change
the existing media tool profile. This publication reused the existing CDN
route and R2 publisher without changing the Worker, DMG channels or appcast.

# Unified plugin distribution (0.2.0)

The current App bundles the reproducible unified ZIP and exports it from Settings.
It contains one `voxstudio@voxstudio-local` plugin at `/app/mcp`. Claude Desktop's
extension is rebuilt from `mcpb/` as 0.3.1 during every App bundle. Source manifests,
transport bytes, UI HTML and package versions are checked before SwiftPM builds.
Both connectors and embedded panels use `Resources/AppIcon.png`. The bundle script
synchronizes that source before building; both package validators require the exact
App icon bytes, so an old connector logo cannot silently enter an artifact.

```sh
python3 scripts/sync-mcp-branding.py
npm --prefix mcp-ui run check
npm --prefix mcp-ui run build
python3 scripts/build-openai-plugin.py
python3 scripts/package-mcpb.py
python3 scripts/package-openai-plugin.py
python3 -m unittest discover -s Tests/scripts -p test_openai_plugin_package.py
node --test mcpb/tests/transport.test.js
```

Keep the SDK lock versions. Do not publish this ZIP or update any CDN URL until
Codex, ChatGPT Desktop and Claude Desktop have passed the real UI acceptance
sequence in `unified-workspace-acceptance.md`. Local packaging, HTTP and fixture
checks do not satisfy that gate. Older immutable ZIPs below remain rollback assets.

## Historical 0.1.2 distribution record

The previous App's Settings → MCP screen linked to an immutable package for
`voxstudio@voxstudio-local` version `0.1.2` and
`voxstudio-knowledge@voxstudio-local` version `0.1.0`. Both plugins are
independently installable from one download. The package is a local marketplace
directory inside a ZIP, not a ZIP-import connector. Users extract it and run its
installer; the same instructions appear in `openai-plugin-install.md`, shipped
as `README.md` at the marketplace root.

The verified package is 16,676 bytes and contains 20 files. SHA-256:

```text
31cb7283c7b7cae8b4e87736a5f941e261dc1833df8ec95103a84ff77240ea3c
```

[Download the verified ZIP](https://assets.voxstudio.me/downloads/voxstudio/plugins/voxstudio/0.1.2/31cb7283c7b7cae8b4e87736a5f941e261dc1833df8ec95103a84ff77240ea3c/VoxStudio-OpenAI-Plugin.zip).

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
used. For 0.2.0 the settings action exports the package bundled with the App; it has
no CDN download URL to replace. Rebuild and sign the App with the verified connector
sources and package. Do not change the DMG stable pointer or Sparkle appcast.

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
`docs/testing/mcp-plugin-2026-10-05/plugin-cdn-verification.json`
for this update; the original publication record remains in
`docs/testing/openai-mcp/plugin-cdn-verification.json`. This package/download
verification does not imply complete ChatGPT Work/Codex business-flow acceptance.

## Historical Knowledge plugin update

Settings → MCP → ChatGPT Work / Codex defaults to Knowledge QA. Users can
choose Media workflows, copy the corresponding `--plugin` install command,
and enable either or both plugins. The endpoint and example prompts follow
the selection. The QA option does not remove media/frame indexes or change
the existing media tool profile. This publication reused the existing CDN
route and R2 publisher without changing the Worker, DMG channels or appcast.

## Media workflow update (2026-10-05)

Media plugin 0.1.2 includes direct transcription from prompt paths and explicitly
identified ChatGPT attachments, automatic language/speaker defaults, and job/session
ID polling that keeps the result associated after its title changes. Knowledge
plugin 0.1.0 remains included. MCP server and panel fixes are supplied by the
VoxStudio app rather than embedded in the plugin ZIP.

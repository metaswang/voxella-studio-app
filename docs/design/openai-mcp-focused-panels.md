# VoxStudio MCP — focused panels

Implementation date: 2026-10-03. Replaces the all-in-one MCP workbench UI. HTML scope is transcription, voiceover and session results. Video editing is a prompt-driven native Mac editor workflow. All UI copy is fixed to English regardless of host/system locale; user content retains its language.

## Official example findings

Rechecked the official repository HEAD: `900032d8bd7c1566202d0cb1666986584f932043`.

- [Bits & Bolts registration](https://github.com/openai/mcp-extensions/blob/900032d8bd7c1566202d0cb1666986584f932043/plugins/bits-and-bolts/src/server/register.ts) separates global/thread/file entry tools, app-visible catalog reads, part detail tools, mutations, settings and forms. `cad.listParts` does not carry a UI resource; `cad.view` does. Its sample nevertheless shares one HTML resource across pages. Independent HTML documents are a VoxStudio product decision, not a requirement asserted by the example.
- [Example controller](https://github.com/openai/mcp-extensions/blob/900032d8bd7c1566202d0cb1666986584f932043/plugins/bits-and-bolts/src/app/controller.ts) demonstrates initialization, tool input/results, theme updates, replacing model context and guarding unsaved changes. VoxStudio follows those boundaries with the official MCP Apps SDK.
- [Entrypoints and display modes](https://github.com/openai/mcp-extensions/blob/900032d8bd7c1566202d0cb1666986584f932043/docs/spec.md) attach UI resources via `_meta.ui.resourceUri`, and static entrypoints via `_meta['openai/ui'].entrypoints`. Fullscreen preference belongs to resource metadata. Empty-object global/thread contracts are retained.
- [Forms helper](https://github.com/openai/mcp-extensions/blob/900032d8bd7c1566202d0cb1666986584f932043/plugins/bits-and-bolts/src/server/forms.ts) demonstrates explicit submission/cancellation. Existing Swift native transcription forms remain capability-gated; the HTML form is the ordinary complete path.
- A `tools/call` from an app returns data; it does not guarantee opening another UI. Cross-panel user actions use the standard `ui/message` request to ask the host to invoke a dedicated UI tool in the current conversation. This may involve a model turn and is host-dependent. The browser fixture simulates the receiving host; it does not prove native ChatGPT/Codex navigation.

## Independent documents

| Tool | Resource | Responsibility |
| --- | --- | --- |
| `app_workbench`, `voxstudio.library` | `ui://voxstudio/library/v3` | Two task entry cards, search/filter/recent sessions |
| `app_transcription` | `ui://voxstudio/transcription/v2` | Media selection, options, explicit start, job progress |
| `app_session`, `voxstudio.session_panel` | `ui://voxstudio/session/v3` | One result: reading, timed preview, opt-in text/timing edit, export |
| `app_dubbing` | `ui://voxstudio/dubbing/v2` | Script, saved voice, language, generation, preview and audio saving |

Panel resource versions change when shared HTML, branding, playback, or CSP changes, so hosts invalidate cached documents. Previous panel URIs remain readable aliases.

Each document has its own JS entry, initial tool result, state and teardown. Shared code is restricted to tokens, primitives and the MCP bridge. There is no mega-page with hidden feature sections. Every document is bundled without external fonts/CDNs. The old workbench URI resolves to the new library for compatibility. Existing document APIs remain available for exports and old clients, but generic document editing is removed from the primary UI/file registrations. Media attachments open the transcription document.

`voxstudio.sessions` is a data-only, app-visible refresh tool. Library metadata includes kind, status, timestamps, language and optional duration, avoiding a status request per row. A detail entry validates session visibility. `media.save_result` saves a completed local voiceover through NSSavePanel.

## Interaction and visual design

Neutral canvas, white surfaces, restrained indigo actions, warm voiceover accents; system typography, thin borders, 8–24 px spacing and readable information hierarchy. Host theme and style variables are applied. Dark and 390 px layouts share the same information order.

The library is a navigation surface. Task panels use progressive disclosure: common choices first, advanced caption/translation choices collapsed. Session detail defaults to reading, with edit controls introduced explicitly. Changing tracks or leaving the panel with a draft is blocked until save/discard. Revision conflicts keep the draft. Actions disable while in flight; successful transcription submission cannot be repeated accidentally. Media and frame previews do not autoplay. Job polling stops at a terminal state or teardown.

Video editing has no HTML document or entry tool. ChatGPT/Codex prompts select the native project with `manage_project`, inspect `get_timeline`/`get_media`, and use the existing undoable editor tools to modify the Mac app's real timeline. Export uses `export_project` and `manage_exports`. The plugin video-editing skill guides this flow and explicitly forbids an HTML fallback.

## Verification and limits

`npm run check` and `npm run build` validate every inline script after insertion (including literal `$` handling). Swift tests cover independent UI resources, data-only tools, unknown session rejection and input grant rejection; existing MCP regression tests also run.

`mcp-ui/preview` is a development-only host using the official AppBridge and PostMessageTransport. By default it forwards read-only requests to the real app MCP at `127.0.0.1:19789`, so the current browser preview shows actual sessions and selected-session content. The loopback proxy restricts methods/tools and rejects cross-origin requests; creation and editing require the installed ChatGPT/Codex plugin. It is not packaged in VoxStudio.

Use `http://127.0.0.1:19790/?mode=fixture` explicitly for sample data, navigation contracts, filtering, explicit start, draft/conflict handling, voiceover interactions and theme checks. Live navigation passes the real selected session ID; fixture state is never the default. Each screenshot labels its data source.

The repository debug build and a sandboxed `/Applications/VoxStudio.app` can read different data directories. Verify the process listening on the MCP port and select the native app by its full bundle path when comparing lists; do not silently merge or overwrite those stores. MCP session metadata uses the native session's computed duration, and linked voiceovers retain their parent transcript's identity/type.

Native ChatGPT/Codex rendering, host-mediated cross-panel opening, real forms, attachment injection, speech generation and prompt-driven native timeline edits/exports remain separate acceptance items. Do not infer those passed from fixture browser tests or direct HTTP checks.

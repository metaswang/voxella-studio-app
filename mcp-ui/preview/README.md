# Local panel preview

Keep the repository's signed VoxStudio build running, then run `npm run preview` from `mcp-ui`.

- `http://127.0.0.1:19790/` shows real app sessions and details through the MCP bridge. This browser host is read-only; creation and editing are available in the installed ChatGPT/Codex plugin.
- `http://127.0.0.1:19790/?mode=fixture` uses sample sessions and mocked jobs for visual and interaction tests. The header explicitly labels fixture data.

Fixture media uses the included 15-second H.264/AAC color-pattern video and quiet
test-tone audio, not real recordings or voiceovers. Both `media.session_preview`
and `media.preview` return an opaque preview URI; `resources/read` supplies their
binary content through the same bridge used by production panels. Other preview
durations require real app data. To test actual session playback, use the default
URL above and select a real session.

The iframe only uses the official MCP Apps bridge. The development host forwards permitted reads to the app's loopback MCP, retains the MCP Session-ID, and closes its session when the page leaves. It does not enable native forms or write arbitrary files. Select a real session from the list before opening Session detail.

When comparing the native app and MCP, use the same app instance. The repository build and a sandboxed installed app can have different workbench stores. No data migration or merging happens in this preview.

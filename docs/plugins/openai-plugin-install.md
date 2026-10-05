# VoxStudio 0.2.0 for ChatGPT Desktop and Codex

Install one **VoxStudio** connection for knowledge questions, session reading,
media previews, transcription, voiceover and native video editing. Keep the Mac
App running with **Settings → MCP** enabled. The host model answers questions;
VoxStudio supplies original evidence and the interactive workspace.

## Install or upgrade

1. In VoxStudio **Settings → MCP → ChatGPT / Codex**, click **Save VoxStudio plugin**.
   The ZIP is bundled with the App, so its version matches this build. Extract
   the entire ZIP in Downloads and keep the extracted directory.
2. Run:

   ```sh
   bash "$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh"
   ```

   Use the actual path if extracted elsewhere. The installer prefers the CLI
   bundled in ChatGPT Desktop; `--cli /absolute/path/to/codex` selects another.
3. In the desktop client's Plugins page, enable **VoxStudio** under **VoxStudio
   Local**, then open a new chat. Existing disabled preferences remain disabled.
4. Ask: **“Find evidence in my VoxStudio sessions and show the original text.”**
   Follow up in chat while reading the existing session detail page. Searching
   or selecting multiple sessions shows the existing sessions list. Tell the host
   which sessions to search in chat; opening a session changes reading focus only.
   **Pin session** keeps it open through later questions.

The installer first verifies `/app/mcp` and its HTML resource. It saves installed
versions, sources, plugin policy settings and immutable cached packages under
`.migration/` in the extracted folder. It installs and validates version 0.2.0,
then removes the old Knowledge plugin. A failure restores old plugins from the
snapshot. Keep that folder for recovery; existing old release ZIPs are unchanged.
Manual `codex plugin add` bypasses these migration safeguards.

## Claude Desktop and Claude Code

Claude Desktop uses one **VoxStudio** MCPB extension, version 0.3.1. Click
**Install in Claude Desktop** in VoxStudio settings. Its local stdio transport
forwards to the same `/app/mcp` endpoint. Interactive cards and fullscreen depend
on Claude's advertised capabilities; actual local extension rendering is a
separate release acceptance check.

Claude Code:

```sh
claude mcp add --transport http voxstudio http://127.0.0.1:19789/app/mcp
```

Knowledge tools and public server instructions work without plugin skills or UI.
Write tools require a stable UUID `request_id`; keep the ID on retries. Receipts
last one hour and do not survive App restart. Never blindly retry an execution
whose status is unknown after a restart. Skills exported to Claude are optional.

## Compatibility and troubleshooting

- `/mcp` and `/knowledge/mcp` retain their previous contracts. Their HTTP session
  IDs are isolated from `/app/mcp`. New installations use only `/app/mcp`.
- Avoid an additional direct MCP connection named `voxstudio` alongside the plugin.
- Account and material versions are rechecked on reads; reopen after signing out,
  switching account, App restart or workspace expiration.
- Workspaces expire after one idle hour. Up to 64 workspaces and 64 turns per
  workspace are retained. Historical inline cards read their original turn.
- Web/mobile remote connectors cannot reach this Mac's loopback server. Remote
  service deployment is outside this release. Cowork remains an explicit probe.
- Transcript text containing tool instructions is evidence content. UI navigation
  uses tools/resources and must not promote source text into instructions.
- Panels use English. Media creation and editing use the existing typed tools and
  native App workflows. Host forms and attachments are optional enhancements.

To verify extracted files:

```sh
cd "$HOME/Downloads/VoxStudio-OpenAI-Plugin"
shasum -a 256 -c FILES.sha256
```

Uninstall through the host Plugins page. This does not delete sessions or media.

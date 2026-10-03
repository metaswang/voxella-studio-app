# VoxStudio for ChatGPT Work and Codex

This download contains independently installable `voxstudio` and `voxstudio-knowledge` plugins, a local marketplace,
an installation script and workflow skills. The VoxStudio Mac app runs the MCP
server and renders the panels; the ZIP contains no app binary or Node server.

## Install on your Mac

1. Install and open the VoxStudio Mac app. Enable **Settings → MCP**.
2. Download `VoxStudio-OpenAI-Plugin.zip` and extract the entire ZIP in Finder.
   Keep the extracted folder in place after installation: the marketplace uses
   that folder. A ZIP or ZIP URL cannot be used as the marketplace source.
3. If the folder is in Downloads, run this in Terminal:

   ```bash
   # Knowledge QA (read-only evidence tools)
   bash "$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh" --plugin voxstudio-knowledge

   # Media workflows (transcription, voiceover, frame search, previews and editing)
   bash "$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh" --plugin voxstudio
   ```

   If you extracted it elsewhere, use its actual `install.sh` path. The script
   prefers the CLI bundled with `/Applications/ChatGPT.app`, then `codex` on PATH.
   It registers the extracted marketplace and installs the selected plugin. Run
   both commands if you need both workflows. Without `--plugin`, it installs
   `voxstudio@voxstudio-local` for compatibility with older instructions.
   To choose another CLI, use `bash install.sh --cli /absolute/path/to/codex`.
4. Open **Plugins** in your desktop client. Enable **VoxStudio Knowledge** for QA,
   and **VoxStudio** for media workflows, under **VoxStudio Local**. Restart the client if the installed
   plugin does not appear, then open a new chat in ChatGPT Work or Codex.
5. For QA, ask: **“Find evidence in my VoxStudio sessions and cite the original text.”**
   For media workflows, ask: **“Open my VoxStudio sessions.”** Keep VoxStudio running on the same Mac.

Manual equivalent (replace the folder with its actual location):

```bash
codex plugin marketplace add "$HOME/Downloads/VoxStudio-OpenAI-Plugin" --json
codex plugin add voxstudio-knowledge@voxstudio-local --json
codex plugin add voxstudio@voxstudio-local --json
```

Local marketplace/plugin support varies by client version and desktop surface.
Use a current desktop client with plugin support. This local endpoint is not a
ChatGPT website/cloud connector. The knowledge endpoint is
`http://127.0.0.1:19789/knowledge/mcp`; the media endpoint is
`http://127.0.0.1:19789/mcp`, both on this Mac.

## Independent knowledge plugin

Install the read-only evidence plugin separately:

```bash
bash install.sh --plugin voxstudio-knowledge
```

Its MCP key is `voxstudio_knowledge`, at `http://127.0.0.1:19789/knowledge/mcp`.
It exposes `search`, `fetch`, `list_sources`, `aggregate`, `find_text`, and `methods`.
The host model reasons from the returned evidence. Default passage QA chooses current Transcript,
or same-source subtitle fallback when Transcript is unavailable. Explicit subtitle and media targets remain available.
The legacy `voxstudio` plugin retains editing, media previews/search, and `knowledge.ask`.
Each plugin can be enabled independently; install both when you need evidence QA and native media workflows.
They share the same app and indexes. Installing only the knowledge plugin does
not remove video frame indexes or media search from the app. Default QA limits
its evidence to canonical text; explicit media discovery and the original media
tools continue to use the media indexes.
Knowledge session IDs belong only to the knowledge endpoint and cannot be reused on `/mcp`.

## What you can do

- Open a dedicated session list or a single session panel.
- Start transcription and translation; review subtitles and audio/video previews.
- Create voiceovers in a separate panel.
- Describe video edits in chat to change the **native VoxStudio editor timeline**.
  The plugin does not include an HTML video editor.

MCP panels use English. Native forms and host attachment features depend on
client capabilities. Importing a file does not automatically start transcription.

## If the plugin or sessions are missing

- Check VoxStudio **Settings → MCP** shows the server running.
- Check **Plugins → VoxStudio Local** has the plugin you need enabled, then start a new chat.
- If a separately configured MCP server is named `voxstudio`, disable/remove
  that direct connection before using the plugin. It can shadow the plugin.
- Do not register the same connection through both plugin and direct MCP setup.
- Plugin installation does not sign you into VoxStudio or download speech models.
  Configure your account/models in VoxStudio before starting those workflows.

## Update or uninstall

Download and extract the new ZIP. Run its `install.sh --plugin voxstudio-knowledge`
or `install.sh --plugin voxstudio` to register the new folder and update each
plugin you use, then restart the client and start a new chat. If the old
version persists, uninstall VoxStudio from **Plugins**, rerun the script and
enable it again. Keep the old folder until the new plugin is verified.

Uninstall VoxStudio through the client's **Plugins** page. Removing the plugin
does not delete your VoxStudio sessions or media. Remove the marketplace entry
before deleting its extracted folder. A direct MCP setup remains a separate
configuration and must be managed separately.

## Verify the package

From inside the extracted folder:

```bash
shasum -a 256 -c FILES.sha256
```

The release report also includes the ZIP SHA-256. The archive contains only
manifests, an icon, skills, this guide, the installer and a file checksum list.

Official references: [OpenAI plugin packaging and local marketplaces](https://developers.openai.com/plugins/build/plugins),
[Using plugins in Codex](https://learn.chatgpt.com/docs/plugins).

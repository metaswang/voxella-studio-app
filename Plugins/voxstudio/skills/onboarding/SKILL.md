---
name: voxstudio-onboarding
description: Open local VoxStudio knowledge, transcription or voiceover panels.
---

Keep VoxStudio running on this Mac with MCP enabled. The core plugin connects to `/chatgpt/mcp`. Open sessions with `voxstudio.workspace`; start questions with `app_knowledge(action: begin, query, request_id)` and follow knowledge-qa. Use `app_transcription` for ASR and `app_dubbing` for TTS, following media-workflow. Panel-only operations are internal UI tools.

Video editing, document changes, color, audio processing, multicam and media generation belong to the separately configured ordinary `voxstudio_native` MCP at `/native/mcp`. It is not bundled in this plugin's mcp.json. If unavailable, give its configuration from VoxStudio Settings → MCP; never try editing through core or Cloud tools.

Local core, native and Cloud are separate connections. Temporary workspace/turn, input, job, document and preview grants stay with their connection. To use a real session/project ID on another connection, reread it there and validate access. Use exact live schemas. Writes requiring request_id need a fresh UUID preserved on retries within one hour and the same App lifetime; never repeat unknown submissions after restart.

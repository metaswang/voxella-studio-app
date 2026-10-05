---
name: voxstudio-file-editing
description: Edit subtitle and UTF-8 text documents and explicitly apply saved subtitles to VoxStudio sessions.
---

Use the file entrypoint for SRT/VTT/TXT/Markdown/JSON. Host file writes must use resources.write for that entrypoint URI, writable:true and the latest ETag. Read-only files can be saved as managed copies. Managed files use document_id, expected_revision and a fresh request_id; no arbitrary path writes. Keep subtitle metadata and punctuation. File save never implies session import. Apply only saved SRT/VTT or voxstudio.transcript v1 JSON via session.document.apply, with explicit target scope/language and current document/session revisions. On conflict reload and preserve the draft; on write failure never claim saved.

For tools whose schema requires `request_id`, supply a fresh UUID for each intended write and preserve it on retries. Never repeat an unknown write after an App restart or after the one-hour receipt lifetime.

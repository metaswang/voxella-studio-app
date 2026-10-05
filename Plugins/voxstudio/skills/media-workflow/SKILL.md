---
name: voxstudio-media-workflow
description: Transcribe local or attached media, create voiceovers, preview and export results.
---

For an explicit ASR request call `app_transcription` once with the exact supplied path or host attachment and start=true. The attachment is the actual ChatGPT fileParams object {download_url, file_id, mime_type?, file_name?}; never invent paths, IDs or URLs. Pass only one input. Omit language/speakers for detection. With no supplied file or a request to configure options, open the panel or prepare it with start=false. Selection and panel opening do not submit jobs. The UI owns file pickers/forms and internal input tools.

For TTS list saved voices with `voice.list`, choose a real compatible voice and call `app_dubbing(text, voice_id, start: true)` once with the supplied/agreed script. To prepare a draft use start=false; to reopen a result use session_id alone. If no voice exists, retain the script in a draft and let the user add a reference in VoxStudio. Audition a reference with voice.preview and play only on request.

Follow returned next_call: resolve job_id using voxstudio.job_status until session_id is returned, then poll media.status every few seconds until completed/failed/cancelled. Never search by title, create again while polling, or report a queued result as complete. Read completed ASR text with fetch(source_id: session_id, view: body). Preview either ASR or TTS with media.session_preview. Export text/subtitles using media.export(format: txt/srt/vtt), optionally save=true for the system save dialog; export completed TTS audio using format=audio. Keep job, input, document and preview grants on this connection.

Writes need a fresh UUID request_id preserved on retries within one hour and the same App lifetime. A delayed/unknown response does not authorize another submission. Generic document changes and advanced media editing use the independent voxstudio_native MCP.

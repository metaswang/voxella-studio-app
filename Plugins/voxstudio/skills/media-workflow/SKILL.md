---
name: voxstudio-media-workflow
description: Transcribe audio/video or generate voiceovers with the local VoxStudio app.
---

Use a dedicated interactive panel: `app_transcription({})` for transcription, `app_dubbing({})` for voiceover, and `app_session({session_id})` for results. The session library is `app_workbench({})`. UI copy is always English; transcript/script content may use any supported language.

For transcription, select local media with `media.choose_local_file`, or open an actual host attachment through its file entrypoint and bind it with `media.bind_attachment`. Keep `resourceUri` opaque. Never invent a path. Selection/import alone must not create a transcription job. Explicit submission calls `transcription.create_from_input`; native `transcription.start_form` remains available only when advertised. Cancel/decline never creates work.

For voiceover, list existing voices using `voice.list`, then submit the user's script and selected voice ID to `dubbing.create`. Do not invent a reference voice or transcript. If the voice library is empty, guide the user to add a reference in VoxStudio. `media.save_result` saves a completed voiceover through the system dialog.

Poll `media.status` every two seconds until completed/failed/cancelled. `media.preview` supports generated voiceover audio; `media.session_preview` provides bounded transcription audio/video. Play only on user action. A successful job submission is not a completed result. Use the independent session panel for reading/editing captions, adding translations and exporting; retain all source and language tracks.

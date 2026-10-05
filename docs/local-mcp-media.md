# Local media MCP

The workbench MCP tools use the existing transcription, subtitle, translation,
voice-library and dubbing services without requiring a video editor project.
They are registered alongside the knowledge and timeline tools at
`http://127.0.0.1:19789/mcp`.

For an explicit prompt such as `transcribe ~/Downloads/recording.wav`, call
`app_transcription({"path":"~/Downloads/recording.wav","start":true})`.
This applies the path and queues transcription in one call, without opening a
file picker or host elicitation form. Omitted language and speaker options
default to automatic detection. `language: "auto"` is also normalized to detection.
The tool returns a stable `session_id` when session creation completes within
one second, otherwise a `job_id` and an explicit `next_call`. Follow that call:
poll `voxstudio.job_status` until it returns `session_id`, then `media.status`.
Read `app_session` with the same ID when completed. Do not match by filename or
title: automatic summaries can rename sessions while transcription runs.
The panel handles both stages and publishes the submission/session identity
and completion state through `updateModelContext` for the chatting model.

ChatGPT prompt attachments use the same tool with `attachment` instead of `path`:
`{"attachment":{"download_url":"HTTPS URL supplied by ChatGPT","file_id":"host file ID","file_name":"recording.wav","mime_type":"audio/wav"},"start":true}`.
The descriptor advertises `openai/fileParams: ["attachment"]`, with all four
[official file-object properties](https://developers.openai.com/plugins/reference#file-inputs).
The app downloads the attachment into managed storage, verifies playable media,
and starts only after import succeeds. It returns download/format errors without
creating a transcription. IDs/URLs must come from the host, not model guesses.
File-viewer `{name, resourceUri}` inputs retain their separate entrypoint contract.

Omit `start` (or pass false) to open/preselect without creating work.
Reject simultaneous `path` and `attachment` inputs. Native host forms remain an
explicit optional workflow, not a fallback for supplied files.

The panel's upload button calls `media.choose_local_file`, which immediately
returns `{job_id, status: "selecting"}` while bringing the native VoxStudio picker
to the foreground. Poll `voxstudio.job_status` with short requests until it
returns cancellation or an `asset_id`; then poll `media.input_status` until ready.
No MCP request waits for the user to interact with a dialog. Only one native
picker can be open across connections; a second request brings it forward and
reports `picker_busy`. Cancellation imports nothing and restores the upload
button. Selection/import still requires an explicit Start transcription.
`documents.choose_local_file` uses the same selection-job contract and resolves
to an imported document or cancellation.

| Tool | Purpose |
| --- | --- |
| `voice.list` | Reference IDs, languages, durations and audio paths |
| `voice.create` | Save a 3–30 second reference and its exact transcript |
| `voice.preview` | Reference metadata/path and optional app playback |
| `dubbing.create` | New local speech generation from text and reference ID |
| `transcription.create` | Local media transcription; optional source clip, speakers, subtitle segmentation and target languages |
| `transcription.translate` | Add multiple translated tracks sequentially |
| `transcription.segment` | Prepare word-timed subtitle cuts |
| `transcription.select_track` | Select source or an existing translated language |
| `media.status` | Job progress, terminal errors, available translations/output |
| `media.preview` | Bounded audio file and timed cues, optional navigation/playback |

Creation returns a `session_id`; poll `media.status` at a few-second interval.
A running multi-language pipeline remains `running` between individual tracks.
Its failures retain already completed tracks and return the specific error.
Underlying media jobs and outputs persist; pending MCP translation sequencing
is in memory. After restarting the app, inspect available languages and resume
missing translations explicitly. Do not claim an unfinished pipeline completed.

All newly created jobs use local compute and storage. Existing account access
checks apply. Subtitle/translation use the configured AI Service routing, which
can use a BYOK provider. Missing subtitle/translation configuration is rejected
before creating a job. Local speech model preparation uses the same workbench
flow as the UI.

`media.preview` exports an M4A excerpt into the application-support MCPPreviews
folder, with a unique name to avoid returning stale audio after regeneration.
It returns seconds on the session timeline, overlapping subtitle cues, and the
preview path; the excerpt duration is limited to 30 seconds. `play` is false by
default. `open` navigates to the existing session. `dubbing.create` status exposes
the full generated output separately from the excerpt path.

Preview captions require an actual nonempty subtitle track. Preview APIs return
`captions_ready` and timed `cues`; they never convert an unsegmented transcript
or voiceover script into preview captions. The player creates a caption area
only when this flag is true and the current clip contains subtitle cues. The
Transcript tab remains independently readable without subtitle segmentation.

Example transcription:

```json
{"path":"/absolute/path/recording.m4a","title":"Bilingual demo","speakers":"off","segment_subtitles":true,"target_languages":["en","ja"]}
```

Example preview:

```json
{"session_id":"UUID from creation","language":"en","start":0,"duration":15,"open":true,"play":true}
```

Settings → MCP contains the server toggle, inline client setup, and eight
workflow prompts. Help's MCP setup entry routes to Settings. Settings → Skills
loads the community catalog by default; the new skills can be installed and
exported to Cursor, Codex or Claude via the existing skill-detail controls.

## Session Summary tab

The session panel places Summary beside Transcript and Subtitles. It reads the
saved summary using the existing read-only `session.get_summary` tool and renders
Markdown headings, lists, quotes, code blocks and tables. CJK bold labels such
as `**标题：**正文` also render correctly without changing the saved source. Raw HTML is sanitized
and external media is excluded. A missing summary shows an empty state; Refresh
summary retries the read after generation in VoxStudio. Long summaries expose
Load more using the tool's character cursor and render the accumulated Markdown.
Unsaved transcript/subtitle edits must be saved or discarded before switching.

This panel is bundled in the Mac app at `ui://voxstudio/session/v7`; v6 and older
URIs remain aliases. No plugin manifest or skill changes are required, so the
verified 0.1.2 plugin ZIP on R2 remains current. Users need the updated VoxStudio
app and should reopen the session panel to load the new resource.

# Local media MCP

The workbench MCP tools use the existing transcription, subtitle, translation,
voice-library and dubbing services without requiring a video editor project.
They are registered alongside the knowledge and timeline tools at
`http://127.0.0.1:19789/mcp`.

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

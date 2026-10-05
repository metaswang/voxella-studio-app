---
name: voxstudio-onboarding
description: Open the local VoxStudio session library or a focused transcription or voiceover panel.
---

Keep VoxStudio running on this Mac. Call `app_workbench` with `{}` for the session library. Its host-normalized name is `mcp__voxstudio__app_workbench`; `voxstudio.library` is a compatible alias. This is a library, not a combined editor.

Use the dedicated UI tools for each task:
- `app_transcription({path, start: true})`: start an explicit request to transcribe the local path from the prompt, with automatic language/speaker detection. No file picker or host form is needed. Read `voxstudio.job_status` for the returned `job_id`, then `media.status` for its `session_id`.
- `app_transcription({attachment, start: true})`: transcribe the ChatGPT media attachment explicitly identified in the prompt. Use the host-supplied `{download_url, file_id, mime_type?, file_name?}` file object; pass either attachment or path. The same automatic defaults and job polling apply.
- `app_transcription({})`: open the panel when no file is specified. `{path, start: false}` preselects a file. Selecting/opening a file alone never starts a job. Use the host form only when the user specifically asks for it.
- `app_dubbing({})`: write a script, choose an existing reference voice and generate speech.
- `app_session({session_id})`: open the selected session's independent detail panel. Use a real ID from the library.

Video editing uses prompts and the native editor tools (`manage_project`, `get_timeline`, clip mutation tools and `export_project`) to modify the Mac app timeline directly. There is no video HTML panel. Read the video-editing skill for that workflow.

Each UI tool above has a separate MCP Apps HTML resource. When a user clicks a navigation action in a panel, invoke the exact requested UI tool with its arguments so the host opens that independent document. Reading a resource or calling a data-only tool does not open a panel. Never claim that a panel is visible solely because its tool succeeded.

Discover callable tools by exact name, including tools deferred to functions.exec. A missing tool in a running app indicates a host exposure problem, not evidence that the app is stopped. Read `native_forms` from the result and only promise native forms when supported. No public server is required.

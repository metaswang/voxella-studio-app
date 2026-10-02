---
name: voxstudio-video-editing
description: Edit the native VoxStudio Mac video editor directly from ChatGPT or Codex prompts through MCP tools.
---

Video editing has no MCP HTML panel. Apply the user's requested edits directly to the VoxStudio Mac app's project and timeline using the existing editor tools. Do not open the session library, an HTML timeline, or a transcription panel as a substitute for video editing.

1. Use `manage_project(action="list")` to identify the current/visible project. If the user names a project, select it by its real returned ID/name. If there is one visible/current project and the request refers to it, use that project. Ask for the target only when multiple choices make it ambiguous. `manage_project(action="open", id=...)` binds the MCP connection to the chosen project and brings the native editor forward.
2. Call `get_timeline` to read the real active timeline and `get_media` before referencing assets. Use returned clip IDs, track IDs and frame ranges; never invent them. Respect editor focus/suspended-project errors.
3. Execute the requested edit with `set_clip_properties`, `split_clips`, `move_clips`, `remove_clips`, `ripple_delete_ranges`, `add_clips`, `add_texts`, `add_captions`, `update_text`, `apply_layout`, `apply_color`, or the appropriate existing tool. Edits use the native editor's undo behavior and update its actual timeline.
4. Verify the mutation receipt/delta. Use `inspect_timeline` when the visual result matters. Report concrete changes and any failed operation; submitting a tool is not proof of success.
5. Export only when requested with `export_project`; use `manage_exports(action="list")` to check progress and completion. Queued does not mean exported.

Trims are source offsets measured in project frames; split positions are timeline frames. Linked audio is nested under a video clip. Use its audio ID for volume, and the video ID for timing edits so linked timing follows. Import external media with `import_media` before placing it. Do not silently create a new project or switch timelines when the user asks to edit an existing one.

Example user prompts:
- “In the current VoxStudio project, trim the first clip to 00:02–00:12 and lower its linked audio to −6 dB.”
- “Split the selected timeline at 10 seconds, then add a title saying ‘A new beginning’.”

If tools are missing from the host, report the exact missing native tool and refresh the plugin connection; do not use an HTML editor fallback.

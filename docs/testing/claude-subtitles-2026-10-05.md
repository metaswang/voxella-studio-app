# Claude Desktop subtitle UI acceptance — 2026-10-05

Actual Claude Desktop 2.19675.0 with existing VoxStudio MCPB 0.3.1.
Public fixture: Make Your Own Lemonade, F18F0A30-AFBE-4C80-AB1D-2143132A03DA.
Chat: https://claude.ai/chat/de5c7b1e-a87b-4eff-82e2-0d64633ddf82

Initially reproduced stale UI in a newly created card: Subtitles displayed two merged segments without cue time ranges, although the running HTTP endpoint served the updated HTML and cue API.

Changed the workspace UI URI from v1 to v2, preserving v1 as a readable alias. Built and signed VoxStudio, launched the new App and disabled/re-enabled the existing Claude extension. No Claude upgrade or MCPB reinstallation was performed. Requested a fresh app_session card in the same chat.

Passed actual UI checks:
- Session detail loaded automatically through app_session.
- Subtitles displayed 40 saved cues rather than two merged segments.
- First cues matched HTTP fetch material=subtitles, view=cues: 0.1–1.9 seconds and 2.6–5.7 seconds, with expected original text.
- Expanded view preserved subtitles, 40-cue count and Claude chat input.
- Screenshot: openai-mcp/claude-subtitles-v2.png.

Supporting checks: TypeScript check/build passed; 37 Swift tests across four relevant suites passed; live v2 HTML matched generated source and v1 alias returned identical HTML.

This acceptance covers the stale subtitle UI issue, not every cross-host release gate. Existing historical cards may retain their original HTML.

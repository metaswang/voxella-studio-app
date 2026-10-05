# Claude Desktop voiceover acceptance — 2026-10-05

Tested the original Lemonade prompt in a fresh, actual Claude Desktop chat using the running signed VoxStudio build and existing local VoxStudio MCPB extension. The host UI showed Sonnet 5.5 Medium; Claude Desktop version was 2.19675.0 and the installed MCPB version was 0.3.1. No Claude upgrade, extension reinstall, or connection refresh was needed for this run.

Chat: https://claude.ai/chat/e05bb57b-fe50-4013-afd0-462c127b94c3

## Input

```text
@VoxStudio create a voiceover using below:
Make Your Own Lemonade” is about turning life’s setbacks into chances for practical action and growth. It encourages acknowledging what’s hard, then choosing a next step—such as addressing worry, protecting your health or finances, and finding small things to be grateful for.
```

No additional tool-routing instructions were included. The test allowed each requested tool once rather than changing persistent permissions.

## Observed tool invocation

Claude first called `voice.list`, then one `app_dubbing` invocation with a script, a saved English voice, and `start=true`:

```json
{
  "request_id": "7c1f2a4e-9b3d-4e56-8a21-5d0c6f3b9e17",
  "text": "\"Make Your Own Lemonade\" is about turning life's setbacks into chances for practical action and growth. It encourages acknowledging what's hard, then choosing a next step—such as addressing worry, protecting your health or finances, and finding small things to be grateful for.",
  "voice_id": "538FB9F9-DC77-4071-990C-83ACE110417F",
  "language": "en",
  "title": "Make Your Own Lemonade",
  "start": true
}
```

The voice was Demo · American Female. The request above was read from Claude's actual tool approval/request UI; it was not supplied by a CLI or fixture host.

## Results

| Check | Actual result |
| --- | --- |
| Prompt-aware panel | Passed: script and title were present while processing at 17%; no empty creation form. |
| Generation | Passed: the same card advanced to Completed 100% and “Your voiceover is ready.” |
| Duplicate submission | One `app_dubbing` creation was observed in this chat; no manual Generate click or retry. |
| Audio preview | Passed: Load preview produced a 00:00–00:15 player; playback advanced, synchronized captions changed, and pausing exposed elapsed time 9.42127 seconds. |
| Session navigation | Passed: View session loaded Transcript with one readable paragraph containing the full tool-submitted script. |
| Expanded Claude panel | Passed: Transcript, preview player and Claude prompt input remained visible. |
| Original reported error | No `Swift.CancellationError`, error toast, or “No transcript available” appeared during this completed run. This run did not deliberately cancel an in-flight request. |

## Text fidelity observation

The user prompt retained the original 276-character script. Claude normalized punctuation before invoking VoxStudio: it added an opening quote, changed the closing curly quote to a straight quote, and changed curly apostrophes to straight apostrophes. Its tool-submitted script therefore had 277 characters. The VoxStudio panel and Transcript showed that submitted text consistently.

Claude's final prose claimed “Your text exactly as written,” which was inaccurate at the character level. This acceptance passes the original empty-panel and generation/preview checks; it does not claim verbatim preservation by the Claude model. The earlier direct local MCP regression separately verified that VoxStudio retains the exact original script when it is passed unchanged.

## Evidence

- [Script retained during generation](progress-script.jpg)
- [Generated preview at 00:09 and filled script](completed-preview.jpg)
- [Expanded session Transcript and preview](session-transcript.jpg)

All screenshots came from the actual Claude Desktop window. This acceptance covers Claude Desktop; it does not replace a ChatGPT Work host test.

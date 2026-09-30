# MCP media and Settings acceptance — 2026-09-22

Client: Cursor Agents, existing `palmier-pro` local MCP connection. Tests are
submitted through Cursor UI; no direct HTTP substitute is used for acceptance.
App: signed workspace `.build/VoxStudio.app`, built with
`./scripts/bundle.sh debug --sign` and restarted before reloading Cursor.

## Published skills and UI

- Repository: https://github.com/voxstudio-me/voxstudio-skills
- Commit: a4dc01b81c2843e78da960eb14b6d0659b9e5ce6
- Added mcp-transcription, mcp-voice-reference, mcp-dubbing; generated catalog has 18 entries.
- Repository catalog validator and skill-creator validator passed for all three.
- Published body SHA-256 prefixes match catalog entries (opt-in app integration test).
- Settings → MCP directly shows server toggle, four client selectors, inline
  connection instructions, eight prompt cards, skill links and footer. There is
  no separate setup window; Help setup routes to this Settings page.
- Cursor selector and Manual setup expand inline with the correct localhost URL.
- Settings → Skills initially shows Community 18 and the new Transcription/Dubbing
  categories. Installed all three through the UI, then used Add to External Agent
  → Cursor. Each displayed “Added to Cursor” and the corresponding managed path.
  Installed count grew from 3 to 6; pre-existing skills were retained.
- Cursor Reload reports Connected, 68 tools and 2 resources.

## Regression

Initial targeted run: 15 tests across MCP media, MCP knowledge, MCP tool-list
announcement, and Skills catalog passed, including the published catalog check.
A subsequent focused run passed 5 media tests after the first live-test fix.

Found and fixed:
1. Integer-valued JSON seconds could bypass `as? Double` checks. Numeric arguments
   now use validated NSNumber values; tests cover negative, zero/equal ranges,
   oversized preview, boolean/numeric confusion and invalid language arrays.
2. First-use lazy voice-library hydration caused an immediate “not ready” result,
   even for transcription. MCP waits briefly for store hydration before proceeding.
3. ToolError did not implement LocalizedError; its generic Foundation description
   hid the useful message. The MCP adapter now returns `ToolError.message`, with a
   regression that checks the actual caller-visible error.
4. Preview names are unique to avoid returning stale cached audio after regeneration.

## Test input and transcription

Input: `/Users/adamwang/Downloads/Recording-20260920-090129-eb0ad694_audio.m4a`
(about 20 seconds). Test title: `MCP E2E Media 20260922`.

First call failed before creating a session due to lazy hydration; Cursor verified
no matching session existed. After the fix, the exact request was retried once:
`transcription.create(path=..., speakers=off, segment_subtitles=false)`.

Session: `6CD6C9A4-8E31-480C-8B2C-5ABB3D02916F`.
Creation returned queued; status returned completed/progress=1. Preview requested
start=0, duration=30, open=true, play=false and returned language zh, one cue at
1.232–20.004 seconds:

> 一二三四五六七八九十，开始发射！一二三四五六七八九十，这是一个测试，一个正式的测试。

Actual preview: application-support
`MCPPreviews/6CD6C9A4-8E31-480C-8B2C-5ABB3D02916F-F83ED3E2-D8C7-4373-ABDC-1D226B3E2030.m4a`.
ffprobe verified AAC, 48 kHz, stereo, 20.266667 seconds. The app opened the same
named session and showed the matching transcript; source input was preserved.

## Further live checks

Results for segmentation, multiple translations, track switching, reference
creation and dubbing are recorded below as they complete.

### Segmentation and translations (23:10 SGT)

On the same transcription, Cursor called transcription.segment and observed
queued → completed / “Subtitles ready”. Source became three timed cues, retaining
its full Chinese text. transcription.translate(target_languages=[en,ja]) returned
running and then completed with both tracks after about eight seconds.

Source/English/Japanese previews returned 3/4/5 cues respectively. Selecting ja
made language-less preview return ja. Selecting source made it return zh, while
both translated tracks remained available.

Two follow-up fixes were prompted by these results: selected_language previously
reported the remembered translation language even when source was selected;
it now reports the actual selected track's language. Japanese enumeration could
split “しち” because ideographic comma “、” was absent from the readability
boundary punctuation set; it is now a preferred boundary, with a lossless,
length-bounded regression using the real phrase.

### Reference and dubbing (23:14 SGT)

Cursor read the installed MCP skills and exercised voice.list → voice.create →
voice.preview(play=true) → voice.list. The list grew from five existing references
to six; original entries remained. The test's gender is a supplied fixture label,
not an inference about the recorded person's identity.

- Reference: `11B462E1-49AE-49B9-9F33-D728540A83FA`,
  `MCP E2E Reference 20260922`, zh, 20.202667 seconds.
- Managed WAV: `VoiceLibrary/11B462E1-49AE-49B9-9F33-D728540A83FA/reference.wav`
  under VoxStudio application support; transcript is the exact ASR text above.
- Dub session: `B4BF7091-E962-4300-B5F6-84A591849EDF`,
  `MCP E2E Dub 20260922`.
- Script: 欢迎参加我们的工作坊。今天我们将练习清晰沟通。
- Creation queued → media.status completed/progress=1 (about eight seconds).
- Full output: `Dubs/dub-flow-E87E9AA9-EDAA-4FA2-A29F-4AA94C3F8E45.wav`.
  ffprobe verified 5.973333 seconds, PCM float, 24 kHz, mono.
- Preview: `MCPPreviews/B4BF7091-E962-4300-B5F6-84A591849EDF-76A6B725-5479-48BB-9691-973E51495FEC.m4a`.
  Requested start=0/duration=15/open=true/play=true; returned end=5.973333.
  Cues: 0.144–1.744 欢迎参加我们的工作坊。 / 1.744–5.824 今天我们将练习清晰沟通。
- The visible app showed the matching titled session, waveform, transcript and
  active playback controls. This verifies playback execution, not a subjective
  voice-similarity or listening-quality score.

### Final regression and navigation

75 tests passed across the media adapter, subtitle readability regression, and
existing Flexible media flows suite. The broad run found one stale pre-existing
assertion against the old empty-response wording; it now checks propagation of
`LLMClientError.emptyResponse.localizedDescription` rather than a replaced string.

Help → MCP Instructions was clicked in the running app and opened Settings → MCP
with the same inline setup and workflow cards. The multilingual example's Copy
prompt button showed Copied; pasting into Skills search matched the full prompt.
The test search was cleared. All three skills remained installed.

During final verification the existing Cursor connector was renamed to
`voxstudio` by concurrent workspace/configuration work. Its current connection
was reloaded and showed Connected with 68 tools and 2 resources. Final requests
use the current name; earlier requests used `palmier-pro`.

### Combined-flow race found by final Cursor pass

The final pass confirmed source selected_language=zh and corrected Japanese cuts:
“いち、に、さん、し、ご、ろく、” / “しち、はち、きゅう、じゅう、発射！”.
English remained present after regenerating Japanese.

The first combined clip test (session 1248A900-12D4-42A3-8A09-5D9EE37B4F35,
source 1–10s, segment_subtitles=true, target_languages=[en,ja]) exposed a race:
ASR emitted completed while its flow task still held its reservation during
artifact enrichment. The automatic translation call was therefore ignored by
the workbench's busy guard. MCP correctly reported “Translation did not produce
en subtitles”; it did not misreport success. Source preview was nine seconds,
but neither target track existed.

The chaining waiter now requires completed **and** a released workbench flow
reservation. Status remains running during that finalization window, and direct
postprocessing admission checks the same reservation. Async regression verifies
that an early completed event cannot advance the chain while its task is busy,
and that a failed step prevents continuation.

Boundary calls returned specific errors for duration=31, selecting missing fr,
and translating an empty language list. These did not mutate the failed session.

### Combined-flow fix verified in Cursor (23:27 SGT)

The rebuilt server restored the earlier session via one explicit translate call:
running → completed, en and ja both present, all three previews nine seconds.
The in-memory failure marker had cleared on restart; the persisted source was
still available, so recovery did not require recreating or retranscribing it.

Cursor then created exactly one new combined session,
`FCA19FAC-90F5-44D9-B2D1-1E13AF38F980`, titled
`MCP E2E Clip Combined Fixed 20260922`, using the original fixture, zh,
speakers=off, start=1/end=10, segment_subtitles=true, target_languages=[en,ja].
It completed automatically in about ten seconds, **without a follow-up translate
call**. Source/en/ja previews were all nonempty and ended at nine seconds.
Source cue was 0.240–8.000 “一二三四五六七八九十，开始。”; English cues were
0.240–4.438 “One, two, three, four, five, six,” and 4.438–8.000
“seven, eight, nine, ten. Go.”

Preview files under application support/MCPPreviews:
- Source: `FCA19FAC-90F5-44D9-B2D1-1E13AF38F980-1AF4BA2F-06C8-4140-9316-90DD7EC7D3A1.m4a`
- English: `FCA19FAC-90F5-44D9-B2D1-1E13AF38F980-DBE636E4-DC67-4792-8D1D-45BA6CC8CBD5.m4a`
- Japanese: `FCA19FAC-90F5-44D9-B2D1-1E13AF38F980-28502D64-5569-4FC2-AD55-76B7E413ECE0.m4a`

The three invalid requests were repeated on this completed session and returned
the same specific errors. Final status remained completed with both en and ja.
The chaining fix passed 77 tests across the three regression suites.

This shorter translation lacked enumeration commas, revealing a second Japanese
boundary case: “はち” split across adjacent cues. Display splitting now scores
macOS Japanese word boundaries while retaining character tokens for alignment.
A regression uses the actual unpunctuated phrase, checking lossless text, the
18-character budget, and intact はち / きゅう / じゅう.

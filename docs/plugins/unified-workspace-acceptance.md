# Unified workspace implementation and release gate

This implementation adds `/app/mcp`, service-level presentation state, the standard
`ui://voxstudio/workspace/v1` resource, one OpenAI plugin 0.2.0 and Claude MCPB 0.3.1.
Existing `/mcp` and `/knowledge/mcp` remain separate profiles. SDK versions stay locked.

## Simple session UI (2026-10-05 correction)

The QA panel reuses the existing MCP session detail and sessions list components.
A read source opens its detail; session discovery and multi-session scopes show
only matching/selected sessions. List-to-detail and back stay inside the panel.
The knowledge dashboard, query header, scope controls, evidence columns and raw
observation output have been removed. Questions and scope restrictions come from
the host chat. Detail retains Transcript/Subtitles/Summary, original language,
preview, character highlights, paging and a small pin control. Cloud text does not
depend on local media status. The media profile still uses the same detail component
with its existing edit/translate/export actions.

Discovery observations retain ordered, presentation-free query arguments so list
pagination preserves the user's filters instead of reverting to the full catalog.
`knowledge.workspace_state(page: {observation_id, cursor}, turn_id)` continues an
observed catalog with its exact frozen snapshot and arguments. It leaves a completed
turn, its evidence and its observations unchanged.
The frozen scopes, validated evidence and historical turns below remain server state.

The local plugin 0.2.1 adds the data-only `app_evidence` gateway so original reads
and citation completion remain callable when a host exposes a partial tool inventory.
`app_knowledge` opens/begins the question and returns the local provider and a concrete
`next_call`; the gateway delegates through the existing strict operation schemas,
authorization, frozen scope and evidence recorder. Local workspace/source IDs stay
on `voxstudio`, including cloud-origin sessions displayed by the Mac. The panel sends
both text and structured provider/reading context for “summarize this” while retaining
the general next-question scope. Workspace resource v4 invalidates cached v3 HTML;
v3 remains a readable alias. Data-only results cannot replace the workspace snapshot.

## Protocol and state

- UI clients begin each question with `app_knowledge(action=begin, query,
  request_id, workspace_id?)`. Canonical data calls carry workspace + turn together;
  those fields are removed before strict validation and pagination hashing.
- Search candidates, fetched spans, and committed answer sources are separate.
  Aggregate/summary/metadata observations use a turn-local `observation_id`.
- `complete_turn` accepts only successful reads, freezes results and supports
  answered/no_evidence/clarification/failed. Repeating the same commit is safe.
- Scope is frozen at begin. Later filters can only reduce it. UI scope changes apply
  to the next question. Browsing does not select a query scope.
- Workspace IDs are random; revisions merge parallel reads without global current
  session state. Old operations cannot select the active turn's source. View updates
  use a separate optimistic revision. Pin and reading anchors survive panel rebuilds.
- Authorization and source generations are checked on each operation/state read.
  One-hour idle expiry, 64 workspaces, 64 historical turns, 128 evidence rows and
  256 observations per turn bound state. Source content remains untrusted data.
- Writes on the unified endpoint share service-level idempotent task receipts for
  one hour (256 receipts). Same ID + same input returns the original task result;
  different input rejects. A process epoch changes on App restart. Claude transport
  compares the epoch before replaying a receipt-backed operation.
- Replaying a validated receipt recovers only its returned input/job/document and
  resource grants. Job completion can grant the resulting document or input. Other
  clients, inputs, attachment grants and host capabilities remain separate. Access
  is checked before and after delegated operations. A recovered input uses concrete
  typed tools; opening a new host form requires selecting a fresh input.

## Automated checks

Run the focused Swift suite, package/migration tests, standard transport tests and
UI model tests. Include parallel reads, older turn completion, immutable history,
manual reading/pin, scope isolation, invalid citations, expiry and three HTTP profiles.
The package tests cover neither/main-only/knowledge-only/both installed states,
disabled preferences, repeated installation, omitted legacy records, switching a
registered marketplace source, failure before mutation and rollback. Failed repeated
installation also preserves a completed single-plugin migration without resurrecting
Knowledge from dormant rollback preferences or cached files. Transport
checks preserve metadata/blob/bidirectional messages, bounded recovery, cancellation,
same-process receipt retries and refusal to replay after a changed process epoch.

```sh
swift test --filter 'MCPWorkspaceTests|MCPUnifiedInventoryTests|MCPKnowledgeProfileTests|MCPKnowledgeToolsTests|MCPMediaToolsTests|MCPPanelRoutingTests|MCPDocumentTests|KnowledgeCanonicalRetrievalTests|MCPTranscriptionInputTests|MCPVoiceoverTranscriptTests'
python3 -m unittest discover -s Tests/scripts -p test_openai_plugin_package.py
node --test mcpb/tests/*.test.js
# Optional real App transport smoke, with an authorized readable media sample:
node mcpb/tests/live-smoke.cjs <session-UUID>
(cd mcp-ui && node --test tests/workspace.test.mjs tests/summary-markdown.test.mjs)
./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"
```

## Real host release gate

For each host, use a fresh chat and **one** VoxStudio connection. Record host version,
transport capabilities, screenshots, exact outcome and limitations. Do not change a
pending item to passed merely because its RPC succeeded.

| Host | Required acceptance | Status |
|---|---|---|
| Codex | Question automatically presents workspace; second question updates sources; source/anchor navigation; pin through follow-up; preview; separate chats isolated | Local 0.2.0 migration passed; computer-use denied controlling the current Codex app; real UI remains pending |
| ChatGPT Desktop | Same sequence; verify right-side workspace and installed single plugin | No separate ChatGPT Desktop host available in the app inventory; real UI remains pending |
| Claude Desktop | Install 0.3.1 MCPB; inline session/list; fullscreen with chat input; follow-up source changes; original anchor, pin, preview; historical card unchanged | 0.3.1 installed with authorization; initialization/discovery, actual grounded QA, automatic inline detail, fullscreen with chat input and same-source follow-up, and actual preview playback passed; list/source-follow/history/pin acceptance remains pending |
| Claude Code | Local HTTP canonical QA + citations; media reads; editor schema/write receipt regression | 2.1.225 actual canonical QA/citation passed with one HTTP connection; media/editor automated regression passed, actual CLI media/edit workflow pending |
| Cowork | Inspect capabilities and local reachability, report actual outcome only | Not verified; no first-release support claim |

Exercise canonical Transcript, subtitle fallback, explicit subtitles/translation,
paged cloud body, stale versions, text without timecodes, session switching during
requests, user scope changes while retrieving, account change, App restart and
iframe teardown/rebuild. Confirm media/transcription/voiceover/native editor workflows
still operate. Fixture playback and generated HTML do not prove Claude MCPB rendering.

## Execution evidence on 2026-10-05

- Default Swift test configuration: **79 tests in 10 suites passed**. Includes late
  completion retaining its own historical reading view and selection falling back
  to the highest-ranked successfully read source. No SDK upgrade was made.
  Reconnect receipt tests cover picker execution once, job polling, returned document
  and resource recovery, rejection of unrelated documents, and host capability isolation.
  Completed catalog paging was checked against an unrelated third source: the next
  page stayed within the selected two sessions and left the completed snapshot intact.
  A final focused rerun of the 9 workspace/inventory tests passed after guarding a
  state read against an active turn changing during asynchronous access validation.
- Python packaging/migration: **7 tests passed**. Node transport/entrypoint: **7 tests passed**.
  UI model/summary tests: **10 tests passed** after the session UI simplification. TypeScript and generated HTML syntax
  checks passed. Signed debug App built with the repository bundle script.
- Live `/app/mcp` inventory and standard HTML resource passed the installer probe.
  Its SSE parser now ignores empty priming frames emitted by the real server.
- Actual Codex CLI migration moved main 0.1.2 plus Knowledge 0.1.0 to one enabled
  VoxStudio 0.2.0 connection at `/app/mcp`. The real failure/recovery attempt restored
  both prior versions before the corrected migration succeeded. Recovery copies
  retain installed source bytes and original plugin preference blocks.
- Claude MCPB, the OpenAI plugin and shared panel logo now use exactly the canonical
  App icon bytes. The actual Claude 0.3.0 installer visibly shows the hexagonal
  waveform App icon. Reinstalling the unpublished OpenAI 0.2.0 package refreshed its
  installed cache to the same PNG, with a recovery copy of the preceding installation.
- Claude Code used only the configured local `voxstudio` connection to read the
  public **Make Your Own Lemonade** sample. It returned a grounded quote, its source
  UUID and the available coarse original segment range. No permission denials.
- A standard AppBridge browser host displayed actual local session data, canonical
  Transcript and available language choices. A real media resource was loaded as
  MCP-delivered blob bytes in the iframe; Play/Pause worked. Fixture checks also
  exercised historical inline presentation, fullscreen expansion, pin, summary,
  and internal media-panel return navigation. These are component checks, not
  evidence of Codex, ChatGPT or Claude host UI acceptance.
- The simplified shared components were separately checked in the standard browser
  host: automatic detail, search matches, multi-session scope, list-to-detail/back,
  summary, body paging, text without timecodes, 390px reading layout, preview playback,
  pin through follow-up, and inline history retained until expansion follows the
  active turn. The legacy media detail's edit/save flow passed with synthetic fixture
  text. No real user's transcript was edited.
- With real App data, four consecutive questions alternated original detail,
  matching sessions list, original detail and matching list in the same iframe,
  without reload. Opening the matching row, reading its saved summary and returning
  to that same result list also passed. A deterministic fixture checked a new
  active question arriving in a reading-position update response: the renderer
  applied the returned list rather than consuming its revision without navigation.
  These checks still do not establish a desktop host's automatic panel placement.
- The actual Claude stdio-to-HTTP shim against the signed App forwarded initialization,
  all 97 typed/presentation tools, standard UI metadata, HTML, original text in
  `structuredContent`, and a 1,326,784-byte audio/video resource blob on the final
  signed App after the branding correction. This verifies
  transport bytes; the Claude Desktop iframe still needs real host acceptance.
- The initial Mac lock was resolved by the user's manual unlock. The user explicitly
  authorized Claude installation on the next turn. Current desktop blockers are the
  tool restriction on Codex and absence of a separate ChatGPT host.
- Claude's installed 0.3.0 extension was enabled but timed out during initialization.
  Its bundled Node `nodeHost.js` dynamically imports the configured entry; that
  bypassed `require.main === module` and never started the stdio listener. MCPB
  0.3.1 has a dedicated `server/stdio.js` entry that explicitly starts the transport.
  A child-process regression emulates the import loader and checks initialization
  and tools discovery. The actual Desktop upgrade completed; initialization returned
  in about 65 ms and tools/resources discovery succeeded. A real public-sample chat
  automatically rendered the shared session reader, returned grounded text, expanded
  with a working chat input, and loaded/played a 15-second video preview. This is now
  actual Claude host UI evidence, rather than only a browser fixture or transport check.
  The fullscreen chat input submitted a follow-up and Claude answered from the retained
  public original. A subsequent discovery question completed, but the model's response
  alone does not prove that the visible expanded reader changed to the matching list;
  that transition, active-source changes, historical cards and pin remain unaccepted.
  No other private session was used for the Desktop QA checks.
- A test run with `--traits BundledSpeech,SparkleUpdates` cannot compile an existing
  `AppUpdaterTests.swift:33` initializer call in that configuration. Default tests
  pass; the signed App with those build traits compiles. This pre-existing test
  configuration issue was not expanded into this change.

Keep the extracted local installer folder and its `.migration` snapshots. The
bundled installation path allows local testing without publishing a CDN asset.
**Outstanding real desktop host acceptance remains pending. The user explicitly
authorized publishing OpenAI plugin 0.2.0 on 2026-10-05 before that gate completed;
see `openai-plugin-distribution.md` and `docs/testing/unified-plugin-release-2026-10-05/`.**

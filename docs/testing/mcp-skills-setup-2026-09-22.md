# MCP setup and Community skills verification — 2026-09-22

## Loading and publishing

`SkillCatalog.defaultBase` points to
`https://raw.githubusercontent.com/voxstudio-me/voxstudio-skills/main`.
The App loads `catalog.json` (with a disk cache), groups entries by category,
and installs each entry's `path` into `~/.voxstudio/skills/<id>/SKILL.md`.
`SkillStore` parses frontmatter, caches bodies/hashes and records installed
versions in `.installed.json`. Knowledge-agent discovery additionally requires
`category: knowledge` or `knowledge-qa` in the skill's own frontmatter.

Published commit: https://github.com/voxstudio-me/voxstudio-skills/commit/92b0616

- Added `knowledge-qa` and `knowledge-search` under `skills/knowledge/`.
- Regenerated the catalog using its repository validator: 15 entries.
- Both skills support external MCP clients and the in-app knowledge agent.
  QA explicitly avoids recursively calling `knowledge.ask` inside that pipeline.
- Source-origin filtering and cloud model routing are documented separately.

## Design

The previous page displayed every client setup at once and described only video
editing. The replacement provides a server-status hero, a client selector with
one setup method shown at a time, and four copyable scenarios: QA, search,
cross-session comparison, and caption styling. Workflow cards install/open the
associated skill; the existing skill detail provides external-agent export.
English and Simplified Chinese strings are included.

References consulted:
- Apple onboarding guidance: https://developer.apple.com/design/human-interface-guidelines/onboarding
- MCP server concepts (tools/resources/prompts distinction): https://modelcontextprotocol.io/specification/draft/server/index

The copyable examples are UI templates; this change does not add MCP protocol
`prompts/list` or claim clients are connected merely because the server runs.

## Regression and verification

Reproduced the original bug in the installed App: Community displayed a count of
13 but retained the single Installed video skill. The two collections reused
category IDs inside a lazy stack. The fix uses a collection-specific scroll
identity and an eager stack for the small catalog.

Validated in the signed workspace build (not `/Applications/VoxStudio.app`):

1. Community renders all 13 video skills plus 2 knowledge skills.
2. Searching `knowledge` returns exactly the two new skills.
3. Installed `knowledge-search` from Community and `knowledge-qa` from the MCP
   workflow card; both detail sheets display the complete published bodies.
4. Installed count increases from 1 to 3. Switching back to Community still
   renders all 15 entries. Installed files match the published SHA-256 prefixes.
5. Copy prompt shows feedback; pasting into Skills search yields the full,
   expected prompt. Cleared the test search afterward.
6. Codex selector displays its setup command; four workflow cards render in a
   two-column grid at the minimum window width, with scrolling to the lower row.
7. Add to External Agent exposes Claude, Codex, and Cursor. No external client
   configuration was changed during verification.

Build: `./scripts/bundle.sh debug --sign` succeeded; launched `.build/VoxStudio.app`.

Tests (15 passed across 4 suites):

```sh
VOXSTUDIO_VERIFY_COMMUNITY_CATALOG=1 swift test --traits BundledSpeech \
  --filter 'SkillCatalogTests|SkillFrontmatterTests|KnowledgeSkillFrontmatterTests|MCPKnowledgeToolsTests'
```

The opt-in published-catalog test fetches the real catalog and workflow bodies,
checks hashes, parses frontmatter with the App parser and checks knowledge tool
whitelists. Normal test runs skip this network-dependent test. The skills repo's
`node scripts/build-catalog.mjs` validates its own App-specific frontmatter schema.

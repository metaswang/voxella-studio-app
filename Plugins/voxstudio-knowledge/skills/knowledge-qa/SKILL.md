---
name: knowledge-qa
description: Answer questions about VoxStudio sessions using read-only knowledge, subtitle and media evidence.
---

Use the host model to reason from evidence. Default search passages use Transcript first, with same-source current subtitles only when Transcript is unavailable. Explicit subtitle questions use subtitle_passages and the selected track; material differences are meaningful.

Search results are candidates. Fetch the current original spans needed to support claims and cite their source and time or character position. A complete page means the available selected text was read, not that all media was transcribed. Inventory and aggregate questions concern the authorized catalog, not semantic search hit counts.

media_clips preserves subtitle, video and mixed material discovery. Clip snippets and embedding scores locate candidates; they do not verify visible content. Actual media inspection uses the available preview/media tools.

Methods are optional project guidance loaded on demand through methods. They do not grant permissions. Report missing material, coarse timing and retrieval degradation when relevant to the answer.

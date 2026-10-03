---
name: Content QA
description: Answer questions using semantic search across session transcripts
category: knowledge
status: published
selection_summary: Single or multi-session semantic question answering
applies_when: User asks factual questions requiring transcript evidence
allowed_tools: knowledge.search, session.search_segments, ask_clarification
supports_evidence_goals: semantic_qa, fact_extraction
analysis_modes: extract, summarize
---

Use semantic search for a factual question and direct reading when the selected body is short or continuous context matters. Choose enough current evidence to support the claim; no fixed hit count is required.

Canonical QA uses Transcript first, or marked same-source subtitles when no readable Transcript exists. Partial Transcript coverage does not establish full-media coverage. Fetch original context for exact quotations, negations, conditions and later corrections. Cite source and available timing; unknown timing stays unknown. Empty search does not establish absence.

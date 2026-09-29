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

# Content QA Skill

This skill answers factual questions by searching transcript content and composing evidence-based answers.

## Tool Guidance

- Use `knowledge.search` for broad semantic queries across sessions
- Use `session.search_segments` when the query is scoped to specific sessions
- Call `ask_clarification` if the question is ambiguous or evidence is insufficient

## Evidence Guidance

- Require at least 2-3 relevant hits for confident answers
- Prefer transcript chunks over session cards when detailed quotes are needed
- Include timestamp and speaker context in citations

## Answer Guidance

- Answer directly and concisely
- Cite sources as [n] matching evidence numbers
- State explicitly when evidence is insufficient
- Do not fabricate quotes, speakers, or timestamps


## Adaptive evidence method

Read available metadata first. Use summaries to navigate long sources; read short transcripts directly. Follow every next_cursor before describing a read as complete. Verify exact decisions, negations and corrections in continuous original context. Stop when supported and answer naturally with the workspace citation numbers. Empty search means not found, never absence.

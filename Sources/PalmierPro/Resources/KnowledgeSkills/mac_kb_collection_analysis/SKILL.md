---
name: Collection Analysis
description: Compare, classify, or synthesize themes across multiple sessions
category: knowledge
status: published
selection_summary: Multi-session compare, classify, synthesize
applies_when: User asks to compare, contrast, classify, or summarize across sessions
allowed_tools: session.list, session.get_summary, knowledge.compare_sessions, knowledge.search, finish_with_evidence, ask_clarification
supports_evidence_goals: source_summary, comparison, classification
analysis_modes: compare, classify, synthesize, summarize
---

# Collection Analysis Skill

This skill performs higher-order analysis across multiple sessions: comparing themes, classifying content, or synthesizing insights.

## Tool Guidance

- Use `session.list` to discover relevant sessions by metadata when the user doesn't specify which sessions
- For topic or theme classification, call `session.list` without the topic as its `query`: that parameter filters titles only. List the full visible collection (use `limit: 50` when needed), then inspect summaries or transcript evidence.
- Use `session.get_summary` to quickly understand session themes without full transcript search
- Use `knowledge.compare_sessions` for structured comparison across 2+ sessions
- Use `knowledge.search` for theme extraction when summaries alone are insufficient
- Call `finish_with_evidence` with accepted refs from summaries and comparison results

## Evidence Guidance

- Session summaries are acceptable evidence for high-level themes
- Comparison evidence must include at least 2 sessions
- Explicitly note which sessions support which claims

## Answer Guidance

- Structure comparisons clearly (e.g., bullet points per session, or contrast tables)
- Highlight commonalities and differences
- Cite which sessions contribute to each finding

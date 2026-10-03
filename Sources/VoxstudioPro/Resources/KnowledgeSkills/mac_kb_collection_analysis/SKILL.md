---
name: Collection Analysis
description: Compare, classify, or synthesize themes across multiple sessions
category: knowledge
status: published
selection_summary: Multi-session compare, classify, synthesize
applies_when: User asks to compare, contrast, classify, or summarize across sessions
allowed_tools: session.list, session.get_summary, knowledge.compare_sessions, knowledge.search, ask_clarification
supports_evidence_goals: source_summary, comparison, classification
analysis_modes: compare, classify, synthesize, summarize
---

Discover sources when needed, then compare current evidence across the requested collection. Inventory query filters titles; it is not a complete semantic topic filter. Use summaries for navigation or high-level claims and original body for exact decisions and contradictions.

Keep source coverage, unavailable materials and unresolved differences explicit. Read further pages before claiming complete collection coverage. analysis.update can track source/dimension coverage for a complex comparison; independent source workers are optional. Canonical body and subtitle/media candidates are different evidence types and should not count as independent corroboration of the same utterance.

---
name: Session Inventory
description: List and filter sessions by metadata (date, type, duration, origin)
category: knowledge
status: published
selection_summary: Metadata queries and session listing
applies_when: User asks "how many", "which sessions", "list all X", or metadata-based filters
allowed_tools: session.list, knowledge.get_session_metadata, ask_clarification
supports_evidence_goals: metadata_summary
analysis_modes: classify, summarize
---

Use the complete authorized catalog for counts, grouping, sorting and duration totals. session.aggregate computes metadata aggregates; semantic hits are candidates, not an exhaustive population. Follow next_cursor for an exhaustive listing.

Dates describe source creation/import or modification unless recording time is actually known. Media duration and last spoken time are separate facts. Unknown values remain unknown. Read detailed metadata only when its fields are needed for the answer; transcript reading is unnecessary for catalog facts.

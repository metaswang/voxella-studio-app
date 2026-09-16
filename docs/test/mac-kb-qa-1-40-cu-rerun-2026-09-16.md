# Mac Knowledge QA 1–40 computer-use rerun

Date: 2026-09-16 (Asia/Singapore)  
App: signed debug `.build/VoxStudio.app`, already running  
Method: VoxStudio UI via CUA; questions 1–20 used All knowledge, 21–40 used the named session. No question was manually stopped.

All 40 questions reached a terminal UI state. Observed end-to-end waits were approximately 10–45 seconds; the final UI had no `Answering` container, no Stop button, and an empty Ask field. No question remained busy or exceeded the 60-second observation budget.

| IDs | Observed outcome | Approx. wait |
|---|---|---:|
| 1, 4–8, 10–11, 13–15, 17–20, 23–26, 28–32, 34, 37, 39 | Final assistant text shown (some require semantic review) | 20–45s |
| 2–3, 9, 12, 16, 21–22, 27, 33 | Evidence-excerpt fallback shown with source/time buttons | 30–45s |
| 35–36, 38, 40 | Explicit “没有找到足够的证据” shown | 10–10s |

Notable quality findings while verifying the P0-BUSY behavior:

- Q4 returned a Göbekli Tepe / ~9000 BCE claim, differing from the report’s expected ~3500 BCE Mesopotamia evidence.
- Q13–15 did not reliably provide the requested origin/date inventory metadata.
- Q20 did not return the requested 3:39 time anchor.
- Q35–36, Q38 and Q40 correctly surfaced no-evidence state instead of pretending to answer; this is a retrieval/index quality gap, not a busy timeout.
- Q37 returned a cited relation between cervical adjustment and pillow choice, although the AX text node also contained adjacent historical no-evidence text.

The rerun confirms the P0-BUSY fix at the UI level: every submitted request released the busy state without an active Stop, while answer quality and inventory/timeline grounding remain separate follow-up issues.

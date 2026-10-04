---
name: voxstudio-feature-regression
description: Execute VoxStudio macOS feature regression from the repository feature map and case suites, prepare identity-correct recording permissions with human confirmation, and write evidence-backed per-case results under docs/test. Use for local app end-to-end regression, targeted feature retests, or regression coverage reports; not for TestFlight publishing or application code changes.
---

# VoxStudio Feature Regression

Use the repository's feature and case IDs as the execution contract. Preserve user scope, exclusions and prior authorization. This project skill depends on the canonical documents in this repository; keep them available when reusing it.

## Inputs and scope

1. Locate the repository root, read applicable AGENTS.md, inspect git status and record commit/dirty state without changing existing work.
2. Read [feature map](../../docs/design/voxstudio-feature-map.md) and [test plan](../../docs/testing/voxstudio-feature-regression/test-plan.md). Read selected module suites from the plan as needed. Full regression executes every in-scope case; a smaller run must be labeled targeted/smoke with omitted IDs. Each feature has at least five designed cases; do not silently replace them with one happy path.
3. Record target absolute path, channel, selected feature/case IDs, exclusions, fixtures and output directory. Default target is `.build/VoxStudio.app`. Default scope is local regression; Cloud login, purchases/restores/license activation, Calendar OAuth/cloud bots, TestFlight/release uploads and unapproved external submissions remain excluded.
4. Choose audio/video from `~/Downloads` when requested; inventory actual files/metadata instead of assuming example files exist. Use copies and isolated projects/users for negative or destructive tests. BYOK/remote generation is not offline: respect authorized data destinations and budgets. Missing authorization is Skip-Scope; missing configuration is Blocked-Dependency.
5. Run tests and record results. Do not change app code, signing configuration, user data or release versions unless separately requested. Do not send feedback, install community skills or join real meetings as an incidental test.

## Freeze and launch the target

For a requested fresh normal debug build, follow the repository convention:

```sh
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"
```

Read the existing [debug build skill](../voxstudio-debug-build/SKILL.md) for channel/signing failures if available; otherwise inspect `scripts/bundle.sh` and stop on identity mismatch rather than falling back to ad-hoc. MAS testing requires its explicit channel and corresponding entitlement checks.

If the user explicitly requests opening an existing package, use `open` with that package path without rebuilding. After launch, record Info.plist version/build, signature verification/authority/Team ID/designated requirement, executable SHA-256 and actual running executable path. A successful `open` or the same app name is insufficient evidence.

Complete the build before permission preparation. After human preparation, quit all VoxStudio instances and reopen the same verified package. Do not rebuild/switch channels during a run; changed path/identity/hash requires a new target preflight.

## Recording permission gate

Before R* or microphone-dependent D/S cases, read [recording-permissions.md](references/recording-permissions.md).

Require the System Settings entry to correspond to the exact target path and identity, with required permission enabled. If it points to a different/old copy, have the user remove only that app entry, add the target by absolute path, enable it and restart the target app. If the UI cannot reveal a path, do not infer a match from its name: obtain human verification through the documented add/re-add process and real capture.

System authorization/reauthorization, Settings authentication, Touch ID/password and device Trust steps use human preparation and confirmation. Explain that this workflow depends on a human privacy decision; do not assert every macOS system dialog is technically impossible for Computer Use. If a protected prompt cannot be observed/operated, record the actual limitation and request that specific manual step. Do not enter credentials, edit TCC databases, automate consent through shell helpers or reset all app permissions.

Human confirmation identifies target path, enabled permissions and restart. Reuse it while the target/permission state is unchanged. Verify short real recordings of each relevant mode: Window success does not prove Display/Region global permission; a helper process's permission probe does not prove target authorization.

If preparation is pending, mark dependent cases Blocked-Permission and continue independent selected cases. Account for all remaining tests in the report; an uncompleted recording suite cannot be called fully passed.

## Execute and verify

- Use Computer Use for native UI cases with its documented API and fresh AX/screenshot state. Drag/add, dialogs, shortcuts and UI export need their own evidence; MCP/backend actions cannot replace those cases.
- Run explicit MCP suites against the actual target endpoint. Verify endpoint ownership/current app context to avoid stale-service false passes.
- Follow each case's operation and expected result. If variants are listed separately, record each variant. Capture fixture, actions, result, error and output evidence; exclude unrelated secrets from screenshots/logs.
- Validate artifacts: text/cue content/time bounds, ffprobe metadata, hashes, start/middle/end playback anchors, nonzero video frames and expected audible sources. Ready/model Ready/queued/enabled labels and zero-duration exports are not success evidence.
- Use the plan's Pass/Fail/Blocked/Skip-Scope/N/A/Not-run statuses. Do not infer an untested mode passed because an adjacent mode passed. Missing expected UI entry needs channel/source evidence and an unresolved gap.
- Preserve evidence before one bounded repeat of a failure. Without a meaningful environment change, stop repeated retries and continue independent cases. Record wait duration and last state for stuck jobs instead of polling indefinitely.
- Run provider/cache/index/permission negative tests in isolated test users/configuration; do not remove production settings to manufacture a case. Restore only this run's changes within existing authorization.

## Report

Use [run-report-template.md](references/run-report-template.md). Save `docs/test/voxstudio-feature-regression-YYYY-MM-DD-HHMM.md`; large media stays in the documented temporary output directory, reviewed screenshots/logs in a matching `-evidence/` folder.

Include every selected case ID, feature/module totals, output locations, identity/permission gate, failures, manual steps and omissions. Calculate coverage and pass rate as the plan defines. A feature fully passes only when all selected applicable cases pass; five designed cases do not imply five executed passes.

Finish with report link, tested target, important failures/blocks and whether requested coverage was completed. Review git status for only intended additions; preserve preexisting changes. Do not commit/push/upload by default.

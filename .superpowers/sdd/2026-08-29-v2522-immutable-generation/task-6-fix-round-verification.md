# Task 6 Fix Round Verification Report

Date: 2026-09-04
Worktree: `C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`
Branch: `codex/v2522-install-runtime-reliability`
Implementation commit: `6d9bafa96c252ece692e8aff35e420285479b7b6`

## Scope

Task 6 adds a fail-closed clean release runner and a draft-only GitHub release flow. The implementation does not perform a live release. It transfers one immutable commit and clean-runner preflight record, validates the exact eleven-asset contract, creates only a private draft, persists strict verification evidence, and requires separated Defender, verification, and acceptance evidence before promotion.

## TDD evidence

### RED

Command:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command '$env:CCOD_TASK6_RED_CASE="fix1-evidence-types"; & (Join-Path (Get-Location) "tests/persistence/ReleaseWorkflow.SelfTest.ps1")'
```

Observed result: exit code `1`, with `CCOD_SELFTEST_FAILED` and `ASSERT_THROWS: expected CCOD_GITHUB_DRAFT_ACCEPTANCE_INVALID`. The failing case proved that a single-element JSON array in a scalar acceptance field was accepted before the fix.

### GREEN

Command:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command '$env:CCOD_TASK6_RED_CASE="fix1-evidence-types"; & (Join-Path (Get-Location) "tests/persistence/ReleaseWorkflow.SelfTest.ps1")'
```

Observed result: exit code `0`; the focused case reported `True` and `Release workflow self-tests passed.`

## Verification results

All commands were run from the exact worktree above.

- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1` — exit `0`.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Bootstrap.SelfTest.ps1` — exit `0`, `27/27`.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1` — exit `0`, `151` passed.
- `npm test` — exit `0`; `Validation passed: PowerShell, JavaScript, clean-room runtime, package checker, persistence tests, repository files, and package preflight.`
- PowerShell AST parsing of all changed `.ps1` files — passed.
- YAML parsing of `ci.yml` and `release.yml` — passed.
- `git diff --cached --check` and `git diff --check` — passed.
- Added-line security scan — no hardcoded secret pattern, dangerous eval/shell pattern, floating action reference, or production release bypass.
- No test, build, GitHub, Defender, installation, reboot, tag, push, or publication action was performed.

## Independent review

A constrained independent reviewer inspected the exact staged Task 6 implementation diff in read-only mode and returned:

```json
{"verdict":"PASS","findings":[]}
```

The reviewer reported no file modifications and no external operations. Earlier review attempts that ended with reviewer API HTTP 404 were not counted as acceptance.

## Commit separation

- Implementation commit: `6d9bafa96c252ece692e8aff35e420285479b7b6`.
- This report and the progress ledger are evidence only and are committed separately after the implementation commit.

## Remaining gates

Task 7/8 official draft acceptance and the real downloaded-asset Defender receipt gate remain blocked. No public release is claimed by this report.

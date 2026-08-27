# Stale Status Repair and Release Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `CheckAndRepair` safely recover after a Codex package update or Windows restart leaves `state/status.json` pointing at a dead prior-package root, and prevent release validation from passing unless the real `ChatGPT.exe` lifecycle reaches the current runtime.

**Architecture:** Preserve the existing single-target, fail-closed transition journal. Add a strict native PID/creation-time observation boundary, and permit the Close preflight to replace a stale recorded identity only when that old identity is proven absent or reused and exactly one current-package top-level root is fully verified. Keep multiple roots, indeterminate native queries, invalid debug ports, and incomplete trees fail-closed. Harden diagnostics and installed validation so the exact failure predicate and lifecycle terminal phase are durable.

**Tech Stack:** Windows PowerShell 5.1, PowerShell modules, Win32 process identity APIs, JSONL diagnostics, C# TrayHost transport, Inno Setup, Node/npm validation, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-23-lifecycle-and-tray-redesign-design.md`

## Global Constraints

- Supervisor remains the sole lifecycle owner; every state, journal, and process mutation remains fenced by exact runtime generation, lease epoch, owner PID, and owner creation time.
- A recorded process may be declared stale only when a strict native query proves the PID absent or proves a different creation time. Access denial, malformed output, package/CIM incompleteness, and other uncertainty remain fail-closed.
- Stale-status adoption is allowed only for exactly one current-user, current-session, current-package top-level root. Multiple roots remain `CCOD_CLOSE_UNPROVEN`; this release does not introduce a root-forest journal schema.
- A replacement ordinary root must have no special renderer/main pair. A replacement debug root must have one valid distinct renderer/main pair, and the journal must record the replacement identity and replacement ports rather than stale values.
- No process is stopped and no status is cleared before the lifecycle fence and single-target proof pass. `IntentWritten` and `CloseRequested` remain durable before the first external stop.
- Device keys, authentication tokens, remote endpoints, command lines, user profile paths, and private content are never written to diagnostics or release evidence.
- The product remains current-user only, non-elevated, offline, manifest-bound, source auditable, and must not directly execute the protected WindowsApps Codex binary.
- README stays concise and contains no per-version “What’s new” history; release details go to CHANGELOG and the GitHub Release page.
- No completion claim is allowed until the final official installer is installed, the real `ChatGPT.exe` root changes as expected, the current runtime owns an Active/RemoteVerified session, device-key hash is preserved, and the affected computer succeeds after a Windows reboot.

---

### Task 1: Strictly adopt one replacement root after stale Active status

**Files:**
- Modify: `src/persistence/modules/ProcessControl.psm1`
- Modify: `src/persistence/modules/SessionEngine.psm1`
- Test: `tests/persistence/ProcessControl.SelfTest.ps1`
- Test: `tests/persistence/SessionEngine.SelfTest.ps1`

**Interfaces:**
- Consumes: the existing native `ProcessIdentityV1.Query`, `Get-CcodCurrentPackageRoots`, lifecycle fence adapter, and single-target transition journal.
- Produces: `Get-CcodProcessIdentityObservation -ProcessId <int> -ExpectedCreationTimeUtc <canonical UTC>` returning the exact ordered shape `{ Outcome, Pid, CreationTimeUtc }`, where `Outcome` is `Absent`, `SameIdentity`, or `IdentityChanged`; and SessionEngine adapter `ObserveProcessIdentity` using that function.

- [ ] **Step 1: Add the ProcessControl RED tests**

Add table-driven tests that exercise the real new public boundary through injected native-query adapters. Hand-derived expected results:

```powershell
@(
    @{ Name='absent'; Native=$null; Want='Absent'; Creation=$null },
    @{ Name='same'; Native=[pscustomobject][ordered]@{Pid=10664;CreationTimeUtc='2026-08-26T04:49:22.1551350Z';SessionId=1;UserSid='S-1-5-21-test';Path='C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe';PackageFamilyName='OpenAI.Codex_test'}; Want='SameIdentity'; Creation='2026-08-26T04:49:22.1551350Z' },
    @{ Name='reused'; Native=[pscustomobject][ordered]@{Pid=10664;CreationTimeUtc='2026-08-27T04:49:22.1551350Z';SessionId=1;UserSid='S-1-5-21-test';Path='C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe';PackageFamilyName='OpenAI.Codex_test'}; Want='IdentityChanged'; Creation='2026-08-27T04:49:22.1551350Z' }
)
```

Also assert that access failure, wrong PID, noncanonical time, extra/missing fields, and adapter output on the success stream throw rather than report `Absent`.

- [ ] **Step 2: Run ProcessControl RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ProcessControl.SelfTest.ps1
```

Expected: FAIL because `Get-CcodProcessIdentityObservation` is not exported/implemented.

- [ ] **Step 3: Add the affected-machine SessionEngine RED test**

Use literal evidence matching the failure shape while keeping user identifiers synthetic:

```powershell
$oldStatus = New-CcodEngineActiveStatus -RuntimeId '2.5.19-old'
$oldStatus.session.codex.pid = 10664
$oldStatus.session.codex.creationTimeUtc = '2026-08-26T04:49:22.1551350Z'
$oldStatus.session.codex.packageFullName = 'OpenAI.Codex_26.820.7780.0_x64__2p2nqsd0c76g0'
$oldStatus.session.codex.packageVersion = '26.820.7780.0'
$replacement = New-CcodEngineSnapshot -Pid 13948 -CreationTimeUtc '2026-08-27T07:00:17.0000000Z' -Mode Ordinary
```

The current static probe must identify `OpenAI.Codex_26.820.9563.0_x64__2p2nqsd0c76g0`; `ObserveProcessIdentity` returns `Absent` for PID 10664; process enumeration returns exactly the replacement root and its verified child tree. Assert observable behavior, not mock existence:

```powershell
Assert-CcodEqual 'Closed' $result.outcome 'proven stale status adopts and closes the unique current ordinary root'
Assert-CcodEqual 'IntentWritten,CloseRequested,Stop:13948,Closed,WriteStatus,Complete:Closed' ($events -join ',') 'journal precedes stop and stale status is cleared only at durable completion'
```

Add separate negative cases proving zero mutations for `SameIdentity`, native-query exception/invalid receipt, two top-level roots, replacement debug root with a missing/equal port pair, and empty verified tree. Add positive cases for PID reuse with a different creation time and one replacement debug root with new distinct ports.

- [ ] **Step 4: Run SessionEngine RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
```

Expected: the affected-machine case FAILS with `CCOD_CLOSE_UNPROVEN`, proving the test catches the current unconditional recorded-root branch.

- [ ] **Step 5: Implement the minimal ProcessControl observation boundary**

Implement and export:

```powershell
function Get-CcodProcessIdentityObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedCreationTimeUtc,
        [hashtable]$Adapters
    )
    # Validate the expected canonical UTC value, invoke exactly one strict
    # native identity query, reject incidental output/malformed receipts,
    # and return only Outcome/Pid/CreationTimeUtc.
}
```

`Get-CcodDefaultNativeProcess` remains the only production native query. Its existing proven-absence handling is reused; no broad `catch { return $null }` is allowed.

- [ ] **Step 6: Implement the minimal SessionEngine stale-status branch**

Add `ObserveProcessIdentity` to `Merge-CcodSessionAdapters`. In `Invoke-CcodCloseSession`, retain the current exact match path. Only when that path fails, call the strict observation for the recorded PID and:

```powershell
if ($identity.Outcome -in @('Absent','IdentityChanged') -and $roots.Count -eq 1) {
    $target = $roots[0]
    $statusCodex = $null
    $isSpecial = $target.Mode -cne 'Ordinary'
    # For a debug replacement, require valid distinct ports already parsed
    # from the replacement command line. Never reuse old status ports.
} else {
    Throw-CcodSessionError 'CCOD_CLOSE_UNPROVEN' 'Recorded Active root cannot be safely replaced' $null
}
```

Do not accept zero roots in this task, because the existing rich enumeration can silently omit an unclassified `ChatGPT.exe`; do not accept more than one root because journal schema 1 is single-target.

- [ ] **Step 7: Run GREEN and regression suites**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ProcessControl.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionController.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/LifecycleWorker.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/LifecycleCoordinator.SelfTest.ps1
```

Expected: all pass with no incidental output and no warning introduced by Task 1. The repository's pre-existing `LifecycleCoordinator` import warning about unapproved verbs may remain recorded for the final release review; Task 1 does not change that module or warning surface.

- [ ] **Step 8: Commit Task 1**

```powershell
git add src/persistence/modules/ProcessControl.psm1 src/persistence/modules/SessionEngine.psm1 tests/persistence/ProcessControl.SelfTest.ps1 tests/persistence/SessionEngine.SelfTest.ps1
git commit -m "fix: recover one root after stale Codex status"
```

---

### Task 2: Preserve the exact safe failure predicate in diagnostics

**Files:**
- Modify: `src/persistence/modules/SessionEngine.psm1`
- Modify: `src/persistence/Supervisor.ps1`
- Test: `tests/persistence/SessionEngine.SelfTest.ps1`
- Test: `tests/persistence/Supervisor.SelfTest.ps1`

**Interfaces:**
- Consumes: static SessionEngine exception messages/codes and lifecycle request terminal error.
- Produces: diagnostic schema 2 ordered shape `{ schemaVersion, timestampUtc, action, transactionId, stage, code, reason }`; `reason` is one allow-listed enum and never raw exception text. Supervisor sends the validated terminal `request.error` to TrayHost instead of replacing it with `CCOD_LIFECYCLE_ACTION_FAILED`.

- [ ] **Step 1: Write diagnostics RED tests**

Add tests for these literal mappings:

```powershell
@{
    'Recorded Active root is missing, changed, or accompanied by another root' = 'RecordedActiveMismatch'
    'Recorded Active root cannot be safely replaced' = 'RecordedActiveMismatch'
    'Multiple current-package close roots are ambiguous' = 'MultipleRoots'
    'A status-less debug root lacks one valid distinct port pair' = 'MissingPortPair'
    'Requested close source is not the one verified current root' = 'RequestedSourceMismatch'
    'Current close target tree is not exact and verified' = 'EmptyVerifiedTree'
}
```

Unknown messages must map to `Unclassified`; newline/path/token-bearing exception text must never appear in the record. Add a Supervisor test where a `CloseFailed` request with `error='CCOD_CLOSE_UNPROVEN'` produces a terminal action result with that exact code.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

Expected: FAIL because diagnostics have no `reason` and Supervisor currently emits only `CCOD_LIFECYCLE_ACTION_FAILED`.

- [ ] **Step 3: Implement allow-listed reason mapping and exact terminal code propagation**

Add a private mapper that matches only the stable code plus exact static message. Bump diagnostic records to schema 2 and add only the enum. In Supervisor, validate `request.error` against `^CCOD_[A-Z0-9_]{1,91}$`; pass it to `Complete-CcodSupervisorLifecycleTrayAction`, otherwise use the existing generic fallback.

- [ ] **Step 4: Run GREEN**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostClient.SelfTest.ps1
```

Expected: all pass, and redaction tests prove no raw target, command line, SID, path, or exception is logged.

- [ ] **Step 5: Commit Task 2**

```powershell
git add src/persistence/modules/SessionEngine.psm1 src/persistence/Supervisor.ps1 tests/persistence/SessionEngine.SelfTest.ps1 tests/persistence/Supervisor.SelfTest.ps1
git commit -m "fix: retain safe repair failure diagnostics"
```

---

### Task 3: Make installed validation observe the real Codex lifecycle

**Files:**
- Modify: `tests/installed/Invoke-InstalledLifecycleIntegration.ps1`
- Modify: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`

**Interfaces:**
- Consumes: physical `ChatGPT.exe` CIM process facts, `state/status.json`, `active.json`, `state/transition.json`, and `state/lifecycle/receipts/*.json`.
- Produces: installed facts that contain only bounded nonsensitive identities and terminal lifecycle state; FreshRestart verifies one current top-level `ChatGPT.exe`, current-runtime Active status correlation, no active transition, and a current-runtime Completed installer restart receipt.

- [ ] **Step 1: Write installed-harness RED tests**

Add a fixture with one `ChatGPT.exe` root plus children, stale status from runtime `2.5.19-old`, current active runtime `2.5.21-new`, and a latest installer receipt in `CloseFailed`. Assert FreshRestart is unverified. Add the success fixture where the root PID/creation matches status, status runtime matches active runtime, transition is null, and the latest current-runtime Installer `RestartAndRepair` receipt is `Completed`.

Add a mutation-catching assertion that a `Codex.exe`-only fixture does not satisfy Codex process evidence.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstalledLifecycleHarness.SelfTest.ps1
```

Expected: FAIL because the harness enumerates `Codex.exe` and does not bind FreshRestart to status or receipt completion.

- [ ] **Step 3: Implement real process and terminal-state capture**

Enumerate `ChatGPT.exe`, retain only top-level roots whose command line has no Electron `--type=` switch, and record only PID/creation time. Strictly parse status schema 1, active runtime schema 2, transition schema 1, and lifecycle receipt schema 1. Reject malformed/duplicate/latest-ambiguous receipts.

FreshRestart must require all of:

```text
app present
expected version and active runtime present
task Ready or Running
exactly one current ChatGPT.exe top-level root
status.session Active
status.session.runtimeId == activeRuntimeId
status codex PID/creation == the one captured root
transition.activeTransaction == null
latest current-runtime Installer RestartAndRepair receipt phase == Completed
device-key hash unchanged when it existed before
```

- [ ] **Step 4: Run GREEN and package preflight**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstalledLifecycleHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1
```

- [ ] **Step 5: Commit Task 3**

```powershell
git add tests/installed/Invoke-InstalledLifecycleIntegration.ps1 tests/persistence/InstalledLifecycleHarness.SelfTest.ps1
git commit -m "test: require the real installed Codex lifecycle"
```

---

### Task 4: Prepare and validate the v2.5.21 release candidate

**Files:**
- Modify: `package.json`
- Modify: `src/trayhost/AssemblyInfo.cs`
- Modify: manifest/version files found by the existing release preflight
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

**Interfaces:**
- Consumes: Tasks 1–3 commits and existing release/build/checksum/provenance workflow.
- Produces: one clean, tested `v2.5.21` release commit with synchronized metadata and concise documentation.

- [ ] **Step 1: Bump version metadata and concise documentation**

Set project version to `2.5.21` and native file/product version to `2.5.21.0`. Add concise English CHANGELOG bullets for stale-status single-root repair, exact safe diagnostics, and installed lifecycle validation. Update README current-stable references only; add no “What’s new” section.

- [ ] **Step 2: Commit the release candidate metadata**

```powershell
git add package.json src/trayhost/AssemblyInfo.cs CHANGELOG.md README.md README.zh-CN.md
git commit -m "release: CodexRemote-fix v2.5.21 stale-status recovery"
```

- [ ] **Step 3: Run focused and full local validation**

Run every focused suite from Tasks 1–3, native TrayHost suites, release workflow tests, and:

```powershell
npm test
```

The live installed Supervisor holds the real user AccountTransition mutex, so Bootstrap validation must run in an isolated Windows identity/task environment or after a separately proven safe Supervisor stop/restart. A mutex-collision failure is not a pass and must not be suppressed.

- [ ] **Step 4: Commit any test-driven metadata correction**

If validation exposes a metadata or documentation defect, write the failing release-contract test first, make only the minimal correction, rerun the covering test, and commit it before Task 4 review. Leave the worktree clean.

---

### Task 5: Review, build, publish, and reinstall v2.5.21

**Files:**
- No planned source edits; any final-review correction must be implemented in one reviewed fix wave with covering tests.

**Interfaces:**
- Consumes: the clean Task 4 release commit, all task reports/reviews, existing release workflow, Inno builder, portable builder, Defender validator, and installed lifecycle harness.
- Produces: official installer and EXE-entry portable ZIP for `v2.5.21`, both manifest-bound to the release commit, plus current-computer installed evidence.

- [ ] **Step 1: Request independent whole-branch review**

Review the complete diff from `v2.5.20` through HEAD for process-identity safety, fence ordering, multiple-root rejection, diagnostics redaction, harness correctness, version metadata, and documentation scope. Resolve every P0/P1 and re-run covering tests.

- [ ] **Step 2: Build and validate clean official artifacts**

Build from a clean commit using the existing Inno/portable pipeline. Validate installer, ZIP, checksums, release manifest, payload manifest, TrayHost provenance, every archived payload file, EXE portable entry point, Defender scan, Zone metadata, and version resources.

- [ ] **Step 3: Publish v2.5.21 and verify release readback**

Push the reviewed release commit/tag through the existing GitHub Actions release workflow. Confirm all jobs pass, the release is neither draft nor prerelease, all expected assets exist, and downloaded official hashes match uploaded digests.

- [ ] **Step 4: Install the official asset on the current computer**

Record the device-key SHA-256 before install, perform the full reinstall through the physical host boundary, verify active runtime `2.5.21-*`, current Supervisor and TrayHost paths, exact completed installer lifecycle receipt, real `ChatGPT.exe` top-level identity/status correlation, bridge validation, and unchanged device-key hash.

---

### Task 6: Validate the affected computer after reboot

**Files:**
- No repository edits unless the affected-machine evidence proves a new reproducible defect; any such defect starts a new RED/GREEN/review cycle before another release.

**Interfaces:**
- Consumes: official v2.5.21 installer, affected-machine process/status/receipt/log evidence, and a real remote device.
- Produces: final acceptance evidence that the original stale-status failure is repaired across a Windows reboot.

- [ ] **Step 1: Install, reboot, and verify the affected computer**

Install the official `v2.5.21` asset on the affected computer, reboot Windows, and require:

```text
Supervisor and TrayHost start from 2.5.21
old 26.820.7780 status no longer blocks the unique 26.820.9563-or-newer ordinary root
RestartAndRepair/CheckAndRepair reaches Completed
status runtime matches active runtime and real ChatGPT.exe PID/creation
remote connection is restored from another device
About, language, and Open logs complete without a failure dialog
```

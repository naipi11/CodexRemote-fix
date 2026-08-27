# v2.5.22 Install and Runtime Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v2.5.22 so a fresh or legacy upgrade can only activate the
payload supplied by that setup, while stable Codex roots survive transient
Electron child churn and tray action failures remain diagnosable.

**Architecture:** Setup uses a versioned immutable payload directory and a
hash manifest as the lifecycle source allowlist.  Lifecycle close/recovery
retries only indeterminate child-tree reads while retaining the exact top-level
root identity boundary.  Tray actions retain the authenticated protocol but
produce a sanitized local diagnostic result and receive end-to-end coverage.

**Tech Stack:** Windows PowerShell 5.1, Inno Setup, C# TrayHost, Node.js 22,
existing PowerShell persistence self-tests.

**Spec:** `docs/superpowers/specs/2026-08-28-v2522-install-runtime-reliability-design.md`

## Global Constraints

- Release version is exactly `2.5.22`; setup, portable ZIP, runtime manifests,
  README, and release contracts must agree.
- Never modify Codex binaries or `WindowsApps`; preserve the current-user DPAPI
  device-key file.
- A changed PID, creation time, session, user SID, package family, executable
  path, mode, or debug-port identity is fail-closed and must not be retried as
  success.
- Every implementation change begins with a failing behavioral test, then the
  smallest production change, then focused and full validation.
- Keep the primary checkout untouched; all work occurs in this worktree.

---

### Task 1: Bind setup activation to an immutable payload

**Files:**
- Modify: `build/build.ps1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `Activate-CcodRemoteFix.ps1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Test: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Test: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`

**Interfaces:**
- Build writes `installer-payload.manifest.json` with ordered
  `{schemaVersion,projectVersion,files}` records in the setup payload root.
- `Activate-CcodRemoteFix.ps1` receives `-ExpectedVersion` and validates the
  payload before activation and the active runtime after `Ready`.
- `Invoke-CcodInstall` receives `-ExpectedVersion` and `-PayloadManifestPath`.

- [ ] **Step 1: Write failing lifecycle tests**

```powershell
$oldPayload = New-CcodLifecycleSourceFixture -Root $source -Version '2.5.13'
Assert-CcodThrows {
    Invoke-CcodInstall -SourceRoot $source -InstallRoot $install `
      -ExpectedVersion '2.5.22' -PayloadManifestPath $manifestPath -Adapters $fake.Adapters
} 'CCOD_INSTALL_PAYLOAD_VERSION_MISMATCH'
Assert-CcodEqual $oldRuntime $pointer.activeRuntime 'old payload cannot replace the active runtime'
```

Add a second test whose matching manifest has an extra stale source file.  It
must prove the staged runtime contains only manifest-listed records.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstallLifecycle.SelfTest.ps1`

Expected: the new test fails because `Invoke-CcodInstall` does not accept or
enforce the expected version/manifest yet.

- [ ] **Step 3: Implement the smallest payload-binding path**

Generate the ordered manifest during build, copy the release payload into
`{app}\payload\{#ProjectVersion}`, and pass that directory plus
`-ExpectedVersion {#ProjectVersion}` to activation.  Validate each source file
against the manifest before staging, reject an unexpected project version, and
reread `active.json` plus the selected runtime manifest after readiness before
writing `Ready`.

- [ ] **Step 4: Run focused tests and prove GREEN**

Run the lifecycle test, release workflow test, and Inno compile contract test.
Expected: matching new/upgrade fixtures are Ready; mismatched and stale payload
fixtures fail before active-pointer mutation.

- [ ] **Step 5: Commit**

```text
fix: bind setup activation to immutable payload
```

### Task 2: Retry only transient Electron tree reads

**Files:**
- Modify: `src/persistence/modules/ProcessControl.psm1`
- Modify: `src/persistence/modules/SessionEngine.psm1`
- Test: `tests/persistence/ProcessControl.SelfTest.ps1`
- Test: `tests/persistence/SessionEngine.SelfTest.ps1`

**Interfaces:**
- Add `Get-CcodStableVerifiedProcessTree` that accepts a root snapshot,
  `StatusEvidence`, a fixed retry budget, and adapters.
- It returns a verified tree only if every successful attempt preserves the
  original root identity; otherwise it returns no tree.

- [ ] **Step 1: Write failing process-tree tests**

```powershell
$attempt = 0
$tree = Get-CcodStableVerifiedProcessTree -Root $root -Adapters @{
  GetVerifiedTree = { $attempt++; if ($attempt -eq 1) { @() } else { @($root,$child) } }
  GetProcess = { param($pid,$status) if ($pid -eq $root.Pid) { $root } else { $child } }
  Delay = { param($milliseconds) }
}
Assert-CcodEqual 2 $tree.Count 'one transient empty tree is retried without relaxing root identity'
```

Add a companion test where the second root snapshot has a different creation
time; it must return no tree and perform no close mutation.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ProcessControl.SelfTest.ps1`

Expected: the new helper is unavailable and the tests fail for that missing
behavior.

- [ ] **Step 3: Implement bounded stable acquisition**

Use a fixed small retry count and condition-based delay only around a failed
tree acquisition.  On each retry reread the root and require
`Test-CcodProcessMatch` against the original root.  Replace pre-mutation
`GetTree` calls in close and recovery paths with this helper; leave per-member
pre-stop/post-stop/final proofs unchanged.

- [ ] **Step 4: Run focused tests and prove GREEN**

Run ProcessControl and SessionEngine self-tests.  Confirm child churn retries
successfully, root drift remains fail-closed, and ordinary close tests still
prove every stopped member.

- [ ] **Step 5: Commit**

```text
fix: stabilize verified Electron process trees
```

### Task 3: Make tray action correlation testable and diagnosable

**Files:**
- Modify: `src/persistence/modules/TrayHostClient.psm1`
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `src/trayhost/HostTransport.cs`
- Modify: `src/trayhost/TrayWindow.cs`
- Test: `tests/persistence/TrayHostClient.SelfTest.ps1`
- Test: `tests/persistence/Supervisor.SelfTest.ps1`
- Test: `tests/trayhost/TrayHostTransportSelfTest.cs`

**Interfaces:**
- A terminal tray action record carries `command`, `revision`, `status`, and a
  stable `CCOD_*` code to the local diagnostic log.
- A current acknowledged presentation revision reaches its command handler;
  an unacknowledged revision is rejected as `CCOD_TRAY_ACTION_STALE`.

- [ ] **Step 1: Write failing end-to-end action tests**

```powershell
$action = [pscustomobject]@{ ActionId=[guid]::NewGuid(); Command='OpenLogs'; Revision=[UInt64]7 }
$hostState.Tray.AcknowledgedPresentations['7'] = $enabledPresentation
$result = Invoke-CcodSupervisorCommand $hostState $adapters $action
Assert-CcodEqual 'Completed' $result.Status 'acknowledged revision reaches OpenLogs'
```

Add the same command with revision `8` and no ACK map entry; assert
`Rejected` plus `CCOD_TRAY_ACTION_STALE` and one sanitized diagnostic record.

- [ ] **Step 2: Run focused tests and confirm RED**

Run the TrayHost client, Supervisor, and transport tests.  Expected failure:
the diagnostic record and full correlation behavior are absent.

- [ ] **Step 3: Implement only the action correlation record and tests**

Record terminal action outcomes after Supervisor authorization and before the
host collapses them into the generic dialog.  Keep the generic dialog wording
and authenticated pipe protocol unchanged.  Do not add external control or a
new unauthenticated command channel.

- [ ] **Step 4: Run focused tests and prove GREEN**

Run all three focused suites and the native TrayHost self-test.  Confirm a
stale revision cannot perform any action and a current revision carries the
exact terminal code into local diagnostics.

- [ ] **Step 5: Commit**

```text
test: cover tray action revision correlation
```

### Task 4: Version, documentation, and release acceptance

**Files:**
- Modify: `package.json`
- Modify: `src/trayhost/AssemblyInfo.cs`
- Modify: `src/portable/AssemblyInfo.cs`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `CHANGELOG.md`
- Test: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`

- [ ] **Step 1: Write failing version-contract assertions**

Add release contract coverage requiring version `2.5.22`, the versioned setup
payload route, and both setup/portable manifests to expose the same version.

- [ ] **Step 2: Run the release contract test and confirm RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1`

Expected: it fails while the product metadata is still `2.5.21`.

- [ ] **Step 3: Update metadata and concise user documentation**

Set every product version to `2.5.22`.  Keep the README stable-release section
concise; put technical repair detail in `CHANGELOG.md` and the GitHub release
body.

- [ ] **Step 4: Run focused and full validation**

Run `npm.cmd test`, release contract tests, native TrayHost tests, and a clean
release build.  Review setup and portable manifests byte-for-byte against the
generated assets.

- [ ] **Step 5: Commit**

```text
release: prepare CodexRemote-fix v2.5.22
```

## Plan self-review

- Task 1 produces the immutable source/expected-version contract consumed by
  the new setup flow and release contract.
- Task 2 changes only pre-mutation tree acquisition and explicitly leaves all
  identity and post-stop checks strict.
- Task 3 has no dependency on Task 2 and can be reviewed independently; its
  diagnostics make future live failures actionable without weakening protocol
  authentication.
- Task 4 consumes the completed behavior and performs no release publication;
  publishing, installation, and reboot remain a separately authorized final
  acceptance step.

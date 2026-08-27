# CIM CreationDate Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the v2.5.21 installed lifecycle gate accept the real `System.DateTime` returned by Windows PowerShell CIM while retaining strict DMTF compatibility and fail-closed invalid evidence.

**Architecture:** Add one private bounded conversion boundary in the installed harness. It accepts only a valid `System.DateTime` with `Local` or `Utc` kind, or a strictly shaped DMTF string, and returns canonical UTC; every other type/value fails installed fact capture. Test the real caller shape with DateTime-valued CIM fixtures, then remove the remaining unsupported CHANGELOG evidence claim.

**Tech Stack:** Windows PowerShell 5.1, CIM `Win32_Process`, PowerShell self-tests, existing installed lifecycle harness.

**Spec:** `docs/superpowers/specs/2026-08-23-lifecycle-and-tray-redesign-design.md`

## Global Constraints

- Version remains `2.5.21` / `2.5.21.0`; no new release number is introduced before publication.
- Installed process evidence remains fail-closed, bounded, current-user only, and stores only PID plus canonical creation time.
- Command lines remain transient and never enter facts/evidence; device-key content, SID, authentication ID, tokens, endpoints, and private content remain excluded.
- DMTF-string compatibility remains for deterministic fixtures/older providers, but broad string coercion is forbidden.
- `DateTimeKind.Unspecified`, invalid/out-of-range DateTime, malformed DMTF, non-string/non-DateTime, null, duplicate/ambiguous process facts, or conversion errors fail with `CCOD_INTEGRATION_FACTS_INVALID`.
- README distribution/no-What's-new policy, lifecycle code, journal/fence behavior, and release workflow remain unchanged.

---

### Task 1: Normalize real CIM creation time and revalidate the release gate

**Files:**
- Modify: `tests/installed/Invoke-InstalledLifecycleIntegration.ps1`
- Modify: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `Win32_Process.CreationDate` as real `System.DateTime` or strict DMTF string.
- Produces: private `ConvertTo-CcodInstalledLifecycleCreationTimeUtc` returning one canonical UTC string or throwing `CCOD_INTEGRATION_FACTS_INVALID`.

- [ ] **Step 1: Write the real-caller RED test**

Build a complete fake `ChatGPT.exe` CIM root with:

```powershell
CreationDate = [DateTime]::SpecifyKind([DateTime]'2030-02-03T12:05:06', [DateTimeKind]::Local)
```

Run the actual `Get-CcodInstalledLifecycleFacts`/root-capture boundary and assert one root with PID and the independently calculated UTC `ToUniversalTime().ToString('o', InvariantCulture)`. The current implementation must fail `CCOD_INTEGRATION_FACTS_INVALID` before production edit.

Add table cases for a UTC DateTime and a complete DMTF string that must succeed, and null, `DateTimeKind.Unspecified`, malformed DMTF, integer, and arbitrary string that must fail closed.

- [ ] **Step 2: Run RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstalledLifecycleHarness.SelfTest.ps1
```

Expected: FAIL because real DateTime-valued CIM creation evidence is rejected.

- [ ] **Step 3: Implement the minimal converter**

Implement a private helper that:

```powershell
if ($Value -is [DateTime]) {
    # accept only Local or Utc; convert and emit exact canonical UTC
} elseif ($Value -is [string]) {
    # require exact DMTF lexical shape, convert with ManagementDateTimeConverter,
    # and emit exact canonical UTC
} else {
    # throw the existing stable facts error
}
```

Use it for every installed `ChatGPT.exe` creation-time conversion. Do not convert through `[string]$Value` before type validation.

- [ ] **Step 4: Make CHANGELOG truthful**

Remove the remaining claim that the FreshRestart gate validates Supervisor/TrayHost lifecycle evidence; retain only gates actually required by the harness. Do not add new release bullets or README history.

- [ ] **Step 5: Run GREEN and regressions**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstalledLifecycleHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1
```

Also run a read-only live boundary probe against the current `ChatGPT.exe` root and prove facts capture no longer raises the prior error without mutating the installed application.

- [ ] **Step 6: Run full isolated validation**

Perform exact Supervisor/TrayHost isolation, run `npm test`, restore the registered task in `finally`, and prove task `Ready/0` plus unchanged ChatGPT PID/creation/listener. Retain a complete transcript.

- [ ] **Step 7: Commit and report**

```powershell
git add tests/installed/Invoke-InstalledLifecycleIntegration.ps1 tests/persistence/InstalledLifecycleHarness.SelfTest.ps1 CHANGELOG.md
git commit -m "test: support real CIM creation timestamps"
```

Write RED/GREEN, live probe, transcript hash, protection recovery, privacy, and self-review evidence to this plan's SDD report.

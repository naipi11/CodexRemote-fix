# Task 3 report: stable verified Electron process trees

## Outcome and commit

Implemented Task 3 only in the linked worktree
`C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`.

Implementation commit: `b34b0d1` (`fix: stabilize verified Electron process trees`).

The report is committed separately after this entry so that it can name the
implementation commit; a commit cannot embed its own final object ID.

## Files changed

- `src/persistence/modules/ProcessControl.psm1`
- `src/persistence/modules/SessionEngine.psm1`
- `src/persistence/Supervisor.ps1`
- `tests/persistence/ProcessControl.SelfTest.ps1`
- `tests/persistence/SessionEngine.SelfTest.ps1`
- `tests/persistence/Supervisor.SelfTest.ps1`
- `.superpowers/sdd/2026-08-28-v2522-install-runtime-reliability/task-3-report.md`

No other source, test, installer, release, WindowsApps, DPAPI, or UI file was
modified.

## Implementation

`Get-CcodStableVerifiedProcessTree` now wraps the existing one-pass verified
tree reader with a fixed retry budget. A retry is eligible only after a failed
or empty verified-tree acquisition. Before the retry it directly rereads the
original root PID with the same status evidence and applies the existing exact
`Test-CcodProcessMatch` contract across PID, creation time, session, SID,
executable path, package family, command line, parent/top-level shape, mode,
renderer port, and main port. A successful tree must also contain exactly one
root member that exactly matches the original snapshot. Missing, malformed,
changed, or differently mapped roots return no tree. The 50 ms adapter delay is
entered only after the failed-tree condition and exact root reread both hold.

SessionEngine routes every pre-mutation current-package `GetTree` boundary in
Close, Recover, recovery cleanup, and CloseRequested replay through that stable
helper. Journal creation and all stop mutations remain after stable acquisition.
The existing per-member pre-stop, post-stop, and final absence/identity proofs
were not changed.

Supervisor post-worker proof confirmation now has the same bounded policy. It
retries one empty ordinary/special enumeration only when a direct read of the
candidate PID still matches all twelve snapshot fields. It then performs one
condition-based 50 ms adapter delay and one final refresh. A nonempty mismatch,
ambiguity, missing or malformed direct read, creation-time drift, debug-port
drift, or mode drift is not delayed or retried and receives no proof authority.
The lifecycle result continues to reduce through the stable
`CCOD_REMOTE_PROOF_REBIND_FAILED` reason, and `FailedSpecialProofKey` remains
bound to the original candidate PID and creation time.

One pre-existing recovery fixture was made deterministic by fixing its
preferred renderer port to the exact port in its expected root snapshot. The
new stable helper correctly exposed that the old fixture supplied a 41001 tree
root while the launch fixture selected 9335.

## Baseline

Before test or production changes:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ProcessControl.SelfTest.ps1
exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
existing output reached the final production-adapter cases without a failure; the
initial combined shell capture timed out before its receipt, so the suite was
rerun independently during RED/GREEN and final verification below.
```

## RED evidence

Tests were added before production changes.

### RED 1: missing stable process-tree helper

Command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ProcessControl.SelfTest.ps1
```

Result: exit `1` at
`retries one transient verified tree miss while the exact root identity remains stable`:

```text
The term 'Get-CcodStableVerifiedProcessTree' is not recognized
```

### RED 2: SessionEngine did not retry transient tree churn

Command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/SessionEngine.SelfTest.ps1
```

Result: exit `1` at
`retries transient Electron tree churn before committing and closes every verified member`:

```text
expected=[Closed] actual=[Error]
```

### RED 3: Supervisor had no bounded second rebind

Command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

After correcting the empty-array fixture to emit one array object, result was
exit `1`:

```text
one transient empty rebind enumeration receives exactly one bounded retry
expected=[3] actual=[2]
```

The count includes one pre-worker candidate observation plus the two required
post-worker observations.

### RED 4: Supervisor retry had no condition-based delay

After the immediate bounded retry was implemented, a timing boundary test was
added before adding a Delay adapter. The same Supervisor command exited `1`:

```text
same-candidate retry enters one bounded condition-based delay
expected=[50] actual=[]
```

## GREEN and final verification

Fresh committed-content verification command:

```powershell
$tests=@(
  'tests/persistence/ProcessControl.SelfTest.ps1',
  'tests/persistence/SessionEngine.SelfTest.ps1',
  'tests/persistence/Supervisor.SelfTest.ps1'
)
foreach($test in $tests){
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test
  if($LASTEXITCODE -ne 0){ throw "$test failed" }
}
```

Result: exit `0` for all three suites.

- ProcessControl: 40 behavioral cases passed, including transient empty-tree
  retry and creation-time drift fail-closed coverage.
- SessionEngine: 58 behavioral cases passed, including retry-before-journal,
  child-first stop of every captured member, root drift with zero close
  mutation, ordinary close behavior, and all existing per-member proof cases.
- Supervisor: 93 behavioral cases passed. The suite printed
  `Supervisor self-tests passed: 93`, including one exact condition-based
  50 ms retry, creation-time drift with zero delay, port/mode drift with zero
  delay, no proof authority for changed roots, and the stable
  `CCOD_REMOTE_PROOF_REBIND_FAILED` terminal result.

`git diff --cached --check` exited `0` before the implementation commit.

## Scope, safety, and concerns

- No real Codex, ChatGPT, installer, tray, or UI process was started, stopped,
  signaled, or controlled. All process behavior used fixtures/adapters.
- Nothing was installed, pushed, published, released, uploaded, or signed.
- WindowsApps and DPAPI/device-key boundaries were not changed.
- Exact root identity was not relaxed. Retry eligibility uses the same full
  snapshot matcher, including mode and both debug ports.
- The only delay is fixed at 50 ms and is adapter-driven. It is called only
  after an empty/failed acquisition plus an exact candidate-root reread; all
  mismatch tests assert zero delay.
- The repository-wide suite was not run because other persistence integration
  paths may exercise real process-stop boundaries, which conflicts with this
  task's explicit fixture-only authority. The three brief-named focused suites
  are green.
- No independent agent review was run because the task explicitly prohibited
  spawning agents. Parent integration review remains the next external gate.

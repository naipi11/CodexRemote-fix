# Task 4 report: tray action revision correlation and diagnostics

## Outcome and commit

Implemented Task 4 only in the linked worktree
`C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`.

Implementation commit: `b312174` (`test: cover tray action revision correlation`).

The report is committed separately after this entry so that it can name the
implementation commit; a commit cannot embed its own final object ID.

## Files changed

- `src/persistence/Supervisor.ps1`
- `tests/persistence/Supervisor.SelfTest.ps1`
- `tests/persistence/TrayHostClient.SelfTest.ps1`
- `tests/trayhost/TrayHostTransportSelfTest.cs`
- `.superpowers/sdd/2026-08-28-v2522-install-runtime-reliability/task-4-report.md`

No protocol, installer, release, lifecycle worker, Codex, WindowsApps, DPAPI,
or user-facing localization file was changed. The planned production files
`src/persistence/modules/TrayHostClient.psm1`, `src/trayhost/HostTransport.cs`,
and `src/trayhost/TrayWindow.cs` required no production change: the existing
authenticated result boundary already preserved action id, revision, terminal
status, and canonical error code, and the existing TrayWindow already reduced
terminal failures to the approved generic localized dialog. Their behavior is
now covered more precisely by the wrapper, transport, and native tests.

## Root cause and implementation

The native menu action already reached TrayHost, the PowerShell wrapper already
queued the exact command and presentation revision, and Supervisor already
authorized actions against the exact acknowledged-presentation map. The missing
boundary was in `Send-CcodSupervisorTrayActionResult`: it forwarded a terminal
result to TrayHost without first writing a support-safe record. Once TrayHost
accepted a rejected or failed result, it queued only the generic failure UI, so
the end user saw the intended generic wording but the local log had no command,
revision, terminal status, or stable code with which to diagnose the failure.

`Write-CcodSupervisorTrayActionTerminal` now writes a fixed schema before the
terminal result is sent to TrayHost:

- `schemaVersion`
- `timestampUtc`
- `component`
- `stage`
- `code`
- `outcome`
- `command`
- `revision`
- `status`

The record deliberately excludes action ids, transaction ids, filesystem
paths, tokens, exception messages, and arbitrary result text. `Completed` uses
the safe success code `CCOD_TRAY_ACTION_COMPLETED`. `Rejected` and `Failed`
preserve an exact canonical `CCOD_*` code; malformed codes fall back to
`CCOD_TRAY_ACTION_FAILED`. Canonical validation uses the absolute `\z` regex
terminator so a trailing newline cannot be accepted as part of a log code.

`Accepted` is not terminal and is not logged by this helper. Lifecycle actions
therefore receive one terminal record only when their later `Completed` or
`Failed` result is produced. Existing result delivery, transaction correlation,
authenticated pipe framing, and generic dialog wording are unchanged.

## TDD and RED evidence

Tests were written before the production implementation.

### RED 1: terminal diagnostic record was absent

Command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

Result: exit `1` after all earlier cases passed. The acknowledged revision 7
test reached the real `OpenLogs` adapter, but no local terminal record existed:

```text
ASSERT_EQUAL_FAILED: terminal action writes exactly one local diagnostic record expected=[1] actual=[0]
```

This RED established that the failure was the missing diagnostic boundary, not
an invalid test fixture, PowerShell parse error, or broken command handler.

### RED 2: end-of-line regex semantics allowed an unsafe code

After the initial minimal logger was green, a sanitation test was added before
tightening the canonical-code matcher. PowerShell's `$` anchor accepted a
terminal line-feed boundary, and the test exited `1`:

```text
ASSERT_EQUAL_FAILED: malformed terminal code is replaced by the canonical fallback
expected=[CCOD_TRAY_ACTION_FAILED] actual=[CCOD_INJECTED\n]
```

The production matcher was then changed from `$` to `\z`; the test proves the
newline-bearing value cannot enter the local diagnostic record.

### Focused baseline outside the missing logger

Before the production change, these two brief-named boundaries were already
green:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostClient.SelfTest.ps1
exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly
exit 0; TrayHost transport self-tests passed: 8
```

They showed that the authenticated wrapper and host-side action-result queues
were not the missing production behavior. Their assertions were then extended
to prove the exact stale result reaches the parent-client boundary once and
that HostTransport retains the exact revision, terminal status, and canonical
code before the generic UI consumes the failure.

## GREEN and final verification

Fresh pre-commit verification ran the three brief-named focused suites, the
native TrayHost suite, and the whitespace gate:

```powershell
$tests=@(
  @{Name='TrayHost client';Command=@('tests\persistence\TrayHostClient.SelfTest.ps1')},
  @{Name='Supervisor';Command=@('tests\persistence\Supervisor.SelfTest.ps1')},
  @{Name='TrayHost transport';Command=@('tests\trayhost\Invoke-TrayHostSelfTest.ps1','-TransportOnly')},
  @{Name='TrayHost native';Command=@('tests\trayhost\Invoke-TrayHostSelfTest.ps1','-NativeOnly')}
)
foreach($test in $tests){
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File @($test.Command)
  if($LASTEXITCODE -ne 0){throw "$($test.Name) failed"}
}
git diff --check
```

Result: exit `0` throughout.

- TrayHost client: 8 behavioral cases passed. The only output warning is the
  pre-existing PowerShell warning about unapproved imported verb names.
- Supervisor: 96 behavioral cases passed.
- TrayHost transport: 8 behavioral cases passed.
- TrayHost native: 15 behavioral cases passed.
- `git diff --check`: exit `0`.
- `git diff --cached --check`: exit `0` immediately before commit `b312174`.

The new Supervisor cases prove the required ordering and side-effect boundary:

1. revision 7 is present in `AcknowledgedPresentations`;
2. `OpenLogs` is invoked exactly once;
3. `CCOD_TRAY_ACTION_COMPLETED` is logged with command `OpenLogs`, revision 7,
   and status `Completed`;
4. the log write occurs after the handler and before `ActionResult:Completed`;
5. revision 8 has no acknowledged map entry;
6. the stale action invokes `OpenLogs` zero times;
7. `CCOD_TRAY_ACTION_STALE` is logged before `ActionResult:Rejected`.

The native suite retains the existing assertion that failure feedback uses only
the acknowledged snapshot's localized generic title and `Action failed` text.
No internal code is added to the dialog.

## Scope, safety, and concerns

- No real Codex or ChatGPT process was started, stopped, signaled, or controlled.
- No production TrayHost process, installer, release build, or interactive
  product UI was launched. The explicitly required native self-test exercised
  its test-owned Win32 owner/fake platform and P/Invoke surface only.
- Nothing was installed, pushed, published, released, uploaded, or signed.
- WindowsApps, application binaries, and DPAPI/device-key data were untouched.
- The authenticated pipe protocol, action-result wire schema, capability gate,
  and revision ACK map were not weakened or changed.
- The repository-wide suite was not run because this task authorized the three
  focused suites plus native TrayHost verification; broader persistence tests
  may cross real process-control boundaries. All task-required suites are green.
- No independent agent review was run because the task explicitly prohibited
  spawning agents. Parent integration review remains the next external gate.

## Fix round 1: durable diagnostic gate and real correlation chain

Independent review identified that implementation commit `b312174` attempted
the terminal log before delivery but swallowed `WriteLog` failure and still sent
the terminal `ActionResult`. That allowed HostTransport to queue the generic
failure dialog without any durable local terminal record. Review also found
that the original wrapper, Supervisor, transport, and native assertions were
separate tests rather than one test traversing their real correlation chain.

Fix implementation commit: `94ca92f`
(`fix: gate tray feedback on durable diagnostics`).

### RED evidence

The `WriteLog` failure test was added before changing production code:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
```

Result: exit `1` at the new case after all preceding cases passed:

```text
ASSERT_EQUAL_FAILED: failed diagnostic persistence prevents terminal feedback delivery
expected=[False] actual=[True]
```

This proved the exact reviewed defect: the Supervisor returned
`Delivered=True` even though the local action record had not persisted.

The real correlation test was also written before the production fix. It uses
the test-only `TrayHostCorrelationTestBridge`, which compiles and composes the
checked-in production `TrayWindow`, `NativeMenu`, `HostTransport`, action/result
types, and revision behavior. No replacement protocol or external channel is
introduced.

### Implementation and pending-action safety

`Write-CcodSupervisorTrayActionTerminal` now returns `true` only after the
existing `WriteLog` adapter completes without error. It returns `false` after
adding `CCOD_SUPERVISOR_LOG_FAILED` to the Supervisor cleanup receipt on any
clock, schema-construction, or log-write exception.

For terminal `Completed`, `Rejected`, and `Failed` results,
`Send-CcodSupervisorTrayActionResult` now stops immediately with
`Delivered=false` when that durable-record gate fails. It does not call
`SendTrayActionResult`, so HostTransport cannot queue About work or generic
failure feedback without the required local record. `Accepted` remains a
nonterminal lifecycle acknowledgement and retains its existing authenticated
delivery path.

The pending HostTransport action is safe under this outcome:

- it receives no false terminal acknowledgement;
- it cannot display generic terminal feedback without a durable diagnostic;
- it remains protected by the existing action-id replay cache and eight-entry
  pending-action bound;
- lifecycle completion receives `Delivered=false`, so the existing repair and
  SafeExit gates do not mark the terminal notification complete or exit the UI;
- the Supervisor cleanup receipt exposes `CCOD_SUPERVISOR_LOG_FAILED` for the
  enclosing host outcome.

No retry or unauthenticated fallback was added, so the change cannot duplicate
a lifecycle terminal result or weaken action identity/capability authority.

### Real end-to-end correlation coverage

The new Supervisor behavioral case executes both branches through one actual
chain:

```text
TrayWindow.HandleContextMenu
  -> NativeMenu selected command and displayed revision
  -> HostTransport.TryRegisterAction
  -> Supervisor AcknowledgedPresentations revision/capability gate
  -> actual OpenLogs adapter or stale rejection
  -> sanitized WriteLog record
  -> Supervisor SendTrayActionResult boundary
  -> HostTransport.TryAcknowledgeAction
```

For revision 7, the same action selected by the native menu is placed in the
ACK map, invokes `OpenLogs` exactly once, returns `Completed`, and is accepted
by the real HostTransport with revision 7. For revision 8, no ACK-map entry is
created; `OpenLogs` is invoked zero times, Supervisor returns
`CCOD_TRAY_ACTION_STALE`, and the real HostTransport accepts the exact rejected
terminal result and preserves revision 8 and the stale code before generic UI
consumption.

The bridge is test-only and calls the production in-process APIs directly. It
does not start a production TrayHost process, open an external control surface,
or alter the authenticated wire protocol.

### Diagnostic record shape ruling

Tests now treat `command`, `revision`, `status`, and `code` as required inclusive
fields. They retain and validate the sanitized standard envelope
`schemaVersion`, `timestampUtc`, `component`, `stage`, and `outcome`. They also
explicitly assert the absence of `ActionId`, `TransactionId`, path, token,
exception, message, and raw arbitrary-text properties. The envelope is a local
log schema, not a new wire protocol.

### GREEN and fresh verification

After the minimal fail-closed implementation, the Supervisor suite passed 98
cases, including the new durable-log failure and real correlation tests. Fresh
pre-commit verification then ran every Task 4 required suite:

```text
TrayHost client: exit 0; 8 behavioral cases
Supervisor: exit 0; 98 behavioral cases
TrayHost transport: exit 0; 8 behavioral cases
TrayHost native: exit 0; 15 behavioral cases
git diff --check: exit 0
git diff --cached --check: exit 0
```

The existing lifecycle safety tests remained green, including SafeExit refusal
to shut down when its correlated terminal result is not delivered and terminal
lifecycle completion only after acknowledgement.

### Fix-round scope and concerns

- Changed only `src/persistence/Supervisor.ps1`, its behavioral self-test, the
  test-only C# correlation bridge, and this report.
- No real Codex/ChatGPT or production TrayHost process was started, stopped, or
  controlled. No installer, release, install, push, signing, WindowsApps, DPAPI,
  or interactive product UI operation occurred.
- No independent agent was used because this fix round explicitly prohibited
  agents. Parent integration review remains the next review gate.

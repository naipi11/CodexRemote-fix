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

## Fix round 2: release pending actions through a host-side diagnostic gate

Re-review found that fix round 1's suppression of the terminal ACK prevented
generic feedback without a record, but permanently retained the corresponding
HostTransport pending entry. Eight Supervisor-log failures could therefore fill
the pending-action bound and disable later tray commands.

Fix implementation commit: `3bdd575`
(`fix: release tray actions after diagnostic failure`).

### TDD and RED evidence

Tests were changed before production code. The new transport regression
required a typed terminal record and a diagnostic-writer HostTransport boundary.
The focused transport compile failed with the expected missing production API:

```text
CS0246: TrayTerminalDiagnostic could not be found
CS1729: HostTransport does not contain a constructor that takes 2 arguments
CCOD_TRAYHOST_NATIVE_COMPILE_FAILED
```

The Supervisor correlation suite independently failed to compile its real
native/transport bridge for the same missing type. This established that the
repeated-failure recovery behavior did not exist.

After the first implementation, a second behavioral test treated a missing
writer as a persistence failure. It failed before the default was hardened:

```text
TrayHost transport self-test failed: System.InvalidOperationException
missing diagnostic writer cannot authorize generic feedback
```

The default was then changed to fail closed for feedback while still consuming
the authenticated terminal result.

### Implementation

`TrayTerminalDiagnostic` is a new internal strong type. Its constructor accepts
only an existing `TrayCommand`, positive revision, terminal
`TrayActionResultStatus`, and canonical result code. `Completed` maps to
`CCOD_TRAY_ACTION_COMPLETED`; malformed failure values map to
`CCOD_TRAY_ACTION_FAILED`. It cannot carry an action id, transaction id, path,
token, exception, or arbitrary message.

`TrayTerminalDiagnosticLog.TryAppend` writes exactly one fixed-format line:

```text
command=<enum> revision=<invariant UInt64> status=<terminal enum> code=<canonical CCOD code>
```

It returns `true` only after `File.AppendAllText` closes successfully and returns
`false` without throwing on persistence failure. The native self-test writes to
an isolated temporary file, verifies the line byte-for-byte, and verifies that
an invalid file target returns `false`.

Production `Program` derives a fixed current-user path under
`LocalApplicationData\CodexControlOtherDevices\logs\trayhost-actions.log` and
injects the typed writer into HostTransport. No path or arbitrary payload comes
from the authenticated message, and no new pipe message, command, external
control surface, or unauthenticated channel was added.

HostTransport now processes a valid authenticated terminal result in this
order while holding its existing correlation lock:

1. require the exact pending action id and presentation revision;
2. enforce lifecycle Accepted-before-Completed rules;
3. build the typed terminal diagnostic from the pending command and result;
4. attempt the injected local write;
5. remove the pending action regardless of write success;
6. enqueue About or generic failure feedback only when the write succeeded;
7. return terminal acceptance so the authenticated reader does not treat a
   consumed valid result as a protocol violation.

If no writer exists or the writer returns/throws failure, no feedback is
queued, but pending capacity is released. If the bounded feedback queue is
already full, the additional terminal result is likewise consumed and its
pending entry released; only the redundant UI item is suppressed.

Supervisor again sends the authenticated terminal result after attempting its
standard sanitized envelope log. This gives two safe cases:

- Supervisor log succeeds: the standard timestamped local record already
  exists, and TrayHost also gates feedback on its typed host receipt.
- Supervisor log fails: `CCOD_SUPERVISOR_LOG_FAILED` remains in the cleanup
  receipt, while the host receipt either persists before feedback or suppresses
  feedback. In both cases the authenticated terminal result releases pending
  capacity.

The standard Supervisor envelope and its inclusive-field ruling were not
changed.

### Repeated failure and recovery proof

The transport regression submits ten distinct authenticated failed actions
while the diagnostic writer returns false. Every action registers, every exact
terminal result is accepted, every pending entry is released, and zero generic
feedback items are available. After switching the same writer to success, a new
failed action registers and produces feedback, followed by a new command that
registers and completes. The last typed record is asserted as exactly
`OpenLogs`, revision 22, `Completed`, and `CCOD_TRAY_ACTION_COMPLETED`.

The Supervisor end-to-end test repeats ten stale native-menu actions while both
Supervisor and host diagnostic writes fail. The same real
`TrayWindow -> NativeMenu -> HostTransport -> Supervisor ACK map -> result ACK`
chain accepts every terminal result without invoking `OpenLogs` or producing
feedback. After both writers recover and revision 2 is acknowledged, the next
native command registers, reaches `OpenLogs` exactly once, and completes.

### Fresh verification

Fresh pre-commit verification results:

```text
TrayHost client: exit 0; 8 behavioral cases
Supervisor: exit 0; 98 behavioral cases
TrayHost transport: exit 0; 9 behavioral cases
TrayHost native: exit 0; 16 behavioral cases
TrayHost production compile/headless smoke: exit 0
git diff --check: exit 0
git diff --cached --check: exit 0
```

The production smoke compiles every checked-in TrayHost C# source, including
the new diagnostic type, and runs only the existing no-UI headless path.

### Fix-round scope and concerns

- No authenticated wire field or result status changed.
- No real Codex/ChatGPT or production interactive TrayHost process was started,
  stopped, signaled, or controlled.
- Nothing was installed, pushed, published, released, signed, or written to
  WindowsApps/DPAPI. Runtime logging was tested only through an isolated temp
  path; the production path was compiled but not exercised against user data.
- No independent agent was used because this fix round explicitly prohibited
  agents. Parent re-review remains the next gate.

## Fix round 3: bounded reparse-safe receipts and production correlation trace

Independent re-review retained three Important findings: the host action log
was unbounded, its fixed LocalAppData path lacked reparse-component checks,
diagnostic I/O ran while holding HostTransport's correlation lock, and the
in-process bridge did not prove the real TrayHostClient/ParentClient/Wire/Program
authenticated path.

Fix implementation commit: `9c1e4df`
(`fix: harden tray terminal diagnostics`).

### RED evidence

Tests were added before each production change.

The blocking-writer transport test deliberately held the diagnostic writer for
up to three seconds, then attempted to register another action. Current code
failed because writer I/O still held `_gate`:

```text
TrayHost transport self-test failed: System.InvalidOperationException
blocking terminal I/O cannot hold the correlation lock or pending capacity
```

The bounded-retention native test failed at compile time before the fixed log
contract existed:

```text
CS0117: TrayTerminalDiagnosticLog does not contain a definition for MaximumBytes
CCOD_TRAYHOST_NATIVE_COMPILE_FAILED
```

After adding the first lock/retention implementation, a missing-writer assertion
was retained from fix round 2 and remained green: no writer cannot authorize
generic feedback but still releases the terminal pending action.

The production authenticated trace test referenced Program's actual result
dispatch before it was extracted. ParentClient-only compilation failed:

```text
CS0117: Program does not contain a definition for TryDispatchAuthenticatedActionResult
CCOD_TRAYHOST_NATIVE_COMPILE_FAILED
```

This proved the old peer was not traversing Program's production result branch.

### Bounded deterministic retention

`TrayTerminalDiagnosticLog.MaximumBytes` is fixed at 64 KiB. Each record is
encoded as UTF-8 without a BOM. Under the logger's private file gate, the writer
selects one of two deterministic modes:

- append when existing bytes plus the complete new record remain within 64 KiB;
- recreate the file with only the complete newest record when the next append
  would exceed 64 KiB or an already oversized file is encountered.

The stream is closed after `Flush(true)`. The test writes 1,400 distinct
records, proves the file never exceeds `MaximumBytes`, and proves the complete
latest record remains at the end after rollover. This prevents long-running
tray action volume from growing the file without bound.

### Fixed-path and reparse defense

Production no longer calls an unconditional `Directory.CreateDirectory` over
the full path. `TryGetDefaultPath` starts from the system-provided current-user
LocalApplicationData root and creates only the fixed
`CodexControlOtherDevices` and `logs` child directories, one level at a time.
Before each creation it verifies the existing parent chain, and after creation
it verifies the new directory.

`TryAppend` accepts only an absolute path whose leaf is exactly
`trayhost-actions.log`. It rejects a directory leaf, a reparse-point file, any
missing directory, or any existing directory component with the
`FileAttributes.ReparsePoint` bit. Production supplies only the fixed path; no
wire field, CLI value, action property, or user payload can select a path.

The native test creates a real junction inside an isolated temporary root and
proves a fixed-name log beneath that junction is rejected. All temporary files
and the junction are removed by the test.

### Diagnostic I/O outside the correlation lock

HostTransport now validates the exact action id/revision and lifecycle state,
constructs the typed diagnostic, and removes the terminal action from
`_pendingActions` while holding `_gate`. It then releases `_gate` before calling
the writer. After the writer returns, it reacquires `_gate` only to enqueue the
About/generic feedback item when persistence succeeded and the transport is
still active.

The blocking-writer regression starts terminal acknowledgement on a background
thread, waits until the writer is blocked, then registers a distinct action.
Registration completes within 250 ms, proving neither correlation lock nor
pending capacity is held by file I/O. After releasing the writer, both the first
terminal acknowledgement and the concurrently registered action complete.

False, throwing, absent, blocked, and full-feedback-queue outcomes continue to
release pending capacity. Only persisted records authorize UI feedback.

### Production authenticated correlation trace

`Program.TryDispatchAuthenticatedActionResult` is the exact production reader
operation extracted from the existing ActionResult branch:

```text
TrayHostWire.ReadActionResult(payload)
  -> HostTransport.TryAcknowledgeAction(result)
```

The production reader itself now calls this internal function. No new CLI mode,
frame type, wire field, external endpoint, or unauthenticated channel was added.

The ParentClient self-test compiles Program and the real native/transport/wire
sources into its isolated test executable. Its existing test-only peer process
performs the real parent/host bootstrap, key derivation, MAC verification,
sequence checks, and Action/ActionResult serialization. The peer registers the
same action in real HostTransport and sends it over `TrayHostWire`; the result
returns over the real authenticated `TrayHostParentClient` writer and is
consumed by Program's production dispatch.

`TrayHostProductionTrace.SelfTest.ps1` then loads that same compiled assembly
and uses the real production PowerShell wrapper:

```text
TrayHostClient.Receive-CcodTrayHostEvents
  -> TrayHostParentClient authenticated event
  -> current or stale terminal decision fixture
  -> TrayHostClient.Send-CcodTrayHostActionResult
  -> TrayHostParentClient authenticated writer
  -> TrayHostWire ActionResult
  -> Program production dispatch
  -> HostTransport diagnostic and feedback gate
```

The current case preserves `OpenLogs` revision 1, receives `Completed`, and
produces no generic failure feedback. The stale case preserves `OpenLogs`
revision 8 and `CCOD_TRAY_ACTION_STALE`; after the persisted typed receipt, the
real feedback queue is consumed and `TrayWindow.ShowActionFailed` runs against a
fake native platform. It proves the dialog contains only the acknowledged
snapshot's generic `string-0|string-15` title/message, not the internal code.
The fake platform creates no real window or interactive UI.

Test-only peer arguments remain implemented only by the self-test main type;
they are not recognized by production Program and therefore create no product
control surface.

### Fresh verification

Fresh verification completed with these results:

```text
TrayHost client: exit 0; 8 behavioral cases
Supervisor: exit 0; 98 behavioral cases
TrayHost transport: exit 0; 10 behavioral cases
TrayHost native: exit 0; 17 behavioral cases
TrayHost parent-client: exit 0; 4 behavioral cases
TrayHost production correlation trace: exit 0; 2 current/stale cases
TrayHost production compile/headless smoke: exit 0
git diff --check: exit 0
git diff --cached --check: exit 0
```

The first combined verification command exceeded its 30-second tool window
after the ParentClient cases and before the trace receipt was printed. It was
not counted as evidence for the remaining stages. ParentClient+production trace
and ProductionOnly smoke were rerun independently and both returned explicit
exit `0` receipts.

### Fix-round scope and concerns

- Changed only TrayHost terminal logging/correlation production files, focused
  tests/trace orchestration, and this report.
- No real Codex/ChatGPT or production interactive TrayHost process was started,
  stopped, signaled, or controlled. Native behavior used fake platforms; the
  subprocess trace used only the compiled self-test peer.
- Nothing was installed, pushed, published, released, signed, or written to
  WindowsApps/DPAPI. Reparse and rollover writes were confined to unique temp
  roots.
- No independent agent was used because the fix-round instruction prohibited
  agents. Parent re-review remains the next gate.

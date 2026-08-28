# Task 2 report: asynchronous bounded tray terminal receipts

Date: 2026-08-28

Worktree: `C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`

Branch: `codex/v2522-install-runtime-reliability`

## Status

Task 2 is implemented and its focused transport/native acceptance is green.
The authenticated reader now consumes a correlated terminal result before one
zero-wait sink submission; receipt store I/O and durable UI publication run on
one bounded background writer. This report does not claim the Task 3 shared
child-session/full production trace or the Task 4 release gate.

## Implementation

- `src/trayhost/TrayTerminalReceiptSink.cs`
  - Adds a typed `TrayTerminalReceipt` containing the correlated immutable
    action result plus the existing sanitized `TrayTerminalDiagnostic` used by
    the accepted handle-pinned store.
  - Binds each receipt to the `HostTransport` that correlated it and permits
    publication at most once.
  - Starts exactly one background receipt writer. No error, timeout, or hang
    starts a replacement writer.
  - `TrySubmit` uses a non-waiting admission gate and admits at most eight
    outstanding receipts, including the receipt currently inside store I/O or
    its durable callback.
  - Store `false`/throw and callback `false`/throw drop only feedback and allow
    the same writer to process later receipts.
  - Disposal closes admission, clears queued work, suppresses late callbacks,
    and joins the one writer for at most 100 ms. If store I/O remains hung, the
    original background writer owns deferred store cleanup after it eventually
    returns; shutdown never starts or waits for a replacement.
- `src/trayhost/HostTransport.cs`
  - `TryAcknowledgeAction` validates correlation under the existing lock,
    creates the typed terminal receipt, removes the pending action, and returns
    without file I/O or capacity waiting.
  - `TryPublishDurableReceipt` accepts only a once-publishable receipt from the
    same transport. Completed About maps to About work; rejected/failed maps to
    generic failure; all other completed commands map to no UI.
  - About and generic feedback share one eight-item UI bound. Queue or callback
    failure consumes the publication but leaves no retryable feedback.
  - UI work is provisional while the application-post callback is unresolved.
    Consumers return immediately without seeing it; callback failure removes
    it, while callback success makes it ready. If a posted work message probes
    the provisional item before callback return, the transport posts one
    replacement work message after marking it ready. Replacement-post failure
    removes the ready item and returns its shared UI capacity.
  - Presentation and receipt callbacks are separate. Application receipt work
    posting remains outside the transport correlation lock.
- `src/trayhost/Program.cs`
  - Composes one existing `TrayTerminalDiagnosticStore`, one `HostTransport`,
    and one `TrayTerminalReceiptSink`.
  - The authenticated reader calls correlation and one `TrySubmit`, ignores
    admission failure after the action is consumed, and no longer posts UI work
    immediately for terminal wire results.
  - The durable callback is the only terminal path that posts About/failure
    work. Its production callback checks the actual `PostMessage` result and
    fails closed before UI visibility when posting fails. Sink disposal
    precedes window/transport disposal, and the sink owns safe deferred store
    disposal if its writer is hung.
  - No command-line selector, message type, wire field, direction, sequence,
    capability, authentication, or storage-security rule changed.
- `tests/trayhost/TrayHostTransportSelfTest.cs`
  - Retains the parent/presentation/pending/replay/result-correlation coverage
    and replaces the synchronous-writer expectations with Task 2 behavior.
  - Uses a controllable fake store that blocks before open, during write, and
    during flush.
  - Covers current and following terminal returns under 250 ms, pending removal
    before submission, eight outstanding including current, immediate ninth
    drop, deterministic busy admission, closed admission, store failure,
    callback failure, provisional UI invisibility, early-message repost, later
    recovery on the same writer, shared UI bound, trusted once-only
    publication, and hung-store disposal.
  - The blocked following result is completed About, while the current result
    is failed OpenLogs, so both About and generic feedback are proven absent
    until explicit durable success.
- `tests/trayhost/TrayHostNativeSelfTest.cs`
  - Adds a fake-native-window integration test using the real handle-pinned
    store through the asynchronous sink. Generic native feedback is unavailable
    before durable success and appears exactly once afterward.
- `tests/trayhost/Invoke-TrayHostSelfTest.ps1`
  - Adds the new source to the existing temporary transport/native compilation
    list. Production compilation already collects every `src/trayhost/*.cs`.
- `tests/trayhost/TrayHostParentClientSelfTest.cs`
  - Migrates the current temporary peer caller to the typed receipt/sink API so
    the complete production source set compiles. This is only an API adaptation;
    it is not the Task 3 shared production child-session trace.

## TDD evidence

### Clean baseline

Before test changes:

```text
TransportOnly: exit 0, TrayHost transport self-tests passed: 10
NativeOnly:    exit 0, TrayHost native self-tests passed: 22
```

### RED

The new behavioral tests and temporary compile list were written before the
new production source/API.

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly
```

Exit `1`; decisive output:

```text
CCOD_TRAYHOST_SOURCE_MISSING
FullyQualifiedErrorId : CCOD_TRAYHOST_SOURCE_MISSING
```

This was the expected missing-feature RED: the planned
`TrayTerminalReceiptSink.cs` and typed receipt API did not yet exist. No
production source had been changed when this run was captured.

### Callback-visibility RED

Post-commit concurrency review identified that the first implementation placed
UI work in a consumable queue before its application callback returned. A
callback that later threw could therefore race a queue consumer. A test held a
callback that would throw and probed the UI queue concurrently. Before the
two-phase UI work fix, TransportOnly exited `1` with:

```text
TrayHost transport self-test failed: System.InvalidOperationException
provisional UI work returns immediately but remains unavailable while callback outcome is unknown
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

The fixed transport keeps the item provisional and nonblocking until callback
success, or removes it before visibility on callback failure.

### Early-work-message repost RED

The provisional design also needs to recover when the posted work message is
processed before the callback returns and before the item becomes ready. The
repost behavior was removed before its test was added. Without the repost,
TransportOnly exited `1` with:

```text
TrayHost transport self-test failed: System.InvalidOperationException
an early work-message probe causes one replacement UI post
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

The green implementation records the early probe, marks the item ready only
after callback success, and posts one replacement message without duplicating
the UI item.

### Replacement-post failure RED

A final callback-failure test made the replacement post throw after the first
post succeeded but was processed while the item remained provisional. Before
the fail-closed replacement handling, TransportOnly exited `1` with:

```text
TrayHost transport self-test failed: System.InvalidOperationException
replacement callback failure reports publication failure
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

The green path removes the ready-but-unnotified item, returns `false`, and
retains no latent UI work or occupied UI capacity.

### Focused GREEN and stability

After the final source/test change, the focused gates were rerun:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly
```

Exit `0`:

```text
TrayHost transport self-tests passed: 13
```

The final transport suite was also run ten consecutive times in one stability
probe; all ten runs reported `TrayHost transport self-tests passed: 13` with
exit `0`.

The first attempted ten-run probe exposed a test-helper defect: `WaitUntil`
evaluated a consuming `TryTake*` condition twice, so the second evaluation saw
an already-consumed queue and reported a false failure. The helper now caches
the successful evaluation; no production change was made for that incident,
and the complete ten-run probe above was rerun from the start.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Exit `0`:

```text
TrayHost native self-tests passed: 23
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionOnly
```

Exit `0`, no output. This compiles every production TrayHost source, including
the new sink and all current production callers, then runs `--headless-smoke`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
```

Exit `0`:

```text
TrayHost protocol self-tests passed: 11
```

No wire implementation file changed; the protocol run is the byte-level
regression gate for the existing schema/directions/sequences.

```powershell
git diff --check
```

Exit `0`. Git printed only repository LF-to-CRLF conversion notices.

## Diagnostic-only run, not Task 3 acceptance

`ParentClientOnly` was run once after adapting its current temporary caller and
exited `0`. That command still uses the pre-Task-3 fake peer/correlation trace;
it does not exercise the approved shared `TrayHostChildSession` seam and is not
counted as production-trace acceptance here.

## Commit

- `7549dde154fd6c2430a13aa9ddcf66698560f717` —
  `fix: isolate tray terminal receipt writes`
- `1f1ecc5f72fbbb1c070d62a745b36be003b50506` —
  `fix: hide provisional tray receipt UI`
- `1212579676a1b4773450ed961094a02c6322d0f7` —
  `fix: drop failed tray receipt reposts`

## Concerns and explicit boundaries

- Task 3 remains required to extract the shared child session and prove current
  and stale results through the real authenticated ParentClient/PowerShell
  path with a temporary fake native runtime. The existing fake-peer diagnostic
  is not that proof.
- The legacy `tests/persistence/Supervisor.SelfTest.ps1` correlation bridge has
  an explicit pre-Task-2 source list and old synchronous HostTransport calls.
  It is a test-only caller, not production source, and is intentionally deferred
  for the Task 3 trace/bridge migration. The full persistence suite is therefore
  not claimed by Task 2.
- Task 4 release-workflow/provenance gating and release-wide validation remain
  deferred. The production build itself discovers every TrayHost `.cs` source,
  so the new sink is compiled without a new runtime selector.
- A receipt store that never returns leaves the one background writer alive
  until process termination; this is the approved no-replacement failure mode.
  Admission and pending-action capacity remain bounded and responsive.
- No installer, installed Codex process, real tray UI, push, release, install,
  signing, or public operation was run.

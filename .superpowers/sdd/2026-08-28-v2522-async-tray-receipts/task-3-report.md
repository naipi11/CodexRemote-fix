# Task 3 report: authenticated child-session production trace

## Outcome

Task 3 now runs the real authenticated TrayHost child session in temporary
child processes without adding a shipped test selector or using
`TrayHostParentClient.TestProcessFactory`.

- `Program.RunChild` is a thin argument/identity/Windows-runtime adapter.
- `TrayHostChildSession` owns the existing bootstrap, directional keys,
  authenticated reader/writer sequences, action registration, presentation and
  shutdown work, async receipt admission, and token-bound UI drain.
- `WindowsTrayHostRuntime` composes the unchanged `Win32TrayPlatform`,
  `TrayWindow`, and `TrayHostApplication` behavior.
- `TrayHostProductionTraceSelfTest.cs` is compiled only under the runner's
  temporary directory. Its fake native platform remains under `tests/`; no
  test runtime, scenario, witness, macro, or selector is present in
  `src/trayhost`.
- The old ParentClient fake peer is again only a narrow authenticated
  parent-writer test. It no longer calls production dispatch, HostTransport
  receipt drains, or the dialog directly.
- The deferred Supervisor correlation bridge now uses the real async
  `TrayTerminalReceiptSink` and `TrayHostApplication` token dispatch rather
  than the removed synchronous `TryTakeFailedAction` path.

## End-to-end evidence

### Current action

The trace launches a distinct requested executable through the normal
`TrayHostParentClient.Start` path. After the real parent/child identity and
authenticated handshake, the temporary runtime calls the real
`TrayWindow.HandleContextMenu`; its fake `INativeTrayPlatform` returns
`OpenLogs` from `TrackPopupMenuEx`. The shared child session registers and
writes that exact action. The real PowerShell `Receive-CcodTrayHostEvents`
delivers it to `Invoke-CcodSupervisorCommand`, whose in-memory `OpenLogs`
adapter runs once and whose terminal result returns through
`Send-CcodTrayHostActionResult` and the real ParentClient writer.

The child reader authenticates and correlates the completion, the real async
sink flushes exactly one sanitized receipt, and `HostTransport` publishes no
receipt UI for a completed `OpenLogs`. The witness contains no dialog, no
duplicate action, no fault, and the normal parent-requested shutdown receives
an authenticated acknowledgement.

### Stale authenticated negative

The separately compiled temporary stale fixture emits an explicit revision-8
`OpenLogs` through the same child-session command delegate; this is test-only
and does not use a runtime-id convention or production selector. The real
PowerShell client receives the authenticated action. Because only revision 1
is acknowledged, `Invoke-CcodSupervisorCommand` rejects it with
`CCOD_TRAY_ACTION_STALE` before the `OpenLogs` adapter and sends the exact
correlated terminal result through ParentClient.

The child consumes the pending action, flushes one receipt containing only
`command`, `revision`, `status`, and canonical `code`, then posts a nonzero
token on `WmApp+3`. The test-only message pump invokes the real
`TrayHostApplication` handler; only `TryTakeReceiptUi(exactToken, ...)` reaches
the runtime's `TrayWindow.ShowActionFailed` delegation. The witness asserts
the order `durable receipt -> token post -> generic dialog`, exactly one dialog
with caption `trace-0` and text `trace-15`, and no internal code or correlation
identifier in that dialog. Normal authenticated shutdown then completes.

## TDD RED evidence

The real-process trace and runner were written before the production seam.
Running the required command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostProductionTrace.SelfTest.ps1
```

exited 1 with the expected missing-seam failure:

```text
tests\trayhost\TrayHostProductionTraceSelfTest.cs(84,46): error CS0246: ITrayHostRuntime
CCOD_TRAYHOST_PRODUCTION_TRACE_COMPILE_FAILED
```

No `src/trayhost` file had been changed when this RED was captured.

Running the complete Supervisor fixture then exposed the Task 2 report's
explicitly deferred legacy bridge migration. It exited 1 at
`Supervisor.SelfTest.ps1:818`: `HostTransport.cs(107)` could not resolve
`TrayTerminalReceipt` because the pre-Task-2 Add-Type list omitted the async
sink, and the bridge still used the old synchronous drain. Adding the actual
sink/application sources and migrating the bridge to token dispatch made the
same fixture pass 98 tests.

## Fresh GREEN and stability evidence

All commands below ran on the final production/test source tree and exited 0:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostProductionTrace.SelfTest.ps1
# TrayHost production child-session trace passed: 2

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ParentClientOnly
# TrayHost parent-client self-tests passed: 4

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostClient.SelfTest.ps1
# 9 cases passed; TrayHost client self-tests passed.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
# TrayHost native self-tests passed: 25

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly
# TrayHost transport self-tests passed: 16

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
# TrayHost protocol self-tests passed: 11

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionOnly
# complete production compile and --headless-smoke, exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/Supervisor.SelfTest.ps1
# Supervisor self-tests passed: 98

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostBuild.SelfTest.ps1
# 6 build/provenance cases; TrayHost build self-tests passed.
```

The direct production-trace command was additionally run three consecutive
times on the final tree. Every iteration launched both current and stale child
processes and printed `TrayHost production child-session trace passed: 2`.

`git diff --check` exited 0; Git printed only the repository's expected
LF-to-CRLF conversion notices.

## Production CLI and Task 2 boundary

The trace runner separately compiles the production executable with
`/main:Program` and invokes it with `--production-trace-test-selector`; the
test requires exit code 2. A final source audit found no trace selector,
`TRAYHOST_TRACE` define, trace runtime-id convention, or test-factory
assignment in `Program.cs`, `TrayHostChildSession.cs`, or
`WindowsTrayHostRuntime.cs`. `Program.Main` still recognizes only the existing
single `--headless-smoke` form and seven-argument `--child` form.

`HostTransport`, `TrayTerminalReceiptSink`, `TrayHostWire`,
`TrayHostParentClient`, and the PowerShell wire surface were not changed.
Native 25/25 and transport 16/16 confirm the Task 2 tokened `WmApp+3`
publication, provisional-visibility, repost, disposal, and failure behavior
remains green.

## Remaining risks and safety boundary

- The broad trace deliberately uses a fake native platform and a temporary
  handle-flushed witness store. It proves the shared session, authenticated
  wire, ParentClient, PowerShell client/Supervisor decision, async sink,
  tokened application work, and generic dialog mapping; it is not an installed
  desktop automation or real shell-notification-area test.
- Native receipt-store pinning/reparse/hard-link/rollover behavior remains
  covered by the focused Task 1/native tests, not duplicated here.
- Installer, installed-runtime, Defender, release workflow, signing, and
  independent review remain later acceptance boundaries.
- No real UI, Codex process, installer, installation, release, push, signing,
  or public operation was started by Task 3.

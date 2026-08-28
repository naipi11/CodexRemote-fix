# v2.5.22 Async Tray Receipt Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make terminal tray receipts non-blocking, bounded, handle-verified,
and genuinely traceable through the authenticated production child flow.

**Architecture:** Terminal action correlation remains in `HostTransport`, but
receipt persistence moves to one bounded background sink.  A native pinned
handle store writes the fixed local receipt without pathname re-resolution.
An internal child-session seam lets a temporary trace executable exercise the
same authenticated child behavior with a fake native platform.

**Tech Stack:** Windows PowerShell 5.1, C#/.NET Framework 4.8, Win32 file
handles, existing TrayHost authenticated protocol and self-tests.

**Spec:** `docs/superpowers/specs/2026-08-28-v2522-async-tray-receipts-design.md`

## Global Constraints

- Preserve the existing wire message types, directions, payloads, sequences,
  MAC checks, command IDs, and current-user boundaries exactly.
- Receipt disk text contains only command, revision, terminal status, and a
  canonical code; never persist action IDs, transaction IDs, paths, tokens,
  exception text, or arbitrary payload text.
- No production command-line test mode, listener, environment-variable switch,
  or external control surface may be added.
- All terminal actions leave the pending set before any receipt I/O or queue
  wait; no writer hang may create a replacement writer thread.
- Generic UI feedback is produced only after durable receipt success; its queue
  is bounded and runs on the existing STA work path.
- Keep primary checkout untouched; work only in this linked worktree.

---

### Task 1: Add a pinned, bounded receipt store

**Files:**
- Modify: `src/trayhost/TrayTerminalDiagnostic.cs`
- Modify: `src/trayhost/Program.cs`
- Test: `tests/trayhost/TrayHostNativeSelfTest.cs`
- Test: `tests/trayhost/Invoke-TrayHostSelfTest.ps1`

**Interfaces:**
- `TrayTerminalDiagnosticStore` owns validated native directory/leaf handles.
- `TryAppendDurably(TrayTerminalDiagnostic)` returns `true` only after a full
  write and `Flush(true)` through the validated leaf handle.
- `TryGetDefaultPath` remains fixed to the current-user receipt leaf; no caller
  can choose another production path.

- [ ] **Step 1: Write failing native-store tests**

Add a temporary-root test that precreates a reparse directory, reparse leaf,
hard-link leaf, and an outside sentinel.  Add a barrier that attempts to
replace the logs directory after the store has opened its directory chain.
Assert each unsafe case returns `false` and the sentinel bytes remain unchanged.
Add 64-KiB boundary and rollover tests that verify one whole latest record is
retained through the open handle.

- [ ] **Step 2: Run RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly`

Expected: compile or behavioral failure because the current path-based store
does not own native handles or the barrier contract.

- [ ] **Step 3: Implement the minimal handle-pinned store**

Open the existing LocalAppData/product/logs compatibility parents and the fixed
leaf through `CreateFileW` safe handles.  Create only
`logs\tray-receipts` as a protected current-user/SYSTEM/Administrators child,
then reopen and validate its exact handle; legacy direct receipt leaves are
never reused.  Reject reparse, non-directory, non-file, multi-link,
unexpected-final-path, share, and handle-query failures before writes.  Keep
handles while using `SetLength`, write, and `Flush(true)` for the 64-KiB
rollover.  Do not re-resolve the leaf path for append or truncation.

- [ ] **Step 4: Run GREEN**

Run the native suite and production headless compile smoke.  Assert the store
write is bounded, handle-validated, and cannot alter an outside sentinel.

- [ ] **Step 5: Commit**

```text
fix: pin tray terminal receipt storage
```

### Task 2: Make terminal receipt dispatch asynchronous and bounded

**Files:**
- Create: `src/trayhost/TrayTerminalReceiptSink.cs`
- Modify: `src/trayhost/HostTransport.cs`
- Modify: `src/trayhost/Program.cs`
- Test: `tests/trayhost/TrayHostTransportSelfTest.cs`
- Test: `tests/trayhost/TrayHostNativeSelfTest.cs`

**Interfaces:**
- `HostTransport.TryAcknowledgeAction` returns a typed terminal receipt for a
  terminal result after removing its pending entry.
- `TrayTerminalReceiptSink.TrySubmit` is zero-wait and admits at most eight
  outstanding receipts.
- `HostTransport.TryPublishDurableReceipt` accepts only a trusted in-memory
  receipt and places one bounded UI item.

- [ ] **Step 1: Write failing sink/transport tests**

Use a controllable fake store that blocks before open, during write, and during
flush.  Assert current and following authenticated terminal results return
within 250 ms, the ninth outstanding receipt is dropped immediately, no pending
entry remains, and no generic UI work exists until an explicit durable-success
callback.  Add disposal and recovery tests without starting a replacement
writer.

- [ ] **Step 2: Run RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly`

Expected: the current synchronous writer blocks the terminal call and the new
receipt-sink API is unavailable.

- [ ] **Step 3: Implement one worker and bounded UI completion**

Separate correlation from receipt work.  The reader submits once and returns;
only the single background writer calls the store.  On durable success it posts
bounded About/failure work to the existing application context.  On admission,
store, callback, queue, or disposal failure, consume the terminal result but
show no feedback.  Do not alter the wire result or add a new message type.

- [ ] **Step 4: Run GREEN**

Run transport and native suites.  Confirm a hung writer cannot stall the reader
or action capacity, and a later durable receipt still produces exactly one
generic feedback item.

- [ ] **Step 5: Commit**

```text
fix: isolate tray terminal receipt writes
```

### Task 3: Trace the actual child session without a shipped test hook

**Files:**
- Create: `src/trayhost/TrayHostChildSession.cs`
- Create: `src/trayhost/WindowsTrayHostRuntime.cs`
- Modify: `src/trayhost/Program.cs`
- Modify: `src/trayhost/TrayHostApplication.cs`
- Create: `tests/trayhost/TrayHostProductionTraceSelfTest.cs`
- Modify: `tests/trayhost/Invoke-TrayHostSelfTest.ps1`
- Modify: `tests/persistence/TrayHostProductionTrace.SelfTest.ps1`
- Test: `tests/trayhost/TrayHostParentClientSelfTest.cs`
- Test: `tests/persistence/TrayHostClient.SelfTest.ps1`

**Interfaces:**
- `TrayHostChildSession.Run` accepts only internal stream/runtime/sink
  dependencies; `Program.Main` exposes no new arguments.
- `WindowsTrayHostRuntime` composes the existing Windows platform, window, and
  application; the temporary trace executable supplies a fake implementation.

- [ ] **Step 1: Write failing real-trace tests**

Compile a temporary trace executable with the same child session and a fake
native platform.  Start it through normal `TrayHostParentClient.Start` (without
`TestProcessFactory`).  Require a current native `OpenLogs` selection to reach
the PowerShell TrayHostClient/Supervisor fixture and a stale authenticated
negative action to show only the generic dialog after durable receipt success.

- [ ] **Step 2: Run RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostProductionTrace.SelfTest.ps1`

Expected: it fails because `Program.RunChild` cannot be composed with a
test-only runtime while preserving the production child session.

- [ ] **Step 3: Extract the minimal internal session seam**

Move the current child bootstrap, reader/writer sequencing, work drain, and
shutdown behavior into `TrayHostChildSession`.  `Program.RunChild` becomes a
thin argument/identity/Windows-runtime adapter.  The trace executable shares
the child session and real protocol code but has no production CLI selector.

- [ ] **Step 4: Run GREEN**

Run ParentClient, TrayHostClient, production trace, native, transport, and
headless-smoke suites.  Confirm current completion has no generic dialog;
stale rejection has one generic dialog with no internal code or correlation
data; no production executable recognizes test arguments.

- [ ] **Step 5: Commit**

```text
test: trace authenticated tray terminal receipts
```

### Task 4: Revalidate v2.5.22 release inputs

**Files:**
- Modify: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Test: `tests/PersistenceSelfTest.ps1`
- Test: `tests/Validate.ps1`

- [ ] **Step 1: Write a failing release-surface test**

Require the TrayHost provenance record to include every newly compiled source
and require the release workflow to run the production trace before producing
setup or portable assets.

- [ ] **Step 2: Run RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1`

Expected: it fails until the release validation includes the receipt trace.

- [ ] **Step 3: Add the smallest release gate**

Invoke the production trace in the existing TrayHost/release validation path;
preserve existing manifest, Defender, payload, and exact-version checks.

- [ ] **Step 4: Run GREEN and commit**

Run release workflow plus the persistence/validation suites under the existing
controlled isolation harness.  Commit:

```text
test: gate release on tray receipt trace
```

## Plan self-review

- Task 1 handles filesystem identity and bounded storage without changing
  authenticated action semantics.
- Task 2 consumes terminal actions before zero-wait sink admission and never
  lets a writer block the reader or pending-action capacity.
- Task 3 proves the shared production child session end-to-end in a temporary
  executable, so tests cannot create a production test control path.
- Task 4 makes the new trace a release gate before the existing v2.5.22
  metadata/build/reinstall acceptance task begins.

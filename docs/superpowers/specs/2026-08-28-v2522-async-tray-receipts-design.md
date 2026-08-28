# v2.5.22 Async Tray Receipt Reliability Design

## Goal

Replace the synchronous TrayHost terminal-diagnostic write with a bounded,
asynchronous receipt pipeline.  A slow, failed, or unsafe receipt write must
never block authenticated result consumption, exhaust pending tray actions, or
show a generic dialog without a durable local receipt.

## Why this is a separate design

The prior task established action correlation, exact acknowledgement gates, and
sanitized terminal fields.  Three repair rounds showed that a synchronous file
append on the authenticated reader path cannot meet the full contract: a
path-only reparse check has a time-of-check/time-of-use gap, `Flush(true)` can
block the only reader, and an in-process test bridge does not prove the real
authenticated child session.  The user approved this architectural correction
on 2026-08-28.

## Non-negotiable constraints

- Keep the existing authenticated TrayHost wire schema, directions, message
  types, action-result fields, sequence rules, and capability policy unchanged.
- Do not add a production test command, listener, environment switch, external
  control path, or unauthenticated input channel.
- A terminal action is consumed exactly once.  It never returns to the pending
  set after receipt admission, failure, queue saturation, writer hang, or
  shutdown.
- Generic failure feedback and About display require a successfully flushed,
  sanitized receipt.  A failed, full, busy, closed, or hung receipt path drops
  only the feedback; it never invents a result or blocks later actions.
- Receipt disk content contains exactly `command`, `revision`, `status`, and a
  canonical `CCOD_*` code.  It excludes action IDs, transaction IDs, paths,
  tokens, exceptions, messages, and raw wire data.
- Preserve current-user operation.  Do not modify Codex binaries, WindowsApps,
  account data, or the DPAPI device-key store.

## Architecture

### 1. Terminal correlation and zero-wait admission

`HostTransport` continues to authenticate and validate a terminal result
against its pending action ID, revision, accepted-before-completed rule, and
command policy.  Under its correlation lock it constructs a typed
`TrayTerminalReceipt`, removes the pending action, and returns the receipt to
the child session.  It performs no file I/O and no wait for queue capacity.

`TrayTerminalReceiptSink.TrySubmit` accepts at most eight outstanding receipts,
including one currently writing.  It returns immediately with an admission
result.  Busy, full, or closed admission suppresses feedback but leaves the
action consumed.  The sink has one background writer only; it never creates a
replacement thread for a stuck write.

After a durable write, the sink calls back into `HostTransport` with the
in-memory receipt.  The transport enqueues a single bounded UI work item:
completed About maps to About; rejected/failed maps to the existing generic
failure dialog; all other completed commands map to no UI. Receipt UI uses an
internal tokened work message, separate from presentation/shutdown drains. The
transport makes a token visible only for a successful tokened post; ordinary
work messages can never consume a receipt item while that post is unresolved.
If the post fails, the item is retracted before any UI path can see it. The UI
queue is also bounded at eight shared items.

The sink claims callback admission under its close gate before invoking the
durable callback. Once `Dispose` closes that gate, no new callback can begin;
an already-started callback may finish, but the disposed transport refuses to
publish UI work.

### 2. Pinned, bounded native receipt store

The store uses the fixed path
`%LOCALAPPDATA%\CodexControlOtherDevices\logs\tray-receipts\trayhost-actions.log`.
The existing product and `logs` directories are created by supported historical
installations with normal inherited current-user ACLs, so they remain
compatibility parents: the store opens and pins them as non-reparse directory
handles but does not require them to have the receipt-private ACL.  Beneath the
pinned `logs` handle it creates the fixed `tray-receipts` child with a protected
current-user/SYSTEM/Administrators ACL, reopens and validates that exact child
handle, and fails closed if an existing child does not match.  It never reuses
the legacy direct `logs\trayhost-actions.log` leaf.

The store holds the native directory chain with reparse-point opening flags and
delete sharing denied while it opens the fixed leaf.  The leaf is opened through
a native handle before any write; its handle must prove a regular, non-reparse,
single-link file at the expected final path.  Writes and rollover occur only
through that validated handle, never through a re-resolved pathname.

The file is UTF-8 without a BOM and has a hard 64 KiB limit.  If adding a whole
record would cross the limit, the validated handle is truncated and receives
only the new complete record.  A receipt is durable only after the write and
`Flush(true)` both succeed.  Handle or validation failure fails closed for UI
feedback.

### 3. Child-session seam and trace executable

Move the existing `Program.RunChild` session behavior behind an internal child
session/runtime seam.  `Program.Main` retains only its existing `--child` and
`--headless-smoke` inputs and creates the Windows runtime adapter.  A temporary
self-test executable uses the same child session and authenticated startup but
substitutes only a fake native tray platform.  It is compiled in the existing
temporary test directory and is never shipped or selectable by the production
binary.

The production trace uses the real PowerShell TrayHostClient exports,
TrayHostParentClient, authenticated wire, child session, HostTransport, receipt
sink, and generic-dialog invocation.  It covers both a current native
`OpenLogs` selection and an explicitly authenticated stale-revision negative
fixture.  The latter is required because an ordinary native click always uses
the current displayed revision.

## Failure policy

| Condition | Pending action | Receipt/UI |
| --- | --- | --- |
| Sink busy, full, or closed | Consumed | Drop receipt and UI feedback |
| Unsafe path, reparse, hard link, sharing failure | Consumed | Store fails; no UI feedback |
| Write or flush failure | Consumed | Store fails; no UI feedback |
| Writer hangs | Consumed | One writer remains blocked; bounded later receipts drop; no UI feedback |
| Durable success, UI queue full | Consumed | Keep durable receipt; drop only UI item |
| Disposal | Consumed | Stop admission and callbacks; bounded join only |

## Acceptance criteria

1. A terminal result removes its pending action before sink admission; eight or
   more failed admissions cannot stop later actions from registering.
2. A blocked store leaves the authenticated reader responsive to a subsequent
   presentation or ping and cannot hold the transport correlation lock.
3. The store rejects reparse directory components, a reparse leaf, a hard-link
   leaf, a second writer, and a concurrent replacement attempt before any
   outside target is written.
4. Receipt storage never exceeds 64 KiB and retains one complete latest record
   after rollover through the validated handle.
5. Generic feedback or About work is queued only after durable success; false,
   throw, full, blocked, or failed paths queue none.
6. The production trace exercises current and stale paths through TrayHostClient
   to ParentClient, authenticated wire, child session, HostTransport, receipt
   sink, and generic dialog, without a production-only test selector.
7. Existing installer/new-user/upgrade, process identity, package, native
   TrayHost, and Defender checks remain green before release acceptance.

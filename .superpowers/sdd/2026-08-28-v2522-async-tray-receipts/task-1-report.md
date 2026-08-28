# Task 1 report: pinned, bounded tray receipt store

Date: 2026-08-28

Worktree: `C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`

Branch: `codex/v2522-install-runtime-reliability`

## Status

Task 1 is implemented and focused verification is green. This report does not
claim the later asynchronous sink, bounded UI completion, or child-session
trace from Tasks 2 and 3.

## Files

- `src/trayhost/TrayTerminalDiagnostic.cs`
  - Replaced the caller-selected path append helper with
    `TrayTerminalDiagnosticStore`.
  - The production constructor has no path parameter. `TryGetDefaultPath`
    resolves only
    `%LOCALAPPDATA%\CodexControlOtherDevices\logs\trayhost-actions.log`.
  - Opens LocalAppData, product, and logs through `CreateFileW` directory
    handles using backup-semantics/open-reparse flags, `FILE_LIST_DIRECTORY`,
    attribute/security read access, read/write sharing, and no delete sharing.
  - Validates the actual opened directory handles for disk type, directory and
    non-reparse attributes, expected final path, and (for product/logs) exact
    current-user/SYSTEM/Administrators owner/DACL policy.
  - Opens the fixed leaf through `CreateFileW(OPEN_ALWAYS)` with open-reparse
    and write-through flags plus read sharing only. It rejects non-disk,
    directory, reparse, device, multi-link, unexpected-final-path, query, and
    sharing failures before any content write or truncation.
  - Reads length, performs rollover with `SetLength(0)`, writes the complete
    UTF-8 no-BOM record, and calls `Flush(true)` through the already validated
    leaf handle. It returns `true` only after the flush succeeds.
- `src/trayhost/Program.cs`
  - Owns one `TrayTerminalDiagnosticStore` and passes
    `TryAppendDurably` to the existing transport callback.
  - Disposes the store during the existing shutdown cleanup.
  - No command-line input, protocol type, wire field, direction, sequence, or
    authentication rule changed.
- `tests/trayhost/TrayHostNativeSelfTest.cs`
  - Added exact UTF-8/sanitization and fixed-production-path checks.
  - Added temporary-root reparse-directory, reparse-leaf, ordinary-directory
    leaf, hard-link leaf, unsafe DACL, directory-replacement barrier, concurrent
    writer, exact 64-KiB, crossing-rollover, and oversized-file checks.
  - The directory replacement and hard-link cases retain an outside sentinel
    byte-for-byte.
- `tests/trayhost/Invoke-TrayHostSelfTest.ps1`
  - Defines `TRAYHOST_SELF_TEST` only for the temporary NativeOnly test
    executable. The temporary-root factory and barriers are compiled out of
    every production build and do not create a production CLI, environment
    switch, listener, or external control surface.

## TDD evidence

### Clean baseline

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Output before test changes, exit `0`:

```text
TrayHost native self-tests passed: 17
```

### Initial RED

The behavioral test surface was added before production code.

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Exit `1`; exact decisive output:

```text
tests\trayhost\TrayHostNativeSelfTest.cs(66,20): error CS0246: ... TrayTerminalDiagnosticStore ...
CCOD_TRAYHOST_NATIVE_COMPILE_FAILED
```

This was the expected missing-feature failure: the current implementation did
not provide a store that owned native handles or exposed the temporary-only
barrier contract.

### Directory replacement behavior RED and native root cause

After the first minimal implementation compiled, the barrier remained red:

```text
TrayHost native self-test failed: System.InvalidOperationException
the opened logs handle denies rename replacement
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

A temporary in-memory Win32 probe isolated the cause. With the same
no-delete-share flags, an attribute-only directory handle allowed
`Directory.Move`; adding `FILE_LIST_DIRECTORY` made the move fail with sharing
violation `0x80070020`:

```text
ReadAttributes       : move-succeeded
ListDirectory        : IOException:80070020
Delete               : IOException:80070020
GenericRead          : IOException:80070020
ReadAttributesDelete : IOException:80070020
```

The production directory open therefore requests the minimal
`FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL` access needed for
the no-delete-share pin to enforce the approved barrier.

### ACL RED

An additional test added an Everyone full-control ACE to the existing logs
directory. Before handle-based ACL validation, NativeOnly exited `1` with:

```text
TrayHost native self-test failed: System.InvalidOperationException
an unexpected logs DACL is rejected before writing
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

The green implementation queries the security descriptor through the opened
directory handle with `GetSecurityInfo`. It never repairs an existing
unexpected ACL and rejects it before opening or creating the receipt leaf.

## Fresh GREEN evidence

All commands below were rerun after the last source/test change.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Exit `0`:

```text
TrayHost native self-tests passed: 21
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionOnly
```

Exit `0`, no output. This compiled the complete production TrayHost and ran
`--headless-smoke` without the self-test symbol.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -TransportOnly
```

Exit `0`:

```text
TrayHost transport self-tests passed: 10
```

This preserves the existing rule that a `false` persistence result cannot
produce About/failure feedback.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
```

Exit `0`:

```text
TrayHost protocol self-tests passed: 11
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ParentClientOnly
```

Exit `0`:

```text
TrayHost parent-client self-tests passed: 4
TrayHost production correlation trace passed: 2
```

The ParentClient run also printed the repository's existing PowerShell warning
about unapproved verbs in `TrayHostClient`; no command in this task changed
that module or warning surface.

```powershell
git diff --check
```

Exit `0`; only Git's existing LF-to-CRLF conversion notices were printed.

## Commit

- `365fde2430723fc8f80106e86490f7fb70be163f` —
  `fix: pin tray terminal receipt storage`

## Concerns and explicit boundaries

- `Program` still invokes the receipt callback synchronously because the
  bounded background sink is Task 2. This commit fixes filesystem identity,
  pinning, safety, and bounded storage only; it does not yet make the
  authenticated reader non-blocking.
- Existing product/log directories with a different owner or DACL fail closed
  and are not repaired. This follows the approved design, but a pre-existing
  inherited/broadened directory will suppress receipt durability and therefore
  generic feedback until a separately authorized migration or repair policy is
  designed.
- The private ACL, reparse, hard-link, and sharing controls contain accidental
  replacement and unsafe filesystem objects. They are not represented as a
  security boundary against a fully hostile process already running as the
  same Windows user.
- No installer, installed Codex process, real tray UI, push, release, or public
  operation was run. Release-wide and real-machine acceptance remain outside
  Task 1.

## Fix round 1/5: inherited compatibility parents

Review finding: the first implementation required the existing product and
`logs` directories to have the protected receipt-private ACL. Supported
current and legacy installations create those parents with normal inherited
ACLs, so production receipt writes returned `false` before opening a leaf.

### Compatibility ruling and implementation

- The fixed production leaf moved from the legacy direct path to
  `%LOCALAPPDATA%\CodexControlOtherDevices\logs\tray-receipts\trayhost-actions.log`.
- LocalAppData, product, and `logs` remain pinned compatibility parents. Their
  actual opened handles must still prove disk-directory type, non-reparse
  attributes, and the exact final path, and the handles continue to deny
  delete sharing while the receipt child and leaf are opened and written.
- The store no longer creates product or `logs`; supported installation/runtime
  setup remains responsible for those parents. A missing, wrong-type,
  reparse-point, or unqueryable parent fails closed.
- Only the fixed `logs\tray-receipts` child is created with the protected
  current-user/SYSTEM/Administrators ACL. Its reopened native handle must pass
  the strict owner/DACL, non-reparse, type, and final-path checks. An existing
  arbitrary or broadened child remains rejected and is never repaired.
- The direct legacy `logs\trayhost-actions.log` leaf is never opened, reused,
  truncated, or written.

### RED evidence

The compatibility test precreated product and `logs` with normal inherited
ACLs, asserted `AreAccessRulesProtected == false`, placed a byte sentinel in
the legacy direct leaf, and requested a durable receipt. Before the production
fix, this command exited `1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -NativeOnly
```

Exact decisive output:

```text
TrayHost native self-test failed: System.InvalidOperationException
inherited supported parents accept a durable receipt in the dedicated private child
CCOD_TRAYHOST_NATIVE_TEST_FAILED
```

This is the reviewed compatibility defect: the old store rejected supported
inherited parents before it could create a safe receipt boundary.

### GREEN and regression evidence

After the change, the compatibility test proves durable success, exact private
ACL creation on `tray-receipts`, exact UTF-8 content in the new leaf, and
byte-identical retention of the direct legacy leaf. Existing negative coverage
was retained or moved to the correct boundary: reparse compatibility parent,
reparse receipt child, reparse/directory/hard-link leaf, broadened receipt-child
ACL, concurrent writer, replacement barrier/outside sentinel, and exact or
crossing 64-KiB rollover.

Fresh pre-commit commands and results:

```text
NativeOnly:       exit 0, TrayHost native self-tests passed: 22
ProductionOnly:   exit 0, headless compile/run emitted no output
TransportOnly:    exit 0, TrayHost transport self-tests passed: 10
ProtocolOnly:     exit 0, TrayHost protocol self-tests passed: 11
ParentClientOnly: exit 0, TrayHost parent-client self-tests passed: 4
Production trace:          TrayHost production correlation trace passed: 2
git diff --check: exit 0 (only repository LF-to-CRLF notices)
```

The ParentClient command again emitted the repository's existing unapproved-
verbs warning for `TrayHostClient`; this fix did not modify that module.

### Fix-round commit and remaining boundary

- `f207496df1ceee744a09bbc5c3d24a48695e58bc` —
  `fix: preserve tray receipt parent compatibility`

Task 1 now supports the inherited parent ACLs created by existing
installations while retaining a dedicated fail-closed private receipt child.
The asynchronous/non-blocking sink remains Task 2. No installer, installed
process, real UI, release, push, or public operation was run in this fix round.

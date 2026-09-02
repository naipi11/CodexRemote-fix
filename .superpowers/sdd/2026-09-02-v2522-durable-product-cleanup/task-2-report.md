# Task 2 report: atomic real-mutex proof and final verification

## Scope and review status

Task 2 consumes Task 1's durable Pending/Completed cleanup fence without
changing Task 1 production behavior.  The only final source change is the
atomic-proof test in `tests/persistence/InstallFileTransaction.SelfTest.ps1`.
`KernelObjects.psm1` is unchanged.  This report records evidence for fresh
independent review; it makes no release-readiness claim.

## Atomic protocol

The parent opens N under the Task 1 real outer `AccountTransition` lease,
creates the exact durable Pending fence, and binds it to the strict product
transaction.  The MTA child receives only paths and event name.  Its
`EnterMutex` adapter calls the real `Enter-CcodMutex -Kind
AccountTransition`; its only wait override is:

```powershell
[Threading.WaitHandle]::SignalAndWait($enteredActualWaitEvent,$mutexHandle,15000,$false)
```

After the parent observes that signal it proves that N+1 has neither written
its result nor exited, opens N's retained shortcut, closes N's strict product
authority, and completes N's durable fence.  It then proves N+1 remains
blocked while N's outer lease is still live, releases that outer lease, and
requires N+1 to commit generation 2.  The test also asserts that the closed N
capability cannot be reused.

## Temporary-mutation RED

The only temporary mutation replaced the real `Enter-CcodMutex` call in
`Enter-CcodLifecycleProductCleanupLease` with a shape-valid test lease having
no mutex handle.  This removed only N's real *outer* lease.  It was restored
immediately after the run; it is not present in the final diff.

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit: `1`
- Exact failure: `ASSERT_TRUE: N+1 commit remains blocked after N strict
  authority closes while its durable outer AccountTransition lease is live`.

This is the intended post-close blocked assertion.  Earlier test shaping
attempts were rejected because removing the inner lease failed before the
blocked assertion during retained/fence validation; the final test opens the
retained generation only after the first blocked proof and tests the outer
lease only after the inner strict authority is closed.  The accepted RED was
not caused by STA, adapter loading, marker timing, or a mocked mutex.

## Final GREEN and verification

All commands below were fresh direct runs after production restoration.

| Command | Exit | Result |
|---|---:|---|
| `tests\persistence\InstallFileTransaction.SelfTest.ps1` | 0 | `Install file transaction self-test passed.` |
| `tests\persistence\KernelObjects.SelfTest.ps1` | 0 | 16 named cases passed; real cross-process mutex, ACL, timeout, abandoned, and same-thread-release cases included. |
| `tests\persistence\ProductRegistration.SelfTest.ps1` | 0 | `Product registration self-tests passed: 13` |
| `tests\persistence\UninstallBootstrap.SelfTest.ps1` | 0 | `Uninstall bootstrap self-tests passed: 23` |
| `tests\persistence\InstallLifecycle.SelfTest.ps1` | 0 | `Install lifecycle self-tests passed: 126` |
| `git diff --check` | 0 | no whitespace errors (only Git LF-to-CRLF checkout warnings) |
| `tests\PersistenceSelfTest.ps1` | 0 | fresh tracked direct aggregate exit; no failure output |

The lifecycle run retained Task 1's fail-closed cross-process observation:
`exit=23 mutex=True authority=False product=False verified=False
error=CCOD_PRODUCT_REGISTRATION_FAILED`.

`[System.Management.Automation.Language.Parser]::ParseFile` parsed the one
final changed PowerShell file successfully: `PowerShell parser passed: 1/1`.

## No-real-action statement

No real registry, Start-menu/Desktop shortcut, installer, uninstaller,
installed product, product process, network, release, tag, signing, push,
publication, installation, restart, or reboot action was performed.  Tests
used temporary fixtures, marker adapters, named mutexes, and temporary event
handles only.

## Review request and remaining boundary

Please perform fresh independent review of the final test diff and this
evidence, with particular attention to the two post-signal blocked assertions
and exact Task 1 fence ordering.  A green focused suite and aggregate are not
release or installed-product acceptance evidence.

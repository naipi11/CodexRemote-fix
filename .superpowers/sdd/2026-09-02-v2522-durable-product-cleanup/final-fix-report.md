# Final fix report: durable product cleanup recovery gaps

## Scope and review status

- Final-review base: `b1aec464b255661596d19c6a5d2bdb6ead4a7003`.
- Implementation: `9e00ccf3ce4fb1f5e2f1e80c415c8fd787b71509`
  (`fix: close durable cleanup recovery gaps`).
- The implementation commit contains only:
  - `src/persistence/modules/InstallLifecycle.psm1`
  - `tests/persistence/InstallFileTransaction.SelfTest.ps1`
  - `tests/persistence/InstallLifecycle.SelfTest.ps1`
- This is the plan's single final-fix wave. It fixes the three final-review
  Important findings together. It does not claim release readiness or
  installed-product acceptance; one scoped independent re-review remains.

## Root causes and fixes

### Old Pending before selector advance

The previous flow first committed the new selector and terminal Ready record,
then called registration for the new Ready transaction. That registration saw
the old Pending record only as foreign history, while strict old authority had
already become stale and could no longer be opened for recovery.

An upgrade now acquires the real outer `AccountTransition` product-cleanup
lease before creating the new generation or any new nonterminal transaction
record. It resolves cleanup against the exact currently selected old ordered
12-field Ready transaction, then retains that lease across the selector commit.
The later same-thread `InstallLease` and lifecycle ownership acquisitions are
recursive acquisitions of the same mutex. Normal release is LIFO: lifecycle
ownership, install lease, then the pre-upgrade product-cleanup lease. Every
exception path attempts the same order, and a resolve failure exits before a
new selector or Ready record is written.

The existing resolver behavior remains exact: a live foreign owner blocks, a
same-thread retained capability may retry, and a proven-dead owner must open,
bind, and close fresh strict old authority before appending Completed.

### Fence binding failure cleanup

After strict `OpenProduct` succeeded, a binding failure previously reached a
Ready close. Its missing-fence assertion ran before native close and authority
lease release, permanently retaining the inner recursive mutex.

The process-local cleanup entry now records whether the exact durable fence was
successfully bound. An unbound strict transaction is closed directly with
`Disposition Failed`; that path always attempts native runtime cleanup and the
inner authority lease release and never appends Completed. On successful abort
the stale transaction capability is discarded while durable Pending remains.
If the abort itself fails, the exact capability remains retryable; a later
same-thread call first retries the Failed abort, then opens and binds fresh
strict authority. Only a successful bound Ready close permits Completed.

### Exact crash temporary recovery

The create-only writer can leave a read-only `.ccod.<32-lowercase-hex>.tmp`
after abrupt process termination. The fence reader previously classified that
internal crash artifact as an unknown object forever.

The final design deliberately does not alter the independently reviewed IFT
seal/rename ABI. Delete-on-close was rejected for this wave because the current
write-close, strict-reopen, read-only, and no-replace rename sequence did not
provide a sufficiently narrow proof that delete-pending could be cleared on
every rename/collision/exception path without reopening a crash window.

Instead, the fence reader performs the brief's narrow recovery while the real
outer product-cleanup lease is live. A private inert-marker CLR bridge:

- accepts only the exact lowercase internal temporary name;
- pins install root, `state`, and `product-cleanup-fences` through relative
  non-reparse native directory handles;
- opens one leaf with `DELETE`, read/write-attribute access, and zero sharing;
- proves non-directory, non-reparse, default-stream-only, single-link identity,
  exact final path, and stable volume/file index;
- clears only that pinned orphan's read-only attribute, arms native delete
  disposition, revalidates the same identity, closes the handle, and requires
  the pinned parent enumeration to show the leaf absent;
- re-enumerates the whole fence plane before any history is accepted.

Unknown names, reparse objects, ADS, hardlinks, and any open/nonexclusive exact
temporary still fail closed and are not removed or ignored. There is no broad,
recursive, wildcard, or path-only deletion.

## RED evidence

### Upgrade with old Pending

- Runner: Windows PowerShell 5.1 targeted execution of the checked-in lifecycle
  case `upgrade resolves a dead-owner old Pending while the old Ready is still
  selected`.
- Exit: `1`.
- Harness result:
  `CCOD_SELFTEST_FAILED case=upgrade-resolves-a-dead-owner-old-Pending-while-the-old-Ready-is-still-selected error=ASSERT_EQUAL`.
- Exact failure:
  `dead-owner old Pending is reconciled before selector advance expected=[] actual=[A different product cleanup transaction remains Pending]`.
- Meaning: the old code made the new Ready visible before trying to reconcile
  old cleanup and could then only reject it as foreign Pending.

### Bind failure leaks inner authority

- Runner: Windows PowerShell 5.1 targeted execution of the checked-in lifecycle
  case `fence bind failure aborts the real strict transaction before exact retry
  recovery`.
- Exit: `1`.
- Harness result:
  `CCOD_SELFTEST_FAILED case=fence-bind-failure-aborts-the-real-strict-transaction-before-exact-retry-recovery error=ASSERT_TRUE`.
- Exact failure:
  `Failed abort releases the inner real AccountTransition mutex for another process`.
- The fixture used real strict `OpenProduct` and the real inner
  `AccountTransition` mutex. Only the private fence-proof call was injected to
  fail. The second Windows PowerShell process exhausted its real 15-second mutex
  wait. Pending/no-receipt/no-product-write assertions had already passed.

### Abrupt writer crash artifact

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  tests\persistence\InstallFileTransaction.SelfTest.ps1`.
- Exit: `1`.
- Harness result:
  `CCOD_SELFTEST_FAILED case=abrupt-writer-exit-cannot-strand-an-exact-internal-create-only-temporary-leaf error=ASSERT_EQUAL`.
- Exact failure:
  `process termination deletes every exact internal temporary through its native handle disposition expected=[0] actual=[1]`.
- The child used a real state transaction and real create-only collision, wrote
  its collision marker, remained alive, and was then terminated. Exactly one
  `.ccod.<32-lowercase-hex>.tmp` remained.
- After selecting narrow recovery, the final checked-in form also failed before
  production support with stable `CCOD_PRODUCT_REGISTRATION_FAILED` and
  `Product cleanup fence plane contains an unknown object`.

An attempted ADS fixture using a .NET path API was rejected by that API and was
not counted as RED evidence; it was replaced with the repository's existing
Windows ADS fixture pattern. A first bind retry fixture omitted staged shortcut
candidates and was likewise rejected as behavior evidence before the final
green run.

## Focused GREEN evidence

- Old-Pending upgrade targeted runner: exit `0`; the old transaction retained
  `1:Pending|1:Completed`, then the distinct new Ready transaction recorded its
  own `1:Pending|1:Completed`.
- Bind-failure targeted runner: exit `0`; the other process acquired the real
  mutex and exited `23` on live Pending before strict authority. The later exact
  retry succeeded with three bind attempts and three lower closes: one unbound
  Failed abort, one fresh bound recovery Ready close, and one new verification
  Ready close.
- Hostile-temporary targeted runner: exit `0`; unexpected name, reparse, ADS,
  hardlink, and live/open exact-name cases all remained present and failed
  closed before product or shortcut writes.
- Crash-artifact case is included in the final IFT suite and passed after the
  real child crash left one exact orphan, narrow recovery removed it, canonical
  Pending remained readable, and the original final record hash stayed exact.

## Fresh final matrix after source freeze

| Command | Exit | Result |
|---|---:|---|
| `tests\persistence\InstallFileTransaction.SelfTest.ps1` | 0 | 35 named cases; `Install file transaction self-test passed.` |
| `tests\persistence\KernelObjects.SelfTest.ps1` | 0 | 16 named cases passed. |
| `tests\persistence\ProductRegistration.SelfTest.ps1` | 0 | `Product registration self-tests passed: 13`. |
| `tests\persistence\UninstallBootstrap.SelfTest.ps1` | 0 | `Uninstall bootstrap self-tests passed: 23`. |
| `tests\persistence\InstallLifecycle.SelfTest.ps1` | 0 | `Install lifecycle self-tests passed: 128`. |
| PowerShell parser over all three changed PowerShell files | 0 | `PARSER_TOTAL=3 FAIL=0`. |
| `git diff --check` | 0 | No whitespace errors; only checkout LF-to-CRLF warnings. |
| `tests\PersistenceSelfTest.ps1` | 0 | Fresh tracked aggregate; no failure output. |

The final lifecycle run retained the required fresh-process observation:
`CCOD_CROSS_PROCESS_OBSERVED exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`.

The full focused and aggregate suites also retain the prior exact ten-field
fence and ordered twelve-field Ready proof, create-only history, real MTA
`SignalAndWait`, stale-N and closed-N rejection, live-owner blocking, dead-owner
strict recovery, and the absence of post-Ready lifecycle Failed or false
verified receipts.

## No-real-action statement and remaining boundary

No real registry, Start-menu/Desktop shortcut, installer, uninstaller,
installed product, product process, network, release, push, tag, signing,
publication, installation, restart, or reboot action was performed. Tests used
only temporary fixtures, marker-file product adapters, test child processes,
and private named mutex/event objects.

Please perform one fresh scoped independent review of the implementation and
evidence commits, especially the pre-upgrade recursive mutex lifetime, unbound
Failed-abort retry state, and native orphan identity/delete sequence. A green
matrix and aggregate are not release-readiness or installed-product evidence.

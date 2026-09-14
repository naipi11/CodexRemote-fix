# Task 1 report: durable cross-process product-cleanup fence

## Review status

Task 1 implementation and focused evidence are recorded for independent task
review. This report does not claim Task 1 or Task 4 complete and makes no
release-readiness claim.

## Scope and commit

- Base: `25eedda46a7963e8951a44d472b902015d38697d`
- Implementation: `271a6e57ccfcc0568151f620c5cef0e3d43e1416`
  (`fix: fence durable product cleanup`)
- Production/tests commit contains only:
  - `src/persistence/modules/InstallLifecycle.psm1`
  - `src/persistence/modules/InstallFileTransaction.psm1`
  - `tests/persistence/InstallLifecycle.SelfTest.ps1`
  - `tests/persistence/InstallFileTransaction.SelfTest.ps1`

## RED evidence

### Private lower native-close seam

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit: `1`
- Exact failure:
  `private-lower-close-seam-preserves-the-real-transaction-cleanup-retry-path`
  reached `ASSERT_THROWS: expected CCOD_INSTALL_CLOSE_FAILED`.
- Meaning: the old close path did not traverse the injected lower native-close
  boundary. The later seam is module-private and leaves the real authority
  lease-release code in effect.

### Same-process durable Pending

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Exit: `1`
- Exact failure:
  `first lower close failure leaves exactly one durable Pending record
  expected=[1] actual=[0]`.
- This was the valid rerun after narrowing the seam to `ProductOnly`; an
  earlier cleanup/setup failure was explicitly rejected as RED evidence.

### Fresh-process release-before-fence window

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Exit: `1`
- Exact observation before the fix:
  `CCOD_CROSS_PROCESS_OBSERVED exit=0 mutex=True authority=True product=True verified=True error=`
- Exact assertion:
  `fresh process fails closed on the durable pending fence expected=[23]
  actual=[0]`.
- The child was a fresh Windows PowerShell process. It received paths and the
  package hash only, acquired the real `AccountTransition` mutex, and read the
  install state itself; it received no parent in-memory cleanup signal.

### IFT release guard

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit: `1`
- Exact failure:
  `Ready product close rejects release before a durable cleanup fence is bound`
  reached `ASSERT_THROWS: expected CCOD_INSTALL_CLOSE_FAILED`.

### Proven-dead owner recovery

- Targeted Windows PowerShell helper execution invoked the checked-in
  `Invoke-CcodLifecycleDeadOwnerCleanupTest` fixture after loading the helper
  prefix of `InstallLifecycle.SelfTest.ps1` in a fresh process.
- Exit: `1`
- Exact failure:
  `dead owner requires a fresh strict cleanup close before the new verification
  close expected=[2] actual=[1]`.
- The fixture persisted a Pending record with PID `2147483647`, a canonical old
  creation time, and the current SID under a real outer account lease. The old
  implementation appended Completed without a fresh strict open/close.

## GREEN evidence

### Lifecycle focused suite

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Exit: `0`
- Result: `Install lifecycle self-tests passed: 122`
- Exact fresh-process observation:
  `CCOD_CROSS_PROCESS_OBSERVED exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`
- Covered behavior includes one-attempt lower close failure, durable Pending,
  two same-thread retained-capability failures with no receipt, exact retry and
  Completed append, live-owner cross-process blocking, and proven-dead owner
  fresh strict cleanup before a new verification transaction.

### Install file transaction focused suite

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit: `0`
- Result: `34/34` declared named cases passed and the suite printed
  `Install file transaction self-test passed.`
- New cases prove an unbound Ready product close retains its same-thread lease
  and that the private lower-close seam preserves retry behavior.

### Parser and diff

- Parser command: parse the two changed modules and two changed self-tests with
  `[System.Management.Automation.Language.Parser]::ParseFile`.
- Parser exit: `0`, output `PowerShell parser passed: 4/4`.
- Command: `git diff --check`
- Exit: `0`; output contained only Git LF-to-CRLF checkout warnings.

## Durable ordering and recovery behavior

- The state plane is
  `state\product-cleanup-fences\<attempt>.Pending|Completed.<transactionId>.json`.
  Records are written through an IFT state-only transaction and
  `Write-CcodInstallRecord` create-only publication.
- Each payload has exactly the ordered ten fields required by the brief. The
  containing path binds the canonical install root; every read also reproves
  the complete ordered 12-field Ready transaction and selected generation.
- A real outer `AccountTransition` lease covers resolve, Pending publication,
  strict product open/use, lower close, and Completed publication. IFT refuses
  a Ready product close unless the exact Pending record is same-handle read and
  bound first.
- A live matching owner blocks before product authority opens. The same owner
  on the same managed thread retries only the retained original capability.
- A proven-dead owner is reconciled without old-process memory: under the fresh
  outer lease, code opens a new strict product transaction, binds the existing
  Pending record, performs real close, and appends Completed only after success.
  Failure leaves Pending and fails closed.

## No-real-action statement

No real registry, Start-menu/Desktop shortcut, installer, uninstaller,
installed product, product process, network, release, push, tag, signing,
installation, restart, or reboot action was performed. Product effects in all
tests were in-memory or temporary marker-file adapters. Named mutexes and
temporary fixture state were the only real OS primitives exercised.

## Compatibility and remaining review boundary

- Existing `CCOD_INSTALL_CLOSE_FAILED` same-thread retry semantics remain.
- Test-only authority used solely for mutex exclusion now closes with
  disposition `Failed`; real product registration uses Ready only after a
  durable Pending bind.
- Full aggregate/release validation and Task 4 completion are outside this
  Task 1 report and remain for the plan's later independent verification.

## Fix round 1: fail-closed strict open and transaction-partitioned history

### Scope and implementation commit

- Review base: `ffb5dd0` (`docs: record durable product cleanup evidence`).
- Fix implementation: `79b4825244fe53b9af8d10bf2b7e4efae347c909`
  (`fix: partition durable cleanup history`).
- The implementation commit contains only:
  - `src/persistence/modules/InstallLifecycle.psm1`
  - `tests/persistence/InstallLifecycle.SelfTest.ps1`
- The fix keeps every record under the exact ten-field validator and canonical
  filename validator, validates Pending/Completed sequencing independently per
  `transactionId`, binds current records to the exact current Ready identity,
  ignores only fully completed foreign history, and blocks every unresolved
  foreign Pending record.
- A new Pending entry starts with `CloseCompleted = false`. A strict open
  failure therefore retains Pending and cannot append Completed. A later
  same-owner/same-thread call first opens, binds, and closes fresh strict
  authority for that Pending fence before starting a new verification attempt.

### RED evidence

#### Strict product open failure

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Exit: `1`.
- Exact first failure:
  `CCOD_SELFTEST_FAILED case=strict-product-open-failure-retains-Pending-and-later-reconciles-before-verified-success error=ASSERT_EQUAL`
- Exact assertion:
  `ASSERT_EQUAL: strict product open failure leaves only its durable Pending record expected=[1] actual=[2]`.
- The test first created a production-shaped temporary Ready generation with
  both sealed registration shortcut candidates, then used the existing
  module-private native dispatcher boundary to fail only `OpenProduct` after
  Pending publication. It observed no returned receipt or real product action.

#### Completed older transaction poisoning a new Ready upgrade

- Targeted Windows PowerShell execution loaded lines 1-681 (imports and helper
  definitions) from the checked-in lifecycle self-test, parsed the same file
  with the PowerShell AST, selected the exact test named
  `completed cleanup history from an older Ready transaction permits new upgrade registration`,
  and invoked its checked-in scriptblock. The runner was passed through
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand` using
  UTF-16LE solely to preserve shell quoting.
- Exit: `1`.
- Exact valid failure:
  `ASSERT_EQUAL: older completed cleanup history is ignored for the new Ready attempt sequence expected=[] actual=[CCOD_PRODUCT_REGISTRATION_FAILED]`.
- The valid fixture kept project version `2.5.22` and the same computed package
  hash, changed a sealed payload byte to create a distinct runtime and Ready
  transaction, and started with the prior Ready transaction's complete
  Pending/Completed history. Thus failure occurred at fence-history validation,
  not package identity or adapter setup.
- An earlier same-version/different-explicit-hash attempt stopped at
  `CCOD_INSTALL_PACKAGE_CONFLICT`, and an interim `2.5.23` attempt skipped the
  version-gated product-registration path. Neither was counted as RED evidence.

#### Prior Pending preservation

- The same targeted runner selected
  `unresolved Pending from an older transaction blocks new Ready registration fail closed`.
- Before the production fix it exited `0` and printed
  `TARGETED_PRIOR_PENDING_PASS`: the pre-existing behavior blocked, performed
  zero product and shortcut writes, emitted no receipt, retained the foreign
  Pending record, and appended no lifecycle Failed snapshot. This was retained
  as a must-stay-green regression while completed history was partitioned.

### GREEN evidence

- Targeted strict-open runner: exit `0`,
  `TARGETED_STRICT_OPEN_GREEN`.
- Targeted completed-history upgrade runner: exit `0`,
  `TARGETED_UPGRADE_HISTORY_GREEN`.
- Targeted prior-Pending runner: exit `0`,
  `TARGETED_PRIOR_PENDING_GREEN`.
- The direct unknown-field negative is included in the full lifecycle suite. It
  temporarily clears and restores the read-only bit only on its temporary test
  fence, adds `unknownFenceField`, and proves default registration fails closed
  before product writes. A first attempt to overwrite the still-read-only file
  was rejected as fixture setup failure and was not counted as behavior evidence.

#### Full focused suites

- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Exit: `0`.
- Result: `Install lifecycle self-tests passed: 126`.
- Exact cross-process observation remained:
  `CCOD_CROSS_PROCESS_OBSERVED exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`.
- Command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit: `0`.
- Result: all `34/34` named cases printed `True`, followed by
  `Install file transaction self-test passed.`

#### Parser and diff

- Parsed the two production modules and two focused self-tests with
  `[System.Management.Automation.Language.Parser]::ParseFile`.
- Exit: `0`; output: `PowerShell parser passed: 4/4`.
- Command: `git diff --check`.
- Exit: `0`; output: `git diff --check passed`, plus only Git checkout
  LF-to-CRLF warnings.

### No-real-action and remaining boundary

No real registry, Start-menu/Desktop shortcut, installer, uninstaller,
installed product, product process, network, release, push, tag, signing,
installation, restart, or reboot action was performed. All product effects were
temporary in-memory or marker-file adapters. This fix round is ready for scoped
re-review; it does not claim Task 1, Task 4, aggregate validation, or release
readiness complete.

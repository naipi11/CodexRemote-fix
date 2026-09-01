# Task 4 report: post-Ready product registration

## Status

Implemented current-user uninstall registration and the exact Start-menu and
desktop `CodexRemote-fix.lnk` records after the Task 2 terminal `Ready` proof.
All three new records are read back before the exact legacy migration is
authorized. Product-registration failures are reported after the file
transaction closes and never enter install compensation, append `Failed`, or
downgrade an already durable `Ready` transaction.

The direct installed uninstaller now runs only from the canonical selected
`2.5.22-<digest16>-<nonce32>` generation, invokes that generation's
manifest-bound uninstall bootstrap, and completes through the verified
external transaction payload. No Inno uninstaller is required.

No real registry or shortcut mutation, installer/uninstaller/product
execution, release build, network write, push, tag, signing, or publication was
performed.

## RED evidence

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1`
  exited `1` because
  `src\persistence\modules\ProductRegistration.psm1` did not exist.
- After the six registration behavior groups were added, the lifecycle suite
  exited `1` with `CCOD_INSTALL_ADAPTER_INVALID`, target
  `RegisterProduct`; there was no post-Ready lifecycle seam.
- The uninstall bootstrap suite exited `1` with
  `CCOD_UNINSTALL_ADAPTER_INVALID`, target `RemoveProductRegistration`; there
  was no verified post-cleanup product-state remover.
- The file-transaction suite exited `1` because the exact capability export
  surface did not contain the fixed SpecialFolder open/copy operations.
- The Ready-finalization recovery regression exited `1`: expected one product
  registration after the missing Ready snapshot was recovered, actual zero.

## GREEN evidence

- Product registration:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1`
  exited `0`; `Product registration self-tests passed: 6`.
- File capability:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
  exited `0`; all 26 named cases passed.
- Uninstall bootstrap:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
  exited `0`; `Uninstall bootstrap self-tests passed: 17`.
- Install lifecycle:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `0`; `Install lifecycle self-tests passed: 115`.
- Explicit PowerShell parser checks passed all nine changed `.ps1`/`.psm1`
  implementation and test files (`PARSER_FAILURES=0`).
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were
  emitted.
- The aggregate `tests\PersistenceSelfTest.ps1` was not requested by the Task
  4 brief and was not run; no aggregate-pass claim is made.

## Implemented boundaries

- `New-CcodProductRegistration`, `Test-CcodProductRegistration`,
  `Commit-CcodProductRegistration`, and
  `Remove-CcodLegacyProductRegistration` enforce the canonical runtime ID,
  exact version/hash, exact runtime bootstrap/uninstaller paths, fixed HKCU
  product key, and two fixed shortcut leaves.
- Shortcut candidates are generated before runtime identity calculation,
  copied into `registration/` inside the immutable generation, included in its
  manifest/runtime-ID binding, and copied after Ready only through pinned
  current-user Programs/Desktop handles. Arbitrary destination paths and
  shortcut leaf names are not accepted.
- The shortcut candidates start the one fixed current-user Supervisor task.
  Task 2 already binds that task action to the selected generation bootstrap;
  this avoids embedding a not-yet-computable runtime ID in candidate bytes
  while still resolving the sealed bootstrap selected and proven Ready.
- Normal install and the bounded missing-Ready-snapshot recovery both perform
  post-Ready registration. The recovery uses the state transaction only for
  fixed SpecialFolder capability operations; generation and pointer mutation
  remain unavailable.
- Uninstall removes only a matching current product runtime key and the two
  exact new shortcut paths after protected application cleanup. Legacy
  migration requires the canonical AppId, verified new registration, and the
  exact legacy shortcut allowlist before deletion starts.

## Compatibility concerns

- Legacy migration is deliberately conservative: a missing or changed legacy
  shortcut name, wrong AppId, or unreadable legacy entry retains all legacy
  state for later diagnosis rather than attempting partial cleanup.
- The ordinary same-user writer and in-process introspection limits documented
  by the immutable-generation design remain unchanged.
- No live Windows Settings launch, real shell-link promotion, or installed
  uninstall was executed in this task; those remain part of later installed
  acceptance.

## Implementation commit

- `e43d9ce18c5d79bb438e08c9ff2973be592277aa`
  (`feat: register product only after readiness`).

## Fix round 1: matched uninstall and retriable registration

Scoped review of `70bc231..97cf17d` found one Critical and four Important
issues. The installed wrapper could synchronously continue after deleting its
own generation; product cleanup could remove an entire key without exact
value/shortcut evidence; `AlreadyInstalled` skipped registration retry;
legacy removal was not compensating; and shortcut copy accepted a state-only
transaction plus arbitrary absolute source path.

### RED evidence

- UninstallBootstrap first exited `1` because
  `src\persistence\InstalledUninstallFinalizer.ps1` did not exist.
- ProductRegistration exited `1` with `CCOD_PRODUCT_ADAPTER_INVALID`, target
  `ReadLegacyEntry`, before exact current-state and per-entry legacy
  compensation adapters existed.
- InstallLifecycle exited `1` in the exact Ready/package idempotence case:
  registration calls expected `1`, actual `0`.
- InstallFileTransaction exited `1` because the export surface lacked
  `Open-CcodInstallProductRegistrationTransaction` and
  `Open-CcodInstallRetainedFile`; product shortcut copy still exposed
  `SourcePath`.

### GREEN and verification evidence

- ProductRegistration exited `0` with
  `Product registration self-tests passed: 9`. Coverage includes exact
  registry/shortcut evidence, unknown/replaced/reparse/ambiguous no-delete,
  mid-sequence legacy restoration, and replacement-preserving compensation.
- InstallFileTransaction exited `0`; all 27 named cases passed. The new case
  proves product-only retained-file authority, no arbitrary shortcut source
  path, state-only denial, and product-scope denial for state writes.
- UninstallBootstrap exited `0` with
  `Uninstall bootstrap self-tests passed: 19`. The installed path now stops at
  `TaskRemoved`; its staged finalizer waits for exact wrapper exit, validates
  transaction and selected generation, performs matched removal, proves root
  absence, removes only matched product state, and then finalizes. Wrong
  wrapper/generation/transaction cases delete nothing.
- InstallLifecycle exited `0` with
  `Install lifecycle self-tests passed: 116`. Both normal and missing-Ready
  recovery registration failures remain outside rollback/Failed and are
  reconciled by a later exact same-package `AlreadyInstalled` invocation.
- Explicit parser checks passed all 11 changed PowerShell source/test files
  (`PARSER_COUNT=11`, `FAILURES=0`).
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were
  emitted.
- The aggregate `tests\PersistenceSelfTest.ps1` was not run in this fix round;
  no aggregate-pass claim is made.

### Remediated boundaries

- The selected-generation wrapper launches a hidden external finalizer from
  the ACL-bound staged payload and returns. Application removal cannot begin
  until the exact wrapper PID/creation-time identity has exited.
- Current product cleanup accepts only the exact allowed registry value names,
  kinds and values plus both shortcut hashes, targets, arguments, and regular
  file identities. Registry values are revalidated and removed individually;
  a key is deleted only after it is empty and has no subkeys.
- Legacy migration captures exact registry kinds/values and shortcut bytes,
  deletes entries one by one, and restores prior removals in reverse order
  only while their names remain absent. A replacement is never overwritten.
- Product shortcut promotion now accepts only an opaque file capability opened
  from one selected generation at either fixed manifest-relative candidate.
  Product-only transactions cannot write state, generations, manifests,
  pointers, or retirements; state-only transactions cannot acquire shortcut
  authority.

### Compatibility and external boundaries

- Conservative mismatch behavior may leave current or legacy registration for
  diagnosis instead of partially deleting it.
- No real registry, shortcut, installer, uninstaller, product process,
  WindowsApps, DPAPI, network, release, push, tag, signing, or publication
  action was performed.

### Fix implementation commit

- `2e76698d535e6e824df1c57d81314be1c2e053e8`
  (`fix: complete matched product lifecycle`).

## Fix round 2: exact Ready-bound finalization and cleanup

Scoped review of `97cf17d..0fdc392` found four Important gaps: installed
finalization did not durably bind wrapper/manifest/epoch and removed too broad
a root; coherent registration replacement could self-authorize cleanup;
product source authority did not require latest selected Ready evidence; and
legacy restore failures were suppressed.

### RED evidence

- UninstallBootstrap exited `1` with `CCOD_INSTALLED_FINALIZER_INVALID`, target
  `RemoveSelectedGeneration`, then separately with `NamedParameterNotFound`
  for `Invoke-CcodUninstallBootstrap -WrapperIdentity`.
- ProductRegistration exited `1` because `Remove-CcodProductRegistration`
  lacked `ReadyEvidence`; the fixed `schtasks.exe` negative later failed by not
  throwing `CCOD_PRODUCT_REGISTRATION_NOT_READY`.
- InstallFileTransaction exited `1` because
  `Open-CcodInstallProductRegistrationTransaction` lacked `ReadyEvidence`.
- ProductRegistration exited `1` with `CCOD_PRODUCT_ADAPTER_INVALID`, target
  `WriteLegacyCompensationFailure`.

### GREEN evidence

- ProductRegistration: `10/10`, exit `0`.
- InstallFileTransaction: `27/27`, exit `0`.
- UninstallBootstrap: `19/19`, exit `0`.
- InstallLifecycle: `116/116`, exit `0`.
- Explicit parser checks: `10/10`, zero failures.
- `git diff --check`: exit `0`; only LF-to-CRLF checkout warnings.
- Aggregate was not run; no aggregate-pass claim is made.

### Boundaries

- Prepare durably records exact wrapper PID/creation/session/SID, selected
  runtime root, manifest hash, generation, Ready evidence and lease epoch.
  Finalizer requires an initially verified wrapper and its later exact exit,
  current epoch, matching leaf/manifest, and deletes only that generation.
- Registration and cleanup bind canonical install root, Ready runtime and
  generation, package/manifest/candidate hashes, exact arguments, and the
  canonical `%System%\schtasks.exe` target. Coherent arbitrary replacements
  preserve every entry.
- Product-only and retained-file capabilities require the latest append-only
  pointer, matching manifest and one matching Ready install record; pre-Ready,
  stale/unselected, absolute, state-only and wrong-relative sources fail.
- Legacy compensation verifies absence before each restore. Replacement or
  restore failure is never overwritten or swallowed: it writes an explicit
  unresolved record and returns `CCOD_LEGACY_PRODUCT_COMPENSATION_FAILED`.
  A normal migration failure is reported only after full restoration.

No real registry, shortcut, uninstall, product process, WindowsApps, DPAPI,
network, release, push, tag, signing, or publication action was performed.

### Fix implementation commit

- `283ecbe3eb012f1e78377e9336aacc7b3acc9336`
  (`fix: bind matched product finalization`).

### Supplemental pre-cleanup target gate

Final pre-commit audit added a noncanonical Ready target negative. Its RED
returned the expected validation error but observed `Cleanup=1`: validation
failure was captured without clearing the fresh context. The fix clears every
failed fresh context, validates the same canonical Ready invariant on stored
resume transactions, and rejects before cleanup. Fresh UninstallBootstrap is
`20/20`, exit `0`; focused parser `4/4` and diff check exit `0`.

- Supplemental commit: `67c79d82e18c805f27aec8e05553938f1f706380`
  (`fix: reject invalid Ready evidence before cleanup`).

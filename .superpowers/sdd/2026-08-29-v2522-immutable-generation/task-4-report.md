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

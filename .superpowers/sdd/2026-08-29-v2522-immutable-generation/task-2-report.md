# Task 2 report: immutable lifecycle generations

## Status

Implemented the Task 2 immutable lifecycle migration in the assigned worktree.
The install path now stages a unique manifest-bound generation, appends the
transaction and active-generation chains, selects the generation bootstrap for
the scheduled task, retains legacy root shells and failed/old generations, and
uses a higher compensating pointer after post-pointer failure.

No release, push, tag, signing, build, installation, real product process
start/stop, WindowsApps access, DPAPI access, or external write was performed.

## RED evidence

- Recovery baseline command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `1` at `first-install-stages-verifies-activates-task-and-persists-consent`,
  old assertion `stable bootstrap copied`. The obsolete root-shell expectation
  was replaced by the approved generation-specific shell contract.
- Runtime identity RED exited `1` because `New-CcodUniqueRuntimeId` had no
  `ContentSha256` parameter. GREEN binds the full SHA-256 of
  `projectVersion + NUL + sealedPackageSha256` and a per-attempt nonce into a
  96-character runtime ID.
- Activation receipt RED exited `1` because `StartingProtection` wrote mutable
  `state\post-install-activation.json`. GREEN writes phase-specific create-only
  records below `state\activation-receipts` through the opaque transaction.
- Operational-state RED reproduced `UnauthorizedAccessException` and
  `CCOD_ATOMIC_REPLACE_FAILED` after the Task 1 record seal made status and UI
  files read-only. GREEN separates immutable initialization evidence below
  `state\install-initializations\<runtimeId>` from writable operational state
  materialized only when all operational leaves are absent.
- Real idempotence RED expected `AlreadyInstalled` but received `Upgraded`.
  GREEN performs no pointer, runtime, task, or process mutation only when the
  active Ready transaction has the exact explicitly supplied package identity;
  a different explicit identity returns `CCOD_INSTALL_PACKAGE_CONFLICT`.
- Bounded reader RED exited `1` because `Read-CcodStrictJson` had no
  `MaxBytes` parameter. GREEN rejects oversized records before JSON parsing.
- Transaction-chain identity RED exited `1` because a contiguous snapshot
  chain could change `oldRuntimeId`. GREEN binds every immutable transaction
  identity field across all snapshots.

## GREEN and verification evidence

- Lifecycle command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
- Lifecycle exit/result: `0`; `Install lifecycle self-tests passed: 108`.
- Runtime manifest command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1`
- Runtime manifest exit/result: `0`; 16 named cases passed.
- Uninstall bootstrap command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
- Uninstall bootstrap exit/result: `0`; `Uninstall bootstrap self-tests passed: 12`.
- Persistence I/O command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\PersistenceIO.SelfTest.ps1`
- Persistence I/O exit/result: `0`; 24 named cases passed.
- Aggregate command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
- Aggregate exit: `0` (`TASK2_AGGREGATE_EXIT=0`). The prior local
  Bootstrap/mutex boundary did not reproduce in this fresh run.
- Parser command: explicit
  `[Management.Automation.Language.Parser]::ParseFile` pass over all eight
  changed PowerShell code/test files.
- Parser exit: `0` (`TASK2_PARSER_EXIT=0`); every file reported `PARSER_OK`.
- Diff command: `git diff --check`
- Diff exit: `0` (`TASK2_DIFF_CHECK_EXIT=0`; checkout emitted only LF-to-CRLF
  warnings).

## Behavior and boundaries

- Runtime IDs are unique per attempt and retain a full deterministic digest of
  project version plus canonical sealed package identity. Runtime manifest
  validation still rejects runtime-ID, project-version, file-list, length, and
  content tampering.
- `state\active-generation\<20-digit>.json` is the only new active selector.
  New installs never write `active.json`; legacy `active.json` remains read-only
  migration input.
- Transaction snapshots have exact fields and types, strict positive integer
  generations, bounded safe reads, contiguous phases, immutable identity, and
  rejection for unknown objects, reparse points, ADS, multilinks, competing
  nonterminal chains, duplicate/gapped/post-terminal chains, and ambiguous
  terminal selection.
- Initial settings, status, verified packages, transition, and UI preference
  evidence is create-only and generation-bound. The operational state plane is
  separately created only when entirely absent and remains writable; the tests
  perform real StateStore and UI write/read round trips without changing file
  attributes.
- Pre-pointer failures retain the failed candidate and leave the old pointer
  and legacy root bootstrap/uninstaller bytes unchanged. Post-pointer failures
  either append a higher compensation pointer to the retained old runtime and
  prove it ready, or persist exactly
  `Failed/CCOD_INSTALL_ROLLBACK_FAILED`. Both generations remain retained.
- Stable shell candidates remain inside the immutable runtime generation. The
  scheduled-task adapter is updated only after pointer commit and targets that
  generation's bootstrap. There is no root shell overwrite or install-hot-path
  recursive runtime deletion.
- Idempotence/conflict decisions require an explicit canonical
  `SealedPackageSha256`. A legacy/direct call that omits it cannot claim package
  identity and follows the normal unique-generation path; Task 3 Setup must
  always pass the sealed package hash.
- Task 1 file-layer modules are imported lazily without `-Force` only when an
  immutable install operation is actually invoked. This preserves the staged
  uninstall module import closure and avoids rebinding a live Task 1
  transaction.

## Concerns

- The current-user ordinary-race boundary remains unchanged: this does not
  claim protection from an unrestricted same-user writer or in-process module
  introspection.
- The pre-Task-3 activation owner still consumes the legacy single receipt in
  its synthetic compatibility tests. Task 3 owns migration of the sealed Setup
  bootstrap/validator to the create-only receipt chain and must pass the
  canonical package identity explicitly.
- Failed and superseded generations intentionally consume disk until a
  separately proven maintenance/uninstall reclamation path runs.

## Commit

- `fix: commit lifecycle through immutable generations` (this Task 2 commit)

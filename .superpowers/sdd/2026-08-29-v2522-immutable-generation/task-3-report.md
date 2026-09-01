# Task 3 report: sealed Setup package and temporary bootstrap

## Status

Implemented the Task 3 sealed installer package and no-`{app}` Setup bootstrap.
Setup now embeds exactly four `dontcopy` inputs, retains package/manifest/
bootstrap locks across activation and validation, and accepts success only from
the same temporary bootstrap's strict append-only `Ready` validation.

No release build, installation, product process control, external service,
WindowsApps access, DPAPI access, signing, push, tag, or publication occurred.

## RED evidence

The following REDs were observed in order. Obsolete-test REDs are identified
separately from production defects so they are not mistaken for regressions.

- `ReleaseWorkflow.SelfTest.ps1` exited `1` because
  `build\InstallerPackage.psm1` did not exist.
- After the package matrix went GREEN, ReleaseWorkflow exited `1` because the
  production ISS lacked `CreateAppDir=no` and still exposed the old `{app}`
  product-copy contract.
- Expected obsolete-contract REDs then identified old destination-inventory,
  `{app}\payload`, direct portable-launcher, recursive/reparse-gate, shortcut,
  icon, uninstall, installed-validation, and legacy receipt assertions. They
  were replaced with Task 3 no-product-write and append-only assertions; no
  production compatibility fallback was added.
- The first real sealed-package ISCC compile exited `2` with
  `Unknown identifier 'CreateGuid'`; the compiled path now uses the proven
  `CoCreateGuid` / `StringFromGUID2` contract.
- PE validation REDs exposed Inno version-string field truncation for full
  64-character manifest/bootstrap hashes. The final PE contract binds each as
  exact 32+32 fields and independently recomposes both hashes.
- The first real package-to-bootstrap execution returned
  `CCOD_INSTALLER_PACKAGE_INVALID`. The cause was compact PowerShell text such
  as `return[pscustomobject]` and `throw'CODE'` being parsed as command names.
  The syntax was corrected and the same real test then passed.
- The Setup provenance RED failed because the old schema bound only the payload
  manifest. Schema 2 now records and revalidates package, package-manifest, and
  bootstrap hashes plus canonical build inputs and the PE split contract.
- `InstallLifecycle.SelfTest.ps1` REDs identified the pre-Task-3 mutable
  `state\post-install-activation.json` fixtures. Ready, Failed, and progress
  fixtures now use separate append-only leaves. A correlated nonterminal leaf
  returns `CCOD_ACTIVATION_RECEIPT_NOT_READY`; no receipt returns
  `CCOD_ACTIVATION_RECEIPT_MISSING`; conflicting terminal leaves fail closed.

## Implemented behavior

- `New-CcodInstallerPackage` creates one ZIP containing exactly the
  manifest-listed payload plus `installer-payload.manifest.json` and emits a
  canonical package manifest bound to version and 40-hex commit.
- `Test-CcodInstallerPackage` rejects missing, extra, duplicate,
  case-colliding, unsafe, length-changed, content-changed, version-changed,
  commit-changed, package-hash-changed, and manifest-hash-changed inputs.
- `build.ps1` creates and immediately revalidates the sealed package, binds the
  package, manifest, and bootstrap hashes into generated ISCC input, and uses
  schema-2 sealed Setup provenance.
- The ISS has `CreateAppDir=no`, `Uninstallable=no`, no product `[Files]`
  destination, and no `[Icons]`, `[Registry]`, `[UninstallRun]`, recursive
  extraction, legacy shortcut deletion, or `{app}` bootstrap execution.
- Inno extracts four named temporary inputs, hashes/locks/rehashes package,
  manifest, and bootstrap, executes that exact bootstrap path, then invokes it
  again with `-ValidateReceiptOnly` while the locks remain held.
- The bootstrap validates and extracts only the ZIP manifest entry set into a
  fresh private root, passes the exact package SHA-256 as
  `-SealedPackageSha256`, and validates only append-only activation receipts.
- A real disposable test proves package -> temporary bootstrap -> child hash
  propagation and append-only Ready. A separate replacement barrier proves
  locked original bootstrap bytes, not replacement bytes, are executed.

## GREEN and verification evidence

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1`
  exited `0`; final output: `Release workflow self-tests passed.` The suite
  includes a real Inno Setup 6.7.3 production-script compile.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  exited `0`; final output: `Install lifecycle self-tests passed: 113`.
- Explicit PowerShell parser validation passed all eight changed `.ps1`/
  `.psm1` files (`PARSER_COUNT=8`).
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were emitted.
- Static boundary audit reported `BOUNDARY_VIOLATIONS=0` for pre-Ready `{app}`
  writes, product sections, recursive extraction, old app bootstrap execution,
  Setup mode, and mutable receipt-reader authority.
- The full aggregate was not requested by the Task 3 brief and was not run; no
  aggregate-pass claim is made.

## Boundaries and remaining work

- Task 4 still owns post-Ready uninstall registration, shortcuts, icons, and
  exact legacy registration/shortcut migration.
- Task 5 still owns Defender scanning and the final exact public asset contract.
- The current-user ordinary-writer boundary and retained-generation disk-use
  boundary from Tasks 1-2 are unchanged.

## Commit

- `fix: bootstrap sealed installer package` (the Task 3 commit containing this
  report; resolve the exact object as this worktree's Task 3 HEAD).

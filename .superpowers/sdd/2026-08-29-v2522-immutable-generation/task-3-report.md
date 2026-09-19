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

- Initial implementation commit:
  `9e1c41c72d296c2d0c014a45561a855699ebd39b`
  (`fix: bootstrap sealed installer package`).

## Fix round 1: portable identity, exact provenance, and executed Setup proof

### Review findings and RED evidence

Scoped review of `46692e7..9e1c41c72d296c2d0c014a45561a855699ebd39b`
failed with four Important findings.

- Portable identity RED: `ReleaseWorkflow.SelfTest.ps1` exited `1` because
  `Invoke-CcodPortableLifecycleInstaller` did not exist. The portable wrapper
  revalidated its manifest after Defender but discarded that result and called
  `Install-CodexControlOtherDevices.ps1` without `-SealedPackageSha256`.
- Exact provenance RED: the new schema-two mutation matrix exited `1` with
  `ASSERT_THROWS: expected CCOD_SETUP_PROVENANCE_INVALID`. The validator
  accepted altered nested evidence because it did not require every property
  order/type/name/length/count/hash.
- Executed Setup RED: the deliberately wrong-package-hash production Setup
  compiled successfully and executed its real temporary input path, but the
  test observed exit `0`. Its runtime log proved the hash gate did run:
  `CurStepChanged raised an exception` with
  `CCOD_SETUP_INPUT_BINDING_INVALID`; Inno defaulted the suppressed error box
  to OK and still returned success.
- Report RED: the initial report said only “Task 3 HEAD”, which did not provide
  an immutable 40-hex object identity.

### Remediated behavior

- Portable now retains both the initial and post-Defender verified
  `PayloadManifestSha256`, requires an exact canonical match before invoking
  the lifecycle child, and passes that value explicitly as
  `-SealedPackageSha256`. A changed canonical identity fails with
  `CCOD_PORTABLE_PACKAGE_IDENTITY_INVALID` before the child marker can run.
- `Test-CcodSealedSetupBuildProvenance` requires exact ordered top-level and
  nested schemas, JSON types, artifact names, actual lengths and SHA-256s,
  manifest `fileCount` and `payloadManifestSha256`, canonical version/commit/
  timestamp, compiler/template/inventory identity, and the complete split PE
  contract. Twenty-four independent mutations are rejected.
- The same `ExtractAndLockCcodInputs` gate now runs from `PrepareToInstall`.
  A nonempty error uses Inno's actual install-failure contract; `CurStepChanged`
  consumes only the three already-held verified handles. The executed
  wrong-hash fixture exits nonzero, records
  `CCOD_SETUP_INPUT_BINDING_INVALID`, never runs its inert activation marker,
  creates no `/DIR` app output, and never logs the real LocalAppData product
  root.

### GREEN and verification evidence

- Final `ReleaseWorkflow.SelfTest.ps1`: exit `0`, including the portable exact
  identity test, 24-case provenance mutation matrix, real production ISCC
  compile, and bounded wrong-hash Setup execution.
- Final `InstallLifecycle.SelfTest.ps1`: exit `0`;
  `Install lifecycle self-tests passed: 113`.
- Explicit parser checks passed all four changed PowerShell code/test files.
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were emitted.
- Static no-`{app}` boundary audit reported `FIX1_BOUNDARY_VIOLATIONS=0`.
- No aggregate run was performed in this fix round; no aggregate-pass claim is
  made.
- No release build, real install, product process control, external service,
  WindowsApps, DPAPI, signing, push, tag, or publication action occurred.

### Exact implementation commit

- `51def5c9ae2f5e0722b9083e478b17c507e9cee8`
  (`fix: harden sealed setup evidence`).

## Fix round 2: copied portable identity and raw evidence binding

### Review findings and RED evidence

Scoped review of
`9e1c41c72d296c2d0c014a45561a855699ebd39b..728b62710c0729b40908e92887d3fe70903edbba`
remained FAIL with three Important findings.

- Copied portable identity RED: `ReleaseWorkflow.SelfTest.ps1` exited `1`
  with `NamedParameterNotFound` for `CopiedSealedPackageSha256`. The wrapper
  still used a source identity and `Copy-CcodPortablePayload` returned its
  pre-copy manifest result rather than an identity revalidated from the
  published target.
- Raw provenance RED: a top-level duplicate `schemaVersion` member remained
  accepted because Windows PowerShell `ConvertFrom-Json` collapsed it before
  the parsed-object exact-schema checks.
- Product-state evidence RED: the executed wrong-hash Setup fixture exited `1`
  because `Get-CcodReadOnlyProductTreeSnapshot` did not exist. The prior test
  checked only its isolated `/DIR`, marker, and log rather than comparing the
  actual current-user product root.

### Remediated behavior

- `Copy-CcodPortablePayload` now validates the moved published installer tree
  and returns that copied manifest identity. The portable wrapper requires the
  initial source, post-Defender source, and copied identities to be the same
  canonical SHA-256, and only the copied value reaches the lifecycle child.
- A production-module breakpoint regression changes source bytes exactly
  between manifest validation and `File.Copy`. Destination rehashing returns
  `CCOD_PORTABLE_COPY_HASH_MISMATCH`; no installer root, lifecycle child, or
  lifecycle state becomes visible.
- A bounded raw JSON scanner walks objects and arrays before any provenance or
  package-manifest `ConvertFrom-Json`, decodes escaped property names, rejects
  duplicate semantic member names at every depth, and enforces 1 MiB / depth
  32 limits. Duplicate mutations at the top level and all five nested
  provenance objects fail with `CCOD_SETUP_PROVENANCE_INVALID` while the prior
  24 exact-schema mutations remain covered.
- The wrong-hash production Setup fixture now snapshots the exact LocalAppData
  product root before and after execution. The read-only snapshot manually
  traverses without following reparse points, rejects alternate streams, is
  bounded to 8192 entries / 256 MiB per file / 1 GiB total, and records root/
  directory metadata plus file metadata and SHA-256. Before and after canonical
  snapshots are identical. Fixture cleanup still targets only its unique temp
  root and never creates, modifies, or removes the real product root.

### GREEN and verification evidence

- Final `ReleaseWorkflow.SelfTest.ps1`: exit `0`, including copied-identity,
  full copy-race, six-level raw duplicate, and actual product-tree snapshot
  coverage.
- Final `InstallLifecycle.SelfTest.ps1`: exit `0`;
  `Install lifecycle self-tests passed: 113`.
- Explicit parser checks passed all four changed PowerShell code/test files.
- `git diff --check` exited `0`; only checkout LF-to-CRLF warnings were emitted.
- Static no-`{app}` audit reported `FIX2_BOUNDARY_VIOLATIONS=0`.
- No aggregate run was performed in this fix round; no aggregate-pass claim is
  made.
- No release build, real install, product-process control, external service,
  WindowsApps, DPAPI operation, signing, push, tag, or publication occurred.

### Exact implementation commit

- `1cb91621f2565318143dffe08844a91a350a36d9`
  (`fix: bind portable sealed execution`).

## Fix round 3: actual portable entrypoint race evidence

### Review finding and RED evidence

Scoped review of
`728b62710c0729b40908e92887d3fe70903edbba..a5d595892f134a5ef957feab4ec4e68228cec97b`
remained FAIL with one Important test-compliance finding. The race test invoked
`Copy-CcodPortablePayload` directly inside the module and therefore did not
prove that the real `Install-CodexRemote-fix.ps1` control flow stopped before
its child and lifecycle boundaries. This review failure is the RED evidence;
the production post-Defender revalidation behavior itself did not require a
code change.

### Remediated evidence

- The replacement fixture copies the production
  `Install-CodexRemote-fix.ps1` byte-for-byte and asserts the copy hash before
  invoking that actual script path.
- It uses the production `PortableRelease.psm1`, a valid manifest, and an
  isolated child installer that would create both a marker and fixture
  lifecycle directory if execution reached it.
- Test-local Defender commands remain entirely inside the fixture process.
  `Start-MpScan` changes the child source after the entrypoint's initial
  manifest validation and before its copy boundary.
- The actual entrypoint returns `CCOD_PORTABLE_MANIFEST_INVALID` from its
  post-Defender `Test-CcodPortablePayloadManifest` call. Only after it returns,
  the test proves the marker and fixture lifecycle root are both absent.
- The helper identity test remains as unit coverage, but no helper-only race
  test is claimed as end-to-end evidence.

### GREEN and verification evidence

- Final `ReleaseWorkflow.SelfTest.ps1`: exit `0`; the named actual-entrypoint
  validation-to-copy race case passed.
- Final `InstallLifecycle.SelfTest.ps1`: exit `0`;
  `Install lifecycle self-tests passed: 113`.
- The changed PowerShell test file parsed with zero errors (`1/1`).
- `git diff --check` exited `0`; only the checkout LF-to-CRLF warning was
  emitted.
- No aggregate run was performed in this fix round; no aggregate-pass claim is
  made.
- No external release, push, tag, signing, install, product-process,
  WindowsApps, or DPAPI action occurred.

### Exact implementation commit

- `58bd7603fa83133d78d2f62ac045ec00d25134c9`
  (`test: exercise portable sealed race end to end`).

## Fix round 4: final portable copy-barrier evidence

### Review finding and RED evidence

Scoped review of
`a5d595892f134a5ef957feab4ec4e68228cec97b..9e971d1fe26c0f60d8e8519318c11006798dc493`
remained FAIL with one Important test-compliance finding. The actual-entrypoint
fixture changed its child during the mocked Defender gate, so the production
post-Defender manifest revalidation returned
`CCOD_PORTABLE_MANIFEST_INVALID`; it did not exercise the later validated
source-to-`File.Copy` barrier.

The unfinished fix-round-4 test was run before completion. The full
`ReleaseWorkflow.SelfTest.ps1` exited `1` in
`actual portable entrypoint rejects the final File.Copy barrier race before
child or lifecycle state`: its
`CCOD_PORTABLE_COPY_HASH_MISMATCH` assertion failed because the fixture never
performed the intended source mutation and `SourceMutated` remained false.
This was the expected RED for the missing test-local copy-boundary condition.

### Remediated evidence

- The fixture invokes a byte-identical temporary copy of the production
  `Install-CodexRemote-fix.ps1` and uses a byte-identical temporary copy of the
  production `PortableRelease.psm1`; both identities are asserted before the
  entrypoint runs.
- The existing test-local entrypoint breakpoint redirects only the module's
  private expected-installer-root function to a new disposable fixture root.
  No public production parameter or externally reachable test switch was
  added.
- The manifest order is asserted so the marker-capable child reaches the first
  production payload copy boundary. A breakpoint on the copied module's unique
  ordinary `[IO.File]::Copy($sourceFile,$destination,$false)` line writes
  distinct child text after the module has validated its source record and
  immediately before that production copy executes.
- The production copy and destination SHA-256 comparison then run unchanged
  and return `CCOD_PORTABLE_COPY_HASH_MISMATCH`. Only after the actual
  entrypoint returns does the test prove that the child marker, fixture
  lifecycle/install root, and published fixture installer root are all absent.
- The separate post-Defender source-revalidation fixture remains intact and
  continues to cover its earlier `CCOD_PORTABLE_MANIFEST_INVALID` boundary.

### GREEN and verification evidence

- Final `ReleaseWorkflow.SelfTest.ps1`: exit `0`; final output
  `Release workflow self-tests passed.` The actual-entrypoint final
  `File.Copy` barrier case passed.
- Final `InstallLifecycle.SelfTest.ps1`: exit `0`; final output
  `Install lifecycle self-tests passed: 113`.
- The changed PowerShell test file parsed with zero errors (`1/1`).
- `git diff --check` exited `0`; only the checkout LF-to-CRLF warning was
  emitted.
- No aggregate run was performed in this fix round; no aggregate-pass claim is
  made.
- No real installer, network, external action, listener, product process
  control, release, push, tag, signing, install, WindowsApps, or DPAPI action
  occurred. All new runtime files were temporary fixture files below a unique
  disposable root.

### Exact implementation commit

- `141ab716001e7c1048db10e248101fa8cd3f54ae`
  (`test: exercise portable copy barrier race`).

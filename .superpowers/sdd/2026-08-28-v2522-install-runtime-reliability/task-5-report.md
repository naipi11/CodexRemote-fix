# Task 5 report — v2.5.22 release metadata, documentation, and contract

## Scope and safety boundary

- Worktree: `C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`
- Starting reviewed HEAD: `1d6bd1f` (`docs: record tray trace gate bypass fix`)
- Implemented only release metadata, native build/artifact version verification,
  release-coupled tests, stable README release references, CHANGELOG notes, and
  deterministic GitHub release-note extraction.
- Did not install or run the installer, start a real Codex/UI process, stop the
  real Supervisor/TrayHost, publish, push, sign, tag, or write WindowsApps/DPAPI.

## TDD evidence

### Release version contract RED

After changing only the ReleaseWorkflow contract to require v2.5.22:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
exit 1
ASSERT_EQUAL: package metadata is the 2.5.22 release
expected=[2.5.22] actual=[2.5.21]
```

All preceding release gates, including real ISCC compilation, had passed. This
proved the new contract failed for the intended missing release metadata.

### Native static-metadata gate RED

The next test called the real TrayHost/portable build entrypoints against
controlled package, AssemblyInfo, and manifest mismatches before production
changes:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostBuild.SelfTest.ps1
exit 1
expected=[CCOD_TRAYHOST_VERSION_MISMATCH]
actual=[CCOD_TRAYHOST_SOURCE_MISSING]
```

This proved a requested version mismatch was not rejected before compiler input
resolution.

### Artifact manifest and PE version RED

A real compiled TrayHost artifact was validated against a copied repository
contract. The test changed the manifest and then aligned package/static
metadata/provenance to a false `9.9.9` while retaining the original PE:

```text
exit 1
expected=[CCOD_TRAYHOST_VERSION_MISMATCH|CCOD_TRAYHOST_ARTIFACT_VERSION_INVALID]
actual=[|]
```

The old validator accepted both mutations. The final mutation coverage also
changes valid-version manifest bytes without changing the identity, proving the
manifest SHA binding independently.

### Release-note extraction RED/GREEN

The behavior test first failed because the workflow extractor did not exist.
After the tool was added, a CRLF fixture produced a second intentional RED
because the target English section retained CRLF bytes. The final extractor
normalizes output to LF and emits only the exact target English section; the
test excludes Unreleased, newer-version, Chinese, and older-version decoys.

## Implementation

### Version sources

- `package.json`: `2.5.22`
- TrayHost AssemblyVersion/FileVersion and Windows manifest: `2.5.22.0`
- Portable launcher AssemblyVersion/FileVersion and Windows manifest:
  `2.5.22.0`

Historical CHANGELOG entries and non-release presentation/runtime fixtures
remain unchanged. In particular, the TrayHost native `2.5.21` strings are
acknowledged-presentation test inputs, `InstalledLifecycleHarness` uses
`2.5.21-new` runtime fixtures, and ReleaseWorkflow retains an intentional old
payload/structural workflow fixture.

### Fail-closed native build and artifact verification

`build/TrayHostBuild.psm1` now:

- requires requested `-Version` to match `package.json`;
- requires exactly one matching AssemblyVersion and AssemblyFileVersion;
- parses the Windows assembly manifest and requires the exact identity name,
  `win32` type, and `<version>.0` value;
- applies that contract to both TrayHost and portable build entrypoints before
  compiler/reference resolution;
- reads the compiled PE FileVersion and ProductVersion and requires exact
  `<version>.0` values before publishing either artifact;
- makes `Test-CcodTrayHostArtifact` repeat the static contract, bind the source
  manifest/config hashes from provenance, and reject PE version drift.

Regression cases independently mutate package version, AssemblyVersion,
AssemblyFileVersion, manifest version, manifest bytes, provenance/static
version, and PE version relationship.

### Documentation and release notes

- README/README.zh-CN now name v2.5.22 only in the stable status, Quick Start,
  and release-asset descriptions; no What's new block or internal error code
  was added.
- Removed the English README's literal `\r\n` text.
- Corrected the asset contract: portable publishes its payload manifest as an
  external asset; Setup embeds and hash-binds its versioned
  `installer-payload.manifest.json`.
- CHANGELOG has four concise v2.5.22 English bullets followed by Chinese notes.
- `.github/workflows/release.yml` calls the behavior-tested
  `tools/New-GitHubReleaseNotes.ps1`, so the GitHub body contains only the
  requested release's English section.

## Verification before primary commit

```text
TrayHostBuild.SelfTest.ps1
  exit 0; 8 cases

ReleaseWorkflow.SelfTest.ps1
  exit 0; all cases, including real ISCC, real TrayHost PE validation,
  CRLF-to-LF English-only release notes, and v2.5.22 documentation contract

Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
  exit 0; 3 production child-session trace cases

Invoke-TrayHostSelfTest.ps1 -NativeOnly
  exit 0; 25 native fake-platform cases

PowerShell AST parse
  exit 0; TrayHostBuild module, three release-coupled test scripts,
  and New-GitHubReleaseNotes.ps1

version audit
  package=2.5.22
  tray Assembly/File/manifest=2.5.22.0
  portable Assembly/File/manifest=2.5.22.0
```

### InstallLifecycle environment boundary

The full requested test was run without stopping the real Supervisor:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
exit 1 after approximately 67 seconds
case=transactional-uninstall-reaches-ReadyForInno-only-after-recovery-protection-stop-task-proof-and-application-removal
error=CCOD_LIFECYCLE_LEASE_TIMEOUT
message=Lifecycle ownership mutex timed out
```

That failing case begins at line 1876. The v2.5.22 release-coupled builder case
begins at line 2588, so it was not reached and is not reported as passing. No
mutex bypass or real Supervisor stop was attempted. `npm test` / aggregate
Validate were not run because they would recurse into the same known live
mutex boundary, contrary to the task's safety constraint.

## Clean release build

The primary release commit was created as:

```text
49f88e2 release: prepare CodexRemote-fix v2.5.22
```

From that clean HEAD, the normal release workflow completed:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 -Version 2.5.22
exit 0
```

Generated assets remained under `build/dist` only:

```text
CodexRemote-fix-2.5.22-windows-x64.zip
  55d0b0e383faa208f0795dbeb6b2ae01051807fdd2d40ddea115951ae6fae02b
CodexRemote-fix-2.5.22-setup.exe
  298dd4c821b83df3bcca32ffe0193bcaa55eff1ddcdf3115680198c635d668a0
CodexRemote-fix-2.5.22-payload-manifest.json
  08cbbd5eb0093b15d461f42912e1395cf2c90da0c1da503b41b9bda1293b2492
CodexRemote-fix-2.5.22-release-manifest.json
  e313e9943888f3b346d20f7d6627fbf60254de40c6518d47e7c3ba46bd6fd18e
CodexRemote-fix-2.5.22-setup-release-manifest.json
  b7a95f58b0cb3178a3a2e7d208b5ba931c2fe7d391970ec297c1b8c70db17579
CodexRemote-fix-2.5.22-trayhost-provenance.json
  95bc8535ba54b4a0bfc4356fd4162e71800b599b0a1b42476c0ce9912ab0ac40
```

Both release manifests passed `Test-CcodReleaseAssetManifest` for expected
version `2.5.22`; portable reported distribution `portable-zip`. Both manifests
and TrayHost provenance bound commit
`49f88e2bd511a0f98ce93f48967e4cf3a333f93b`. The generated TrayHost and
portable PE FileVersion/ProductVersion values were all `2.5.22.0`.

The installer was compiled but never executed. No asset was installed,
published, pushed, signed, or tagged. A post-build documentation precision fix
corrected the actual embedded filename from the design spelling
`installer-payload-manifest.json` to the implementation spelling
`installer-payload.manifest.json`; therefore these local artifacts are retained
as build evidence and must not be treated as immutable publish candidates for
the follow-up documentation HEAD without a fresh clean rebuild.

## Remaining acceptance boundary

- A real setup install/upgrade, reboot, remote connection, About/language/logs,
  repair, and Defender outcome remain outside this Task 5 local build scope.
- Independent parent review remains required before any tag, push, publish,
  signing, or installation decision.

## Fix round 1 — portable artifact verification and release-note body

Independent review found two Important gaps: the freshly compiled portable
launcher was copied into the payload without an artifact validator analogous to
TrayHost, and the GitHub notes extractor synthesized an H1 instead of returning
only the selected English section body.

### RED evidence

The portable regression was added before production code and called the wished-
for validator against a real compiled launcher:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostBuild.SelfTest.ps1
exit 1
Test-CcodPortableLauncherArtifact is not recognized
```

The release-note expectation was independently changed to the exact English
body with one LF, producing:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
exit 1
expected=[- Target English note.\n- Second target English note.\n]
actual=[# CodexRemote-fix 2.5.22\n\n- Target English note.\n- Second target English note.\n]
```

### Implementation

`Test-CcodPortableLauncherArtifact` now revalidates:

- requested version against package, portable AssemblyInfo, and the portable
  Windows manifest;
- PE FileVersion and ProductVersion;
- schema/product/version/framework/reference-pack, exact commit, and canonical
  timestamp provenance;
- exact `PortableLauncher.cs` and `AssemblyInfo.cs` source name/hash set;
- icon, manifest, source config, executable, and artifact config hashes.

`build/build.ps1` invokes that validator immediately after portable compilation
and before the first portable EXE/config/provenance copy into the payload. The
tamper regression changes commit, timestamp, every required hash class, source
hashes, and a fully aligned false static/provenance version whose PE remains
2.5.22.0.

`New-GitHubReleaseNotes.ps1` now writes only the normalized target English body
with exactly one trailing LF. The GitHub release title remains the workflow's
separate `gh release create/edit --title` responsibility.

### GREEN evidence and boundary

```text
TrayHostBuild.SelfTest.ps1
  exit 0; 8 cases including portable validator tamper coverage

ReleaseWorkflow.SelfTest.ps1
  exit 0; English-body-only extraction and build-before-copy validator order
```

No formal release build, installer execution, install, publish, push, tag,
signing, or real Codex/UI operation was performed in this fix round. The final
fresh clean release build remains gated on scoped independent re-review.

## Fix round 2 — CRLF-stable release-note fixture

Final-candidate validation on a clean CRLF checkout exposed a test portability
defect. The fixture already contained CRLF, but the test blindly replaced every
LF with CRLF, producing CRCRLF. The real extractor then correctly rejected the
malformed heading boundary:

```text
ReleaseWorkflow.SelfTest.ps1
exit 1
CCOD_RELEASE_NOTES_RELEASE_SECTION_INVALID
```

A focused local reproduction independently confirmed the old expression:

```text
CRCRLF_REPRODUCED=True
```

The fixture now normalizes CRLF and lone CR to LF before converting LF to CRLF.
This preserves the intended CRLF-input coverage on LF, CRLF, and mixed-line-
ending checkouts without changing production extraction behavior.

Fresh GREEN evidence:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
exit 0
Release workflow self-tests passed.
```

No build, installer execution, install, publish, push, tag, or signing occurred
in this fix round.

## Fix round 3 — current portable branding regression

The final controlled isolated `npm test` reached
`InstallLifecycle.SelfTest.ps1:2942` and produced the expected RED in
`README and release workflow publish current portable-release branding`. The
release-coupled regression still required v2.5.21 setup/ZIP names at lines
2949/2950/2957/2958 and the retired inline
`englishSection = [regex]::Match` implementation at lines 2971/2972.

The regression now requires the v2.5.22 setup and portable asset names in both
Quick Start sections. It preserves the public GitHub release title assertion,
requires workflow use of `tools\New-GitHubReleaseNotes.ps1`, and rejects a
second inline English extractor. The missing-English boundary is exercised
against the real tool with a controlled changelog and requires
`CCOD_RELEASE_NOTES_ENGLISH_SECTION_INVALID` with no notes output.

Local bounded verification:

```text
PowerShell AST parse of InstallLifecycle.SelfTest.ps1
  exit 0

git diff --check
  exit 0
```

The local full InstallLifecycle suite was not represented as GREEN because the
normal desktop environment retains the earlier real-Supervisor lifecycle mutex
boundary. The parent will rerun the controlled isolated aggregate after scoped
re-review. No build, installer execution, install, publish, push, tag, release,
or signing occurred in this fix round.

## Final security-fix wave — exact activation bytes, hard-link leaves, and Setup proof

### Scope and safety boundary

- Started from clean reviewed head `31fd365` in the named v2.5.22 worktree.
- Preserved package/native version `2.5.22` / `2.5.22.0`, the authenticated
  TrayHost protocol, receipt architecture, and existing CI/trace gates.
- Did not execute an installer, install or upgrade the product, start or stop
  real Codex/TrayHost/Supervisor/UI processes, publish, push, tag, sign, or
  read/write WindowsApps or DPAPI device-key data.

### RED evidence

#### Exact activation bytes

A real cross-process barrier supplied a test-only `powershell.exe` wrapper.
The wrapper stopped after the activation parent verified the payload and before
the child interpreter ran. The test then replaced the accepted manifest,
installer, and lifecycle module. The old pathname flow returned success but
proved that it parsed/executed the replacements:

```text
ReleaseWorkflow.SelfTest.ps1
exit 1
case=activation-executes-only-the-verified-manifest-installer-and-module-bytes-across-the-child-launch-barrier
expected=[original:2.5.22]
actual=[replacement:9.9.9]
```

No production test flag, environment switch, listener, or unauthenticated
control input was added.

#### Hard-linked install leaves

The lifecycle regression created an outside sentinel and hard-linked each
stable target leaf in turn. The old copy path did not reject either target:

```text
InstallLifecycle.SelfTest.ps1
exit 1
case=stable-bootstrap-and-public-uninstaller-reject-hard-linked-target-leaves-before-outside-bytes-change
ASSERT_THROWS: expected CCOD_INSTALL_UNSAFE_LEAF
```

A separately compiled and safely executed Inno predicate fixture placed a hard
link inside the existing Setup tree. The old `IsSafeExistingSetupTree` accepted
the leaf, reached the simulated overwrite, and therefore did not write the
fixture's success receipt (`result.txt` missing).

#### Independent Setup artifact and provenance

The real-ISCC artifact test was added before its validator:

```text
ReleaseWorkflow.SelfTest.ps1
exit 1
case=compiled-Setup-independently-binds-PE-versions-commit-and-activation-payload-manifest-hash
ASSERT_TRUE: independent Setup artifact validator exists
```

After the validator API existed, the setup release fixture added the required
setup-provenance asset before the release validator changed. The old validator
then failed its exact asset contract, proving the provenance was not yet part
of the accepted release:

```text
CCOD_RELEASE_MANIFEST_INVALID
Release manifest does not bind the exact required asset set
```

#### Failure cleanup

The cleanup regression injected a deterministic exception after creating the
exact GUID-named installer payload stage and destination inventory. It first
failed because the production finally scope did not exist:

```text
ASSERT_TRUE: build exposes its production temporary Setup scope
```

### Implementation contract

#### Activation byte sealing

- The activation parent opens the compile-bound manifest once, hashes and
  parses the same byte array, and opens every current manifest record with
  read-only/no-write/no-delete sharing.
- It writes only those verified byte arrays into a unique sibling stage,
  rehashes each staged leaf, and holds read handles for the entire child
  lifetime. Original payload path replacement after the barrier cannot change
  the child's inputs.
- The child independently opens and holds the staged manifest/records, hashes
  and parses the same manifest bytes, verifies exact version/package/file set,
  and only then imports `InstallLifecycle.psm1`.
- Lifecycle receives the accepted manifest as Base64 exact bytes plus the
  expected SHA-256; it does not reopen the accepted manifest pathname for JSON
  parsing. Existing final Ready pointer/runtime-manifest/version proof remains.

#### Hard-link-safe leaves

- Lifecycle now uses `CreateFileW` plus `GetFileInformationByHandle` and
  requires `NumberOfLinks == 1`, regular/non-reparse shape, no alternate data
  streams, and canonical install-root containment before/after copies.
- Production copy writes a fresh same-directory temporary leaf and uses a
  namespace replace/move, avoiding in-place mutation of an existing inode.
- Stable `bootstrap.ps1`, the public uninstaller, staged runtime leaves,
  runtime manifest, and recursively deleted install trees use the same leaf
  contract.
- Inno `PrepareToInstall` recursively checks every existing Setup leaf with
  native handle link count plus stream enumeration before `[Files]` writes.

#### Independent Setup artifact/provenance

- `build/SetupArtifact.psm1` verifies final Setup PE `FileVersion` and
  `ProductVersion` equal `<Version>.0`.
- The final PE version resource independently binds product/version, the exact
  40-hex source commit, and the exact 64-hex installer payload-manifest SHA-256.
  The negative test reuses the same final EXE with a mismatched expected hash
  and requires `CCOD_SETUP_PAYLOAD_BINDING_INVALID`; no textual binary scan is
  claimed.
- `CodexRemote-fix-2.5.22-setup-provenance.json` records canonical
  version/commit/timestamp, payload manifest name/length/hash/file count, Inno
  template and inventory hashes, ISCC hash/version, and the expected PE
  resource contract. It is embedded as a `dontcopy` Setup source and published
  as an explicit release asset.
- The setup release manifest hash-binds Setup, checksum, TrayHost provenance,
  and Setup provenance. `Test-CcodReleaseAssetManifest` revalidates provenance
  plus the final PE and rejects asset or metadata tampering.
- Provenance validation reads the raw canonical timestamp representation and
  accepts the JSON integer types produced by both Windows PowerShell 5.1 and
  pwsh 7.

#### Cleanup and documentation

- The installer payload stage and destination inventory now live inside one
  exact `try/finally` scope. Cleanup requires the build-root parent, exact GUID
  leaf pattern, expected file/directory kind, and a reparse-free tree.
- README and README.zh-CN now call v2.5.22 a release candidate and explicitly
  leave stable Windows acceptance pending real install/upgrade/reboot/repair/UI/
  Defender evidence. No What's-new block was added.

### GREEN and regression evidence

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
exit 0
Release workflow self-tests passed.
  includes real ISCC compilation, activation swap barrier, Inno hard-link
  fixture, Setup PE positive/negative proof, failure cleanup, and release
  provenance validation

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly
exit 0; 3 production child-session trace cases

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -NativeOnly
exit 0; 25 native fake-platform cases

PowerShell AST parse of all modified .ps1/.psm1 files
exit 0

git diff --check
exit 0
```

The lifecycle suite passed the new activation/hard-link cases and continued to
the already documented live-Supervisor boundary. It was not reported green:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
exit 1
case=transactional-uninstall-reaches-ReadyForInno-only-after-recovery-protection-stop-task-proof-and-application-removal
error=CCOD_LIFECYCLE_LEASE_TIMEOUT
```

No mutex bypass and no real Supervisor stop was attempted.

### Clean-head build evidence

Normal build from clean implementation head
`1f4259f7003d29d1023a567d15c877c22dfabd6c`:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 -Version 2.5.22
exit 0
TEMP_SETUP_INPUT_COUNT=0
```

Both Windows PowerShell 5.1 and pwsh 7 independently returned
`portable=True` and `setup=True`. Setup FileVersion/ProductVersion were both
`2.5.22.0`; portable/setup release manifests and Setup provenance all bound
commit `1f4259f7003d29d1023a567d15c877c22dfabd6c`. The embedded activation
payload-manifest SHA-256 was
`e03753640f65f28aebdf46eb113f8ad26317169cbfc424e1629a6795c752a4f1`.

Final retained build evidence hashes:

```text
CodexRemote-fix-2.5.22-windows-x64.zip
  a70419842a2509ae2035e6890474b3e7258d5f64682edb8813d6782adc1c299b
CodexRemote-fix-2.5.22-setup.exe
  5f650bc187112a5256f5a5b5d37972a6400cfe6e32586956830458adfc6b53e9
CodexRemote-fix-2.5.22-setup-provenance.json
  8f0d1973b69d440ca8dad699bb9065b3030ea4f455d757fc5278e706f6cc76e9
CodexRemote-fix-2.5.22-setup-release-manifest.json
  559fa329221fcd092356119b8b4aa8bf4562afe173a432ca4251969db5c4a9e6
```

Two earlier ignored artifact sets were preserved rather than deleted at:

```text
C:\Users\33384\AppData\Local\Temp\ccod-v2522-pre-final-security-build-0ff1f869906848418dc15e9ef89d5375
C:\Users\33384\AppData\Local\Temp\ccod-v2522-ca5a5f7-build-00f3b177a3974b02bee3fe3f99f2cbc0
```

### Commits and remaining acceptance boundary

```text
cb36d0b test: expose activation payload byte swap
ed782ec fix: seal activation bytes and reject linked leaves
ca5a5f7 fix: bind setup artifact provenance
1f4259f fix: validate setup provenance across hosts
```

- The compiled installer was never executed. Generated assets are unsigned,
  unpublished local evidence only.
- Real setup install/upgrade, reboot, remote connection, About/language/logs,
  repair, Defender, and controlled isolated aggregate acceptance remain
  pending. README intentionally does not call v2.5.22 stable.

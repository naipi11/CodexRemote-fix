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

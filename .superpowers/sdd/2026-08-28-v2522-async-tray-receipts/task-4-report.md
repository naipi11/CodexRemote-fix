# Task 4 report: fail-closed release trace and TrayHost provenance

## Outcome

Task 4 closes both release-boundary gaps without changing the TrayHost wire,
CLI, authentication, installer, version metadata, or installed runtime.

- CI job `validate` and release job `build` each contain exactly one step named
  `Run authenticated TrayHost production trace`, with `shell: pwsh` and the
  exact run value
  `./tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly`.
- The release trace is immediately before the asset-producing build step and
  structurally precedes the real PowerShell command
  `./build/build.ps1 -Version $version`.
- `Test-CcodTrayHostArtifact` now compares provenance with the exact current
  `src/trayhost/*.cs` name-to-SHA-256 set. Missing records, count differences,
  duplicate names, unexpected or case-different names, malformed hashes, and
  name/hash mismatches fail with `CCOD_TRAYHOST_SOURCE_TAMPERED`.
- The production validator never resolves a path supplied by provenance. It
  hashes the enumerated current sources first, stores them in an ordinal
  dictionary, and validates records against that bounded set.

Implementation commit:

```text
1743de6 test: gate release on tray receipt trace
```

## TDD RED evidence

### Release workflow gate

Only the structural release test had been changed when this command ran:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1
```

It exited 1 after all preceding release/manifest/Defender cases passed:

```text
CCOD_SELFTEST_FAILED case=CI-and-release-build-jobs-uniquely-gate-asset-production-on-the-authenticated-TrayHost-trace error=CCOD_RELEASE_TRACE_GATE_INVALID
CCOD_RELEASE_TRACE_GATE_INVALID
```

No workflow production file had been changed before this RED. Adding the exact
CI/release steps then made the same command exit 0.

### Exact source provenance

The provenance fixture and negative tests were added before changing
`build/TrayHostBuild.psm1`. The same required ReleaseWorkflow command exited 1:

```text
CCOD_SELFTEST_FAILED case=TrayHost-artifact-validation-requires-the-exact-compiled-source-name-and-hash-set error=ASSERT_THROWS
ASSERT_THROWS: expected CCOD_TRAYHOST_SOURCE_TAMPERED
```

The old verifier had accepted provenance with `TrayHostChildSession.cs`
removed. After the exact-set validator was implemented, the same command
exited 0 and all four provenance mutations were rejected.

## Workflow evidence

- `.github/workflows/ci.yml:53-55` contains the sole CI trace step under
  `jobs.validate.steps`.
- `.github/workflows/release.yml:68-70` contains the sole release trace step
  under `jobs.build.steps`.
- `.github/workflows/release.yml:72-78` places it before the build step and
  the AST-confirmed `build.ps1 -Version` invocation.
- `ReleaseWorkflow.SelfTest.ps1` parses job and step indentation rather than
  searching the whole file. It parses each PowerShell `run` body into an AST,
  counts the real trace/build commands, and compares their step indexes.
- Controlled negative YAML fixtures reject a comment-only decoy, a trace in
  `publish`, a post-build trace, an anonymous pre-build command, duplicate
  named steps, and a duplicate trace invocation under a different name.

The checked-in workflows each had one trace name and one exact trace run value
at final review.

## Provenance evidence

The final source enumeration contained 19 `.cs` files. Both the lightweight
release fixture and the real compiled artifact test cover:

- omission of `TrayHostChildSession.cs`;
- a same-count duplicate of `TrayHostChildSession.cs` replacing
  `WindowsTrayHostRuntime.cs`;
- a changed source-name set;
- a wrong hash for `WindowsTrayHostRuntime.cs`.

The real build test also requires the provenance names to equal the canonical
sorted source names and explicitly requires both new production source files.
The validator uses ordinal name comparison and canonical lowercase 64-digit
SHA-256 values.

## Command ledger

### Required/focused tests

| Command | Result |
| --- | --- |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1` | RED 1: exit 1, missing workflow gate (`CCOD_RELEASE_TRACE_GATE_INVALID`). |
| same ReleaseWorkflow command after workflow change | exit 0. |
| same ReleaseWorkflow command after provenance test, before verifier change | RED 2: exit 1, missing source record was wrongly accepted (`ASSERT_THROWS`). |
| final same ReleaseWorkflow command | exit 0; release workflow self-tests passed, including structural decoys and provenance mutations. |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/TrayHostBuild.SelfTest.ps1` | exit 0; six build/provenance cases passed against a real compiled artifact. |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/trayhost/Invoke-TrayHostSelfTest.ps1 -ProductionTraceOnly` | exit 0; `TrayHost production child-session trace passed: 3`. |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/InstalledLifecycleHarness.SelfTest.ps1` | exit 0; 20 controlled adapter/temp-root scenarios passed. |
| all repository `.ps1`/`.psm1` files through `System.Management.Automation.Language.Parser` | exit 0; 92 files parsed. |
| all `src` JS/MJS files through `node --check` | exit 0; 5 files parsed. |
| `node.exe tests/CleanroomSelfTest.js` | exit 0; JSON result `ok: true`, 19 cases. |
| `node.exe tests/PackageCheckerSelfTest.mjs` | exit 0. |
| `git diff --check` | exit 0; only the repository's existing LF-to-CRLF warnings. |

### Full Persistence/Validate isolation boundary

The direct, non-npm aggregate command was attempted once:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/PersistenceSelfTest.ps1
```

It exited 1 before reaching Task 4 tests:

```text
CCOD_SELFTEST_FAILED case=selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer error=ASSERT_EXACT
CCOD_PERSISTENCE_SELFTEST_FAILED test=Bootstrap.SelfTest.ps1 exit=1
```

Running `Bootstrap.SelfTest.ps1` alone twice reproduced
`previous fallback succeeds expected=[0] actual=[1]`. A corrected zero-wait
production mutex probe exited 0 and reported:

```text
CCOD_ACCOUNT_TRANSITION_PROBE outcome=TimedOut
```

An initial diagnostic probe invocation had a parent-shell quoting error and
exited 1 before importing the module or touching a mutex; the corrected
single-quoted probe above is the relevant result.

The installed Supervisor was live, and an independent probe showed that the
fixed account transition boundary was unavailable. `tests/Validate.ps1 -SkipInstalledPackageCheck`
was not started because it unconditionally invokes the same Persistence
aggregate; repeating it could not produce independent evidence. No process was
stopped and no kernel-name, SID, or safety check was forged to bypass the
boundary. The existing fully controlled InstalledLifecycle harness and the
safe pre-Persistence validation components were run instead and passed.

## Scope

Changed implementation/test files:

- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `build/TrayHostBuild.psm1`
- `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- `tests/persistence/TrayHostBuild.SelfTest.ps1`

This task did not modify production TrayHost wire fields, message types,
sequence/authentication rules, CLI selectors, child-session behavior, receipt
storage, installer behavior, version metadata, README/CHANGELOG content, or
Task 5 static manifest/version binding.

No real UI, Codex process, installer, installation, release, push, package
signing, or public operation was started. Tests used temporary artifacts and
the Task 3 fake-native production trace only.

## Remaining risks

- Full `PersistenceSelfTest.ps1` and therefore `Validate.ps1` still require a
  fresh run when the real account transition mutex is safely quiescent. This
  task did not stop the live Supervisor to manufacture a green aggregate.
- The production trace proves the shared authenticated child-session path with
  a fake native platform; installed-machine notification-area and Defender
  validation remain later release acceptance boundaries.
- Version, Windows manifest identity, README/CHANGELOG, and final asset
  acceptance are Task 5 scope and were intentionally not changed here.

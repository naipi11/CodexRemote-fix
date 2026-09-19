# Task 5 report: exact assets and dual Defender evidence

## Status

Implemented the deterministic Task 5 release-security foundation in commit
`fb163b7b6b594e302cf4dffe1dedd055b5f8d9d4`. The build, release-manifest
validator, Defender checker, promotion validator, Setup bootstrap, portable
entrypoint, tests, and candidate documentation now share one exact public
asset contract.

This is candidate infrastructure only. It does not claim a live Defender
scan, a production build, a published release, stable Windows acceptance, or
completion of Tasks 6-8. Scoped review is still required.

No real Defender command, official build, installation, uninstall, registry
or shortcut mutation, network request, GitHub action, restart, reboot, signing,
tag, push, upload, promotion, or publication was performed. Defender and
activation tests used temporary files and test-local adapters/functions only.

## Exact public asset authority

`tools/ReleaseAssetContract.psm1` is the single production source for the
ordered 11-name set:

1. `CodexRemote-fix-2.5.22-windows-x64.zip`
2. `CodexRemote-fix-2.5.22-windows-x64.zip.sha256.txt`
3. `CodexRemote-fix-2.5.22-trayhost-provenance.json`
4. `CodexRemote-fix-2.5.22-payload-manifest.json`
5. `CodexRemote-fix-2.5.22-release-manifest.json`
6. `CodexRemote-fix-2.5.22-setup.exe`
7. `CodexRemote-fix-2.5.22-setup.exe.sha256.txt`
8. `CodexRemote-fix-2.5.22-setup-provenance.json`
9. `CodexRemote-fix-2.5.22-setup-payload-manifest.json`
10. `CodexRemote-fix-2.5.22-setup-destination-inventory.iss`
11. `CodexRemote-fix-2.5.22-setup-release-manifest.json`

`Test-CcodExactReleaseAssetSet` requires a canonical plain directory with
exactly those 11 regular non-reparse leaves. It rejects missing, extra,
case-varied, duplicate, directory, reparse, unsafe-ancestry, noncanonical,
manifest-order, hash, commit, timestamp, and shared-provenance mutations.

Portable manifest public records are indices `0,1,2,3`, with index `4` as its
manifest leaf. Setup manifest public records are indices `5,6,2,7,8,9`, with
index `10` as its manifest leaf. Both distributions bind the same lower-case
40-hex commit, canonical build timestamp, and TrayHost provenance bytes.
Checksums bind the exact candidate leaf and bytes. A bounded recursive lexical
JSON pass rejects duplicate property names at every object depth, including an
escaped spelling such as `\u0067itCommit`, before deserialization.

`build/build.ps1` imports this module only after the clean-checkout gate,
derives all 11 paths by their fixed indices, writes the two manifest views,
then validates the complete exact set. `tools/Test-ReleaseDefender.ps1` also
uses the central names for its portable and Setup manifest validators.

## Defender receipt contract

`Invoke-CcodReleaseDefenderCheck` now requires the exact candidate, matching
checksum, explicit matching manifest, expected version/commit, evidence path,
and one of two origins. Its ordered schema-two receipt has exactly these 25
fields:

`schemaVersion, assetType, assetName, assetSha256, checksumName,
checksumSha256, manifestName, manifestSha256, version, gitCommit, origin,
workflowArtifactIdentity, zoneId, defenderServiceEnabled, antivirusEnabled,
realTimeProtectionEnabled, defenderPlatformVersion, defenderEngineVersion,
signatureVersion, signatureUpdatedAtUtc, scanStartedAtUtc,
scanCompletedAtUtc, detectionCount, outcome, errorCode`.

- `InternetDownload` requires the actual `Zone.Identifier` stream with exactly
  one `ZoneId` property whose value is `3`. The public tool has no Zone
  synthesis parameter, and workflow identity must be null.
- `TrustedWorkflowArtifact` has a null Zone and requires the exact ordered
  GitHub Actions identity fields `provider, repository, runId, runAttempt,
  artifactId, artifactName, artifactDigest, gitCommit`. Provider, repository,
  artifact name, positive integral identifiers, `sha256:<64hex>` digest, and
  expected commit are all exact.
- Defender service, antivirus, and real-time protection must be enabled.
  Platform, engine, signature version, and signature timestamp must be
  present. The signature can be at most 72 hours old at scan start and at most
  five minutes in the future. Completion cannot precede start or exceed two
  hours; no invalid-clock fallback is used.
- The checker records the pre/post detection difference, requires zero new
  detections for success, and preserves stable scan/detection/write errors.
  It revalidates candidate, checksum, manifest, expected commit, hashes, and
  Internet Zone after the scan and before writing a receipt.
- Default evidence writing requires an existing canonical plain parent and a
  new `.json` leaf. It uses a create-new temporary file, durable flush, a
  second target preflight, no-replace move, and exact cleanup. Existing files,
  directories, reparse leaves, reparse ancestry, noncanonical paths, and ADS
  targets are rejected before scanning.

The receipt contains no source path or raw Defender output.

## Promotion authority

`Test-CcodReleasePromotionEvidence` requires both `-EvidenceDirectory` and the
mandatory authoritative `-AssetDirectory`, plus version and expected commit.
It first validates the exact 11 assets and their common commit. It then accepts
exactly these two receipt leaves:

- `CodexRemote-fix-2.5.22-setup.internet-download.defender.json`
- `CodexRemote-fix-2.5.22-windows-x64.internet-download.defender.json`

Both must be schema-two `InternetDownload`/Zone-3/Completed/zero-detection
receipts. Setup receipt hashes are compared with actual contract indices
`5,6,10`; portable receipt hashes are compared with indices `0,1,4`.
Missing, extra, duplicate, swapped, reused, forged-but-well-formed, field-
mismatched, or trusted-workflow substitutions fail closed. Trusted workflow
receipts remain separate CI evidence and cannot satisfy official-download
promotion.

## Pre-mutation scan ordering

- Setup holds the already verified package seal, scans the canonical package
  path returned by that seal, and only then creates the extraction temp root,
  expands payload bytes, opens activation state, writes any activation log or
  receipt, or launches the lifecycle worker. The production-shaped failure
  injection proves no package temp root or product-state entry appears.
- Portable retains `manifest validate -> Defender scan -> manifest revalidate
  -> copy -> lifecycle`. Its local gate now records the same service/AV/
  real-time/platform/engine/signature/timestamp facts. A real entrypoint copy
  with a throwing test-local scan proves no child or lifecycle state is
  created; existing post-scan and final-copy race tests remain green.

## Candidate documentation

README and README.zh-CN remain candidate-scoped. The old `always published`,
`始终发布`, and `已验证……均可用` claims were removed. The exact 11-name list is
present once in each release section inside a collapsed `<details>` block, and
Defender receipts are explicitly evidence rather than public assets. No
version-specific What's New section was added. CHANGELOG adds one concise
English and Chinese bullet describing the enforced dual-download evidence.

## RED evidence

The following failures were observed before the corresponding production
implementation:

- Asset contract: exit `1`, `ASSERT_TRUE: central release asset contract
  module exists`.
- Defender v2 API: exit `1`,
  `NamedParameterNotFound,Invoke-CcodReleaseDefenderCheck` for
  `-CandidatePath`.
- Promotion: exit `1`, missing central asset module.
- Evidence writer: exit `1`, missing Defender `-CandidatePath` API.
- Setup ordering: exit `1`, exact scan call count expected `1`, actual `0`.
- Documentation: exit `1`, `English README makes no unconditional publication
  or verification claim`.
- Authoritative promotion follow-up: exit `1`,
  `NamedParameterNotFound,Test-CcodReleasePromotionEvidence` for mandatory
  `-AssetDirectory`; the old shape could not compare receipts with real
  assets.
- Lexical JSON follow-up: exit `1`, `ASSERT_THROWS: expected
  CCOD_RELEASE_ASSET_SET_INVALID`; a duplicate top-level property was folded.
- Zone follow-up: exit `1`, `ASSERT_THROWS: expected
  CCOD_DEFENDER_ZONE_REQUIRED`; the first matching ZoneId line was accepted.
- Post-scan identity follow-up: exit `1`, `ASSERT_THROWS: expected
  CCOD_RELEASE_ASSET_HASH_MISMATCH`; candidate mutation during the fake scan
  reached receipt creation.

During GREEN iteration, the first asset-path implementation looped at the
drive root after trimming `C:\` to `C:`; the session was interrupted and root
termination was corrected. The first default evidence writer closure could
not resolve its validator and was corrected without weakening preflight.
Two test-oracle defects were also corrected: base names were no longer counted
inside checksum names, and restoration of a mutated EXE explicitly restored
its test Zone ADS before later cases.

## Frozen GREEN evidence

The final source was frozen at pre-commit diff hash
`55eaabfc6770bee68afda76c6996ff41d569e2f0`. From that unchanged source:

- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File
  tests\persistence\ReleaseWorkflow.SelfTest.ps1` exited `0`; all 58 declared
  cases passed, including exact assets, dual promotion, origins, full status,
  unique Zone, clocks, post-scan identity, create-only evidence, Setup order,
  portable failure/races, build wiring, and bilingual documentation.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File
  tests\persistence\PortableRelease.SelfTest.ps1` exited `0`; `5/5`.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File
  tests\persistence\InstallLifecycle.SelfTest.ps1` exited `0`; `151/151`.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File
  tests\PersistenceSelfTest.ps1` exited `0`; the sorted aggregate completed
  all 39 registered persistence suites.
- PowerShell parser checks covered all 103 repository `.ps1`/`.psm1` files
  with `PARSER_FAILURES=0`.
- `git diff --check` exited `0`; only checkout LF-to-CRLF notices appeared.
- Before commit there were zero active worktree self-test children and zero
  matching Task 5 temporary directories. Two exact directories left by the
  intentionally interrupted early RED run were inspected as plain temp
  directories and removed before this check.

## Implementation commit and review boundary

- Implementation: `fb163b7b6b594e302cf4dffe1dedd055b5f8d9d4`
  (`feat: require dual Defender release evidence`).
- Plan/brief baseline: `1109854`.
- Tasks 6-8 remain blocked. Task 5 needs a scoped review of
  `1109854..fb163b7` before it can be marked complete.

# Task 5 fix round 1 report: non-synthesizable Defender authority

## Status

Implemented Task 5 fix round 1 in commit
`9f8a9e7f4aa8ba6028941026cbca776cbd908610`
(`fix: close Defender authority review gaps`). The previous Task 5
implementation commit remains `fb163b7b6b594e302cf4dffe1dedd055b5f8d9d4`.
The scoped review that failed Task 5 saw `1109854..fb163b7`. This round
covers `fb163b7..9f8a9e7`.

This remains candidate infrastructure only. It does not claim a live
Defender scan, a production build, a published release, Windows
acceptance, or completion of Tasks 6-8. Scoped re-review is still
required.

No real Defender command, official build, installation, uninstall,
registry or shortcut mutation, network request, GitHub action, restart,
reboot, signing, tag, push, upload, promotion, or publication was
performed. Defender and activation tests used temporary files and
module-scope adapters only.

## Finding 1: public Defender surfaces cannot synthesize authority

Public `Invoke-CcodReleaseDefenderCheck` and `tools/Test-ReleaseDefender.ps1`
now accept only candidate, checksum, manifest, origin, optional workflow
identity, version, commit, and evidence path. They expose neither
`-Adapters` nor `-Library`. Production adapters resolve only real
Defender cmdlets, the actual Zone stream, and the create-only receipt
publisher. Adapter-taking logic lives in non-exported
`Invoke-CcodReleaseDefenderCheckCore`; tests reach it only through
module-scope invocation.

RED: `fix1-public` enumerates public parameters/exports and attempts the
old forged receipt path. Actual first-failure shape, before this round,
was a public function that accepted `-Adapters` and a script `-Library`
bypass.

## Finding 2: nested payload and provenance are now exact

`Test-CcodExactReleaseAssetSet` and promotion consume deep portable and
Setup validation from `tools/ReleaseAssetContract.psm1`. Portable
validation checks payload records, ZIP membership, root launcher hashes,
and embedded payload-manifest identity. Setup validation checks nested
package-manifest, provenance, inventory grammar, and PE binding. The
Task 5 fixture now uses internally consistent nested bytes instead of
placeholder hashes.

RED: `fix1-deep` mutates nested payload length/hash, ZIP root launcher,
ZIP extra entry, TrayHost nested schema, Setup package payload binding,
Setup provenance nested schema/length, and inventory grammar while
keeping outer hashes self-consistent. Each mutation fails closed with
`CCOD_RELEASE_ASSET_SET_INVALID`.

## Finding 3: scan and promotion hold identities through the decision

Candidate, checksum, manifest, Zone, all 11 public assets, and both
receipts are pinned with read-only no-write/no-delete handles. Shared
final-path, file-id, reparse, ADS, and multilink checks revalidate
identity through scan, receipt durable read-back, and promotion return.
Promotion rechecks exact directory membership before return.

RED: `fix1-handle-scan` same-byte ABA writes are denied; `fix1-handle-post`
post-revalidation replacement is denied; `fix1-handle-promotion` cannot
replace a held asset or receipt before return.

## Finding 4: receipts require production write/read-back

Receipt publication serializes one canonical UTF-8 byte sequence, writes
create-only under the held evidence directory, flushes, publishes
no-replace, reopens the final leaf, and compares regular/nonreparse
identity, exact 25 fields, bytes, hash, and object. Failed scan receipts
use the same read-back before the stable scan error is returned.

RED: `fix1-receipt-NoOp`, `Corrupt`, `WrongTarget`, `StaleObject`,
`ReplacedReadback`, and `FailedNoOp` all fail with
`CCOD_DEFENDER_EVIDENCE_WRITE_FAILED`.

## Frozen GREEN evidence

The final source was frozen at pre-commit diff hash
`be3fc4f1c194ccc4d64bae4609e86531a10cb1da2a8f9813ca0962ad58f387a2`.
From that unchanged source:

- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests\\persistence\\ReleaseWorkflow.SelfTest.ps1` exited `0`; 63 declared cases passed, including public-surface, deep nested, handle, receipt read-back, dual promotion, origins, status, clocks, Setup order, portable races, build wiring, and bilingual documentation.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests\\persistence\\PortableRelease.SelfTest.ps1` exited `0`; `5/5`.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests\\persistence\\InstallLifecycle.SelfTest.ps1` exited `0`; `151/151`. The existing cross-process observation still prints `exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`.
- PowerShell parser checks covered all 104 repository `.ps1`/`.psm1` files with `PARSER_FAILURES=0`.
- `git diff --check` exited `0`; only checkout LF-to-CRLF notices appeared.
- `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests\\PersistenceSelfTest.ps1` exited `0`; all 39 registered persistence suites completed.

## Implementation commit and review boundary

- Implementation: `9f8a9e7f4aa8ba6028941026cbca776cbd908610`
  (`fix: close Defender authority review gaps`).
- Previous Task 5 implementation: `fb163b7b6b594e302cf4dffe1dedd055b5f8d9d4`.
- Plan/brief baseline remains `1109854`; fix-round brief is
  `task-5-fix1-brief.md`.
- Tasks 6-8 remain blocked. Task 5 needs a scoped re-review of
  `fb163b7..9f8a9e7` before it can be marked complete.


# Task 5 brief — exact assets and dual Defender evidence

Implement Task 5 from `docs/superpowers/plans/2026-08-29-v2522-immutable-generation.md` with RED -> GREEN. Read the matching design section and existing release/Defender code before editing.

## Required contracts

1. Create `tools/ReleaseAssetContract.psm1` as the single source of the exact ordered 11 public v2.5.22 asset names. `Test-CcodExactReleaseAssetSet` rejects missing, extra, duplicate/case-varied, directory, reparse, unsafe ancestry, or noncanonical entries and cross-validates portable/Setup checksum, provenance, payload manifest, release manifest, version and 40-hex commit bindings.
2. Extend `Invoke-CcodReleaseDefenderCheck` to accept only `TrustedWorkflowArtifact` or `InternetDownload`, exact Setup or ZIP plus matching checksum/manifest, and a create-only regular evidence leaf. `InternetDownload` requires the actual Zone.Identifier ADS with ZoneId 3 and exposes no synthesis switch. `TrustedWorkflowArtifact` requires exact workflow artifact identity. Require Defender service/AV/real-time enabled, current nonempty platform/engine/signature metadata and timestamp, bounded scan timestamps, successful custom scan, and zero new detections. The canonical receipt contains no source path or raw Defender output.
3. `Test-CcodReleasePromotionEvidence` validates the two distinct official-download receipts (Setup and portable ZIP), their exact asset/manifest hashes, version, commit and `InternetDownload` origin. Reject duplicate, swapped, missing, extra, reused or mismatched receipts. Trusted-workflow receipts remain separately origin-bound evidence and never substitute for the two official-download receipts.
4. Keep portable scanning before activation. Add Setup sealed-package scanning before the lifecycle can create `Prepared`, transaction-root or product state. A scan failure must produce no activation mutation.
5. Update build/manifest validation to consume the centralized 11-name contract. Update README/README.zh-CN/CHANGELOG only to enforced candidate behavior: no unqualified stable/verified claim and no per-version What's New clutter on the README home page. Receipts are evidence, never public assets.

## RED coverage

Cover exact asset-set mutations; every receipt binding field; Setup/ZIP duplicate/swap/missing; both origin rules; ZoneId absent/other/synthetic attempt; disabled Defender/service/real-time; absent/stale signature; scan error/detection; existing/reparse evidence; write failure; portable and Setup scan failure before mutation; and documentation wording.

## Verification and boundaries

Run ReleaseWorkflow, PortableRelease, InstallLifecycle, changed parsers, `git diff --check`, and the full persistence aggregate from frozen source. Tests use adapters only and cannot claim a live Defender pass. Do not execute real scans, builds, network, GitHub, installation, restart, reboot or publication. Commit implementation and evidence separately, then request a scoped review. Tasks 6–8 stay blocked.

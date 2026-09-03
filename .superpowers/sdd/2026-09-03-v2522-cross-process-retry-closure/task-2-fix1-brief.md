# Task 2 fix round 1 — directory creation recovery and exact durable evidence

Read the Task 2 report and scoped review. Fix the three Important findings without weakening the already accepted V6 scope, Ready/fence/lease, overlap, or cleanup-tail boundaries.

## Required RED -> GREEN

1. Cover the CREATE-to-ACL crash shape for `state\legacy-registration-migrations`. A newly created directory must never leave an unregistered handle on Set/Validate failure. A later ProductTransaction may normalize only an empty, non-reparse directory owned by the current SID whose inherited ACL contains only the explicitly trusted SID/SYSTEM/Administrators full-control principals; nonempty, foreign-owner, untrusted-ACE, ADS, or identity-drift cases fail closed. Reader-first retry must recover the known empty crash artifact before returning no plan. Prefer atomic creation security if the native layer can provide it more safely.
2. Require exact nested schema. Persisted `profile` must have exactly the six canonical profile fields (`profileId,appId,minimumVersion,maximumVersion,uninstallCommandShape,shortcutNames`) in canonical order and byte-equivalent values to `Resolve-CcodLegacyRegistrationProfile`. `expectedInstallRoot`, every historical shortcut path/target/working-directory, and other identity paths must equal their canonical strings, not merely normalize to them. Add extra/missing/reordered profile and equivalent-noncanonical path REDs.
3. Add separate-`powershell.exe` replay evidence that reads serialized plan/live-state data and invokes the production durable replay parser/classifier with no parent-process object identity. Add published-but-threw writer and post-write read-back failure cases: first invocation performs zero current writes; the later invocation reads the existing exact leaf, does not republish it, and converges. Use independent serialized objects for all read-backs.

Run IFT, ProductRegistration and Lifecycle focused suites, then repeat the complete frozen gate, parsers and `git diff --check`. Commit implementation and evidence separately, update the ledger/report, and request a scoped fix-round review. No real system/external actions or release claim.

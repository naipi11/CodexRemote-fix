# v2.5.22 Runtime V7 ABI Closure Plan

**Goal:** Ensure the final embedded install-file CLR implementation cannot silently reuse the pre-fix RuntimeV6 in a long-lived PowerShell AppDomain.

**Scope:** `src/persistence/modules/InstallFileTransaction.psm1` and its self-test, plus only evidence/ledger files. No behavioral redesign.

## Task

1. Add an independent child-process RED that preloads a minimal pre-fix `CcodInstallGenerationCapabilityMarkerV6` / `CcodInstallGenerationRuntimeV6`, then force-imports the current module. It must prove the current module binds the stale V6 instead of a new ABI/type. Keep the fixture self-contained and independent of Git history.
2. Mechanically advance the embedded marker, runtime type and `CapabilityAbi` to V7/7. Update every exact ABI assertion. A preloaded V6 must coexist but never be selected; repeated force-import of the final V7 must reuse the same correct V7 type.
3. Run InstallFileTransaction, ProductRegistration, InstallLifecycle, UninstallBootstrap, RuntimeManifest, InstalledLifecycleHarness, Bootstrap, ManualWrappers, all changed parsers, `git diff --check`, and `tests\PersistenceSelfTest.ps1` from frozen source.
4. Commit implementation and evidence separately, then request one independent scoped review. Do not claim Tasks 5–8 or release readiness.

**Constraints:** No real registry, shortcut, scheduled task, installation, uninstall, process restart, reboot, network, push, tag, release, or publication. Preserve all V6 file/plan behavior byte-for-byte except required CLR symbol/ABI changes and tests.

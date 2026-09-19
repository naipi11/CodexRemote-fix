# v2.5.22 Transactional Install and Release Acceptance Design

## Status

The user approved this architecture on 2026-08-28. It supersedes the
incomplete installer/write-boundary portions of the earlier v2.5.22 designs.
`v2.5.22` is not tagged or released, so this design retains that version rather
than creating a second public version number.

## Goal

Make a fresh install, a supported legacy upgrade, and a same-version repair
converge on one sealed current-user runtime. A failed transaction must retain a
known runnable runtime or fail without creating an active mixed state. The
release path must not expose assets publicly until both Setup and the EXE-based
portable ZIP are verified, scanned, and accepted on the current Windows host.

## Evidence and non-goals

The existing candidate already has useful foundations: versioned manifests,
exact payload hashes, source-byte sealing in the activation worker, runtime
pointer revalidation, strict process identity, and authenticated tray receipts.
It does not yet make Setup writes, activation-script execution, lifecycle
copies/promotions/deletes, Defender release evidence, and reboot acceptance one
end-to-end transaction.

This design does not modify `ChatGPT.exe`, `app.asar`, `WindowsApps`, account
state, or the current-user DPAPI device-key store. It does not add an external
remote-control channel or change the authenticated TrayHost protocol.

## Invariants

- All product state remains current-user scoped.
- The release version is exactly `2.5.22` until it is publicly released.
- A runtime may become active only from a manifest-listed sealed package whose
  version, source commit, and payload hash match the transaction contract.
- A file write, promotion, or delete uses a pinned parent identity and a
  single relative leaf name. Pathname checks are validation, not authority.
- A failure before pointer commit leaves the old pointer and stable shell
  untouched. A failure after pointer commit uses a monotonic compensating
  generation pointing back to the retained old runtime; it never rewrites a
  generation number.
- `Ready` requires a matching active pointer, runtime manifest, Supervisor,
  authenticated TrayHost, expected version, and terminal activation receipt.
- A release remains draft until its exact asset set and both Defender receipts
  are read back successfully. A failed scan or missing evidence is a hard
  release failure, never a bypass.

## Architecture

### 1. Sealed package generation and trusted Setup bootstrap

Build produces one manifest-bound package archive for Setup, containing the
complete runtime source and stable-shell candidates. The Setup executable keeps
that archive, its manifest, and the activation bootstrap as `dontcopy` inputs.
The installer no longer relies on a writable `{app}` tree as the code execution
source.

At `PrepareToInstall`, Setup:

1. extracts the bootstrap and package only to its private temporary area;
2. rehashes the extracted files against compile-time values while their handles
   deny write and delete sharing;
3. starts a sealed bootstrap process from that locked source;
4. waits for the bootstrap to create and pin the target transaction root and
   return a fixed capability/ready result; and
5. performs no recursive product payload extraction itself.

The bootstrap is the only component allowed to unpack the package into the
current-user install root. It keeps its package and destination pins until the
terminal receipt has been validated. A diagnostic copy under `{app}` may exist
after a successful transaction, but Setup must never execute that copy as part
of the install success path.

The new Inno shell sets `CreateAppDir=no` and `Uninstallable=no`; it writes no
product file, product shortcut, or product registry entry under `{app}` before
`Ready`. The old Inno `AppId`, installed user-facing name, current-user scope,
and existing control-panel uninstall entry remain compatibility inputs during
migration. After `Ready`, the transaction writes and reads back one verified
current-user product registration pointing at the sealed stable uninstaller and
two verified current-user shortcut records: the Start-menu `CodexRemote-fix`
shortcut and the desktop `CodexRemote-fix` shortcut. Only after all three
records are read back does it remove the exact legacy registry entry and exact
legacy shortcut names. A failed transaction never unregisters or recursively
deletes a legacy entry. Legacy installer shell files are never used as a
source-file discovery root.

### 2. Private pinned file transaction module

Add one private persistence module,
`InstallFileTransaction.psm1`. Its native interop is internal; callers do not
receive arbitrary pathname write APIs.

Its required operations are:

| Operation | Contract |
| --- | --- |
| Open/create pinned directory | Opens or creates exactly one child under an already pinned parent; rejects reparse points and unexpected identities. |
| Create pinned temporary leaf | Creates only a single generated leaf under a pinned directory with no overwrite of an existing inode. |
| Copy and verify | Reads sealed source bytes, writes through the pinned leaf, flushes, and rehashes through the same handle. |
| Commit promotion | Atomically promotes a verified temporary leaf within the pinned directory; identity or sharing ambiguity fails closed. |
| Retire owned tree | Atomically moves a complete, transaction-owned nonempty tree to a no-replace quarantine name under its pinned parent. Empty owned trees may be marked for delete-on-close. |
| Close transaction | Releases handles only after a terminal success/failure decision; quarantine is retained for later diagnosis or separately proven reclamation rather than performing a pathname-recursive delete. |

The module accepts only pinned handles and validated relative segments. It
cannot be called with an untrusted absolute destination. Existing checks for
ADS, reparse points, link count, manifest membership, length, and SHA-256
remain mandatory at every transition.

### 3. Transaction state machine and compatibility recovery

The bootstrap persists a private, bounded transaction record under the existing
state root. It contains a transaction ID, old/new runtime IDs, old/new
generation, sealed package hash, phase, and candidate object names. It contains
no credentials, remote keys, arbitrary paths, or raw exception text.

```text
Prepared
  -> PackageVerified
  -> RuntimeStaged
  -> PreviousProtectionStopped
  -> RuntimePromoted
  -> PointerCommitted
  -> StableShellCommitted
  -> ProtectionReady
  -> Ready
  -> Failed
```

- Before `PointerCommitted`, a failure leaves the previous stable shell and
  active pointer unchanged, then proves the retained previous runtime can run.
- The stable shell is committed only after pointer commit. That creates one
  post-pointer compensation boundary, but preserves the pre-pointer invariant:
  a failure before pointer commit cannot alter the shell a legacy bootstrap
  would execute.
- After `PointerCommitted`, a failure records a new, higher compensating
  generation targeting the retained previous runtime and restores the matching
  stable shell. If compensation cannot be proven, it writes no `Ready`, retains
  all candidates, writes terminal `Failed` with a stable rollback code, and
  returns that code.
- `Failed` is the only terminal error phase. Its record carries the same sealed
  transaction identity and phase order as `Ready`, plus exactly one canonical
  `CCOD_*` error code; no raw exception or private path is persisted.
- Legacy installations without the transaction record start at `Idle`; their
  active runtime is treated as a compatibility candidate only after the
  existing strict identity and manifest checks succeed.
- A same-version repair reuses a package only when version and sealed package
  hash both match. A same version with different bytes fails as a conflict,
  preventing a mixed repair.
- Unknown legacy files are never recursively removed. Nonempty transaction-owned
  objects are retired atomically; only a separately proven empty tree is
  physically removed. Cleanup is therefore limited to transaction-owned objects
  that the module can prove safe.

### 4. Defender and draft-release promotion

Both local installer entry paths scan their sealed input before activation:

- portable scans its verified payload as today, retaining the existing strict
  Defender failure behavior;
- Setup bootstrap scans the verified Setup package before beginning the
  transaction.

Release publishing becomes a staged promotion:

```text
clean build -> exact asset manifests -> draft release -> official draft download
-> SHA/manifest revalidation -> Defender scan of Setup and portable ZIP
-> receipts bound to exact assets -> full install/reboot acceptance -> public release
```

The release workflow uploads only an explicit 11-item asset allowlist. It
creates a draft, uploads the exact set, reads every asset back, and never
publishes a partial asset set. Its Defender gate has two explicit origins:

- `TrustedWorkflowArtifact` for an internally generated candidate whose
  artifact identity, manifests, version, commit, and hashes are verified; and
- `InternetDownload` for an official browser download that must retain actual
  ZoneId 3. The workflow must not synthesize a Zone identifier.

Each receipt binds asset SHA-256, manifest SHA-256, version, commit, Defender
platform/signature data, timestamps, and zero new detections. Disabled Defender,
missing real-time protection, stale/missing signature metadata, missing receipt,
or a scan error blocks promotion. The release workflow must use a documented
Defender-capable Windows runner; if unavailable, it fails while leaving the
release draft private for review.

### 5. Acceptance evidence

Automated acceptance must cover:

1. clean fresh install with initially missing transaction directories;
2. legacy upgrade from the currently released installer;
3. same-version repair with same hash and rejection of same-version/different
   hash input;
4. failures injected at each state-machine phase, including post-pointer
   compensation;
5. pinned copy, promotion, and deletion boundaries retaining outside sentinel
   data unchanged;
6. Setup and portable artifact integrity, both manifest contracts, exact
   11-item release assets, and dual Defender receipts;
7. a clean Windows runner full suite, never treating a live local mutex as a
   pass; and
8. a current-machine official-draft acceptance: full uninstall/reinstall,
   reboot, active-runtime/process identity, DPAPI key preservation, tray
   About/language/logs/repair actions, and a real second-device remote
   connection.

The last tray and remote interactions require recorded end-user evidence
(screenshots plus redacted logs) in addition to programmatic status checks.
No release may be called stable until this evidence exists.

## Files and interfaces expected to change

- `build/build.ps1`, `build/CodexControlOtherDevices.iss`, payload and
  destination inventory generation;
- `Activate-CcodRemoteFix.ps1` and a private
  `src/persistence/modules/InstallFileTransaction.psm1`;
- `src/persistence/modules/InstallLifecycle.psm1` and its transaction/state
  tests, plus `src/persistence/modules/ProductRegistration.psm1` for the
  post-Ready current-user uninstall and shortcut migration;
- `Install-CodexRemote-fix.ps1`, `tools/Test-ReleaseDefender.ps1`, CI/release
  workflows, release contract tests, and installed lifecycle acceptance tests;
- concise English and Chinese README/CHANGELOG text that only describes
  verified behavior.

The implementation plan will map these changes into reviewable TDD tasks with
separate source, workflow, and installed-machine acceptance gates.

## Explicit non-release rule

All local `build/dist` directories produced before this transaction design are
historical evidence only. They must not be uploaded, tagged, installed, or used
for acceptance. A clean candidate is built only from the final reviewed commit.

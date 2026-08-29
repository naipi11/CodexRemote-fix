# v2.5.22 Immutable Generation Install Design

## Status

The user confirmed this revised model on 2026-08-29. It replaces the
unreleased v2.5.22 transaction design's attempted persistent DACL/recursive
deletion boundary. No v2.5.22 tag or public release exists.

## Goal

Make fresh installation, legacy upgrade, same-version repair, and reboot
recovery converge on a complete, manifest-bound current-user runtime without
ever activating a partially copied generation. A failure retains the last
known-good generation and leaves the new generation inactive and diagnosable.

## Security model

The product remains a current-user utility. It defends against accidental and
ordinary pathname races by using unique create-only generations, strict
manifest/hash/version checks, and atomic pointer commits. It does not claim to
defeat a same-user process that already has unrestricted write/DACL authority;
that guarantee would require an elevated or signed broker, which is outside
this product's current-user scope.

This design never modifies `ChatGPT.exe`, `app.asar`, `WindowsApps`, account
state, or the current-user DPAPI device-key store. It does not add a remote
control channel or change the authenticated TrayHost wire contract.

## Invariants

- Every generation directory and file name is unique and create-only. No
  existing runtime or stable shell is overwritten during staging.
- A generation becomes eligible only after every manifest-listed file is
  copied, flushed, and rehashed, and its runtime manifest/version/commit match.
- The only mutable install control record is a small atomic active-generation
  pointer. It includes a monotonically increasing generation number and the
  previous generation ID.
- Before pointer commit, the old pointer and stable bootstrap remain untouched.
  After pointer commit, any failure appends a higher compensating pointer to the
  retained old generation; it never decrements or rewrites a generation.
- Installation never recursively deletes a nonempty runtime or package tree in
  its hot path. Old and failed generations are retained under an owned retired
  namespace until a separately verified maintenance/uninstall operation.
- `Ready` requires the active pointer, generation manifest, Supervisor,
  authenticated TrayHost, expected version, and activation receipt to agree.
- Setup and portable inputs are Defender-scanned before activation; public
  promotion requires exact asset read-back, two actual downloaded-asset scan
  receipts, complete old-version upgrade/fresh-install/reboot evidence, and the
  named tray/remote manual evidence.

## Architecture

### 1. Immutable package and generation layout

Build creates a single manifest-bound Setup package containing the complete
runtime and stable-shell candidates. The package and its manifest are extracted
to a private Setup temporary directory and validated before any install-state
write.

The bootstrap asks the file layer to create a unique generation such as
`runtime\<runtimeId>` and copies only manifest-listed files there. The runtime
manifest is written as the final generation file, then validated through the
same create-only path. Existing generations are never used as a source root.

Stable `bootstrap.ps1` and `Uninstall-CodexControlOtherDevices.ps1` are
generated as new candidates inside the generation. They are made visible only
after the active pointer is committed and the new protection has reached
verified readiness. An upgrade does not overwrite a stable file while the new
generation is still incomplete.

### 2. Small pinned file layer without persistent DACL mutation

`InstallFileTransaction.psm1` keeps only opaque transaction capabilities and
native handles needed to create/read/flush/hash a unique generation. It exposes
no arbitrary native helper, raw stream, or caller-mutable seal state.

Required operations are create-only:

```powershell
Open-CcodInstallGeneration -InstallRoot <absolute-root> -RuntimeId <unique-id>
New-CcodInstallGenerationLeaf -Generation <opaque-generation> -Leaf <single-segment>
Copy-CcodInstallSealedSource -Generation <opaque-generation> -SourcePath <sealed-source> -Leaf <single-segment> -ExpectedLength <int64> -ExpectedSha256 <hex>
Write-CcodInstallGenerationManifest -Generation <opaque-generation> -Manifest <object>
Commit-CcodInstallActivePointer -InstallRoot <absolute-root> -ExpectedPreviousGeneration <uint64> -NewRuntimeId <unique-id> -FileTransaction <context>
Retire-CcodInstallGeneration -InstallRoot <absolute-root> -RuntimeId <owned-id> -FileTransaction <context>
Close-CcodInstallFileTransaction -Transaction <opaque-context> -Disposition Ready|Failed
```

`Retire-CcodInstallGeneration` removes a generation from the active namespace
by an atomic create-only pointer/retired-record update; it does not recursively
delete the nonempty directory. Physical reclamation is a later operation that
requires no running owner and a complete safe-tree proof. This avoids a
partial-delete rollback claim and avoids persistent DACL changes.

### 3. Append-only phase and compensation record

The bootstrap writes a bounded install transaction record under `state` with
the transaction ID, old/new runtime IDs, old/new generation, package hash,
phase, and stable error code. The phases are:

```text
Prepared -> PackageVerified -> RuntimeStaged -> PreviousProtectionStopped
          -> RuntimePromoted -> PointerCommitted -> StableShellCommitted
          -> ProtectionReady -> Ready
```

`Failed` is the only terminal error phase and carries one canonical `CCOD_*`
code. All records are atomically written through the file layer. A failure
before `PointerCommitted` leaves the old pointer and bootstrap untouched. A
failure from `PointerCommitted` onward writes a higher compensating pointer to
the retained old generation and proves its Supervisor/TrayHost; if proof fails,
it retains both generations, writes `Failed/CCOD_INSTALL_ROLLBACK_FAILED`, and
does not claim readiness.

Legacy installations without this record are treated as `Idle` after the
existing pointer/runtime identity checks. Same-version repair is idempotent
only when the package hash matches; a different hash returns a conflict before
pointer mutation.

### 4. Setup and product registration

The Inno shell uses `CreateAppDir=no` and `Uninstallable=no` and has no
pre-Ready `[Files]`, `[Icons]`, `[Registry]`, or `[UninstallRun]` product
writes. It extracts only the package, manifest, and activation bootstrap to its
private temporary area, locks and validates them, and invokes the bootstrap.
The bootstrap performs the generation transaction and Setup waits for strict
`Ready` validation.

After `Ready`, a product-registration module writes and reads back the exact
current-user uninstall registration and the two exact `CodexRemote-fix`
Start-menu/desktop shortcut records. It then removes only exact legacy
registration/shortcut entries. A failed migration leaves the legacy entries.

### 5. Defender, draft, and final acceptance

Portable scans its verified payload before installation. Setup scans its
verified private package before `Prepared`. The release contract has exactly
these 11 public assets for v2.5.22:

```text
CodexRemote-fix-2.5.22-windows-x64.zip
CodexRemote-fix-2.5.22-windows-x64.zip.sha256.txt
CodexRemote-fix-2.5.22-trayhost-provenance.json
CodexRemote-fix-2.5.22-payload-manifest.json
CodexRemote-fix-2.5.22-release-manifest.json
CodexRemote-fix-2.5.22-setup.exe
CodexRemote-fix-2.5.22-setup.exe.sha256.txt
CodexRemote-fix-2.5.22-setup-provenance.json
CodexRemote-fix-2.5.22-setup-payload-manifest.json
CodexRemote-fix-2.5.22-setup-destination-inventory.iss
CodexRemote-fix-2.5.22-setup-release-manifest.json
```

The destination inventory name above is checked as part of the release contract.
Defender receipts are evidence files, not public release assets. The local
official-draft preflight downloads the Setup and ZIP
through a browser, requires actual ZoneId 3, scans each with the real Defender
entry, and records receipts bound to both asset hashes and the matching commit.

The final current-machine acceptance must prove: manifest-bound v2.5.21 Setup
upgrade; complete uninstall while preserving the DPAPI key hash; fresh v2.5.22
install; reboot auto-recovery; exactly one Supervisor and authenticated
TrayHost; and individual About, Language, OpenLogs, Repair, and second-device
remote-control evidence. The README remains candidate-oriented until those
facts are recorded; release notes may summarize only recorded facts.

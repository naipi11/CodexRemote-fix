# Task 1 report: immutable generation file layer

## Status

Implemented and committed the unprivileged immutable-generation data plane in
the assigned worktree. No release, push, tag, signing, installer execution,
product process control, WindowsApps change, DPAPI change, or persistent DACL
mutation was performed.

## RED evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `1`
- Expected failure: the old module exported the pinned/DACL transaction API;
  the required seven immutable-generation operations were absent.
- Additional retirement immutability RED: the same focused command exited `1`
  because a retired capability could still create `post-retire.bin`; GREEN now
  rejects it with `CCOD_INSTALL_GENERATION_RETIRED`.

## GREEN and verification evidence

- Focused command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `0`
- Result: `10/10` named cases passed, including duplicate generation/leaf and
  pointer generation collisions, private pinned source/destination handles,
  flush plus same-handle length/SHA-256, manifest immutability, reparse/ADS/
  multilink rejection, forged/cross-transaction/closed capabilities, handle
  release, no-replace monotonic pointer records, and nonempty retirement.
- Parser command: explicit PowerShell parser pass over the four changed files.
- Parser exit code: `0` (`Changed PowerShell parser check passed.`)
- Diff command: `git diff --check`
- Diff exit code: `0` (only Git LF-to-CRLF checkout warnings).

## Aggregate evidence and known local limitation

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
- Exit code: `1`
- Exact boundary: `Bootstrap.SelfTest.ps1`, case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck`
- Exit code: `1`
- Exact top-level marker: `CCOD_VALIDATION_FAILURE[0] Persistence self-test
  failed with exit code 1; CCOD_SELFTEST_FAILED case=selects-previous-runtime-
  after-active-exits-before-ready-and-swaps-pointer error=ASSERT_EXACT`.
- Classification: the task brief's known local Bootstrap fallback/mutex
  aggregate boundary. It is recorded as environmental and is not reported as
  a pass. The focused file-layer suite and changed-file parser checks pass.

## Windows behavior

- Generation and directory leaves use relative `NtCreateFile` `FILE_CREATE`
  semantics below validated native parent handles.
- Sealed sources are opened without write/delete sharing; destinations are
  created once, flushed, rehashed through the same handle, then handed off to
  read-only pins without exposing streams or handles.
- Active pointer records are append-only, zero-padded generation files written
  to unique temporary leaves and atomically renamed without replacement.
- Retirement validates the entire owned tree, retains the generation root
  handle while descendant handles close, then performs one no-replace relative
  rename into `retired\<runtimeId>.<unique-id>`. Bytes and the original SDDL
  remain unchanged; a create-only retirement record is retained.
- The only exported CLR type is the inert `CcodInstallCapabilityMarker`; all
  path/handle operations remain on an internal type. PowerShell capabilities
  have no public fields and are bound through module-private weak tables.

## Commit

- `e3ad4f703884ed6893f89565b2bcdc925977a37d` — `fix: use immutable generation file primitives`

## Concerns

- This is deliberately a current-user ordinary-race boundary, not protection
  against a same-user process with unrestricted DACL/write authority.
- The append-only pointer reader/consumer migration and complete manifest
  semantic validation belong to later plan tasks; Task 1 enforces create-only
  storage, manifest presence, owned runtime identity, and monotonic record
  collision behavior.
- Failed no-replace record publication can retain a unique `.ccod.*.tmp` leaf
  for diagnosis; there is intentionally no install-hot-path recursive cleanup.

## Fix round 1 — review remediation

This section supersedes the original report's description of physical
generation retirement. Retirement is now record-only; the nonempty generation
is never renamed or deleted.

### RED evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `1`
- Exact first failure: case
  `force-re-import-rebinds-the-current-runtime-ABI-before-real-use`; after two
  `Import-Module -Force` calls, real `Open-CcodInstallGeneration` failed because
  `$script:CcodRuntimeType` was unset (`VariableIsUndefined`).

### GREEN evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `0`
- Result: `13/13` named cases passed. New coverage proves:
  - ABI v2 rebinding works after two forced imports and a real create;
  - a 16-worker write/name-exchange attack during handle handoff either leaves
    a final strict handle revalidated for identity/length/SHA-256 or causes a
    stable seal failure that cannot commit;
  - successful sealed leaves remain readable by path before transaction close;
  - close races a real synchronized CLR relative create and releases source,
    destination, generation, and retained diagnostic temporary handles;
  - pointer generation `1 -> 2`, UInt64 overflow rejection, and two independent
    Windows PowerShell contenders with exactly one no-replace winner;
  - record-only retirement, collision, record-path I/O failure, post-retirement
    mutation rejection, and repeated in-transaction idempotence.
- Reliability rerun: three consecutive expanded focused runs exited `0`.
- Parser command: explicit parser pass over the four Task 1 PowerShell files.
- Parser exit code: `0` (`Changed PowerShell parser check passed.`)
- Diff command: `git diff --check`
- Diff exit code: `0` (only LF-to-CRLF checkout warnings).

### Aggregate evidence

- `tests\PersistenceSelfTest.ps1`: exit `1` at the unchanged known local case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- `tests\Validate.ps1 -SkipInstalledPackageCheck`: exit `1` with the same
  `CCOD_VALIDATION_FAILURE[0]` Bootstrap marker.
- These aggregate results remain environmental boundaries and are not called a
  pass. The expanded immutable-generation suite exits zero.

### Windows behavior after remediation

- The current CLR bridge uses `CcodInstallGenerationCapabilityMarkerV2` ABI 2;
  every module import resolves the marker and rebinds the internal runtime type
  even when the AppDomain already contains it.
- Destination handoff opens a temporary read bridge only while the private
  verified writer still pins the identity. After writer close it opens the
  strict read handle and immediately rechecks file identity, final path, plain
  file/stream/link invariants, length, and SHA-256 on that same strict handle.
- Retirement creates exactly
  `state\retired-generations\<runtimeId>.json` through the atomic no-replace
  record path. The original `runtime\<runtimeId>` tree and handles remain in
  place. State changes to retired only after record publication succeeds.
- `ExpectedPreviousGeneration = UInt64.MaxValue` fails before addition with
  `CCOD_INSTALL_POINTER_GENERATION_OVERFLOW`.

### Fix commit

- `90d9d8d6f4aa851073fb8973a47ac0c9c0f18b7d` — `fix: close immutable generation review gaps`

### Remaining concerns

- Retirement idempotence is guaranteed for repeated calls using the same live
  opaque transaction. Cross-process crash reconciliation and consumption of
  retired-generation records belong to the later lifecycle/state migration.
- A failed no-replace collision deliberately retains its unique temporary
  record for diagnosis; `Close-CcodInstallFileTransaction` releases its handle,
  and no recursive cleanup is added.

## Fix round 2 — temp-before-validation and commit-final publication

This section supersedes the fix-round-1 handoff description. No final
generation leaf, manifest, pointer record, or retirement record is created
before its private temporary object has completed copy/write, durable flush,
plain-file validation, length verification, and SHA-256 verification.

### RED evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `1`
- Exact failure: case
  `requested-final-leaf-is-absent-until-private-temporary-bytes-are-sealed`.
  A concurrent ordinary path reader observed requested `payload.bin` at length
  `0` while the expected sealed length was `22020096` bytes.

### GREEN evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `0`
- Result: `15/15` named cases passed. The two added regressions prove:
  - the first observable requested final leaf already has the exact sealed
    length and SHA-256, while no successful `.ccod.*.tmp` name remains; and
  - a source-hash failure publishes no final leaf, the source stream is owned
    by the transaction until `Close(Failed)`, and all private temp handles are
    released deterministically.
- Reliability evidence: three consecutive expanded focused runs exited `0`;
  the final post-change focused run also exited `0`.
- Parser command: explicit parser pass over the four Task 1 PowerShell files.
- Parser exit code: `0` (`Changed PowerShell parser check passed.`)
- Diff command: `git diff --check`
- Diff exit code: `0` (only LF-to-CRLF checkout warnings).

### Aggregate evidence

- `tests\PersistenceSelfTest.ps1`: exit `1` at the unchanged known local case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- `tests\Validate.ps1 -SkipInstalledPackageCheck`: exit `1` with the same
  `CCOD_VALIDATION_FAILURE[0]` Bootstrap marker.
- These aggregates remain environmental boundaries and are not called passes.

### Windows behavior after round 2

- `Copy` opens and transaction-registers its source before length/hash I/O and
  creates a generated `.ccod.<guid>.tmp` destination registered before copy,
  flush, or hash can throw.
- `Write` uses the identical private-temp path for manifest, pointer, and
  retirement JSON records.
- `SealAndPublish` closes the private writer under the unguessable temp name,
  reopens and verifies that temp through a strict read handle, closes it,
  opens the validated rename handle, applies the read-only file attribute,
  pre-registers the final dictionary key, and performs one native no-replace
  relative rename. After rename success it performs no open, flush, hash,
  stream handoff, or result allocation.
- Native `Write` returns an existing token rather than allocating an array
  after publication. PowerShell copy/manifest/pointer/retirement result objects
  and retirement capability are prepared before the native commit.
- Before pointer eligibility or retirement, `EnsurePublishedPin` reopens every
  published generation file by relative handle and revalidates identity, final
  path, link/stream type, length, and SHA-256; the read handle then becomes
  transaction-owned.
- Retirement remains exactly one create-only
  `state\retired-generations\<runtimeId>.json` record. The in-memory retired
  transition occurs only after the native record publication returns success.

### Fix commit

- `e74cfdf28fa05c2b0f8c61634b6542f41e734f45` — `fix: seal temporary leaves before publication`

### Remaining concerns

- Between copy publication and later pointer/retirement eligibility checks,
  an unrestricted same-user writer can clear the read-only attribute or rename
  the file. That actor is outside the approved unprivileged boundary; the
  eligibility path nevertheless reopens and rejects any identity/path/hash or
  unknown-leaf change before writing the control record.
- Failed no-replace publication retains a read-only diagnostic temp file but
  no stream handle. It is intentionally not recursively reclaimed in the
  install hot path.

## Fix round 2 scoped re-review — terminal retirement commit and exception-safe close

### RED evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `1`
- Exact failing case:
  `close-retries-a-failing-disposal-and-releases-every-other-registered-resource`.
  An injected first `FileStream.Dispose` exception stopped cleanup; the
  generation directory remained locked, and fixture cleanup failed with
  `The process cannot access the file ... because it is being used by another
  process.` This also proved a later close was short-circuited by the runtime's
  already-disposed flag.

### GREEN evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `0`
- Result: `16/16` named cases passed. The new deterministic disposal regression
  registers an injected throwing stream plus a real source, destination, and
  generation tree. It proves:
  - the first close attempts the throwing stream once and returns the stable,
    sanitized `CCOD_INSTALL_CLOSE_FAILED`;
  - the same first close continues to release the source and every generation
    pin, so both can be moved immediately; and
  - the second close retries the retained failed resource (attempt count 2)
    and reports the same bounded cleanup code rather than returning early.
- Reliability evidence: three consecutive expanded focused runs exited `0`.
- Parser command: explicit parser pass over the four Task 1 PowerShell files.
- Parser exit code: `0` (`Changed PowerShell parser check passed.`)
- Diff command: `git diff --check`
- Diff exit code: `0` (only LF-to-CRLF checkout warnings).

### Aggregate evidence

- `tests\PersistenceSelfTest.ps1`: exit `1` at the unchanged known local case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- `tests\Validate.ps1 -SkipInstalledPackageCheck`: exit `1` with the same
  `CCOD_VALIDATION_FAILURE[0]` Bootstrap marker.
- These aggregates remain environmental boundaries and are not called passes.

### Implementation behavior

- Native `Retire` now completes all generation/tree validation before calling
  the shared temp-record publisher. After the no-replace retirement-record
  rename, it immediately returns the already-existing generation token; the
  previous post-publication `ValidateCurrent(generation)` call is removed.
- The PowerShell retirement capability and bounded result are allocated before
  the native record commit. Only after native success are the prepared result
  stored and the private `Retired` flag set. Collision/write failure leaves
  those state fields unchanged.
- Native `Close` snapshots and attempts every registered external stream and
  pin independently. Successfully released pins are removed; failures remain
  registered for retry. The runtime is closed to further operations from the
  first attempt onward, but subsequent cleanup calls still process retained
  failures.
- `Pin.Dispose` marks a pin closed only after its handle/stream disposal
  succeeds, allowing a genuine failed release to be retried.
- The exported close wrapper records deterministic closed/cleanup-failed state
  and always maps internal cleanup exceptions to the fixed
  `CCOD_INSTALL_CLOSE_FAILED` message.

### Fix commit

- `f86d4397b4a56343db9124f655c923949e6084c0` — `fix: finalize retirement and close cleanup`

### Remaining concerns

- A resource whose `Dispose` permanently fails remains intentionally registered
  and each later `Close` reports `CCOD_INSTALL_CLOSE_FAILED`; all other
  resources are nevertheless released. No recursive deletion or DACL fallback
  is attempted.

## Fix round 3 — retained-generation targets and scoped records

### RED evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `1`
- Exact first failure: the export-surface case expected
  `Open-CcodInstallRetainedGeneration`, `New-CcodInstallDirectory`, and
  `Write-CcodInstallRecord`, but the current module exported none of them and
  pointer commit still accepted a naked runtime ID.

### GREEN evidence

- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Exit code: `0`
- Result: `19/19` named cases passed. Added deterministic coverage proves:
  - install-root `state` and nested `receipts` directories can be opened or
    created only through opaque same-transaction scopes and single-segment
    leaves;
  - JSON/JSONL records use the private-temp publisher, are complete on first
    visibility, collide without replacement, and reject multi-segment leaves;
  - an existing generation is recursively opened read-only only when its final
    path, complete structural tree, manifest hash, and manifest runtime ID
    match; missing/wrong-hash/reparse/ADS/multilink/unowned fixtures fail with
    stable codes;
  - every create/write operation rejects a retained capability;
  - pointer generations 1 and 2 can be followed by a generation-3 compensation
    record targeting the retained old runtime;
  - retained targets from a different transaction on the same root or a
    different install root are rejected; and
  - forced module re-import remains active before all new exported operations.
- Reliability evidence: three consecutive expanded focused runs exited `0`;
  the final pre-commit focused run also exited `0`.
- Parser command: explicit parser pass over the four Task 1 PowerShell files.
- Parser exit code: `0` (`Changed PowerShell parser check passed.`)
- Diff command: `git diff --check`
- Diff exit code: `0` (only LF-to-CRLF checkout warnings).

### Aggregate evidence

- `tests\PersistenceSelfTest.ps1`: exit `1` at the unchanged known local case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- `tests\Validate.ps1 -SkipInstalledPackageCheck`: exit `1` with the same
  `CCOD_VALIDATION_FAILURE[0]` Bootstrap marker.
- These aggregates remain environmental boundaries and are not called passes.

### Interface behavior

- `Open-CcodInstallRetainedGeneration` is tied to an existing writable file
  transaction. Native code opens the existing `runtime\<runtimeId>` root and
  every descendant through relative read-only handles, rejects reparse/ADS/
  multilink/final-path changes, hashes each file, verifies the exact manifest
  hash and uniquely matching manifest runtime ID, and then issues an opaque
  generation scope marked `ReadOnly`.
- Retained scopes may be used only as `TargetGeneration`; directory creation,
  source copy, manifest write, and scoped record write all fail with
  `CCOD_INSTALL_GENERATION_READ_ONLY`.
- `Commit-CcodInstallActivePointer` no longer accepts `NewRuntimeId`. It derives
  the target runtime ID only from a same-transaction opaque generation scope
  and revalidates either the owned new tree or the retained read-only tree
  before its monotonic no-replace pointer record.
- `New-CcodInstallDirectory` treats the opaque transaction itself as the
  install-root parent and composes native single-leaf open/create for bounded
  state directories. Returned child capabilities are recursively composable.
- `Write-CcodInstallRecord` accepts only a same-transaction writable directory,
  sanitized record object, and single-segment leaf; it shares the existing
  temp-before-validation/no-replace publisher.
- Native directory enumeration now removes duplicate names returned across
  repeated `NtQueryDirectoryFile` buffers before retained-tree pin creation.

### Fix commit

- `c1e3ef08f0c820db79872f8438d66d1ced94eeba` — `feat: add retained generation file capabilities`

### Remaining concerns

- Retained manifest runtime-ID validation is intentionally narrow and is also
  bound to the caller-supplied exact manifest SHA-256. Full manifest schema,
  file-list, version, and commit semantics remain the Task 2/RuntimeManifest
  consumer's responsibility.
- This round adds only Task 1 file-layer capabilities; no lifecycle module or
  installer path was migrated.

## Retained-capability extension fix — transitive read-only and ABI V3

### RED evidence

The self-test supports `CCOD_INSTALL_EXTENSION_RED_CASE` only to select one
deterministic regression while preserving all earlier focused cases. Each
targeted command used:

```powershell
$env:CCOD_INSTALL_EXTENSION_RED_CASE='<case>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
```

All five targeted RED runs exited `1` for their intended production gap:

- `retained-alias`: `ASSERT_THROWS`, expected
  `CCOD_INSTALL_GENERATION_READ_ONLY`; an alias reopened through
  transaction-root `runtime\<retained-id>` remained writable.
- `nested-retained`: `CCOD_INSTALL_RETAINED_GENERATION_INVALID`, message
  `retained open failed: Access is denied`; nested retained directories lacked
  directory-listing access.
- `semantic-runtime-id`: `ASSERT_THROWS`, expected
  `CCOD_INSTALL_RETAINED_RUNTIME_ID_MISMATCH`; regex matching accepted a nested
  `metadata.runtimeId` without a matching top-level property.
- `child-transaction`: `ASSERT_THROWS`, expected
  `CCOD_INSTALL_TRANSACTION_INVALID`; a child directory capability was
  accepted as `-FileTransaction`.
- `v3-reimport`: `TypeNotFound` for
  `CcodInstallGenerationCapabilityMarkerV3`; re-import still bound ABI V2.

The unfiltered required command also exited `1`; its first new failure was the
retained-alias `CCOD_INSTALL_GENERATION_READ_ONLY` assertion.

### GREEN evidence

- The same five targeted commands each exited `0`.
- Full command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
- Full focused exit code: `0`.
- Result: `24/24` named cases passed.
- Parser command: explicit PowerShell parser pass over
  `InstallFileTransaction.psm1` and
  `InstallFileTransaction.SelfTest.ps1`.
- Parser exit code: `0` (`TASK1_PARSER_EXIT=0`).
- Diff command:
  `git diff --check -- src/persistence/modules/InstallFileTransaction.psm1 tests/persistence/InstallFileTransaction.SelfTest.ps1`
- Diff exit code: `0` (only LF-to-CRLF checkout warnings).

### Aggregate evidence

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  exited `1` at the unchanged known local case
  `selects-previous-runtime-after-active-exits-before-ready-and-swaps-pointer`,
  error `ASSERT_EXACT`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1 -SkipInstalledPackageCheck`
  exited `1` with the same `CCOD_VALIDATION_FAILURE[0]` Bootstrap marker.
- These aggregates remain environmental boundaries and are not called passes.

### Implementation behavior

- The current CLR bridge is
  `CcodInstallGenerationCapabilityMarkerV3` / internal runtime V3 with ABI 3.
  Every import resolves and binds V3 even when the AppDomain already contains
  the old V2 marker.
- Native `retainedScopes` covers the retained generation and every descendant
  token. Directory opens propagate read-only state from a retained parent and
  also recognize a retained root reopened from the transaction-root alias.
  The PowerShell wrapper asks native `IsRetained` for each returned directory,
  so all exported create/write routes fail closed with
  `CCOD_INSTALL_GENERATION_READ_ONLY`.
- Nested retained child directories are pinned with
  `LIST_DIRECTORY | READ_ATTRIBUTES | SYNCHRONIZE`, while files remain
  read-only. Recursive final-path, reparse, ADS, multilink, identity, length,
  and SHA-256 validation remains intact.
- Native code returns the exact hash-bound manifest text. The wrapper parses it
  with `ConvertFrom-Json`, requires a top-level object and exactly one
  top-level `runtimeId` string equal to the requested ID, and rejects escaped
  or nested-only occurrences.
- `Open-CcodInstallRetainedGeneration` requires the supplied
  `-FileTransaction` object itself to be the transaction-root capability;
  child directory capabilities fail with `CCOD_INSTALL_TRANSACTION_INVALID`.

### Scope note

- The paused uncommitted Task 2 changes in `InstallLifecycle.psm1` and
  `InstallLifecycle.SelfTest.ps1` were neither edited nor staged by this fix.

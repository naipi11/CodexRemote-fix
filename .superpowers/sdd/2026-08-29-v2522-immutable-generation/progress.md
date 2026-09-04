# SDD ledger — plan: docs/superpowers/plans/2026-08-29-v2522-immutable-generation.md

## Context

- Worktree: `C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`
- Branch: `codex/v2522-install-runtime-reliability`
- Base: `03de616` (`docs: plan immutable generation release model`)
- Spec: `docs/superpowers/specs/2026-08-29-v2522-immutable-generation-design.md`
- User confirmed the no-privilege immutable-generation model on 2026-08-29.
- Older Task 1 handle/DACL implementation remains unreleased historical branch
  work and will be rewritten or superseded; no old `build/dist` asset is valid.

## Preflight plan scan

| Producer / consumer | Interface or state | Result |
| --- | --- | --- |
| Task 1 -> Task 2 | opaque create-only generation and pointer primitives | Compatible; Task 2 must not reintroduce overwrite/recursive delete. |
| Task 2 -> Task 3 | sealed generation, phase record, compensation | Compatible; Setup passes package hash and consumes strict Ready. |
| Task 3 -> Task 4 | immutable stable generation/bootstrap | Compatible; registration occurs only after Ready. |
| Task 2 -> Task 5 | pointer/receipt/manifest identity | Compatible; Defender failure must precede activation. |
| Task 3 -> Task 5 | sealed Setup package and expected hashes | Compatible; package scan has a concrete bootstrap hook. |
| Task 5 -> Task 6 | explicit 11 assets and dual receipt contract | Compatible; release code consumes one asset-name source. |
| Task 6 -> Task 7 | clean candidate and private draft | Compatible; Stage never promotes or rebuilds. |
| Task 7 -> Task 8 | official draft and downloaded asset evidence | Compatible; Preflight is the only live scan producer. |
| Task 8 -> promotion | automated lifecycle and manual tray/remote evidence | Compatible; Promote is local and evidence-bound. |

## Rulings

- Ruling: the current-user hostile-writer guarantee is removed — a process with
  unrestricted same-user write/DACL authority cannot be reliably defeated by a
  current-user utility without an elevated/signed broker. The product instead
  guarantees unique create-only generations, strict validation, atomic pointer
  commits, and retention on failure. Cost if wrong: this is a narrower security
  claim, but it is enforceable without changing install privileges.
- Ruling: install-time cleanup retires or retains old generations — it does not
  recursively delete a nonempty tree. Physical reclamation is a separate,
  exclusive maintenance/uninstall operation. Cost if wrong: disk usage grows
  until proven reclamation, but failed installs cannot partially erase a usable
  generation.
- Ruling: stable bootstrap is selected by the immutable generation/pointer
  contract; Setup does not overwrite a writable `{app}` tree before Ready.
  Legacy Inno registration is migrated only after the new generation is Ready.
  Cost if wrong: migration has an extra registration step, but stale app files
  cannot become the activation source.
- Ruling: official browser-downloaded draft assets are the live Defender scan
  source. No workflow or test fabricates ZoneId 3; public promotion waits for
  two actual receipts and the current-machine acceptance chain.

Task 1: in progress (base `03de616`)

Task 1: fix round 1/5 opened after review of `03de616..e3ad4f7` found one
Critical source/stream handoff window and three Important issues: physical
retirement remained despite the revised create-only-record model, long-lived
PowerShell re-import did not rebind its runtime type, and pointer/retirement/
close race coverage was incomplete. The review also clarified that module
session/reflection access is outside the unprivileged threat boundary. Ruling:
retirement is record-only, sealed pins remain private through the handoff, and
the runtime ABI is explicitly rebound on every import. Cost if wrong: the
process-local API is not a sandbox, but ordinary callers cannot obtain raw
handles or a partially verified generation.

Task 1: fix round 1/5 opened after scoped review of `e3ad4f7..90d9d8d` found
one Critical commit-then-failable handoff and two Important gaps: final leaves
were visible before sealing, and streams could escape transaction ownership on
early I/O failure. Ruling: every content write is registered before fallible
I/O, sealed through a private temporary leaf, and only then renamed no-replace;
record-only retirement is state-committed only after its record rename. Cost if
wrong: temporary diagnostic leaves may remain, but no caller observes a partial
final generation or a commit reported failed after it is visible.

Task 1: scoped re-review of fix round 1 remains open. The reviewer marked the
handoff/retirement/coverage set NOT ADDRESSED because a record or final leaf can
still be visible before a potentially failing handoff, retirement record state
can diverge after commit, and early destination streams may not be transaction
owned. Fix round 2 is opened against `90d9d8d`; see
`task-1-fix1-brief.md` for the complete required RED/GREEN changes. No later
task may consume this file layer until the scoped re-review is clean.

Task 1: fix round 2/5 opened after scoped review of `90d9d8d..e74cfdf` found
one Critical retirement record commit-then-fail path and one Important
exception-unsafe Close path. Ruling: retirement performs no fallible action
after record publication, and Close attempts every registered resource before
settling its closed state. Cost if wrong: a failed cleanup may retain a bounded
temporary, but it cannot report a committed record as failed or leave unrelated
handles locked behind the first disposal error.

Task 1: complete (commits `e3ad4f7..f86d439`, scoped review clean). The final
review of `e74cfdf..f86d439` marked retirement commit consistency and
exception-safe/retriable Close ADDRESSED, with no new Critical/Important
findings. Focused immutable-generation self-test is 16/16; aggregate remains
blocked only by the documented local Bootstrap fallback/mutex case.

Task 2: blocked before implementation. The Task 1 API cannot open an existing
retained generation read-only or write generic scoped state/receipt/log records,
so it cannot implement post-pointer compensation without bypassing the
create-only boundary. Ruling: extend Task 1 with retained-generation and
scoped-record primitives first; Task 2 must not invent a second path-based file
API. Cost if wrong: one additional reviewed Task 1 interface round, but
compensation remains bound to the same immutable file layer.

Task 1: fix round 3/5 opened for the retained-generation/scoped-record API
extension; see `task-1-fix3-brief.md`.

Task 1: fix round 3/5 implementation `14178fc` passed its RED/GREEN suites,
but the scoped re-review found one Important issue: Windows PowerShell
`ConvertFrom-Json` collapses duplicate top-level `runtimeId` members, so the
claimed uniqueness check was not strict. Four other findings (transitive
read-only aliases, nested retained listing, V3 re-import, and transaction-root
input) were addressed. Ruling: treat duplicate-key rejection as load-bearing
and open fix round 4/5 with a fresh implementer; no later task may consume the
extension until the scoped re-review is clean. Cost if wrong: a crafted
manifest with duplicate identity keys could be accepted as a retained target.

Task 1: fix round 4/5 (`14178fc..e80b829`) addressed the duplicate top-level
`runtimeId` finding. A scoped re-review marked the finding ADDRESSED, with
Spec Compliance PASS, Task Quality PASS, and no new Critical/Important
findings. The bounded lexical key pass composes with `ConvertFrom-Json` to
reject duplicate members while preserving decoded semantic values. Focused
coverage is 25/25; aggregate Bootstrap ASSERT_EXACT remains an environmental
boundary. Task 1 is complete (`e3ad4f7..e80b829`, review clean).

Task 2 ruling before resumption: stable-shell candidates remain inside each
immutable generation; the scheduled task and post-Ready shortcut/registration
adapters select the generation-specific bootstrap, while legacy root shell
files are retained and never overwritten in the install hot path. This keeps
the create-only file layer honest and still permits upgrades from an old
fixed-root task after the new generation reaches verified readiness. The
existing `Copy-CcodInstallSealedSource` is used only with a writable generation
capability; no root overwrite or second path-based copy API is introduced.
Cost if wrong: an old shortcut may need one post-Ready registration update, but
no incomplete upgrade can replace the only startup shell.

Task 2 ruling: immutable initialization evidence and operational state are
separate planes. The transaction writes create-only defaults below
`state\install-initializations\<runtimeId>`; only when absent are they
materialized into the existing mutable `state\*.json` and
`state\ui-preferences.json` operational plane. The Supervisor updates that
operational plane only after `Ready`; upgrades never overwrite existing or
partial files. Reason: Task1 sealing those runtime state files ReadOnly caused
real StateStore/UI writes to fail with Windows error 5. Cost if wrong: one
extra immutable evidence set per install, but normal tray/state/recovery
updates remain functional rather than silently breaking after activation.

Task 2 ruling: same-version idempotence and package-conflict behavior require
an explicit canonical `SealedPackageSha256`. A direct/legacy invocation without
that identity follows the normal upgrade path and cannot infer package equality
from `package.json`. Task 3 Setup and portable entrypoints must pass the sealed
package identity. Cost if wrong: older direct callers may perform an unnecessary
upgrade, but no unsealed or weakly identified package can silently short-circuit
activation.

Task 2 initial implementation `2101485` passed focused and aggregate tests,
but scoped review failed it with one Critical and six Important findings. The
Critical was a real generation-bootstrap break: the task points at the new
generation bootstrap while that bootstrap still requires root `active.json`,
uses the old runtime-ID format, and lifecycle readiness rejects its parent.
Ruling: fix round 1 must expand Task 2 to bootstrap and Bootstrap self-tests;
it implements the same append-only pointer and canonical runtime-ID contract.
Cost if wrong: a fresh install could report fake-test Ready yet fail on actual
task startup or after reboot.

Ruling: runtime identity is `projectVersion-fileDigest16-nonce32`, revalidated
by manifest and bootstrap; transaction records bind old/new manifest hashes,
the global entrypoint rejects every nonterminal/ambiguous chain, baseline
evidence is written for each generation, and Ready terminalization may never
append Failed after a visible Ready receipt. Cost if wrong: an attacker or
failure could select an unbound generation, bypass a pending transaction, or
leave contradictory terminal evidence.

Task 2 fix round 1 `bd5b690` passed focused suites and aggregate but scoped
re-review remained FAIL: one Critical production fence prevented actual fresh
or append-only upgrade pointer commits, two Important selector consumers still
accepted ADS/multilink/wrong root fallbacks, and the Ready-final-snapshot path
was nonterminal but not recoverable. Ruling: fix round 2 adds a V4 opaque
state-only transaction usable only to append a revalidated missing terminal
state record; it cannot touch generations or pointers. The production fence
must validate the append-only pointer directly, and every pre-runtime consumer
must reject unsafe selector roots/leaves before legacy fallback. Cost if wrong:
real installation can fail before bootstrap, authorization can trust unsafe
selector storage, or terminalization can remain permanently stuck.

Task 2 fix round 2 `f10f725` passed focused and fresh aggregate, but scoped
re-review remained FAIL with Important selector-authorization gaps: several
consumers treated every selector-root lookup failure as absence and fell back
to legacy `active.json`; StaticProbe accepted selector schema version 2; V3 to
V4 re-import evidence loaded V4 first; and Static/Uninstall hostile matrices
omitted malformed JSON. Ruling: fix round 3 must permit legacy fallback only
on a proven ItemNotFound outcome, require schema version 1 everywhere, use a
child V3-first import process, and add malformed-selector regressions. Cost if
wrong: ACL/I/O errors or malformed selectors can silently authorize an old
runtime and the ABI containment claim remains unproved.

Task 2 fix round 3 `8eb6920` passed focused and aggregate but scoped
re-review remained FAIL with two Important absence-proof gaps: an intermediate
`state` regular file can surface ItemNotFound for the child selector and allow
legacy fallback, and StaticProbe treats an adapter null/no-output result as a
proven missing selector. Ruling: fix round 4 must require a real nonreparse
`state` directory before a child absence can be accepted, and StaticProbe must
use a discriminated explicit absence result rather than optional empty output.
Cost if wrong: malformed parent storage or an adapter contract failure can
silently authorize a stale legacy runtime.

Task 2 fix round 4 `d3ec629` passed focused and aggregate but scoped
re-review remained FAIL with one Important uninstall compatibility gap: when
the `state` ancestor is truly absent, Uninstall resolves its child first and
rejects before the permitted legacy pointer fallback. Ruling: fix round 5 must
prove `state` separately, then probe the child only under a real plain
directory; add a no-state legacy fallback regression distinct from later epoch
validation. Cost if wrong: an otherwise valid legacy uninstall cannot recover
its selected runtime when the new selector plane has never been created.

Task 2 verification ruling: the Bootstrap release-failure test's 4-second
whole-process watchdog is a reproducible test-harness flake, not a production
deadlock. The real bootstrap exits about 5.1 seconds after cold start while
correctly logging release failure and killing the fallback child; the harness
kills it first at 4 seconds. Replace the fixed start-to-exit budget with a
release-attempt marker, a bounded 15-second watchdog, and a 2-second
marker-to-exit assertion while retaining log, child-exit, and mutex-release
proofs. Cost if wrong: the test becomes slightly more structured, but it keeps
detecting a swallowed release failure without being load-sensitive.

Task 2: fix round 5 `46692e7` addressed the no-state Uninstall fallback and
the reproducible Bootstrap test-harness timing flake. Scoped re-review marked
Spec Compliance PASS and Task Quality PASS with no Critical/Important
findings. Fresh local focused verification and a full
`tests\PersistenceSelfTest.ps1` aggregate both exited zero. Task 2 is complete
(`2101485..46692e7`, review clean).

Task 3 initial implementation `9e1c41c` passed focused suites but scoped
review failed with four Important gaps: portable did not propagate explicit
sealed identity; schema-2 provenance validation was partial; compiled Inno was
not executed through a safe pre-activation failure fixture; and the report
omitted the exact commit. Ruling: fix round 1 must bind portable identity,
enforce exact nested provenance schemas, run a mismatched-hash compiled Setup
fixture that fails before activation with no product state, and record the
full commit. Cost if wrong: portable differs from Setup identity semantics,
provenance can be cosmetically altered, and the no-write Inno claim lacks
runtime evidence.

Task 3 reporting ruling: a Git commit cannot record its own final hash. The
fix round therefore uses an implementation commit followed by a report-only
evidence commit that records the implementation commit's exact 40-hex SHA;
the scoped review package covers both commits. Cost if wrong: one additional
auditable documentation commit, but no self-referential or ambiguous HEAD
claim.

Task 3 fix round 1 `51def5c..728b627` passed focused suites but scoped review
remained FAIL with three Important binding gaps: portable identity was not tied
to the copied/executed payload, schema-2 provenance accepted duplicate raw JSON
members, and the compiled Setup failure fixture did not snapshot LocalAppData
product state. Ruling: fix round 2 must use the post-copy verified identity,
strictly reject duplicate keys at every provenance object level, and compare a
read-only product-tree snapshot before/after the wrong-hash compiled Setup run.
Cost if wrong: a raced portable payload or ambiguous provenance can be accepted,
and the pre-activation no-product-state claim is incomplete.

Task 3 fix round 2 `1cb9162..a5d5958` passed focused suites but scoped
re-review remained FAIL with one Important test-compliance gap: the portable
race test called only the copy helper, so its child/lifecycle absence assertions
did not prove the portable entrypoint stopped before execution. Ruling: fix
round 3 must invoke `Install-CodexRemote-fix.ps1` with a marker-capable child
fixture and race the verified source at the validation-to-copy boundary; prove
no child marker or lifecycle state before failure. Cost if wrong: portable
production may be correct but the required end-to-end race evidence is absent.

Task 3 fix round 3 `58bd760..9e971d1` passed focused suites but scoped
re-review remained FAIL: its actual-entrypoint mutation occurred during mocked
Defender and was caught by the earlier post-scan manifest validation, not by
the final validation-to-File.Copy race. Ruling: fix round 4 must use the real
entrypoint while mutating at the production copy barrier after the copy helper's
own validation, and require `CCOD_PORTABLE_COPY_HASH_MISMATCH` plus no child or
lifecycle mutation. Cost if wrong: the full-path test validates an earlier
check but not the claimed final copy boundary.

Task 4 initial implementation `e43d9ce..97cf17d` passed focused suites but
scoped review failed with one Critical and four Important findings: installed
uninstall finalizes before deleting its selected generation, matched-only
uninstall cleanup is too weak, failed post-Ready registration cannot retry,
legacy cleanup can partially delete, and exported shortcut capability accepts
arbitrary source paths. Ruling: fix round 1 must add a verified external
generation finalizer, exact registration/shortcut matching with compensating
legacy migration, post-Ready retry, and sealed-generation-only shortcut source
capabilities. Cost if wrong: Windows Settings uninstall deterministically
fails, user replacements can be deleted, registration can remain permanently
absent, or an arbitrary source can be registered as product shortcut.

Task 3 fix round 4 `141ab71..70bc231` addressed the actual production module
File.Copy-boundary portable race. Scoped re-review marked Spec Compliance PASS
and Task Quality PASS with no Critical/Important findings. Fresh local
ReleaseWorkflow, InstallLifecycle, parser/diff verification, and the full
`tests\PersistenceSelfTest.ps1` aggregate all exited zero. Task 3 is complete
(`9e1c41c..70bc231`, review clean).

Task 3 fix round 4 `141ab71..70bc231` addressed the production module
File.Copy-boundary portable race. Scoped re-review marked Spec Compliance PASS
and Task Quality PASS with no Critical/Important findings. Fresh local
ReleaseWorkflow, InstallLifecycle, parser/diff verification, and the full
`tests\PersistenceSelfTest.ps1` aggregate all exited zero. Task 3 is complete
(`9e1c41c..70bc231`, review clean).

Task 2 fix round 5 implementation passed its final verification matrix. The
Uninstall bootstrap now resolves and proves `state` separately, resolves
`state\active-generation` only below a proven plain directory, and permits a
valid legacy pointer when the whole state plane is absent without bypassing
the later lifecycle-epoch boundary. The real no-state regression includes an
invalid-pointer negative control so skipping authorization cannot satisfy it.
The Bootstrap release-failure regression now uses the ruled marker-relative
timing contract without changing production Bootstrap behavior. All eight
focused suites passed (26, 26, 21, 41, 17, 116, 24, and 9 cases), all three
changed PowerShell files parsed, `git diff --check` passed, and the full
`tests\PersistenceSelfTest.ps1` aggregate exited `0`. Task 2 fix round 5 is
ready for scoped re-review.

Task 3: complete. Setup now compiles from one version/commit-bound sealed ZIP,
its canonical package manifest, the hash-bound temporary activation bootstrap,
and setup provenance as exactly four `dontcopy` inputs. It sets
`CreateAppDir=no` and `Uninstallable=no`, has no pre-Ready `{app}` product,
shortcut, registry, uninstall, recursive extraction, or legacy app-bootstrap
path, and retains its input locks through strict append-only Ready validation.
The real disposable package/bootstrap test proves exact
`SealedPackageSha256` propagation. Final focused verification passed
ReleaseWorkflow, InstallLifecycle 113/113, parser 8/8, `git diff --check`, and
the zero-violation static boundary audit. Task 4 retains all product
registration work; Task 5 retains Defender/public-asset work.

Task 3 fix round 1 implementation
`51def5c9ae2f5e0722b9083e478b17c507e9cee8` addressed all four Important
findings from review of `46692e7..9e1c41c`: portable explicitly propagates the
twice-verified sealed identity; schema-two Setup provenance has exact ordered
nested schemas and a 24-case mutation matrix; a real wrong-hash production
Setup execution now fails nonzero from `PrepareToInstall` before activation or
product output; and `task-3-report.md` records full commit identities. Final
focused ReleaseWorkflow and InstallLifecycle 113/113 suites passed, along with
parser 4/4, diff check, and the zero-violation no-`{app}` boundary scan. The
fix-round report evidence is a separate report-only commit so the report can
truthfully contain the immutable implementation SHA.

Task 3 fix round 2 implementation
`1cb91621f2565318143dffe08844a91a350a36d9` addressed the three Important
findings from review of `9e1c41c..728b627`: portable identity is derived from
the revalidated published copy and has a real validation-to-copy race test;
raw duplicate JSON members are rejected before deserialization at every
provenance object depth; and the wrong-hash compiled Setup fixture compares a
bounded read-only before/after snapshot of the actual LocalAppData product
tree. Final ReleaseWorkflow and InstallLifecycle 113/113 suites passed, with
parser 4/4, diff check, and zero no-`{app}` boundary violations. The exact
implementation SHA is recorded through the separate report-evidence commit.

Task 3 fix round 3 implementation
`58bd7603fa83133d78d2f62ac045ec00d25134c9` replaced the helper-only portable
copy race with an actual `Install-CodexRemote-fix.ps1` invocation. A controlled
test-local Defender mutation changes the child source after initial validation;
the production entrypoint's post-Defender revalidation rejects it with
`CCOD_PORTABLE_MANIFEST_INVALID` before child marker or fixture lifecycle state.
ReleaseWorkflow and InstallLifecycle 113/113 passed, with parser 1/1 and clean
diff check. The exact implementation SHA is recorded in the separate report
evidence commit.

Task 4 fix round 1 `2e76698..0fdc392` passed focused suites but scoped review
remained FAIL with four Important gaps: finalizer path/wrapper/epoch binding
was insufficient and removed the whole root; current cleanup accepted coherently
replaced registry/shortcuts; product shortcut authority was pre-Ready/unselected;
and production legacy restoration suppressed restore failures. Ruling: fix
round 2 binds finalizer to exact transaction/runtime root/manifest/epoch and
deletes only that root, makes cleanup/retry capability derive exact Ready
transaction identity, and fails loudly on any uncompensated legacy restore.
Cost if wrong: deletion can target a sibling/root, user replacements can be
removed, or a failed migration can silently leave partial legacy state.

Task 4 and its legacy/uninstall reliability successors are complete through `9d7cc90`, with evidence and
review acceptance through `3eea951`. The true v2.5.21 lifecycle bridge, exact historical registration
profiles, durable pre-write migration plan, same-SID/new-session TaskRemoved recovery, post-reclamation
staged resume, pinned generation reclamation, and Runtime V7 ABI closure all passed their scoped reviews.
The latest frozen persistence aggregate exited 0. Task 5 is now in progress; Tasks 6–8 remain blocked.

Task 5 implementation `fb163b7b6b594e302cf4dffe1dedd055b5f8d9d4` centralizes the exact ordered
11-asset contract, binds schema-two Defender receipts to explicit origin/status/clock and post-scan
identity evidence, requires two distinct official Internet-download receipts cross-checked against the
real asset directory, and scans Setup's held sealed package before any extraction or lifecycle mutation.
Frozen verification passed ReleaseWorkflow 58/58, PortableRelease 5/5, InstallLifecycle 151/151, parser
103/103, diff check, and all 39 aggregate suites. No real Defender/build/install/network/release action
was performed. Task 5 scoped review FAIL (1 Critical, 3 Important): the public Defender function exposes
full-fact adapters; the central contract shallow-validates nested payload/provenance; asset identity is not
handle-held across scan/promotion; and receipt writing lacks production read-back. Task 5 fix round 1 is in
progress. Tasks 6–8 remain blocked.

Task 5 fix round 1 implementation `9f8a9e7f4aa8ba6028941026cbca776cbd908610`
closes the four scoped-review findings without changing the 11 public names,
receipt schema, candidate docs, or Setup/portable ordering. Public Defender
surfaces no longer accept adapters or a library bypass; nested portable/Setup
payload and provenance are exact; scan and promotion hold asset/receipt
identities through the decision; and receipts require production write/read-back.
Frozen verification passed ReleaseWorkflow 63 declared cases, PortableRelease
5/5, InstallLifecycle 151/151, parser 104/104, diff check, and all 39 aggregate
suites. No real Defender/build/install/network/release action was performed.
Task 5 scoped re-review of `fb163b7..9f8a9e7` is PASS (Spec Compliance PASS,
Task Quality PASS, 0 Critical, 0 Important). Original findings 1-4 are closed.
Task 5 is complete. Task 6 is in progress; Tasks 7-8 remain blocked.

Task 6 fix round is implemented in the current worktree after the first scoped review
returned 4 Critical and 7 Important findings. The fix adds fail-closed clean-runner
inspection and create-only preflight evidence; binds prepare/preflight/build/stage to
one resolved 40-hex commit and transfers preflight as a pinned artifact; removes the
GitHub environment bypass and pins every gh call to `naipi11/CodexRemote-fix`; uses a
real same-tag named mutex; separates `defender/`, `verification/`, and `acceptance/`
evidence; persists and revalidates Verify hashes; and requires exact remote asset/state
read-back before and after promotion. No live GitHub, Defender, network, publication,
installation, or reboot action was performed.
Focused Task 6 slices, full ReleaseWorkflow, Bootstrap 27/27, PowerShell/YAML parsing,
static security checks, and the formal `npm test` validation all passed. The old
InstallLifecycle branding assertion was updated to the new draft-tool ownership and
its standalone suite passed 151. A constrained independent re-review inspected the exact staged Task 6 diff and returned PASS with no findings. The implementation was committed as `6d9bafa96c252ece692e8aff35e420285479b7b6`, and the required public module wrappers were restored and verified in corrective commit `325985d9a56bc222be1eb6a73dfb60b6326706da`; the verification report is committed separately. No live GitHub, Defender, network, publication, installation, or reboot action was performed.
Task 6 fix-round implementation and independent acceptance are complete. Task 7/8 official draft acceptance remains blocked until its own gates are implemented.

# v2.5.22 Install and Runtime Reliability Design

## Goal

Make a fresh installation and an upgrade from any supported historical
CodexRemote-fix installation converge on one verified current-user runtime,
then keep remote recovery and tray actions reliable while preserving the
existing strict process-identity security boundary.

## Evidence driving this design

The reported v2.5.21 machine contained a current versioned runtime while its
installer shell and active pointer could still describe an older payload.  The
current Inno route treats a correlated `Ready` receipt as sufficient evidence;
it does not bind the receipt to the setup version or verify the final active
runtime manifest.  Separately, normal Electron child-process churn can make
the one-pass verified-tree read fail during a close operation even though the
top-level Codex root has not changed.  Native tray commands reach TrayHost but
the production result path reduces every rejected or failed action to the same
generic dialog.

## Non-negotiable constraints

- Remain a current-user Windows installation.  Do not modify `ChatGPT.exe`,
  `app.asar`, `WindowsApps`, account state, or the DPAPI device-key store.
- Retain exact PID, creation time, user SID, package family, executable path,
  session, and debug-port checks.  A retry must never convert an identity
  mismatch into success.
- The setup and portable paths must reject an incomplete or stale payload
  instead of reporting successful activation.
- Preserve a working old runtime until the new active pointer, Supervisor, and
  TrayHost have all been proven ready.
- Keep end-user tray text concise; write sanitized support codes to the local
  log rather than exposing raw implementation details in a dialog.

## Architecture

### 1. Immutable, version-bound installer payload

The setup package installs its executable payload into
`{app}\payload\<ProjectVersion>` and launches activation from that exact
directory.  Build generates an `installer-payload-manifest.json` in the same
directory with a schema version, project version, and ordered SHA-256 records
for every file the lifecycle installer may copy.  The activation worker accepts
the compile-time expected version, validates the versioned payload manifest and
the local `package.json`, and passes the expected version and manifest path to
the lifecycle installer.

`InstallLifecycle` consumes the validated manifest records as its source-file
allowlist.  It no longer discovers arbitrary leftover files under `{app}`.
After the scheduled task signals readiness it rereads `active.json`, validates
the selected runtime manifest, and requires that the manifest project version
equals the expected setup version before it writes a terminal `Ready` receipt.
This works for new users because the versioned payload directory is created
from scratch, and for upgrades because an old app root cannot substitute its
payload for the requested version.

Build creates a one-time generated `.iss` from the checked-in template by
replacing one fixed inventory marker with the verified destination-directory
procedure. The template contains no external `#include` or `#+` directive;
build rejects both spellings before ISCC runs. This avoids attempting to
reimplement ISPP preprocessing while making the directory inventory and the
exact source compiled by ISCC one artifact.

### 2. Bounded stable-tree acquisition

Add a retry wrapper around verified Electron process-tree acquisition for
close/recovery work.  It makes a small, bounded number of fresh snapshots with
a short condition-based delay only when a read is indeterminate or the child
set is transient.  Every successful attempt must independently prove the same
top-level root identity and a self-consistent tree.  If the root PID, creation
time, session, SID, package family, executable path, command line mode, or
recorded debug ports change, the operation remains fail-closed immediately.

The wrapper is used before a mutation starts and for a transient rich snapshot
read of an already verified member.  Once a close transition is written, the
existing per-member pre-stop, post-stop, and final identity checks remain
strict.  A `SameIdentity` result is required before retrying a null or
mismatched rich snapshot; an absent or changed root remains fail-closed.

The same bounded policy applies to Supervisor's `RemoteVerified` rebind: it
may retry an indeterminate reread of the exact candidate root, but a different
root, changed creation time, changed ports, or a malformed state read remains
an immediate failed proof.  Diagnostics classify the last stable failure
boundary so a future support log can distinguish tree churn from an unsafe
process identity.

### 3. Tray action correlation and diagnostics

Keep the authenticated TrayHost protocol and revision/capability gates.  Add a
small sanitized action-result record that includes the command, presentation
revision, terminal status, and stable error code.  Add an end-to-end test that
drives a native menu command through the real host transport, presentation ACK
map, Supervisor authorization, and result ACK.  A missing acknowledged revision
must be reported as `CCOD_TRAY_ACTION_STALE`; a current acknowledged revision
must reach the specific handler.

## Acceptance criteria

1. A test simulating an old installer payload with a newer requested setup
   version fails before changing the active pointer and returns a stable
   activation error.
2. A matching versioned payload activates exactly the expected runtime and the
   final receipt is `Ready` only after pointer and manifest revalidation.
3. Fresh and upgrade fixtures copy only manifest-listed payload files; stale
   app-root leftovers cannot enter a new runtime.
4. A stable root plus one transient child-tree read succeeds within the fixed
   retry budget; a changed root identity still fails without a retry-based
   bypass.
5. Tray end-to-end action tests prove an acknowledged current revision succeeds
   and a stale revision is rejected with a recorded support code.
6. Existing persistence, package, release, native TrayHost, and Defender gates
   remain green.  A real current-user setup install, reboot, remote connection,
   About, language switching, open logs, and repair are all checked before
   release completion.

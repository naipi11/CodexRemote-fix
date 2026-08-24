# Lifecycle and Tray Redesign

**Status:** Approved by the user on 2026-08-23

**Target release:** CodexRemote-fix 2.5.0

**Scope:** Replace the fragile post-install restart chain with one durable Supervisor-owned lifecycle, simplify the tray menu to remote-connection essentials, and make install, upgrade, safe exit, restart, repair, and uninstall behavior explicit and testable.

## 1. Problem statement

CodexRemote-fix 2.4.24 successfully installs and starts its current runtime, but the user-visible lifecycle is not reliable:

- choosing **Yes** in the post-install prompt can close Codex without launching it again;
- a later manual Codex launch does not necessarily resume the remote repair;
- the tray can report that the current session is ready when the `Control other devices` tab is absent;
- menu switches can appear to change while their values are lost or silently rejected across IPC;
- the menu exposes overlapping or ambiguous actions such as immediate repair, retry, automation, compatibility trials, and `Uninstall supervisor...`;
- the installer can appear frozen at 100% while runtime activation is still executing;
- an upgrade can finish while an older Supervisor or TrayHost is still the visible process;
- uninstall behavior differs between the tray, Windows Settings, and `unins000.exe`.

The observed 2.4.24 restart failure was not an installer-copy failure or an invalid Codex AUMID. Runtime `2.4.24-880e7e3de4f7a991` was activated, and the new Supervisor and TrayHost started. The restart wrapper then remained in `Recover`, failed to prove an ordinary Codex process within its short observation window, and never reached `Apply`. When the user later started Codex manually, no durable pending Apply request remained and automation was disabled.

The current tray also calculates Boolean toggle values in the native host but does not serialize them in its action frame. This makes a true-to-false transition appear to work while a false-to-true transition is normally received as false. Language commands have a separate enum path, but the UI gives no completion acknowledgement and can remain visually stale.

## 2. User-approved product decisions

1. Supervisor is the sole owner of Codex lifecycle and remote-repair transitions.
2. The tray is reduced to connection status, guardian status, one repair action, language, logs, About, and Exit.
3. Connection guarding is always enabled while CodexRemote-fix is running; it is no longer a user-facing toggle.
4. `Manual retry`, `Allow compatible update trials`, and tray uninstall are removed.
5. Uninstall is available through Windows Settings and the installed `unins000.exe` only.
6. **Exit** means safe exit for the current login session:
   - if a verified remote-enabled Codex session is active, warn the user and recover an ordinary Codex session first;
   - stop TrayHost and Supervisor only after recovery is proven;
   - keep the installed runtime, task registration, settings, logs, and device authorization;
   - start again at the next Windows login or when the user launches CodexRemote-fix from Start/Desktop.
7. Release notes are English only. The application tray remains bilingual.

## 3. Goals

The redesign MUST:

1. Complete or durably resume every user-approved Codex restart and repair.
2. Never equate an Explorer/AppsFolder launch receipt with a verified Codex process.
3. Never show a connected/ready state unless the current special Codex session and remote renderer integration are verified.
4. Preserve device keys, paired-device authorization, user preferences, and state across upgrades.
5. Keep the installer responsive and expose bounded activation phases instead of appearing frozen at 100%.
6. Stop the old Supervisor and TrayHost before considering an upgrade complete.
7. Give every tray action a visible accepted, completed, or failed outcome.
8. Make language changes atomic, acknowledged, persistent, and immediately visible.
9. Provide a safe Exit that is distinct from uninstall.
10. Make Windows Settings and `unins000.exe` use the same fail-closed uninstall workflow.
11. Remain current-user only, non-elevated, offline, manifest-bound, and source auditable.

## 4. Non-goals

The redesign MUST NOT:

- introduce a Windows service, administrator requirement, Run-key entry, network listener, or second scheduled task;
- directly execute the protected WindowsApps Codex binary;
- revoke server-side device authorization during an ordinary upgrade or safe exit;
- silently restart Codex when the user chooses **Later**;
- leave an unverified special Codex session running without Supervisor ownership;
- add advanced compatibility or experimental controls back to the primary tray menu;
- treat logs, prior transactions, or the presence of a tray process as proof that remote control is active.

## 5. Chosen architecture

The stable task and bootstrap remain the entry point, but all lifecycle mutations are serialized through the active, manifest-verified Supervisor:

```text
Inno Setup / Start shortcut / Tray action
                 |
                 v
       durable lifecycle request
                 |
                 v
        active Supervisor owner
         |        |        |
         |        |        +--> TrayHost presentation and actions
         |        +-----------> SessionController repair/recovery
         +--------------------> Runtime/task/install coordination
```

There is exactly one lifecycle owner for a request. The installer and prompt may submit and observe a request, but they do not independently run Recover followed by Apply while Supervisor is active. If no verified Supervisor exists, a manifest-bound one-shot controller may acquire the same lifecycle lease and complete the request; it must not run concurrently with Supervisor.

## 6. Durable restart-and-repair transaction

### 6.1 State model

Every approved restart receives a random transaction ID and an atomic on-disk request with these phases:

```text
Requested
  -> CloseRequested
  -> CloseConfirmed
  -> OrdinaryLaunchRequested
  -> OrdinaryObserved | WaitingForManualLaunch
  -> WaitingForManualLaunch -> OrdinaryObserved
  -> RepairRequested
  -> RemoteVerified
  -> Completed
```

Terminal failure phases are:

```text
CloseFailed
OrdinaryLaunchFailed
OrdinaryObservationTimedOut
LaunchWindowExpired
RepairFailed
VerificationFailed
CancelledBeforeClose
SupersededByUpgrade
```

`SupersededByUpgrade` is legal only from `Requested` before process mutation. `WaitingForManualLaunch` is nonterminal and can transition only to `OrdinaryObserved`, `LaunchWindowExpired`, an ownership/upgrade cancellation terminal, or a fail-closed state-integrity terminal. `LaunchWindowExpired` carries stable code `CODEX_LAUNCH_WINDOW_EXPIRED`. No implementation may invent an implicit phase or treat a diagnostic code as a completed phase.

The record includes schema version, transaction ID, active runtime ID, source Codex identity when present, phase, attempt counters, timestamps, last stable error code, and whether the request came from the installer, tray, shortcut, or automatic guardian. It contains no device key, token, account name, or remote endpoint.

Writes use the existing atomic JSON and transition-journal primitives. Each record also carries an owner runtime ID, active-runtime generation, lifecycle-lease epoch, and owner PID/creation time. Supervisor resumes a nonterminal request after its own restart, prompt exit, or task restart only when all ownership fields still match the active manifest and lease.

The named lifecycle mutex supplies mutual exclusion but is not itself a fencing token. A separate `lifecycle-epoch.json` lives in the current-user mutable state root outside every immutable versioned runtime. It is protected by the existing explicit current-user/System ACL and reparse-boundary checks. Its only counter is an unsigned 64-bit integer.

Every successful or abandoned-mutex lifecycle acquisition, including install, upgrade, rollback, Supervisor restart, one-shot recovery, safe Exit, and uninstall, performs this sequence while holding the mutex:

1. strictly read and validate the current epoch;
2. fail closed if it is missing outside first-install initialization, malformed, duplicated, or `UInt64.MaxValue`;
3. increment it exactly once;
4. atomically persist and read back the incremented value;
5. write that exact value and owner identity into the transaction before any mutation.

Gaps caused by a crash after increment are legal; reuse, decrement, reset on reboot/upgrade/rollback, or wraparound is forbidden. Immediately before every Codex process mutation and every transaction commit, the owner rereads the epoch and active generation and requires exact equality with its transaction plus exact PID/creation-time ownership. A mismatch makes the owner stale and fail closed. Epoch creation, concurrent acquisition, abandoned mutex, crash after increment/write/read-back, corruption, rollback, reboot, uninstall/reinstall, and wraparound are deterministic test cases. A full uninstall may delete the counter only after all owners and the task are proven stopped; a later clean install starts a new state root at epoch 1.

### 6.1.1 Runtime upgrade fencing

An in-flight Codex mutation is never transferred from one versioned runtime to another. Cross-runtime adoption is forbidden.

Before switching `active.json`, the installer acquires the same lifecycle lease and handles the old runtime as follows:

- a request still in `Requested` and with no process mutation may be cancelled as `SupersededByUpgrade`;
- a request at or after `CloseRequested` must be driven by the old runtime to either `RemoteVerified`, a proven ordinary-Codex terminal state, or a fail-closed terminal state before upgrade continues;
- if the old owner cannot prove a stable terminal state, upgrade stops and leaves the previous active runtime unchanged;
- after `active.json` changes generation, the new runtime rejects every request whose runtime ID, generation, or lease epoch belongs to the old runtime;
- the installer restart prompt is shown only after the new runtime is active and ready, so its request is created directly under the new generation;
- rollback restores the previous runtime only when no new-generation Codex mutation has begun. Otherwise rollback is blocked and the new runtime must first reach a proven stable state.

Lifecycle writes compare the lease epoch immediately before every process mutation and terminal commit. A stale owner may record diagnostics but cannot close, launch, repair, recover, or complete a transaction. Tests crash the installer/Supervisor before and after every lease, stable-state, `active.json`, task-start, and readiness boundary.

### 6.2 Close and recovery

Supervisor identifies Codex by PID, creation time, package path/identity, Windows session, and the current status evidence. It stops only the exact verified process tree owned by the transaction.

When the current session is special, Recover must prove one of two safe states before continuing:

- no Codex root process remains and the transaction owns the stopped special process; or
- an ordinary Codex root process exists and is verified as the recovery result.

A failure to prove either state is not success and cannot be converted into Apply.

### 6.3 Ordinary Codex launch

Ordinary launch uses the current packaged-app route:

```text
explorer.exe shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App
```

The Explorer receipt means only `LaunchRequested`. Supervisor then waits for a new ordinary Codex root process and validates:

- exact package family/AUMID contract;
- process path and package identity;
- current Windows session and user;
- PID and creation time newer than the launch request;
- absence of the special renderer/inspector arguments reserved by CodexRemote-fix.

Observation uses bounded backoff with a nominal 45-second immediate deadline, not a fixed five-second single window. AppsFolder activation is attempted at most three times for one transaction, with centrally defined bounded delays. These constants are versioned fields in the lifecycle contract and covered by delayed-launch tests.

If automatic launch cannot be proven, the transaction enters `WaitingForManualLaunch` for ten minutes measured from the first `OrdinaryLaunchRequested` timestamp. This window:

- persists across a Supervisor/task restart in the same Windows logon session;
- does not cross a runtime upgrade or a new Windows logon;
- observes but does not repeatedly close or relaunch Codex;
- accepts only a newly created, verified ordinary Codex root process in the same user/session;
- advances to `OrdinaryObserved` and continues Apply when such a process appears;
- expires as `CODEX_LAUNCH_WINDOW_EXPIRED`, clears automatic mutation intent, updates the tray, and requires a new explicit repair action.

`Later` creates no transaction and therefore can never enter this window. A later user-launched ordinary Codex process can resume only a still-valid `WaitingForManualLaunch` transaction. The tray shows `Waiting for Codex` or the stable failure state rather than `Connected`.

### 6.4 Apply and verification

After `OrdinaryObserved`, Supervisor submits exactly one correlated Apply request through SessionController. Completion requires all current dynamic verification gates, including the special root-process identity and renderer integration evidence.

If Apply fails, Supervisor leaves or restores an ordinary usable Codex instance where safely possible, records the exact stable error code, and exposes `Repair needed` with the one repair action enabled. It never reports ready from a historical transaction.

## 7. Post-install prompt and installer behavior

### 7.1 Prompt choices

The prompt remains English-only:

- **Yes / Restart now** submits a durable restart-and-repair request to the verified new Supervisor and returns after the request is accepted. It does not run a second Recover/Apply controller in parallel.
- **No / Later** records no restart request and leaves the current Codex process and active conversation untouched.

If the request cannot be accepted, the prompt shows an English error with a stable support code and does not close Codex.

### 7.2 Responsive activation

Setup displays bounded phases before completion:

```text
Stopping the previous runtime
Installing the new runtime
Activating the new runtime
Starting connection protection
Ready
```

Long-running work must not execute on the installer UI thread without message pumping. Setup reserves progress for activation and does not display 100% before the new runtime handshake has completed or a clear recoverable error has been returned.

### 7.3 Upgrade ownership

An upgrade performs:

1. stage and verify the new runtime;
2. acquire the install/lifecycle lease;
3. signal the old Supervisor and verify its exit;
4. atomically switch `active.json`;
5. start the scheduled task and verify the new Supervisor/TrayHost readiness handshake;
6. clean obsolete runtimes only after the new runtime is ready;
7. release the lease and show the restart prompt.

`IgnoreNew` task behavior must not hide a request. Failure to prove that the old task instance is idle blocks new-runtime success and preserves the previous runtime for rollback.

## 8. Simplified tray contract

### 8.1 Fixed information architecture

The menu contains only:

```text
CodexRemote-fix 2.5.0
Connection: Connected | Repair needed | Checking | Waiting for Codex | Error
Protection: Running | Reconnecting | Stopping
------------------------------------------------
Check and repair remote connection
Language / 语言 >
Open logs
About
------------------------------------------------
Exit
```

Chinese uses equivalent concise strings. Title, connection status, and protection status are disabled information rows. `Check and repair`, language choices, logs, About, and Exit are the only actions.

The following items are removed from the menu and command authorization surface:

- `ManualRetry`;
- `SetAutomation`;
- `SetCandidateOptIn`;
- tray uninstall and its confirmation submenu.

Legacy command IDs are rejected without side effects. They are not silently reinterpreted as new actions.

### 8.2 Truthful status

Connection status is derived from current verified session evidence:

- **Connected:** the current special Codex process and remote integration are verified.
- **Checking:** a correlated repair/verification request is running.
- **Waiting for Codex:** no suitable current Codex process exists, including a pending delayed relaunch.
- **Repair needed:** an ordinary Codex process exists but remote integration is absent or failed.
- **Error:** state integrity, ownership, or a fail-closed safety gate prevents repair.

Protection status describes Supervisor ownership, not server connectivity:

- **Running:** Supervisor owns the lifecycle lease and is observing Codex.
- **Reconnecting:** a durable restart/repair transaction is advancing.
- **Stopping:** safe Exit has begun and no new action is accepted.

### 8.3 Check and repair

The single repair action is idempotent. It:

1. inspects current Codex and persisted state;
2. adopts/resumes an existing compatible transaction or creates one;
3. avoids restarting an already verified connected session;
4. advances the durable lifecycle to `RemoteVerified`;
5. updates the menu and shows a concise success or failure notification.

Repeated clicks for the same presentation revision do not create concurrent workers.

### 8.4 Language

Language remains `System`, `Chinese`, or `English`. A change is complete only after:

1. Supervisor validates the selected enum;
2. the preference is written atomically;
3. the catalog is resolved;
4. a new complete presentation is acknowledged by TrayHost;
5. the next menu opens using that acknowledged presentation.

Failure rolls back the preference and menu and shows an allow-listed error. TrayHost must rebuild the native menu from the latest acknowledged snapshot; it may not reuse stale menu strings. Selection persists across process and Windows restarts.

### 8.5 About

About reads the active verified runtime manifest and displays:

```text
CodexRemote-fix | Version 2.5.0
```

It does not rely on an installer filename or a stale TrayHost assembly from an older runtime.

### 8.6 Safe Exit

Exit follows the approved A behavior:

1. stop accepting new tray actions;
2. inspect the current session;
3. when a verified special session exists, show a warning that Codex will restart and remote control will stop;
4. on confirmation, execute the durable Recover flow and prove an ordinary Codex state;
5. atomically write a same-logon safe-exit intent containing schema version, trusted logon identity, active runtime ID, and completed recovery transaction ID;
6. stop TrayHost, release the lifecycle lease, and let Supervisor exit successfully;
7. leave the scheduled task registered but not running until the next logon or explicit Start/Desktop launch.

Cancel leaves everything unchanged. If recovery fails, Exit is refused, protection remains running, and the user receives a stable error. Exit never invokes the uninstaller.

The trusted logon identity comes from the current process token's `TOKEN_STATISTICS.AuthenticationId` LUID obtained through `GetTokenInformation`, canonically encoded as fixed-width high/low hexadecimal fields and bound to the exact user SID and Windows SessionId. SessionId alone is never sufficient. Bootstrap, Supervisor, task entry, and explicit shortcut entry derive the identity independently from their own verified current-user token; no identity is accepted from argv or an untrusted file.

Bootstrap and Supervisor both honor the safe-exit intent. A stale task retry with the exact same LUID/SID/SessionId exits successfully without recreating TrayHost. Task restart-on-failure is not triggered by a completed safe exit. A valid marker is cleared only by a different trusted logon identity, an explicit Start/Desktop launch, uninstall, or a successfully authorized runtime upgrade. An explicit launch carries a fixed local entry-point mode, acquires the lifecycle lease, verifies current identity, and only then clears the marker so a scheduled-task race cannot create two Supervisors.

If an automatic task start cannot read or validate either the marker or token identity, it fails closed without starting protection and records a stable diagnostic. An explicit Start/Desktop launch may replace an unreadable marker only after acquiring the lease and showing a local confirmation; it never trusts data from the corrupt marker. A different valid LUID/SID/SessionId is treated as a new logon and expires the old marker. Tests cover RDP disconnect/reconnect, Fast User Switching, SessionId reuse, reboot, task retry, explicit launch, marker corruption, token-query failure, and cross-user attempts.

If Supervisor crashes after recovery but before the marker or shutdown commit is complete, the next owner resumes the safe-exit transaction rather than starting guardian work. If it crashes before recovery is proven, protection restarts and the menu shows the failure; it must not leave an unowned special session. Tests cover task retries, reboot/logon, explicit launch, upgrade, and crashes at every safe-exit boundary.

## 9. Tray transport changes

The next protocol revision uses an allow-list containing only:

```text
CheckAndRepair
SetLanguageSystem
SetLanguageChinese
SetLanguageEnglish
OpenLogs
ShowAbout
Exit
```

Every action contains action ID, expected presentation revision, and command enum. Language is encoded by the command enum; no unused optional value is required. Supervisor authorizes an action only when it is enabled in the last acknowledged presentation.

Completion is explicit:

- immediate UI-only commands return an action acknowledgement;
- lifecycle actions return accepted plus their transaction ID, and presentation updates expose progress;
- rejected/stale/duplicate actions have no side effect and receive a stable result.

### 9.1 Preserved security invariants

Menu simplification does not weaken the native-host security design. Protocol major version increments and both peers reject a mismatched major version before accepting an action. The following existing invariants remain mandatory:

- parent and child verify exact PID, creation time, active runtime ID, executable/assembly identity, and capability set;
- the authenticated session uses a fresh parent challenge, Host nonce, nonzero epoch, directional HKDF-derived keys, HMAC-SHA256, and exact monotonic sequence numbers;
- frame magic, typed schema, strict UTF-8, enum allow-lists, trailing-byte rejection, and the 16 KiB payload limit remain enforced;
- action IDs have a bounded per-epoch replay cache, and stale presentation revisions are rejected;
- `ActionAck` is correlated to action ID; lifecycle acceptance additionally carries the durable transaction ID;
- presentation acknowledgement is emitted only after the native menu snapshot is applied;
- authentication, sequence, framing, identity, heartbeat, or acknowledgement failure fails closed and cannot execute a command;
- user actions cannot starve the reserved control queue or shutdown acknowledgement.

Protocol tests include wrong version, wrong runtime/generation, wrong parent/Host identity, bad HMAC, replay, skipped sequence, oversized/trailing payload, removed legacy command IDs, stale revision, duplicate action ID, missing acknowledgement, and transaction/action correlation.

## 10. Uninstall contract

Windows Settings and the installed `unins000.exe` enter the same Inno uninstaller and invoke one runtime-bound workflow:

1. Inno starts a stable uninstall bootstrap from the installer root.
2. The bootstrap validates its own installed path, current user, install root, `active.json`, active runtime manifest, hashes, reparse boundaries, and the manifest-bound runtime cleanup entry point.
3. It acquires an uninstall/lifecycle lease and writes a resumable uninstall transaction outside every tree that will be deleted.
4. It disables new guardian work.
5. If a verified special session exists, it recovers ordinary Codex; if no Supervisor exists and no special session is verified, it skips recovery safely.
6. It signals Supervisor/TrayHost shutdown and proves exact process exit.
7. It removes the scheduled task, runtime, application state/logs, desktop shortcut, and Start-menu shortcut in recorded phases.
8. Inno removes the installer files and registration only after the cleanup helper reports success.
9. The transaction is marked complete and its nonsensitive receipt is retained for diagnostics; an interrupted uninstall resumes or produces a retryable error instead of silently completing.

Failure to prove recovery or shutdown stops deletion. The uninstaller must not remove a runtime tree underneath an unverified live process. There is no hidden prompt or divergent tray-only uninstall path.

The DPAPI-protected device-key store is outside the application install/state tree and remains in its original Codex profile location by default. Uninstall does not copy, move, weaken ACLs, or create a second private-key copy. A full key wipe is outside the 2.5.0 uninstall scope. Documentation identifies the preservation behavior and states how to revoke devices in Codex before uninstall when the user wants server-side access removed.

The uninstall transaction and helper staging directory are current-user only, reject reparse targets, inherit an explicit user/System ACL, contain no private-key material, and are removed after a successful receipt. Cleanup order, bootstrap/hash failure, ACL/reparse rejection, runtime deletion interruption, Inno finalization failure, reboot, and retry are covered by negative and installed integration tests.

## 11. Failure handling and diagnostics

Stable lifecycle codes distinguish at least:

```text
RESTART_REQUEST_REJECTED
CODEX_CLOSE_UNPROVEN
CODEX_LAUNCH_REQUEST_FAILED
CODEX_LAUNCH_UNOBSERVED
REMOTE_APPLY_FAILED
REMOTE_VERIFICATION_FAILED
SUPERVISOR_REPLACEMENT_FAILED
TRAY_PRESENTATION_UNACKNOWLEDGED
LANGUAGE_CHANGE_ROLLED_BACK
SAFE_EXIT_RECOVERY_FAILED
UNINSTALL_SHUTDOWN_UNPROVEN
```

The installer, prompt, Supervisor, and SessionController share the transaction ID. Prompt stderr is not discarded. Logs record phase, stable code, runtime ID, PID/creation-time evidence where non-sensitive, and duration. They never record device keys, authentication tokens, remote endpoints, or private user content.

## 12. Compatibility and data preservation

- Upgrade from 2.4.x preserves `device-key`, settings, UI preferences, verified package cache, and compatible state.
- A migration converts `automationEnabled` into the always-running guardian policy; the obsolete toggle is no longer displayed or authoritative.
- Candidate-compatible policy remains an internal compatibility decision, not a tray preference.
- Old TrayHost protocol peers cannot control the new Supervisor. Runtime activation replaces both sides atomically.
- Profile mapping and paired-device authorization are not regenerated during ordinary upgrade or repair.

## 13. Verification matrix

### 13.1 Deterministic tests

- lifecycle state transitions, crash/resume, adoption, stale request rejection, and single-owner lease;
- upgrade fencing, generation/epoch mismatch, rollback boundary, and crashes at every active-runtime switch boundary;
- packaged launch receipt versus observed Codex process;
- delayed launch beyond five seconds and within the configured deadline;
- manual Codex launch resuming a pending repair;
- truthful presentation for every connection/protection state;
- language round trip and rollback after missing acknowledgement;
- stale, duplicate, removed, and unauthorized tray commands;
- safe Exit cancel, success, recovery failure, and relaunch from shortcut;
- same-logon task retry suppression plus marker clearing on explicit launch/new logon/upgrade;
- uninstall with and without a live Supervisor;
- stop failure preventing deletion;
- state and device-key hash preservation across upgrade and in-place device-key preservation across uninstall.

### 13.2 Installed Windows integration tests

The release candidate must be installed and exercised on the target Windows machine for:

| Scenario | Required result |
| --- | --- |
| Fresh install, Codex closed | Runtime/task/tray ready; Later leaves Codex closed; repair can launch and activate Codex |
| Fresh install, Codex open, Later | No Codex process or conversation interruption |
| Fresh install, Codex open, Yes | Codex closes, visibly relaunches, remote tab is verified, authorized devices remain |
| Upgrade from 2.4.24 | No old Supervisor/TrayHost remains; active runtime and About agree |
| Slow packaged launch | Pending transaction resumes and reaches RemoteVerified |
| Manual launch after failed automatic launch | Pending repair continues without another installer run |
| Language stress | System/Chinese/English round trip succeeds at least ten times |
| Repair action | Correct behavior when connected, ordinary, absent, busy, and failed |
| Safe Exit | Warning/recovery when connected; task remains; Start shortcut and next logon restore guardian |
| Windows Settings uninstall | Processes/task/files/shortcuts removed with no hidden blocking prompt |
| `unins000.exe` uninstall | Same result and diagnostics as Windows Settings |

### 13.3 Release gates

Before publishing 2.5.0:

1. all PowerShell, Node, native TrayHost, installer, clean-room, and persistence self-tests pass;
2. installed-runtime provenance matches the checkout and release commit byte-for-byte;
3. the final installer receives a clean local Defender scan with Internet Zone metadata;
4. the final installer SHA-256 and checksum asset are verified after upload;
5. GitHub Actions pass on the release commit;
6. the English release note records the lifecycle rewrite, simplified tray, safe Exit, and upgrade preservation;
7. the current machine is upgraded with the final asset and the full Yes/repair/tray flow is verified before completion is claimed.

## 14. Documentation changes

README and README.zh-CN will describe:

- the simplified tray menu and status meanings;
- Restart now versus Later;
- safe Exit versus uninstall;
- Windows Settings/`unins000.exe` uninstall paths;
- upgrade preservation of paired-device authorization;
- concise recovery steps when the tray shows `Repair needed` or `Waiting for Codex`.

Release notes remain English-only.

## 15. Implementation boundary

This specification authorizes the architecture but not a partial patch. Implementation must be split into test-driven tasks and reviewed before merge. No release is complete until the installed end-to-end matrix passes on the actual final installer.

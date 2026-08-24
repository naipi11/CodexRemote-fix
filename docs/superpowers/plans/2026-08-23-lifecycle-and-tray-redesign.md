# Lifecycle and Tray Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver CodexRemote-fix 2.5.0 with a durable Supervisor-owned restart/repair lifecycle, a truthful simplified tray, safe Exit, responsive upgrades, and one fail-closed uninstall path.

**Architecture:** A new persistent lifecycle layer owns transaction phases, a monotonic epoch fence, active-runtime generation, and trusted logon identity. Supervisor is the sole mutation owner and advances one durable request through verified close, ordinary launch observation, Apply, and remote verification; installer prompts and tray actions only submit correlated requests. TrayHost protocol v2 carries the reduced action allow-list and authenticated action results, while install and uninstall reuse the same lifecycle lease and readiness evidence.

**Tech Stack:** Windows PowerShell 5.1, C# 5 targeting .NET Framework 4.8, Win32 APIs, Inno Setup 6, Node.js 22, GitHub Actions on Windows.

**Spec:** `docs/superpowers/specs/2026-08-23-lifecycle-and-tray-redesign-design.md`

## Global Constraints

- Windows 10 1809 or later; current-user, non-elevated installation only.
- Keep exactly one scheduled task, using `Interactive`, `Limited`, and `IgnoreNew`.
- Never execute the protected WindowsApps Codex binary directly; ordinary activation uses `explorer.exe shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App`.
- Preserve device keys, authorized-device mapping, UI preferences, and compatible state on upgrade.
- Default uninstall leaves the DPAPI device-key store in its original Codex profile path and never copies, moves, or deletes it.
- Keep TrayHost on .NET Framework 4.8 with no WinForms, WPF, Windows App SDK, or third-party runtime dependency.
- Preserve authenticated tray framing: exact identity, version negotiation, fresh nonce/epoch, directional HKDF keys, HMAC-SHA256, sequence enforcement, replay rejection, and 16 KiB payload ceiling.
- Release notes are English-only; README and tray UI remain English/Chinese.
- Every implementation task follows red-green-refactor and ends in a focused commit.
- Do not tag, publish, install over the user's active machine, restart Codex, or uninstall the current version until the installed-machine gate explicitly authorizes that mutation.

## File and responsibility map

### New lifecycle units

- `src/persistence/modules/LifecycleTransaction.psm1` — strict request schema, legal phase reducer, atomic request/receipt persistence.
- `src/persistence/modules/LifecycleEpoch.psm1` — lifecycle mutex wrapper, monotonic uint64 epoch, generation/owner fencing.
- `src/persistence/modules/TrustedLogonIdentity.psm1` — token AuthenticationId LUID, SID/Session binding, safe-exit intent.
- `src/persistence/modules/LifecycleCoordinator.psm1` — pure next-step decision engine for restart, repair, and safe Exit.
- `src/persistence/modules/LifecycleRequest.psm1` — bounded current-user request inbox, Supervisor acceptance receipts, wake event.
- `src/persistence/LifecycleWorker.ps1` — one manifest-bound close/launch/observe/apply/verify operation per invocation.
- `src/persistence/UninstallBootstrap.ps1` — stable Inno entry that stages and resumes the manifest-bound uninstall workflow.

### Existing units that retain one responsibility

- `TransitionJournal.psm1` remains the low-level SessionEngine journal; it does not receive 2.5.0 lifecycle phases.
- `SessionController.ps1` remains the fenced single-operation controller.
- `Supervisor.ps1` owns orchestration, worker slots, tray authorization, and lifecycle advancement.
- `SupervisorEngine.psm1` remains a pure decision/presentation reducer.
- TrayHost C# owns native UI and authenticated transport only; it never repairs, launches, or uninstalls.
- `InstallLifecycle.psm1` owns versioned runtime staging/activation and the common uninstall cleanup phases.

---

### Task 1: Add the durable lifecycle transaction schema and reducer

**Files:**
- Create: `src/persistence/modules/LifecycleTransaction.psm1`
- Create: `tests/persistence/LifecycleTransaction.SelfTest.ps1`
- Modify: `src/persistence/modules/StateStore.psm1`
- Modify: `tests/persistence/StateStore.SelfTest.ps1`

**Interfaces:**
- Produces: `New-CcodLifecycleRequest`, `Read-CcodLifecycleRequest`, `Write-CcodLifecycleRequest`, `Move-CcodLifecyclePhase`, `Complete-CcodLifecycleRequest`, `Get-CcodLifecycleRequestPath`, `Get-CcodLifecycleReceiptPath`.
- Request shape: schema version 1 with exact ordered properties `schemaVersion,transactionId,kind,origin,runtimeId,runtimeGeneration,leaseEpoch,ownerIdentity,logonIdentity,phase,createdAtUtc,updatedAtUtc,launchRequestedAtUtc,manualLaunchExpiresAtUtc,automaticLaunchAttempts,error`.
- Phase allow-list: `Requested`, `CloseRequested`, `CloseConfirmed`, `OrdinaryLaunchRequested`, `WaitingForManualLaunch`, `OrdinaryObserved`, `RepairRequested`, `RemoteVerified`, `Completed`, plus the terminal phases from the specification.
- Consumes: `Read-CcodStrictJson` and `Write-CcodAtomicJson` from `PersistenceIO.psm1`.

- [ ] **Step 1: Write failing phase-graph and strict-shape tests**

Add tests that construct one restart request and exercise every legal edge. The core fixture must be exact, not a loose mock:

```powershell
$owner = [pscustomobject][ordered]@{ pid=401; creationTimeUtc='2030-02-03T04:05:06.0000000Z' }
$logon = [pscustomobject][ordered]@{ authenticationId='00000000:000003E7'; userSid='S-1-5-21-1-2-3-1001'; sessionId=2 }
$request = New-CcodLifecycleRequest -Kind RestartAndRepair -Origin Installer -RuntimeId '2.5.0-0123456789abcdef' `
    -RuntimeGeneration 7 -LeaseEpoch 11 -OwnerIdentity $owner -LogonIdentity $logon `
    -NowUtc '2030-02-03T04:05:07.0000000Z' -TransactionId '11111111-2222-3333-4444-555555555555'
Assert-CcodEqual 'Requested' $request.phase 'new lifecycle request starts at Requested'
$close = Move-CcodLifecyclePhase -Request $request -NextPhase CloseRequested -NowUtc '2030-02-03T04:05:08.0000000Z'
Assert-CcodEqual 'CloseRequested' $close.phase 'Requested advances to CloseRequested'
Assert-CcodThrows { Move-CcodLifecyclePhase -Request $request -NextPhase RepairRequested -NowUtc '2030-02-03T04:05:08.0000000Z' } 'CCOD_LIFECYCLE_PHASE_INVALID'
```

Cover `Requested -> SupersededByUpgrade`, the complete success graph, `OrdinaryLaunchRequested -> WaitingForManualLaunch -> OrdinaryObserved`, window expiry, every failure terminal, extra/missing/reordered/script properties, invalid GUID/timestamp/runtime/generation/epoch/owner/logon, terminal immutability, and corrupted persisted JSON.

- [ ] **Step 2: Run the new test and verify red**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleTransaction.SelfTest.ps1
```

Expected: FAIL because `LifecycleTransaction.psm1` and `New-CcodLifecycleRequest` do not exist.

- [ ] **Step 3: Implement the exact request constructor and transition table**

Start the module with explicit constants and an ordered transition map:

```powershell
Set-StrictMode -Version 2.0
$script:CcodLifecycleKinds = @('RestartAndRepair','CheckAndRepair','SafeExit')
$script:CcodLifecycleOrigins = @('Installer','Tray','ExplicitStart','Guardian')
$script:CcodLifecycleTransitions = [ordered]@{
    Requested = @('CloseRequested','SupersededByUpgrade','CancelledBeforeClose')
    CloseRequested = @('CloseConfirmed','CloseFailed')
    CloseConfirmed = @('OrdinaryLaunchRequested','RepairRequested')
    OrdinaryLaunchRequested = @('OrdinaryObserved','WaitingForManualLaunch','OrdinaryLaunchFailed','OrdinaryObservationTimedOut')
    WaitingForManualLaunch = @('OrdinaryObserved','LaunchWindowExpired')
    OrdinaryObserved = @('RepairRequested')
    RepairRequested = @('RemoteVerified','RepairFailed','VerificationFailed')
    RemoteVerified = @('Completed')
}
$script:CcodLifecycleTerminal = @(
    'Completed','CloseFailed','OrdinaryLaunchFailed','OrdinaryObservationTimedOut','LaunchWindowExpired','RepairFailed',
    'VerificationFailed','CancelledBeforeClose','SupersededByUpgrade'
)

function New-CcodLifecycleRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('RestartAndRepair','CheckAndRepair','SafeExit')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Installer','Tray','ExplicitStart','Guardian')][string]$Origin,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)][UInt64]$LeaseEpoch,
        [Parameter(Mandatory)]$OwnerIdentity,
        [Parameter(Mandatory)]$LogonIdentity,
        [Parameter(Mandatory)][string]$NowUtc,
        [string]$TransactionId = ([guid]::NewGuid().ToString('D'))
    )
    [pscustomobject][ordered]@{
        schemaVersion=1; transactionId=$TransactionId; kind=$Kind; origin=$Origin
        runtimeId=$RuntimeId; runtimeGeneration=$RuntimeGeneration; leaseEpoch=$LeaseEpoch
        ownerIdentity=$OwnerIdentity; logonIdentity=$LogonIdentity; phase='Requested'
        createdAtUtc=$NowUtc; updatedAtUtc=$NowUtc; launchRequestedAtUtc=$null
        manualLaunchExpiresAtUtc=$null; automaticLaunchAttempts=0; error=$null
    }
}
```

Implement strict ordered-property validation before reads/writes and make `Move-CcodLifecyclePhase` clone the request rather than mutating the caller's object.

- [ ] **Step 4: Implement atomic state initialization and migration hook**

Extend `Initialize-CcodState` so a 2.4.x state root gains no active request, creates the lifecycle receipt directory with existing ACL adapters, and leaves `device-key`, `verified-packages.json`, `status.json`, and UI preferences untouched:

```powershell
$lifecycleRoot = Join-Path $StateRoot 'lifecycle'
if (-not (& $adapter.DirectoryExists $lifecycleRoot)) {
    & $adapter.CreateDirectory $lifecycleRoot
}
```

The module must treat a missing active request as idle, but reject a malformed existing request as `CCOD_LIFECYCLE_STATE_INVALID`.

- [ ] **Step 5: Run focused persistence tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleTransaction.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\StateStore.SelfTest.ps1
```

Expected: both PASS, including strict-property and migration cases.

- [ ] **Step 6: Commit the transaction foundation**

```powershell
git add src/persistence/modules/LifecycleTransaction.psm1 src/persistence/modules/StateStore.psm1 tests/persistence/LifecycleTransaction.SelfTest.ps1 tests/persistence/StateStore.SelfTest.ps1
git commit -m "Add durable lifecycle transaction model"
```

### Task 2: Add monotonic lifecycle epoch and active-runtime generation fencing

**Files:**
- Create: `src/persistence/modules/LifecycleEpoch.psm1`
- Create: `tests/persistence/LifecycleEpoch.SelfTest.ps1`
- Modify: `src/persistence/modules/RuntimeManifest.psm1`
- Modify: `tests/persistence/RuntimeManifest.SelfTest.ps1`
- Modify: `src/persistence/modules/KernelObjects.psm1`
- Modify: `tests/persistence/KernelObjects.SelfTest.ps1`

**Interfaces:**
- Produces: `Enter-CcodLifecycleOwnership`, `Assert-CcodLifecycleFence`, `Exit-CcodLifecycleOwnership`, `Read-CcodLifecycleEpoch`.
- Ownership receipt exact properties: `schemaVersion,lease,epoch,runtimeId,runtimeGeneration,ownerIdentity,released`.
- Upgrades active pointer to schema version 2: `schemaVersion,activeRuntime,previousRuntime,generation,updatedAtUtc`.
- Consumes: `Enter-CcodMutex`, `Exit-CcodMutex`, strict atomic JSON, and Task 1 request fields.

- [ ] **Step 1: Write failing epoch and generation tests**

Use adapters with an in-memory epoch store to prove strict increments and stale-owner rejection:

```powershell
$first = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 `
    -OwnerIdentity ([pscustomobject][ordered]@{pid=101;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}) `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -TimeoutMilliseconds 1000 -Adapters $adapters
Exit-CcodLifecycleOwnership -Ownership $first -Adapters $adapters | Out-Null
$second = Enter-CcodLifecycleOwnership -InstallRoot $root -RuntimeId '2.5.0-a' -RuntimeGeneration 3 `
    -OwnerIdentity ([pscustomobject][ordered]@{pid=102;creationTimeUtc='2030-02-03T04:05:07.0000000Z'}) `
    -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 2 -TimeoutMilliseconds 1000 -Adapters $adapters
Assert-CcodEqual 1 ([UInt64]$first.epoch) 'first lifecycle owner receives epoch one'
Assert-CcodEqual 2 ([UInt64]$second.epoch) 'next lifecycle owner increments epoch'
Assert-CcodThrows { Assert-CcodLifecycleFence -InstallRoot $root -Ownership $first -Adapters $adapters } 'CCOD_LIFECYCLE_FENCE_STALE'
```

Cover missing-after-initialization, malformed, negative, floating-point, `UInt64.MaxValue`, atomic write failure, read-back mismatch, abandoned mutex, crash gap, rollback, reboot simulation, stale generation, stale owner PID/creation time, and release idempotence.

- [ ] **Step 2: Run focused tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
```

Expected: lifecycle epoch test fails because the module is absent; runtime manifest test fails once schema-v2 expectations are added.

- [ ] **Step 3: Implement epoch acquisition under the existing mutex**

The implementation must increment while holding the mutex and read back before returning:

```powershell
function Enter-CcodLifecycleOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][UInt64]$RuntimeGeneration,
        [Parameter(Mandatory)]$OwnerIdentity,
        [Parameter(Mandatory)][string]$UserSid,
        [Parameter(Mandatory)][int]$SessionId,
        [int]$TimeoutMilliseconds=15000,
        [hashtable]$Adapters
    )
    $lease = Enter-CcodMutex -Kind AccountTransition -UserSid $UserSid -SessionId $SessionId -TimeoutMilliseconds $TimeoutMilliseconds
    if ($lease.Outcome -cne 'Acquired') { throw 'CCOD_LIFECYCLE_LEASE_TIMEOUT' }
    try {
        $current = Read-CcodLifecycleEpoch -InstallRoot $InstallRoot -Adapters $Adapters
        if ($current -eq [UInt64]::MaxValue) { throw 'CCOD_LIFECYCLE_EPOCH_EXHAUSTED' }
        $next = [UInt64]($current + 1)
        Write-CcodLifecycleEpoch -InstallRoot $InstallRoot -Epoch $next -Adapters $Adapters
        if ((Read-CcodLifecycleEpoch -InstallRoot $InstallRoot -Adapters $Adapters) -ne $next) { throw 'CCOD_LIFECYCLE_EPOCH_UNPROVEN' }
        return [pscustomobject][ordered]@{schemaVersion=1;lease=$lease;epoch=$next;runtimeId=$RuntimeId;runtimeGeneration=$RuntimeGeneration;ownerIdentity=$OwnerIdentity;released=$false}
    } catch {
        Exit-CcodMutex -Lease $lease | Out-Null
        throw
    }
}
```

Use normalized `ErrorRecord` codes instead of throwing raw strings in production code. `Assert-CcodLifecycleFence` rereads both epoch and active pointer generation immediately before every caller-authorized mutation.

- [ ] **Step 4: Implement active-pointer schema v2 migration**

`Read-CcodActiveRuntime` accepts schema v1 only for migration, maps its current active pointer to generation 1, and writes schema v2 under lifecycle ownership. Every later `Set-CcodActiveRuntime` increments generation exactly once and returns the committed pointer:

```powershell
[pscustomobject][ordered]@{
    schemaVersion = 2
    activeRuntime = $NewRuntimeId
    previousRuntime = $OldRuntimeId
    generation = [UInt64]($CurrentGeneration + 1)
    updatedAtUtc = $NowUtc
}
```

No downgrade to schema v1 is allowed.

- [ ] **Step 5: Run focused and full persistence tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleEpoch.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\KernelObjects.SelfTest.ps1
npm run test:persistence
```

Expected: all PASS; existing v1 fixture migration remains deterministic.

- [ ] **Step 6: Commit fencing**

```powershell
git add src/persistence/modules/LifecycleEpoch.psm1 src/persistence/modules/RuntimeManifest.psm1 src/persistence/modules/KernelObjects.psm1 tests/persistence/LifecycleEpoch.SelfTest.ps1 tests/persistence/RuntimeManifest.SelfTest.ps1 tests/persistence/KernelObjects.SelfTest.ps1
git commit -m "Fence lifecycle owners by epoch and runtime generation"
```

### Task 3: Add trusted logon identity and safe-exit intent persistence

**Files:**
- Create: `src/persistence/modules/TrustedLogonIdentity.psm1`
- Create: `tests/persistence/TrustedLogonIdentity.SelfTest.ps1`
- Modify: `src/persistence/modules/StateStore.psm1`
- Modify: `tests/persistence/StateStore.SelfTest.ps1`

**Interfaces:**
- Produces: `Get-CcodTrustedLogonIdentity`, `Read-CcodSafeExitIntent`, `Write-CcodSafeExitIntent`, `Test-CcodSafeExitIntentForCurrentLogon`, `Clear-CcodSafeExitIntent`.
- Identity exact properties: `authenticationId,userSid,sessionId`; `authenticationId` is `XXXXXXXX:XXXXXXXX` from `TOKEN_STATISTICS.AuthenticationId`.
- Safe-exit intent exact properties: `schemaVersion,logonIdentity,runtimeId,recoveryTransactionId,createdAtUtc`.
- Consumes: existing current-user ACL/reparse adapters and atomic JSON.

- [ ] **Step 1: Write failing identity and marker tests**

Inject a token adapter rather than requiring the test process's live token:

```powershell
$adapters = @{
    GetTokenStatistics = { [pscustomobject][ordered]@{AuthenticationHighPart=0;AuthenticationLowPart=999} }
    GetCurrentUserSid = { 'S-1-5-21-1-2-3-1001' }
    GetCurrentSessionId = { 2 }
}
$identity = Get-CcodTrustedLogonIdentity -Adapters $adapters
Assert-CcodEqual '00000000:000003E7' $identity.authenticationId 'LUID has canonical fixed-width encoding'
$intent = Write-CcodSafeExitIntent -StateRoot $root -LogonIdentity $identity -RuntimeId '2.5.0-a' `
    -RecoveryTransactionId '11111111-2222-3333-4444-555555555555' -NowUtc '2030-02-03T04:05:06.0000000Z' -Adapters $fileAdapters
Assert-CcodTrue (Test-CcodSafeExitIntentForCurrentLogon -Intent $intent -LogonIdentity $identity) 'same trusted logon is suppressed'
```

Cover RDP reconnect with the same LUID, Fast User Switching, SID mismatch, SessionId reuse with a different LUID, reboot/new LUID, token-query failure, malformed marker, reparse path, cross-user ACL, explicit clear, and missing marker.

- [ ] **Step 2: Run test and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrustedLogonIdentity.SelfTest.ps1
```

Expected: FAIL because the module and functions are absent.

- [ ] **Step 3: Implement the token-statistics adapter and strict identity**

Use one `Add-Type` declaration for `OpenProcessToken`, `GetTokenInformation`, `TOKEN_STATISTICS`, and `CloseHandle`. Production construction must be equivalent to:

```powershell
$statistics = & $adapter.GetTokenStatistics
$authenticationId = '{0:X8}:{1:X8}' -f ([UInt32]$statistics.AuthenticationHighPart),([UInt32]$statistics.AuthenticationLowPart)
[pscustomobject][ordered]@{
    authenticationId = $authenticationId
    userSid = (& $adapter.GetCurrentUserSid)
    sessionId = [int](& $adapter.GetCurrentSessionId)
}
```

Reject zero/invalid handles, short buffers, noncanonical SID, negative SessionId, extra properties, and failures with stable `CCOD_LOGON_IDENTITY_UNAVAILABLE`.

- [ ] **Step 4: Implement safe-exit intent read/write/compare**

Write the marker only after recovery is proven. Automatic task startup with a corrupt/unreadable marker returns a fail-closed result; an explicit launch may clear it only after lifecycle ownership and local confirmation. The comparison must require exact equality of all three identity fields.

- [ ] **Step 5: Run focused tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrustedLogonIdentity.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\StateStore.SelfTest.ps1
```

Expected: PASS.

- [ ] **Step 6: Commit trusted logon support**

```powershell
git add src/persistence/modules/TrustedLogonIdentity.psm1 src/persistence/modules/StateStore.psm1 tests/persistence/TrustedLogonIdentity.SelfTest.ps1 tests/persistence/StateStore.SelfTest.ps1
git commit -m "Persist safe exit by trusted logon identity"
```

### Task 4: Separate verified close, ordinary launch request, and ordinary observation

**Files:**
- Modify: `src/persistence/modules/ProcessControl.psm1`
- Modify: `src/persistence/modules/SessionEngine.psm1`
- Modify: `src/persistence/SessionController.ps1`
- Modify: `tests/persistence/ProcessControl.SelfTest.ps1`
- Modify: `tests/persistence/SessionEngine.SelfTest.ps1`
- Modify: `tests/persistence/SessionController.SelfTest.ps1`

**Interfaces:**
- Produces: `Request-CcodOrdinaryPackagedLaunch`, `Wait-CcodVerifiedOrdinaryRoot`, `Invoke-CcodCloseSession`.
- `Request-CcodOrdinaryPackagedLaunch` returns exact properties `outcome,requestedAtUtc,launcherPid` with outcome `LaunchRequested`; it never returns a Codex snapshot.
- `Wait-CcodVerifiedOrdinaryRoot` accepts `NotBeforeUtc`, expected SID/SessionId, timeout, and status evidence; it returns a verified ordinary snapshot or `$null`.
- SessionController request schema version 2 adds `runtimeGeneration,leaseEpoch,ownerIdentity`; action allow-list becomes `Inspect,Close,Apply,RepairRenderer`.
- Consumes: Tasks 1–2 fence assertions immediately before every stop/start/bridge/status/terminal write.

- [ ] **Step 1: Write failing launch-receipt versus observation tests**

Add a ProcessControl fixture where Explorer starts immediately but Codex appears after eight observations:

```powershell
$receipt = Request-CcodOrdinaryPackagedLaunch -RequestedAtUtc '2030-02-03T04:05:06.0000000Z' -Adapters $adapters
Assert-CcodEqual 'LaunchRequested' $receipt.outcome 'Explorer receipt is only a launch request'
Assert-CcodEqual $null $receipt.PSObject.Properties['Snapshot'] 'launch receipt cannot claim a Codex snapshot'
$ordinary = Wait-CcodVerifiedOrdinaryRoot -NotBeforeUtc $receipt.requestedAtUtc -ExpectedUserSid $sid -ExpectedSessionId 2 `
    -StatusEvidence $status -TimeoutMilliseconds 45000 -Adapters $adapters
Assert-CcodEqual 9001 $ordinary.Pid 'delayed verified ordinary root is observed'
```

Add negative cases for pre-existing ordinary roots, special/debug argv, wrong package/path/SID/session, PID creation before request, no process by deadline, three AppsFolder requests maximum, and a stale lifecycle fence before launch.

- [ ] **Step 2: Write failing fenced controller tests**

Construct a schema-v2 `Close` request and make the fence adapter become stale before the first stop:

```powershell
$request = [pscustomobject][ordered]@{
    schemaVersion=2;action='Close';transactionId='11111111-2222-3333-4444-555555555555'
    runtimeId='2.5.0-a';runtimeGeneration=[UInt64]4;leaseEpoch=[UInt64]9
    ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
    supervisorIdentity=$supervisor;source=$special;existingOnly=$true;rendererPort=$null;mainPort=$null
    timeoutMilliseconds=30000;restartOrdinary=$false
}
Assert-CcodThrows { Invoke-CcodSessionController -Request $request -Paths $paths -ResultPath $result -Adapters $staleFenceAdapters } 'CCOD_LIFECYCLE_FENCE_STALE'
Assert-CcodEqual 0 $world.StopCalls 'stale owner never stops Codex'
```

Repeat the fence flip before special launch, bridge injection, status write, transition completion, and controller final result.

- [ ] **Step 3: Run focused tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProcessControl.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SessionEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SessionController.SelfTest.ps1
```

Expected: new tests fail because the APIs and request fields do not exist.

- [ ] **Step 4: Implement ordinary launch and observation**

Keep the existing AppsFolder route but split the receipt from observation:

```powershell
function Request-CcodOrdinaryPackagedLaunch {
    param([Parameter(Mandatory)][string]$RequestedAtUtc,[hashtable]$Adapters)
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $process = & $adapter.StartProcess `
        ([IO.Path]::GetFullPath((Join-Path $env:WINDIR 'explorer.exe'))) `
        @('shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App') $null
    [pscustomobject][ordered]@{outcome='LaunchRequested';requestedAtUtc=$RequestedAtUtc;launcherPid=if($null -eq $process){$null}else{[int]$process.Id}}
}
```

`Wait-CcodVerifiedOrdinaryRoot` uses bounded monotonic time, delays `250,500,1000,2000` milliseconds capped at two seconds, and validates the returned process snapshot with the existing exact package/process helpers. The lifecycle coordinator, not this function, owns the three-attempt policy and ten-minute manual window.

- [ ] **Step 5: Expose fenced Close and schema-v2 controller handling**

Refactor the existing verified child-first close into `Invoke-CcodCloseSession`. Remove ordinary relaunch from the `Close` action. Call `AssertLifecycleFence` from the controller adapters immediately before each mutation and commit:

```powershell
& $Adapter.AssertLifecycleFence $Request.runtimeGeneration $Request.leaseEpoch $Request.ownerIdentity
$receipt = & $Adapter.StopProcess $member $StatusEvidence $processTimeout
```

Manual/public v1 requests remain read-only compatible only where existing documented wrappers require them; no v1 request may execute the new durable workflow.

- [ ] **Step 6: Run focused tests and persistence suite**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProcessControl.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SessionEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SessionController.SelfTest.ps1
npm run test:persistence
```

Expected: PASS.

- [ ] **Step 7: Commit the fenced process boundary**

```powershell
git add src/persistence/modules/ProcessControl.psm1 src/persistence/modules/SessionEngine.psm1 src/persistence/SessionController.ps1 tests/persistence/ProcessControl.SelfTest.ps1 tests/persistence/SessionEngine.SelfTest.ps1 tests/persistence/SessionController.SelfTest.ps1
git commit -m "Separate Codex launch requests from verified observation"
```

### Task 5: Add the pure lifecycle coordinator and manifest-bound worker

**Files:**
- Create: `src/persistence/modules/LifecycleCoordinator.psm1`
- Create: `src/persistence/LifecycleWorker.ps1`
- Create: `tests/persistence/LifecycleCoordinator.SelfTest.ps1`
- Create: `tests/persistence/LifecycleWorker.SelfTest.ps1`
- Modify: `src/persistence/modules/WorkerRuntime.psm1`
- Modify: `tests/persistence/WorkerRuntime.SelfTest.ps1`
- Modify: `src/persistence/modules/RuntimeManifest.psm1`
- Modify: `tests/persistence/RuntimeManifest.SelfTest.ps1`

**Interfaces:**
- Produces: `Get-CcodLifecycleStep`, `Reduce-CcodLifecycleWorkerResult`.
- Step result exact properties: `kind,nextPhase,workerAction,deadlineUtc,errorCode`; worker actions are `None,Inspect,Close,RequestOrdinaryLaunch,ObserveOrdinary,Apply,VerifyRemote`.
- `LifecycleWorker.ps1` accepts canonical `RequestPath` and `ResultPath`, verifies the active runtime/manifest, reads schema version 1 worker requests, and writes one correlated result.
- Consumes: Tasks 1–4; produces the worker contract used by Supervisor in Task 6.

- [ ] **Step 1: Write failing coordinator table tests**

Build a table where each phase plus current observation returns one exact step:

```powershell
$cases = @(
    @{Phase='Requested';Kind='RestartAndRepair';Observation='Special';Next='CloseRequested';Action='Close'},
    @{Phase='CloseConfirmed';Kind='RestartAndRepair';Observation='NoCodex';Next='OrdinaryLaunchRequested';Action='RequestOrdinaryLaunch'},
    @{Phase='WaitingForManualLaunch';Kind='RestartAndRepair';Observation='Ordinary';Next='OrdinaryObserved';Action='None'},
    @{Phase='OrdinaryObserved';Kind='RestartAndRepair';Observation='Ordinary';Next='RepairRequested';Action='Apply'},
    @{Phase='RepairRequested';Kind='RestartAndRepair';Observation='RemoteVerified';Next='RemoteVerified';Action='None'}
)
function New-CcodCoordinatorFixture {
    param([string]$Phase,[string]$Kind)
    [pscustomobject][ordered]@{
        schemaVersion=1;transactionId='11111111-2222-3333-4444-555555555555';kind=$Kind;origin='Tray'
        runtimeId='2.5.0-a';runtimeGeneration=[UInt64]4;leaseEpoch=[UInt64]9
        ownerIdentity=[pscustomobject][ordered]@{pid=401;creationTimeUtc='2030-02-03T04:05:06.0000000Z'}
        logonIdentity=[pscustomobject][ordered]@{authenticationId='00000000:000003E7';userSid='S-1-5-21-1-2-3-1001';sessionId=2}
        phase=$Phase;createdAtUtc='2030-02-03T04:05:00.0000000Z';updatedAtUtc='2030-02-03T04:05:00.0000000Z'
        launchRequestedAtUtc=$null;manualLaunchExpiresAtUtc=$null;automaticLaunchAttempts=0;error=$null
    }
}
foreach($case in $cases){
    $step=Get-CcodLifecycleStep -Request (New-CcodCoordinatorFixture -Phase $case.Phase -Kind $case.Kind) -Observation $case.Observation -NowUtc '2030-02-03T04:06:00.0000000Z'
    Assert-CcodEqual $case.Next $step.nextPhase "$($case.Phase) next phase"
    Assert-CcodEqual $case.Action $step.workerAction "$($case.Phase) worker action"
}
```

Cover all three request kinds, already-connected idempotence, close failure, launch-attempt count, 45-second immediate deadline, ten-minute expiry, manual launch, Apply/verification failure, stale ownership, safe Exit ordinary/no-Codex paths, and terminal no-op behavior.

- [ ] **Step 2: Write failing worker authorization tests**

Assert the worker rejects wrong runtime/generation, reparse paths, request/result aliases, extra properties, unknown action, stale fence, and an uncorrelated controller result. For `RequestOrdinaryLaunch`, assert only a launch receipt is returned.

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleCoordinator.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleWorker.SelfTest.ps1
```

Expected: FAIL because both units are absent.

- [ ] **Step 4: Implement the coordinator as a pure reducer**

The reducer contains no file, process, UI, or clock calls. It validates its request and observation arguments, then returns an ordered result. Use versioned constants:

```powershell
$script:CcodImmediateLaunchTimeoutMilliseconds = 45000
$script:CcodManualLaunchWindowMilliseconds = 600000
$script:CcodMaximumAutomaticLaunchAttempts = 3
```

`CheckAndRepair` returns `Completed` without restart when remote evidence is already verified. `SafeExit` never routes to Apply.

- [ ] **Step 5: Implement one-operation LifecycleWorker**

The worker request uses exact properties:

```powershell
[pscustomobject][ordered]@{
    schemaVersion=1; transactionId=$transactionId; action=$action
    runtimeId=$runtimeId; runtimeGeneration=[UInt64]$generation; leaseEpoch=[UInt64]$epoch
    ownerIdentity=$owner; notBeforeUtc=$notBeforeUtc; timeoutMilliseconds=$timeoutMilliseconds
}
```

Each action calls one existing manifest-bound facade and writes a result with `schemaVersion,transactionId,action,ok,outcome,observation,error`. It does not loop across lifecycle phases.

- [ ] **Step 6: Add the worker to the runtime manifest allow-list and run tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleCoordinator.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleWorker.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\WorkerRuntime.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
```

Expected: PASS.

- [ ] **Step 7: Commit the coordinator and worker**

```powershell
git add src/persistence/modules/LifecycleCoordinator.psm1 src/persistence/LifecycleWorker.ps1 src/persistence/modules/WorkerRuntime.psm1 src/persistence/modules/RuntimeManifest.psm1 tests/persistence/LifecycleCoordinator.SelfTest.ps1 tests/persistence/LifecycleWorker.SelfTest.ps1 tests/persistence/WorkerRuntime.SelfTest.ps1 tests/persistence/RuntimeManifest.SelfTest.ps1
git commit -m "Add Supervisor lifecycle coordinator"
```

### Task 6: Make Supervisor the sole lifecycle owner and accept durable requests

**Files:**
- Create: `src/persistence/modules/LifecycleRequest.psm1`
- Create: `tests/persistence/LifecycleRequest.SelfTest.ps1`
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `src/persistence/modules/SupervisorEngine.psm1`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`
- Modify: `tests/persistence/SupervisorEngine.SelfTest.ps1`

**Interfaces:**
- Produces: `Submit-CcodLifecycleRequest`, `Receive-CcodLifecycleSubmissions`, `Write-CcodLifecycleSubmissionReceipt`.
- Inbox request exact properties: `schemaVersion,submissionId,kind,origin,runtimeId,runtimeGeneration,createdAtUtc`.
- Submission receipt exact properties: `schemaVersion,submissionId,accepted,transactionId,errorCode,completedAtUtc`.
- Supervisor host state adds `LifecycleOwnership,LifecycleRequest,LifecycleWorkerSlot,ConnectionState,ProtectionState` and removes user-controlled automation/candidate fields from decision authority.
- Consumes: Tasks 1–5; provides lifecycle transaction IDs to tray protocol and installer prompt.

- [ ] **Step 1: Write failing bounded-inbox tests**

```powershell
$submitted = Submit-CcodLifecycleRequest -InstallRoot $root -Kind RestartAndRepair -Origin Installer `
    -RuntimeId '2.5.0-a' -RuntimeGeneration 7 -TimeoutMilliseconds 5000 -Adapters $adapters
Assert-CcodTrue $submitted.accepted 'verified Supervisor accepts restart request'
Assert-CcodEqual '11111111-2222-3333-4444-555555555555' $submitted.transactionId 'receipt correlates durable transaction'
Assert-CcodEqual 0 $world.ControllerCalls 'submitter never runs Recover or Apply'
```

Cover at most eight pending submissions, current-user ACL/reparse checks, duplicate submission ID, runtime/generation mismatch, unavailable Supervisor, wake-event failure, timeout, rejected busy request, stale receipt, and cleanup of consumed files.

- [ ] **Step 2: Write failing Supervisor resume and sole-owner tests**

Seed one persisted `WaitingForManualLaunch` transaction, restart the Supervisor fixture, then make an ordinary Codex observation appear. Assert it advances through Apply and completes under one epoch. Also assert two simultaneous submissions create at most one active transaction and no controller mutation occurs outside the lifecycle worker slot.

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleRequest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SupervisorEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
```

Expected: new inbox and host-state assertions fail.

- [ ] **Step 4: Implement the file inbox and wake event**

Use `state\lifecycle\inbox` under current-user ACL. Writers create `*.request.json` through atomic rename, signal a fixed per-user/session `LifecycleWake` event, and wait only for their matching `*.receipt.json`. Supervisor validates active runtime/generation before converting a submission into Task 1's active request.

- [ ] **Step 5: Integrate lifecycle polling into Supervisor**

Add lifecycle modules to the manifest-bound import list. In every host tick:

```powershell
$submission = Receive-CcodLifecycleSubmissions -StateRoot $layout.StateRoot -MaximumCount 1
$step = Get-CcodLifecycleStep -Request $hostState.LifecycleRequest -Observation $hostState.LifecycleObservation -NowUtc (& $adapters.GetUtcNow)
```

Accept at most one active lifecycle transaction. Start at most one `LifecycleWorker` slot. Reduce its correlated result, assert the fence, atomically move phase, update truthful connection/protection state, and persist a terminal receipt. Existing package observation continues but cannot launch/stop/repair outside this path.

- [ ] **Step 6: Migrate automation semantics**

On 2.4.x state load, ignore `automationEnabled` as an authority toggle and treat protection as running whenever Supervisor owns the lifecycle lease. Keep the old property only for schema migration until a later state-version cleanup. Candidate compatibility remains internal and is not a tray command.

- [ ] **Step 7: Run focused and full persistence tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\LifecycleRequest.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SupervisorEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
npm run test:persistence
```

Expected: PASS with no direct restart chain outside Supervisor.

- [ ] **Step 8: Commit sole ownership**

```powershell
git add src/persistence/modules/LifecycleRequest.psm1 src/persistence/Supervisor.ps1 src/persistence/modules/SupervisorEngine.psm1 tests/persistence/LifecycleRequest.SelfTest.ps1 tests/persistence/Supervisor.SelfTest.ps1 tests/persistence/SupervisorEngine.SelfTest.ps1
git commit -m "Make Supervisor the sole lifecycle owner"
```

### Task 7: Upgrade TrayHost to authenticated protocol v2 with correlated action results

**Files:**
- Modify: `src/trayhost/PipeProtocol.cs`
- Modify: `src/trayhost/TransportMessages.cs`
- Modify: `src/trayhost/TrayHostWire.cs`
- Modify: `src/trayhost/HostTransport.cs`
- Modify: `src/trayhost/ParentTransport.cs`
- Modify: `src/trayhost/TrayHostParentClient.cs`
- Modify: `src/trayhost/Program.cs`
- Modify: `src/persistence/modules/TrayHostClient.psm1`
- Modify: `tests/trayhost/TrayHostProtocolSelfTest.cs`
- Modify: `tests/trayhost/TrayHostTransportSelfTest.cs`
- Modify: `tests/trayhost/TrayHostParentClientSelfTest.cs`
- Modify: `tests/persistence/TrayHostClient.SelfTest.ps1`

**Interfaces:**
- Protocol major becomes 2; all v1 bootstrap and authenticated frames are rejected.
- Command IDs become `CheckAndRepair=2001`, `SetLanguageSystem=2002`, `SetLanguageChinese=2003`, `SetLanguageEnglish=2004`, `OpenLogs=2005`, `ShowAbout=2006`, `Exit=2007`.
- Produces `TrayActionResultStatus` with `Accepted,Completed,Rejected,Failed` and `TrayActionResult` with exact fields `ActionId,Revision,Status,ErrorCode,TransactionId`.
- Parent client produces `TryAcknowledgeAction(TrayActionResult result)`; Host emits action events and consumes one correlated result.
- Preserves all current identity, HKDF, HMAC, epoch, sequence, replay, queue, heartbeat, and payload checks.

- [ ] **Step 1: Write failing v2 codec and negative tests**

Add exact assertions:

```csharp
AssertThrowsProtocol(delegate {
    ProtocolCodec.ReadBootstrap(new MemoryStream(BuildHeader(1, TrayHostMessageType.ParentHello, 0)), ProtocolDirection.ParentToHost);
}, "v1 bootstrap is rejected");
AssertThrowsProtocol(delegate {
    TrayHostWire.ReadAction(BuildActionPayload(Guid.NewGuid(), (TrayCommand)1001, 7UL));
}, "legacy command id is rejected");
```

Retain and rerun bad HMAC, wrong epoch, skipped/replayed sequence, oversized payload, trailing bytes, wrong parent/Host identity, and heartbeat timeout cases under v2.

- [ ] **Step 2: Write failing action-result correlation tests**

```csharp
Guid actionId = Guid.NewGuid();
TrayActionResult accepted = new TrayActionResult(actionId, 12UL, TrayActionResultStatus.Accepted, null, Guid.Parse("11111111-2222-3333-4444-555555555555"));
byte[] payload = TrayHostWire.WriteActionResult(accepted);
TrayActionResult roundTrip = TrayHostWire.ReadActionResult(payload);
AssertEqual(actionId, roundTrip.ActionId, "action result keeps action id");
AssertEqual(TrayActionResultStatus.Accepted, roundTrip.Status, "action result keeps status");
```

Test wrong action ID, wrong revision, double result, completed-before-accepted for lifecycle actions, invalid error code, invalid transaction GUID, queue starvation, and result after epoch change.

- [ ] **Step 3: Run protocol tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
```

Expected: FAIL on protocol major and missing action-result types.

- [ ] **Step 4: Implement the v2 enums and wire schema**

Use exact enum values:

```csharp
public enum TrayCommand : ushort
{
    None = 0,
    CheckAndRepair = 2001,
    SetLanguageSystem = 2002,
    SetLanguageChinese = 2003,
    SetLanguageEnglish = 2004,
    OpenLogs = 2005,
    ShowAbout = 2006,
    Exit = 2007
}

public enum TrayActionResultStatus : byte
{
    Accepted = 1,
    Completed = 2,
    Rejected = 3,
    Failed = 4
}
```

Increment the frame/hello version constants together. Encode ActionResult as `Guid actionId | UInt64 revision | Byte status | Boolean hasError | strict error string | Boolean hasTransaction | Guid transactionId`. Enforce empty error on success and canonical allow-listed error codes on failure.

- [ ] **Step 5: Integrate result queues without weakening control priority**

Host keeps at most eight pending user actions and one pending result per action ID. Parent control messages, presentation ACK, heartbeat, and shutdown remain on the reserved control queue. `TryAcknowledgeAction` refuses an unknown or already-terminal action ID.

- [ ] **Step 6: Update the PowerShell wrapper contract**

`Receive-CcodTrayHostEvents` returns action ID, command, and revision only for v2 allow-listed commands. Add:

```powershell
function Send-CcodTrayHostActionResult {
    param($Tray,[guid]$ActionId,[UInt64]$Revision,[string]$Status,[AllowNull()][string]$ErrorCode,[AllowNull()][string]$TransactionId)
    $transactionGuid=if([string]::IsNullOrWhiteSpace($TransactionId)){$null}else{[guid]::Parse($TransactionId)}
    $result=[Ccod.TrayHost.TrayActionResult]::new($ActionId,$Revision,[Ccod.TrayHost.TrayActionResultStatus]::$Status,$ErrorCode,$transactionGuid)
    if(-not $Tray.TryAcknowledgeAction($result)){throw 'CCOD_TRAY_ACTION_ACK_REJECTED'}
}
```

Normalize real errors through stable `ErrorRecord` IDs.

- [ ] **Step 7: Run native and PowerShell tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ParentClientOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostClient.SelfTest.ps1
```

Expected: PASS.

- [ ] **Step 8: Commit protocol v2**

```powershell
git add src/trayhost/PipeProtocol.cs src/trayhost/TransportMessages.cs src/trayhost/TrayHostWire.cs src/trayhost/HostTransport.cs src/trayhost/ParentTransport.cs src/trayhost/TrayHostParentClient.cs src/trayhost/Program.cs src/persistence/modules/TrayHostClient.psm1 tests/trayhost/TrayHostProtocolSelfTest.cs tests/trayhost/TrayHostTransportSelfTest.cs tests/trayhost/TrayHostParentClientSelfTest.cs tests/persistence/TrayHostClient.SelfTest.ps1
git commit -m "Upgrade tray transport to protocol v2"
```

### Task 8: Replace the old tray presentation with the simplified truthful menu

**Files:**
- Modify: `src/trayhost/PresentationSnapshot.cs`
- Modify: `src/trayhost/NativeMenu.cs`
- Modify: `src/trayhost/TrayWindow.cs`
- Modify: `src/trayhost/NativeMethods.cs`
- Modify: `src/persistence/modules/TrayHostClient.psm1`
- Modify: `src/persistence/modules/SupervisorEngine.psm1`
- Modify: `src/persistence/modules/UiLocalization.psm1`
- Modify: `src/persistence/resources/ui.en-US.json`
- Modify: `src/persistence/resources/ui.zh-CN.json`
- Modify: `tests/trayhost/TrayHostNativeSelfTest.cs`
- Modify: `tests/persistence/SupervisorEngine.SelfTest.ps1`
- Modify: `tests/persistence/UiLocalization.SelfTest.ps1`
- Modify: `tests/persistence/TrayHostClient.SelfTest.ps1`
- Modify: `tests/persistence/TrayUiGallery.SelfTest.ps1`

**Interfaces:**
- Connection enum: `WaitingForCodex,Checking,Connected,RepairNeeded,Error`.
- Protection enum: `Running,Reconnecting,Stopping`.
- Presentation flags: `RepairEnabled,LanguageEnabled,OpenLogsEnabled,AboutEnabled,ExitEnabled,Busy`.
- Fixed strings 0–15: title, connection, protection, repair, language, three choices, logs, About, Exit, About caption/version, Exit warning title/body, action failure.
- Produces one native menu graph exactly matching spec section 8.1.

- [ ] **Step 1: Write failing presentation truth-table tests**

```powershell
$connected = Get-CcodTrayPresentation -ConnectionState Connected -ProtectionState Running -Busy:$false -StateDamageBlocksActions:$false
Assert-CcodEqual 'Connected' $connected.ConnectionState 'verified remote evidence maps to Connected'
Assert-CcodEqual $false $connected.RepairEnabled 'connected session does not invite redundant repair'
$ordinary = Get-CcodTrayPresentation -ConnectionState RepairNeeded -ProtectionState Running -Busy:$false -StateDamageBlocksActions:$false
Assert-CcodEqual $true $ordinary.RepairEnabled 'ordinary Codex enables repair'
```

Cover all five connection states, all three protection states, busy/state-damage blocking, and the rule that historical status or a running TrayHost never yields Connected.

- [ ] **Step 2: Write failing native menu graph tests**

Assert the exact sequence and absence of old labels/IDs:

```csharp
AssertSequence(platform.AppendedText, new string[] {
    "CodexRemote-fix 2.5.0", "Connection: Connected", "Protection: Running",
    "Check and repair remote connection", "Language / 语言", "Open logs", "About", "Exit"
}, "menu contains only the approved information architecture");
AssertFalse(platform.AppendedText.Contains("Allow compatible update trials"), "candidate toggle is removed");
AssertFalse(platform.Commands.Contains(1009U), "tray uninstall command is removed");
```

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SupervisorEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UiLocalization.SelfTest.ps1
```

Expected: old presentation/menu assertions fail.

- [ ] **Step 4: Implement the minimal presentation model**

Replace old `TrayState` and toggle flags with:

```csharp
public enum ConnectionState : byte { WaitingForCodex=0, Checking=1, Connected=2, RepairNeeded=3, Error=4 }
public enum ProtectionState : byte { Running=0, Reconnecting=1, Stopping=2 }
[Flags]
public enum PresentationFlags : uint
{
    None=0, RepairEnabled=1u, LanguageEnabled=2u, OpenLogsEnabled=4u,
    AboutEnabled=8u, ExitEnabled=16u, Busy=32u
}
```

Strictly validate 16 strings and preserve monotonic revisions/language mode.

- [ ] **Step 5: Build only the approved native menu**

Create disabled title/connection/protection rows, separator, repair, language submenu, logs, About, separator, Exit. Use system drawing and existing foreground/input-mode guard behavior. Add a Yes/No native confirmation method for Exit using `MessageBoxW` with `MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2`; emit Exit only after Yes.

- [ ] **Step 6: Replace localization catalogs atomically**

The English catalog includes concise values:

```json
{
  "Menu.CheckAndRepair": "Check and repair remote connection",
  "Menu.Exit": "Exit",
  "Dialog.ExitTitle": "Exit CodexRemote-fix?",
  "Dialog.ExitMessage": "Remote control will stop and Codex may restart in normal mode before CodexRemote-fix exits."
}
```

The Chinese catalog contains equivalent user-facing Chinese. Remove old Automation, CandidateOptIn, ManualRetry, and Uninstall keys from the strict allow-list and both files.

- [ ] **Step 7: Run presentation/native/localization tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\SupervisorEngine.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UiLocalization.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostClient.SelfTest.ps1
```

Expected: PASS in English and Chinese.

- [ ] **Step 8: Commit the simplified menu**

```powershell
git add src/trayhost/PresentationSnapshot.cs src/trayhost/NativeMenu.cs src/trayhost/TrayWindow.cs src/trayhost/NativeMethods.cs src/persistence/modules/TrayHostClient.psm1 src/persistence/modules/SupervisorEngine.psm1 src/persistence/modules/UiLocalization.psm1 src/persistence/resources/ui.en-US.json src/persistence/resources/ui.zh-CN.json tests/trayhost/TrayHostNativeSelfTest.cs tests/persistence/SupervisorEngine.SelfTest.ps1 tests/persistence/UiLocalization.SelfTest.ps1 tests/persistence/TrayHostClient.SelfTest.ps1 tests/persistence/TrayUiGallery.SelfTest.ps1
git commit -m "Simplify the tray to remote connection essentials"
```

### Task 9: Wire repair, language, logs, and About through Supervisor authorization

**Files:**
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `src/persistence/modules/TrayHostClient.psm1`
- Modify: `src/trayhost/TrayWindow.cs`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`
- Modify: `tests/persistence/TrayHostClient.SelfTest.ps1`
- Modify: `tests/trayhost/TrayHostNativeSelfTest.cs`

**Interfaces:**
- `Invoke-CcodSupervisorCommand` accepts only Task 7 commands and the authenticated action ID/revision.
- `CheckAndRepair` returns `Accepted` with a lifecycle transaction ID, then `Completed`/`Failed` through the same action correlation.
- Language completes only after preference write, catalog resolution, presentation ACK, and action result; failure rolls back preference and presentation.
- About completes only after Supervisor verifies the active manifest version; TrayHost displays the acknowledged snapshot version.

- [ ] **Step 1: Write failing command authorization tests**

```powershell
$action=[pscustomobject][ordered]@{ActionId=[guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';Command='CheckAndRepair';Revision=[UInt64]12}
$result=Invoke-CcodSupervisorCommand -HostState $host -Adapters $adapters -Command $action
Assert-CcodEqual 'Accepted' $result.Status 'repair action receives accepted result'
Assert-CcodEqual $world.TransactionId $result.TransactionId 'repair result carries durable transaction id'
Assert-CcodThrows { Invoke-CcodSupervisorCommand -HostState $host -Adapters $adapters -Command ([pscustomobject]@{ActionId=[guid]::NewGuid();Command='SetAutomation';Revision=[UInt64]12}) } 'CCOD_SUPERVISOR_COMMAND_INVALID'
```

Cover stale revision, disabled repair, duplicate action ID, busy request, logs, About manifest mismatch, and all removed commands.

- [ ] **Step 2: Write failing language commit/rollback tests**

For each System/Chinese/English command, assert exact order `WritePreference -> ResolveCatalog -> Publish -> PresentationAck -> ActionCompleted`. On missing ACK assert `RestorePreference -> RestorePresentation -> ActionFailed(LANGUAGE_CHANGE_ROLLED_BACK)`.

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostClient.SelfTest.ps1
```

Expected: old command dispatch fails the new expectations.

- [ ] **Step 4: Implement strict command dispatch and action results**

Normalize command outcomes into:

```powershell
[pscustomobject][ordered]@{
    ActionId=$Command.ActionId; Revision=[UInt64]$Command.Revision
    Status='Accepted'; ErrorCode=$null; TransactionId=$transaction.transactionId
}
```

Send every result through `Send-CcodTrayHostActionResult`. Never write a user preference, launch a worker, open logs, or show About before revision/enabled-state authorization.

- [ ] **Step 5: Move About proof to Supervisor**

Before completing ShowAbout, read `active.json`, validate the active runtime manifest, require its runtime ID to equal the running Supervisor runtime, and republish the exact project version. TrayHost shows the About message only after `Completed` for the same action ID.

- [ ] **Step 6: Run focused and full native/persistence tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostClient.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionOnly
npm run test:persistence
```

Expected: PASS.

- [ ] **Step 7: Commit Supervisor tray actions**

```powershell
git add src/persistence/Supervisor.ps1 src/persistence/modules/TrayHostClient.psm1 src/trayhost/TrayWindow.cs tests/persistence/Supervisor.SelfTest.ps1 tests/persistence/TrayHostClient.SelfTest.ps1 tests/trayhost/TrayHostNativeSelfTest.cs
git commit -m "Authorize simplified tray actions in Supervisor"
```

### Task 10: Implement safe Exit and same-logon restart suppression

**Files:**
- Modify: `src/persistence/Supervisor.ps1`
- Modify: `src/persistence/bootstrap.ps1`
- Modify: `src/persistence/modules/ScheduledTask.psm1`
- Modify: `Reset-CodexControlOtherDevices.ps1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `tests/persistence/Supervisor.SelfTest.ps1`
- Modify: `tests/persistence/Bootstrap.SelfTest.ps1`
- Modify: `tests/persistence/ScheduledTask.SelfTest.ps1`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/ManualWrappers.SelfTest.ps1`

**Interfaces:**
- Bootstrap adds `-EntryMode Task|Explicit`, defaulting to `Task` only for the scheduled-task definition; Start/Desktop shortcuts pass `Explicit`.
- Safe Exit is a Task 1 `SafeExit` lifecycle request; no direct TrayHost shutdown occurs before recovery and marker commit.
- The legacy Reset wrapper becomes a compatibility alias for submitted SafeExit; it no longer moves, backs up, or deletes the device-key store.
- Same LUID/SID/Session task retry returns exit code 0 without creating TrayHost; explicit launch acquires ownership, confirms corrupt-marker replacement when necessary, clears the marker, and starts Supervisor.

- [ ] **Step 1: Write failing safe-exit lifecycle tests**

Seed connected evidence, issue Exit, accept the native warning, and assert:

```powershell
Assert-CcodEqual 'SafeExit' $world.SubmittedKind 'Exit creates a SafeExit lifecycle request'
Assert-CcodEqual 'OrdinaryRunning' $world.RecoverySafeState 'special session is recovered before exit'
Assert-CcodTrue $world.SafeExitIntentWritten 'same-logon marker is committed'
Assert-CcodTrue $world.TrayShutdownAfterIntent 'TrayHost stops only after marker commit'
Assert-CcodEqual 0 $world.SupervisorExitCode 'intentional exit is successful, not task failure'
```

Cover cancel, no Codex, already ordinary, recovery failure, marker write failure, crash before/after recovery and marker, and lifecycle fence loss.

- [ ] **Step 2: Write failing bootstrap/task/shortcut tests**

Assert same-logon Task mode suppresses startup; new LUID clears the marker; Explicit mode clears only after ownership; corrupt marker makes Task fail closed and Explicit request confirmation; task arguments contain `-EntryMode Task`; both shortcuts contain `-EntryMode Explicit`.

Assert the Reset compatibility wrapper submits `SafeExit`, never invokes SessionController directly, and contains no device-key move/copy/delete command.

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ScheduledTask.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
```

Expected: missing EntryMode and safe-exit handling fail.

- [ ] **Step 4: Implement Supervisor safe-exit completion**

When the coordinator reaches a proven ordinary/no-Codex safe state, write the marker using Task 3, publish `Protection=Stopping`, send the terminal action result, request TrayHost shutdown, release lifecycle ownership, and return 0. A failure leaves protection running and sends `SAFE_EXIT_RECOVERY_FAILED`.

- [ ] **Step 5: Implement bootstrap marker policy and entry modes**

Add:

```powershell
[ValidateSet('Task','Explicit')][string]$EntryMode='Explicit'
```

Task mode with the exact same trusted logon marker logs `SAFE_EXIT_SUPPRESSED` and exits 0. Explicit mode acquires lifecycle ownership before clearing a valid marker. New trusted logon identity expires the marker and continues. Token/marker corruption follows the fail-closed policy from the specification.

- [ ] **Step 6: Update task and shortcut arguments**

Scheduled task:

```text
-File "%LOCALAPPDATA%\CodexControlOtherDevices\bootstrap.ps1" -InstallRoot "%LOCALAPPDATA%\CodexControlOtherDevices" -EntryMode Task
```

Start/Desktop shortcuts:

```text
-File "%LOCALAPPDATA%\CodexControlOtherDevices\bootstrap.ps1" -InstallRoot "%LOCALAPPDATA%\CodexControlOtherDevices" -EntryMode Explicit
```

Update `Reset-CodexControlOtherDevices.ps1` to submit SafeExit through `LifecycleRequest.psm1`. Reject the removed `BackupDeviceKeyStore` behavior with a stable migration message and preserve the key in place.

- [ ] **Step 7: Run focused and persistence tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ScheduledTask.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Supervisor.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
npm run test:persistence
```

Expected: PASS.

- [ ] **Step 8: Commit safe Exit**

```powershell
git add src/persistence/Supervisor.ps1 src/persistence/bootstrap.ps1 src/persistence/modules/ScheduledTask.psm1 Reset-CodexControlOtherDevices.ps1 build/CodexControlOtherDevices.iss tests/persistence/Supervisor.SelfTest.ps1 tests/persistence/Bootstrap.SelfTest.ps1 tests/persistence/ScheduledTask.SelfTest.ps1 tests/persistence/InstallLifecycle.SelfTest.ps1 tests/persistence/ManualWrappers.SelfTest.ps1
git commit -m "Add safe exit and same-logon suppression"
```

### Task 11: Make post-install activation responsive and restart submission durable

**Files:**
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `Install-CodexControlOtherDevices.ps1`
- Modify: `Activate-CcodRemoteFix.ps1`
- Modify: `Prompt-CcodRestart.ps1`
- Modify: `Start-CodexControlOtherDevices.ps1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/ManualWrappers.SelfTest.ps1`

**Interfaces:**
- Activation receipt exact properties: `schemaVersion,activationId,phase,runtimeId,previousRuntimeId,startedAtUtc,updatedAtUtc,ready,errorCode`.
- Phase allow-list: `StoppingPreviousRuntime,InstallingRuntime,ActivatingRuntime,StartingProtection,Ready,Failed`.
- `Prompt-CcodRestart.ps1` submits `RestartAndRepair` through Task 6 and succeeds only after an accepted receipt; `Later` writes nothing.
- New-runtime success requires exact old-Supervisor exit, active-pointer generation commit, task idle, new Supervisor ready event, and TrayHost ready handshake.
- Inno remains responsive while a background activation process runs and does not display completed progress before Ready/Failed.

- [ ] **Step 1: Write failing install/upgrade phase tests**

Add adapter-driven tests asserting exact order:

```powershell
$receipt=Invoke-CcodInstall -SourceRoot $source -InstallRoot $root -Adapters $adapters
Assert-CcodEqual 'StoppingPreviousRuntime,InstallingRuntime,ActivatingRuntime,StartingProtection,Ready' ($world.Phases -join ',') 'activation phases are ordered'
Assert-CcodTrue $world.OldSupervisorExitProven 'old owner exits before active pointer switch'
Assert-CcodTrue $world.NewTrayReady 'new Supervisor and TrayHost readiness is proven'
Assert-CcodEqual $expectedKeyHash (Get-FileHash $deviceKey).Hash 'upgrade preserves device key bytes'
```

Cover old transaction nonterminal, stale epoch/generation, old task still Running, active pointer write failure, new task start failure, Supervisor ready timeout, TrayHost ready timeout, rollback before mutation, rollback blocked after new-generation mutation, crash at every upgrade boundary, and old runtime cleanup only after readiness.

- [ ] **Step 2: Write failing prompt and wrapper tests**

Assert Later creates zero inbox files and zero controller calls. Assert Restart creates one submission and receives its transaction ID. Assert stderr/support code is retained. Assert `Start-CodexControlOtherDevices.ps1 -RestartCodex` no longer calls two controllers and instead uses `Submit-CcodLifecycleRequest`.

- [ ] **Step 3: Write failing Inno contract tests**

Replace the old static expectation that `ewNoWait` is sufficient. Assert the `.iss` source contains bounded process polling, status/progress updates, Ready/Failed receipt read, and no unconditional completion after launching activation. Assert prompt runs only after Ready.

- [ ] **Step 4: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
```

Expected: old asynchronous activation and direct Recover/Apply chain fail.

- [ ] **Step 5: Implement generation-fenced upgrade and readiness receipt**

Refactor `Invoke-CcodInstall` to emit each phase through one receipt writer. Before `Ready`, require:

```powershell
if (-not $oldSupervisorStopped) { throw 'CCOD_INSTALL_PREVIOUS_RUNTIME_BUSY' }
if (-not $activePointerCommitted) { throw 'CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN' }
if (-not $taskIdle) { throw 'CCOD_INSTALL_SUPERVISOR_TASK_BUSY' }
if (-not $supervisorReady -or -not $trayReady) { throw 'CCOD_INSTALL_NEW_RUNTIME_NOT_READY' }
```

Normalize these into the existing lifecycle error pattern and preserve the previous runtime until the readiness gate succeeds.

- [ ] **Step 6: Convert the restart prompt to submit-only**

After Yes:

```powershell
$receipt = Submit-CcodLifecycleRequest -InstallRoot $InstallRoot -Kind RestartAndRepair -Origin Installer `
    -RuntimeId $active.activeRuntime -RuntimeGeneration ([UInt64]$active.generation) -TimeoutMilliseconds 5000
if(-not $receipt.accepted){ Show-CcodRestartFailure -Code $receipt.errorCode; exit 1 }
exit 0
```

Do not redirect stderr to `$null`. Append activation ID, submission ID, transaction ID, stable code, and duration to `post-install-activation.log` without private paths or content.

- [ ] **Step 7: Make Inno poll the activation process and receipt while pumping UI**

Declare `OpenProcess`, `WaitForSingleObject`, and `CloseHandle` in `[Code]`. Launch activation with `ewNoWait`, treat ResultCode as the PID, open a synchronize handle, and poll in bounded intervals:

```pascal
while WaitForSingleObject(ProcessHandle, 50) = WAIT_TIMEOUT do
begin
  UpdateActivationPresentation(ReceiptPath);
  WizardForm.Update;
  Sleep(50);
end;
```

`UpdateActivationPresentation` maps the five phase values to status text and reserved progress positions below 100%. After process exit, strictly read Ready/Failed; only Ready advances to completion and then shows the English restart prompt.

- [ ] **Step 8: Run focused and full tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
npm test
```

Expected: PASS.

- [ ] **Step 9: Commit responsive activation**

```powershell
git add src/persistence/modules/InstallLifecycle.psm1 Install-CodexControlOtherDevices.ps1 Activate-CcodRemoteFix.ps1 Prompt-CcodRestart.ps1 Start-CodexControlOtherDevices.ps1 build/CodexControlOtherDevices.iss tests/persistence/InstallLifecycle.SelfTest.ps1 tests/persistence/ManualWrappers.SelfTest.ps1
git commit -m "Make post-install restart durable and responsive"
```

### Task 12: Unify Windows Settings and `unins000.exe` behind a recoverable uninstall bootstrap

**Files:**
- Create: `src/persistence/UninstallBootstrap.ps1`
- Create: `tests/persistence/UninstallBootstrap.SelfTest.ps1`
- Modify: `src/persistence/modules/InstallLifecycle.psm1`
- Modify: `Uninstall-CodexControlOtherDevices.ps1`
- Modify: `build/CodexControlOtherDevices.iss`
- Modify: `tests/persistence/InstallLifecycle.SelfTest.ps1`
- Modify: `tests/persistence/UiActions.SelfTest.ps1`
- Modify: `src/persistence/modules/UiActions.psm1`
- Modify: `src/persistence/Supervisor.ps1`

**Interfaces:**
- Uninstall transaction phases: `Requested,Recovering,RecoveryProven,StoppingProtection,ProtectionStopped,TaskRemoved,ApplicationStateRemoved,ReadyForInno,Completed,Failed`.
- Stable bootstrap arguments: `-InstallerRoot`, `-InstallRoot`, `-Mode Prepare|FinalizeReceipt`.
- Default behavior preserves the device-key path in place; installed uninstaller exposes no KeepSpecial, backup, remove-key, or tray-uninstall option.
- `InitializeUninstall()` in Inno executes `Prepare` and returns false on nonzero result, preventing installer-file deletion.

- [ ] **Step 1: Write failing uninstall bootstrap authorization tests**

```powershell
$receipt=Invoke-CcodUninstallBootstrap -InstallerRoot $installerRoot -InstallRoot $installRoot -Mode Prepare -Adapters $adapters
Assert-CcodEqual 'ReadyForInno' $receipt.phase 'verified cleanup reaches Inno boundary'
Assert-CcodEqual $deviceKeyHash (Get-FileHash $deviceKeyPath).Hash 'device key remains byte-identical in place'
Assert-CcodEqual 0 $world.DeviceKeyCopyCalls 'uninstall creates no second private-key copy'
```

Cover wrong installer/install roots, bad active manifest/hash, reparse/ACL failure, other user, missing Supervisor with no special session, special session recovery, recovery failure, stop unproven, task removal failure, interrupted phase resume, runtime deletion retry, and final receipt.

- [ ] **Step 2: Write failing Inno and public-wrapper tests**

Assert Windows Settings and `unins000.exe` both enter `InitializeUninstall`, which calls the stable bootstrap. Assert `[UninstallRun]` no longer calls a runtime script with `-BackupDeviceKeyStore`. Assert tray command 1009 and `Start-CcodTrayUninstall` are unreachable. Assert installed public wrapper rejects `KeepCurrentSpecialSession`, `BackupDeviceKeyStore`, and `RemoveDeviceKeyStore`.

- [ ] **Step 3: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UiActions.SelfTest.ps1
```

Expected: current divergent uninstall paths fail.

- [ ] **Step 4: Implement stable bootstrap and external transaction**

Use `%LOCALAPPDATA%\CodexRemote-fix-uninstall\<transaction-id>` with explicit current-user/System ACL and reparse rejection. Copy only the manifest-bound cleanup entry and required modules, verify their hashes after copy, and write no private-key content. Resume only the exact transaction ID/runtime/generation/epoch.

- [ ] **Step 5: Make cleanup fail closed and resumable**

The cleanup sequence is:

```text
recover verified special session -> prove ordinary/no Codex
stop TrayHost/Supervisor -> prove exact PIDs exited
remove scheduled task -> remove runtime/state/logs/shortcuts
write ReadyForInno receipt
```

Any failed proof writes `Failed` with a stable code and leaves undeleted material needed for retry. Do not remove the installer root or Inno registration from PowerShell.

- [ ] **Step 6: Route Inno initialization through the bootstrap**

Implement:

```pascal
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\src\persistence\UninstallBootstrap.ps1') +
    '" -InstallerRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' +
    ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -Mode Prepare',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;
```

Inno deletes its own files/registration only when this returns true.

- [ ] **Step 7: Remove tray uninstall code and run tests**

Delete `StartUninstall` adapters, `RequestUninstall` command handling, uninstall UI keys, and old UiActions receipt paths that exist only for the tray. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UiActions.SelfTest.ps1
npm run test:persistence
```

Expected: PASS.

- [ ] **Step 8: Commit unified uninstall**

```powershell
git add src/persistence/UninstallBootstrap.ps1 src/persistence/modules/InstallLifecycle.psm1 Uninstall-CodexControlOtherDevices.ps1 build/CodexControlOtherDevices.iss src/persistence/modules/UiActions.psm1 src/persistence/Supervisor.ps1 tests/persistence/UninstallBootstrap.SelfTest.ps1 tests/persistence/InstallLifecycle.SelfTest.ps1 tests/persistence/UiActions.SelfTest.ps1
git commit -m "Unify fail-closed uninstall lifecycle"
```

### Task 13: Add final-asset installed integration and release-security gates

**Files:**
- Create: `tests/installed/Invoke-InstalledLifecycleIntegration.ps1`
- Create: `tests/persistence/InstalledLifecycleHarness.SelfTest.ps1`
- Create: `tests/persistence/ReleaseWorkflow.SelfTest.ps1`
- Create: `tools/Test-ReleaseDefender.ps1`
- Modify: `tests/Validate.ps1`
- Modify: `package.json`
- Modify: `build/build.ps1`
- Modify: `build/TrayHostBuild.psm1`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Installed harness parameters: `-InstallerPath`, `-PreviousInstallerPath`, `-ExpectedVersion`, `-EvidenceRoot`, `-AllowMachineMutation`, `-AllowCodexRestart`, `-Scenario`.
- Scenario allow-list: `FreshLater,FreshRestart,Upgrade,SlowLaunch,ManualLaunchResume,LanguageStress,RepairStates,SafeExit,SettingsUninstall,DirectUninstall`.
- Build produces installer, checksum, TrayHost provenance, and release manifest containing version, git commit, asset hashes, and build timestamp.
- Defender tool verifies the uploaded/downloaded final asset hash, Internet Zone ADS, Defender platform/signature versions, and custom-scan result without changing exclusions.

- [ ] **Step 1: Write failing harness safety tests**

```powershell
Assert-CcodThrows { & $harness -InstallerPath $setup -ExpectedVersion '2.5.0' -Scenario FreshRestart } 'CCOD_INTEGRATION_MUTATION_NOT_ALLOWED'
Assert-CcodThrows { & $harness -InstallerPath $setup -ExpectedVersion '2.5.0' -Scenario FreshRestart -AllowMachineMutation } 'CCOD_INTEGRATION_CODEX_RESTART_NOT_ALLOWED'
```

Assert evidence redacts device-key contents, tokens, usernames, private paths, and conversation data; only hashes, PIDs/creation times, runtime IDs, task state, phases, result codes, and durations are stored.

- [ ] **Step 2: Implement deterministic harness self-tests**

Use fake installer/task/process adapters to verify scenario order, rollback snapshot creation, cleanup on failure, explicit mutation gates, and receipt schema. The live harness must refuse to run from an unclean checkout or when installer/checksum hashes do not match.

- [ ] **Step 3: Implement the live installed scenario runner**

The entry starts with:

```powershell
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$InstallerPath,
  [string]$PreviousInstallerPath,
  [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion,
  [Parameter(Mandatory)][string]$EvidenceRoot,
  [switch]$AllowMachineMutation,
  [switch]$AllowCodexRestart,
  [Parameter(Mandatory)][ValidateSet('FreshLater','FreshRestart','Upgrade','SlowLaunch','ManualLaunchResume','LanguageStress','RepairStates','SafeExit','SettingsUninstall','DirectUninstall')][string]$Scenario
)
```

Each scenario reads back active runtime/manifest, scheduled task, exact Supervisor/TrayHost PIDs, About version, status/transaction evidence, shortcuts, and device-key hash. The LanguageStress scenario performs System/Chinese/English round trips ten times through protocol actions, not direct file edits.

- [ ] **Step 4: Add release-contract and provenance tests**

Assert package/tag/changelog/asset names agree, release bodies use only the English section, promotion uploads an already-built candidate rather than rebuilding, and provenance includes the exact git commit and source hashes.

- [ ] **Step 5: Implement Defender final-asset gate**

`tools/Test-ReleaseDefender.ps1` requires ZoneId 3, validates the SHA-256 checksum before scan, calls the supported Defender custom scan without exclusions, and writes a receipt with `sha256,zoneId,defenderPlatformVersion,signatureVersion,scanStartedAtUtc,scanCompletedAtUtc,detectionCount`.

- [ ] **Step 6: Wire scripts and CI-safe gates**

Add package scripts:

```json
"test:installed-lifecycle": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/installed/Invoke-InstalledLifecycleIntegration.ps1",
"test:release-contract": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/persistence/ReleaseWorkflow.SelfTest.ps1"
```

CI runs deterministic release/harness tests but does not claim live Codex success. Release workflow promotes the same candidate assets after hash/provenance checks.

- [ ] **Step 7: Run deterministic gates**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
npm test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionOnly
```

Expected: PASS.

- [ ] **Step 8: Commit integration and release tooling**

```powershell
git add tests/installed/Invoke-InstalledLifecycleIntegration.ps1 tests/persistence/InstalledLifecycleHarness.SelfTest.ps1 tests/persistence/ReleaseWorkflow.SelfTest.ps1 tools/Test-ReleaseDefender.ps1 tests/Validate.ps1 package.json build/build.ps1 build/TrayHostBuild.psm1 .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "Add installed lifecycle and release security gates"
```

### Task 14: Update 2.5.0 documentation, build the final candidate, verify, install, and publish

**Files:**
- Modify: `package.json`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/TECHNICAL.md`
- Modify: `docs/CLEANROOM.md`
- Modify: `SECURITY.md`
- Modify: `src/trayhost/CodexRemote.TrayHost.manifest`
- Modify: `tests/persistence/TrayHostBuild.SelfTest.ps1`

**Interfaces:**
- Project version is exactly `2.5.0` in package metadata, installer, TrayHost assembly/manifest, provenance, README asset names, and release tag.
- CHANGELOG adds one `## v2.5.0` section with `### English` only.
- Documentation describes Restart now/Later, the five connection states, three protection states, safe Exit, Windows Settings/`unins000.exe`, in-place key preservation, and no tray uninstall.
- Final release is accepted only from the same asset hash that passes build, Defender, installed integration, upload read-back, and GitHub Actions.

- [ ] **Step 1: Write failing version/documentation contract tests**

Extend `TrayHostBuild.SelfTest.ps1` and `ReleaseWorkflow.SelfTest.ps1` to require `2.5.0`, English-only v2.5.0 release notes, new menu strings, new uninstall guidance, and absence of current-version references to old toggles/tray uninstall.

- [ ] **Step 2: Run tests and verify red**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\TrayHostBuild.SelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ReleaseWorkflow.SelfTest.ps1
```

Expected: FAIL while metadata/docs still describe 2.4.24.

- [ ] **Step 3: Update version and English release record**

Use these release bullets:

```markdown
## v2.5.0

### English

- Rebuilt restart and repair as a durable Supervisor-owned lifecycle that resumes safely after delayed or manual Codex launches.
- Simplified the tray to truthful connection/protection status, one repair action, language, logs, About, and safe Exit.
- Made upgrades wait for the new runtime and tray, preserved authorized devices, and unified Windows Settings and direct uninstall behind a fail-closed cleanup flow.
```

Set `package.json` to `2.5.0` and update the TrayHost assembly/manifest version through the existing build pipeline.

- [ ] **Step 4: Update bilingual user and technical documentation**

README Quick Start uses `CodexRemote-fix-2.5.0-setup.exe`. English and Chinese pages explain that Yes restarts and repairs, Later leaves Codex untouched, Exit may restore ordinary Codex, and uninstall is outside the tray. Technical/security docs record lifecycle epoch/generation fencing, trusted LUID marker, protocol v2, external uninstall receipt, and unchanged DPAPI key location.

- [ ] **Step 5: Run complete source validation**

```powershell
npm test
npm run test:runtime
npm run test:persistence
npm run test:package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProtocolOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\trayhost\Invoke-TrayHostSelfTest.ps1 -ProductionOnly
```

Expected: all PASS.

- [ ] **Step 6: Build and verify the release candidate**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 -Version 2.5.0
Get-FileHash build\dist\CodexRemote-fix-2.5.0-setup.exe -Algorithm SHA256
Get-Content build\dist\CodexRemote-fix-2.5.0-setup.exe.sha256.txt
```

Require the computed hash to match the checksum and release manifest; verify TrayHost provenance commit/source hashes.

- [ ] **Step 7: Commit release preparation**

```powershell
git add package.json CHANGELOG.md README.md README.zh-CN.md docs/TECHNICAL.md docs/CLEANROOM.md SECURITY.md src/trayhost/CodexRemote.TrayHost.manifest tests/persistence/TrayHostBuild.SelfTest.ps1
git commit -m "Prepare CodexRemote-fix 2.5.0"
```

- [ ] **Step 8: Obtain the live-restart checkpoint and run the installed matrix**

Immediately before any Codex restart, report the exact candidate SHA-256 and ask the user to confirm the active conversation can be interrupted. Then execute the Task 13 scenarios against the final candidate, including upgrade from 2.4.24, Yes, delayed/manual resume, ten language cycles, repair states, safe Exit, relaunch, and both uninstall entries. Reinstall the same final candidate after uninstall tests.

- [ ] **Step 9: Scan the final uploaded/downloaded asset with Defender**

Download the candidate to a new path retaining ZoneId 3, verify hash equality, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Test-ReleaseDefender.ps1 `
  -InstallerPath $downloadedSetup -ChecksumPath $downloadedChecksum -EvidencePath $defenderReceipt
```

Expected: matching SHA-256 and `detectionCount=0` without exclusions.

- [ ] **Step 10: Review, merge, tag, and publish the verified commit**

Run the `superpowers:requesting-code-review` and `superpowers:verification-before-completion` gates. Merge only reviewed commits, tag the verified release commit `v2.5.0`, push main/tag, wait for GitHub Actions, and read back the GitHub Release assets. Confirm uploaded installer/checksum/provenance hashes equal the locally verified candidate; the release body contains only the English v2.5.0 bullets.

- [ ] **Step 11: Record final installed evidence**

Verify the current machine runs Supervisor and TrayHost 2.5.0, About reports 2.5.0, the `Control other devices` tab and authorized devices are present, repair and language commands work, and no 2.4.x process/runtime remains active. Store only the redacted receipt paths and hashes in the handoff.

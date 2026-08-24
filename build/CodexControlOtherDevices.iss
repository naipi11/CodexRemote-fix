[Setup]
#ifndef TrayHostArtifactDirectory
#define TrayHostArtifactDirectory SourcePath + "\generated\trayhost"
#endif
AppId={{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}
AppName=CodexRemote-fix
AppVersion={#ProjectVersion}
AppVerName=CodexRemote-fix {#ProjectVersion}
AppPublisher=naipi11
AppPublisherURL=https://github.com/naipi11/CodexRemote-fix
AppSupportURL=https://github.com/naipi11/CodexRemote-fix/issues
AppUpdatesURL=https://github.com/naipi11/CodexRemote-fix/releases
VersionInfoVersion={#ProjectVersion}.0
DefaultDirName={localappdata}\CodexControlOtherDevices-installer
DefaultGroupName=CodexRemote-fix
UsePreviousGroup=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=CodexRemote-fix-{#ProjectVersion}-setup
SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico
UninstallDisplayIcon={app}\assets\CodexRemote-fix.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
SetupLogging=yes
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.zh-CN.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\CodexControlOtherDevices.iss"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\build.ps1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\build-trayhost.ps1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\TrayHostBuild.psm1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\TrayHostReferencePack.psm1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\trayhost-packages.lock.json"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\CodexRemote.TrayHost.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\CodexRemote.TrayHost.exe.config"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\trayhost-build-provenance.json"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\.github\workflows\release.yml"; DestDir: "{app}\.github\workflows"; Flags: ignoreversion
Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets"; DestName: "CodexRemote-fix.ico"; Flags: ignoreversion
Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets\codexremote-fix"; Flags: ignoreversion
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\tests\*"; DestDir: "{app}\tests"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\Install-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Uninstall-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Start-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Reset-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Test-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Activate-CcodRemoteFix.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Prompt-CcodRestart.ps1"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{userprograms}\Codex Control other devices\Codex Control other devices for Windows.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Open the tray supervisor.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Compatibility check.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Uninstall Codex Control other devices.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\CodexRemote-fix.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\CodexRemote-fix compatibility check.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Uninstall CodexRemote-fix.lnk"
Type: dirifempty; Name: "{userprograms}\Codex Control other devices"
Type: files; Name: "{userdesktop}\Codex 设备连接 (Device Connection).lnk"

[Icons]
Name: "{group}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\CodexRemote-fix compatibility check"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Test-CodexControlOtherDevices.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\Uninstall CodexRemote-fix"; Filename: "{app}\unins000.exe"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{userdesktop}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"

[Code]
const
  ACTIVATION_TIMEOUT_MILLISECONDS = 300000;
  ACTIVATION_POLL_MILLISECONDS = 50;
  VALIDATION_RETRY_MILLISECONDS = 500;
  VALIDATION_TIMEOUT_MILLISECONDS = 2000;
  VALIDATION_LAUNCH_BUDGET_MILLISECONDS = 5000;
  CCOD_FILE_ATTRIBUTE_DIRECTORY = $00000010;
  CCOD_FILE_ATTRIBUTE_REPARSE_POINT = $00000400;
  CCOD_INVALID_FILE_ATTRIBUTES = $FFFFFFFF;

type
  TActivationPhase = (apNone, apStoppingPreviousRuntime, apInstallingRuntime,
    apActivatingRuntime, apStartingProtection, apReady, apFailed);

function GetTickCount64(): Int64;
  external 'GetTickCount64@kernel32.dll stdcall';
function CoCreateGuid(var Guid: TGUID): HResult;
  external 'CoCreateGuid@ole32.dll stdcall';
function StringFromGUID2(var Guid: TGUID; GuidString: String; MaxCharacters: Integer): Integer;
  external 'StringFromGUID2@ole32.dll stdcall';
function GetFileAttributesW(const FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function NewActivationId(): String;
var
  Guid: TGUID;
  GuidString: String;
  GuidLength: Integer;
begin
  if CoCreateGuid(Guid) <> 0 then
    RaiseException('CodexRemote-fix activation correlation could not be created.');
  SetLength(GuidString, 39);
  GuidLength := StringFromGUID2(Guid, GuidString, 39);
  if GuidLength <> 39 then
    RaiseException('CodexRemote-fix activation correlation could not be formatted.');
  SetLength(GuidString, 38);
  Result := LowerCase(Copy(GuidString, 2, 36));
  if Length(Result) <> 36 then
    RaiseException('CodexRemote-fix activation correlation is invalid.');
end;

function IsSafeActivationFile(const FileName: String): Boolean;
var
  Attributes, DirectoryAttributes, RootAttributes: Cardinal;
  DirectoryName, RootName: String;
begin
  Attributes := GetFileAttributesW(FileName);
  if (Attributes = CCOD_INVALID_FILE_ATTRIBUTES) or
    ((Attributes and CCOD_FILE_ATTRIBUTE_DIRECTORY) <> 0) or
    ((Attributes and CCOD_FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Exit;
  DirectoryName := ExtractFileDir(FileName);
  RootName := ExtractFileDir(DirectoryName);
  DirectoryAttributes := GetFileAttributesW(DirectoryName);
  RootAttributes := GetFileAttributesW(RootName);
  Result := (DirectoryAttributes <> CCOD_INVALID_FILE_ATTRIBUTES) and
    (RootAttributes <> CCOD_INVALID_FILE_ATTRIBUTES) and
    ((DirectoryAttributes and CCOD_FILE_ATTRIBUTE_DIRECTORY) <> 0) and
    ((RootAttributes and CCOD_FILE_ATTRIBUTE_DIRECTORY) <> 0) and
    ((DirectoryAttributes and CCOD_FILE_ATTRIBUTE_REPARSE_POINT) = 0) and
    ((RootAttributes and CCOD_FILE_ATTRIBUTE_REPARSE_POINT) = 0) and
    ((Attributes and CCOD_FILE_ATTRIBUTE_DIRECTORY) = 0) and
    ((Attributes and CCOD_FILE_ATTRIBUTE_REPARSE_POINT) = 0);
end;

procedure RefuseStaleActivationReceipt(const ReceiptPath: String);
var
  Attributes: Cardinal;
begin
  Attributes := GetFileAttributesW(ReceiptPath);
  if Attributes <> CCOD_INVALID_FILE_ATTRIBUTES then
  begin
    if not IsSafeActivationFile(ReceiptPath) then
      RaiseException('CodexRemote-fix refused an unsafe stale activation receipt.');
    if not DeleteFile(ReceiptPath) then
      RaiseException('CodexRemote-fix could not remove a stale activation receipt.');
  end;
  if GetFileAttributesW(ReceiptPath) <> CCOD_INVALID_FILE_ATTRIBUTES then
    RaiseException('CodexRemote-fix refused a stale activation receipt.');
end;

function LoadBoundedActivationReceipt(const ReceiptPath: String; var Content: AnsiString): Boolean;
var
  ReceiptSize: Int64;
begin
  Result := False;
  if not FileSize64(ReceiptPath, ReceiptSize) then Exit;
  if (ReceiptSize <= 0) or (ReceiptSize > 16384) then Exit;
  Result := LoadStringFromFile(ReceiptPath, Content);
end;

function HasJsonStringValue(const Content, FieldName, FieldValue: String): Boolean;
begin
  Result := (Pos('"' + FieldName + '": "' + FieldValue + '"', Content) > 0) or
    (Pos('"' + FieldName + '":"' + FieldValue + '"', Content) > 0);
end;

function DetectActivationPhase(const Content: String): TActivationPhase;
begin
  Result := apNone;
  if HasJsonStringValue(Content, 'phase', 'StoppingPreviousRuntime') then
    Result := apStoppingPreviousRuntime
  else if HasJsonStringValue(Content, 'phase', 'InstallingRuntime') then
    Result := apInstallingRuntime
  else if HasJsonStringValue(Content, 'phase', 'ActivatingRuntime') then
    Result := apActivatingRuntime
  else if HasJsonStringValue(Content, 'phase', 'StartingProtection') then
    Result := apStartingProtection
  else if HasJsonStringValue(Content, 'phase', 'Ready') then
    Result := apReady
  else if HasJsonStringValue(Content, 'phase', 'Failed') then
    Result := apFailed;
end;

procedure UpdateActivationPresentation(const Phase: TActivationPhase);
begin
  case Phase of
    apStoppingPreviousRuntime:
      begin WizardForm.StatusLabel.Caption := 'Stopping the previous protected runtime...'; WizardForm.ProgressGauge.Position := 20; end;
    apInstallingRuntime:
      begin WizardForm.StatusLabel.Caption := 'Installing the verified runtime...'; WizardForm.ProgressGauge.Position := 40; end;
    apActivatingRuntime:
      begin WizardForm.StatusLabel.Caption := 'Committing the runtime generation...'; WizardForm.ProgressGauge.Position := 60; end;
    apStartingProtection:
      begin WizardForm.StatusLabel.Caption := 'Starting Supervisor and TrayHost protection...'; WizardForm.ProgressGauge.Position := 80; end;
    apReady:
      begin WizardForm.StatusLabel.Caption := 'Verifying activation completion...'; WizardForm.ProgressGauge.Position := 95; end;
    apFailed:
      begin WizardForm.StatusLabel.Caption := 'Activation failed safely.'; WizardForm.ProgressGauge.Position := 95; end;
  end;
end;

function ReadActivationProgressPhase(const ReceiptPath, ExpectedActivationId: String): TActivationPhase;
var
  Content: AnsiString;
  Text: String;
begin
  Result := apNone;
  if not FileExists(ReceiptPath) then Exit;
  if not IsSafeActivationFile(ReceiptPath) then Exit;
  if not LoadBoundedActivationReceipt(ReceiptPath, Content) then Exit;
  Text := String(Content);
  if HasJsonStringValue(Text, 'activationId', ExpectedActivationId) then
    Result := DetectActivationPhase(Text);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  LaunchResultCode: Integer;
  ValidationResultCode: Integer;
  PromptResultCode: Integer;
  Parameters, ReceiptPath, ActivationId: String;
  Phase: TActivationPhase;
  DeadlineTick, NextValidationAttemptTick: Int64;
  LastValidationResultCode: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;
  ActivationId := NewActivationId();
  ReceiptPath := ExpandConstant('{localappdata}\CodexControlOtherDevices\state\post-install-activation.json');
  RefuseStaleActivationReceipt(ReceiptPath);
  DeadlineTick := GetTickCount64() + ACTIVATION_TIMEOUT_MILLISECONDS;
  Parameters := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Activate-CcodRemoteFix.ps1') + '" -AppRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -ActivationId "' + ActivationId + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewNoWait, LaunchResultCode) then
  begin
    Log('CodexRemote-fix activation worker could not be started: ' + SysErrorMessage(LaunchResultCode));
    RaiseException('CodexRemote-fix activation process could not be started.');
  end;
  NextValidationAttemptTick := 0;
  LastValidationResultCode := -1;
  while True do
  begin
    if GetTickCount64() >= DeadlineTick then
    begin
      Log('CodexRemote-fix activation timed out before a validated current-id terminal result.');
      RaiseException('CodexRemote-fix activation timed out.');
    end;
    Phase := ReadActivationProgressPhase(ReceiptPath, ActivationId);
    UpdateActivationPresentation(Phase);
    if (Phase in [apReady, apFailed]) and (GetTickCount64() >= NextValidationAttemptTick) then
    begin
      if GetTickCount64() + VALIDATION_LAUNCH_BUDGET_MILLISECONDS >= DeadlineTick then
      begin
        Log('CodexRemote-fix activation has insufficient remaining budget for strict receipt validation.');
        RaiseException('CodexRemote-fix activation timed out.');
      end;
      Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Activate-CcodRemoteFix.ps1') + '" -AppRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -ValidateReceiptWithTimeout -ValidationTimeoutMilliseconds ' + IntToStr(VALIDATION_TIMEOUT_MILLISECONDS) + ' -ActivationId "' + ActivationId + '"';
      if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewWaitUntilTerminated, ValidationResultCode) then
      begin
        Log('CodexRemote-fix activation validator could not be started: ' + SysErrorMessage(ValidationResultCode));
        RaiseException('CodexRemote-fix activation validator could not be started.');
      end;
      if GetTickCount64() >= DeadlineTick then
      begin
        Log('CodexRemote-fix activation validator exceeded the activation deadline.');
        RaiseException('CodexRemote-fix activation timed out.');
      end;
      case ValidationResultCode of
        0:
        begin
          WizardForm.StatusLabel.Caption := 'CodexRemote-fix activation is ready.';
          WizardForm.ProgressGauge.Position := 100;
          WizardForm.Update;
          if not WizardSilent then
          begin
            Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Prompt-CcodRestart.ps1') + '" -AppRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -ActivationId "' + ActivationId + '"';
            if (not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewWaitUntilTerminated, PromptResultCode)) or (PromptResultCode <> 0) then
              SuppressibleMsgBox('Codex restart was not submitted. Restart Codex manually when convenient.', mbInformation, MB_OK, IDOK);
          end;
          Exit;
        end;
        2:
          begin
            Log('CodexRemote-fix activation validator reported a strict Failed receipt.');
            SuppressibleMsgBox('CodexRemote-fix activation failed safely. Use the support code in post-install-activation.log.', mbError, MB_OK, IDOK);
            RaiseException('CodexRemote-fix activation reported Failed.');
          end;
      else
        begin
          if ValidationResultCode <> LastValidationResultCode then
            Log('CodexRemote-fix activation validator has not accepted a strict terminal receipt; verification will retry.');
          LastValidationResultCode := ValidationResultCode;
          NextValidationAttemptTick := GetTickCount64() + VALIDATION_RETRY_MILLISECONDS;
        end;
      end;
    end;
    WizardForm.Update;
    Sleep(ACTIVATION_POLL_MILLISECONDS);
  end;
end;

function IsCanonicalUninstallTransactionId(const Value: String): Boolean;
var
  Index: Integer;
  Character: Char;
begin
  Result := Length(Value) = 36;
  if not Result then Exit;
  for Index := 1 to Length(Value) do
  begin
    Character := Value[Index];
    if (Index = 9) or (Index = 14) or (Index = 19) or (Index = 24) then
    begin
      if Character <> '-' then begin Result := False; Exit; end;
    end
    else if not (((Character >= '0') and (Character <= '9')) or ((Character >= 'a') and (Character <= 'f'))) then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function TryReadUninstallTransactionId(var TransactionId: String): Boolean;
var
  CurrentPath, Text, Marker: String;
  Content: AnsiString;
  Position: Integer;
begin
  Result := False;
  TransactionId := '';
  CurrentPath := ExpandConstant('{localappdata}\CodexRemote-fix-uninstall\current.json');
  if not IsSafeActivationFile(CurrentPath) then Exit;
  if not LoadBoundedActivationReceipt(CurrentPath, Content) then Exit;
  Text := String(Content);
  Marker := '"transactionId":"';
  Position := Pos(Marker, Text);
  if Position = 0 then Exit;
  Position := Position + Length(Marker);
  if Position + 36 > Length(Text) + 1 then Exit;
  TransactionId := Copy(Text, Position, 36);
  if (Position + 36 > Length(Text)) or (Text[Position + 36] <> '"') or not IsCanonicalUninstallTransactionId(TransactionId) then
  begin
    TransactionId := '';
    Exit;
  end;
  Result := True;
end;

function GetExternalUninstallBootstrapPath: String;
var
  TransactionId: String;
begin
  Result := '';
  if not TryReadUninstallTransactionId(TransactionId) then Exit;
  Result := ExpandConstant('{localappdata}\CodexRemote-fix-uninstall\') + TransactionId + '\payload\src\persistence\UninstallBootstrap.ps1';
  if not FileExists(Result) then Result := '';
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
  Parameters: String;
begin
  Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\src\persistence\UninstallBootstrap.ps1') + '" -InstallerRoot "' +
    ExpandConstant('{app}') + '" -InstallRoot "' +
    ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -Mode Prepare';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
  begin
    Log('CodexRemote-fix uninstall bootstrap refused pre-deletion cleanup, result code ' + IntToStr(ResultCode) + '.');
    SuppressibleMsgBox('CodexRemote-fix could not verify safe cleanup. No installer files were removed; retry uninstall after resolving the reported support code.', mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  Parameters, BootstrapPath: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  BootstrapPath := GetExternalUninstallBootstrapPath;
  if BootstrapPath = '' then
  begin
    Log('CodexRemote-fix uninstall completion receipt could not locate the staged bootstrap.');
    RaiseException('CCOD_UNINSTALL_FINALIZATION_MISSING');
  end;
  Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + BootstrapPath +
    '" -InstallerRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' +
    ExpandConstant('{localappdata}\CodexControlOtherDevices') + '" -Mode FinalizeReceipt';
  if (not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
  begin
    Log('CodexRemote-fix uninstall completion receipt was not finalized, result code ' + IntToStr(ResultCode) + '.');
    RaiseException('CCOD_UNINSTALL_FINALIZATION_FAILED');
  end;
end;

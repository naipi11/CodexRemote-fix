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

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-CodexControlOtherDevices.ps1"" -BackupDeviceKeyStore"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallCodexControlOtherDevices"

[Icons]
Name: "{group}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\CodexRemote-fix compatibility check"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Test-CodexControlOtherDevices.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\Uninstall CodexRemote-fix"; Filename: "{app}\unins000.exe"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{userdesktop}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"

[Code]
const
  PROCESS_SYNCHRONIZE = $00100000;
  WAIT_OBJECT_0 = $00000000;
  WAIT_TIMEOUT = $00000102;

type
  TActivationPhase = (apNone, apStoppingPreviousRuntime, apInstallingRuntime,
    apActivatingRuntime, apStartingProtection, apReady, apFailed);

function OpenProcess(dwDesiredAccess: LongWord; bInheritHandle: Boolean;
  dwProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function HasJsonStringValue(const Content, FieldName, FieldValue: String): Boolean;
begin
  Result := (Pos('"' + FieldName + '": "' + FieldValue + '"', Content) > 0) or
    (Pos('"' + FieldName + '":"' + FieldValue + '"', Content) > 0);
end;

function HasJsonLiteralValue(const Content, FieldName, FieldValue: String): Boolean;
begin
  Result := (Pos('"' + FieldName + '": ' + FieldValue, Content) > 0) or
    (Pos('"' + FieldName + '":' + FieldValue, Content) > 0);
end;

function ReadJsonStringField(const Content, FieldName: String; var Value: String): Boolean;
var
  Marker, Tail: String;
  StartAt, EndAt: Integer;
begin
  Result := False;
  Value := '';
  Marker := '"' + FieldName + '": "';
  StartAt := Pos(Marker, Content);
  if StartAt = 0 then
  begin
    Marker := '"' + FieldName + '":"';
    StartAt := Pos(Marker, Content);
  end;
  if StartAt = 0 then Exit;
  Tail := Copy(Content, StartAt + Length(Marker), Length(Content));
  EndAt := Pos('"', Tail);
  if EndAt <= 1 then Exit;
  Value := Copy(Tail, 1, EndAt - 1);
  Result := True;
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

procedure UpdateActivationPresentation(const ReceiptPath: String);
var
  Content: AnsiString;
  Phase: TActivationPhase;
begin
  if not LoadStringFromFile(ReceiptPath, Content) then Exit;
  Phase := DetectActivationPhase(String(Content));
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

function ReadActivationTerminal(const ReceiptPath: String;
  var TerminalPhase: TActivationPhase; var ActivationId: String): Boolean;
var
  Content: AnsiString;
  Text, RuntimeId, ErrorCode: String;
begin
  Result := False;
  TerminalPhase := apNone;
  ActivationId := '';
  if not LoadStringFromFile(ReceiptPath, Content) then Exit;
  Text := String(Content);
  TerminalPhase := DetectActivationPhase(Text);
  if not ReadJsonStringField(Text, 'activationId', ActivationId) or
    (Length(ActivationId) <> 36) then Exit;
  if TerminalPhase = apReady then
  begin
    if not ReadJsonStringField(Text, 'runtimeId', RuntimeId) or (RuntimeId = '') or
      not HasJsonLiteralValue(Text, 'ready', 'true') or
      not HasJsonLiteralValue(Text, 'errorCode', 'null') then Exit;
    Result := True;
  end
  else if TerminalPhase = apFailed then
  begin
    if not ReadJsonStringField(Text, 'errorCode', ErrorCode) or
      (Pos('CCOD_', ErrorCode) <> 1) or
      not HasJsonLiteralValue(Text, 'ready', 'false') then Exit;
    Result := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PromptResultCode: Integer;
  Parameters, ReceiptPath, ActivationId: String;
  ProcessHandle: THandle;
  TerminalPhase: TActivationPhase;
begin
  if CurStep <> ssPostInstall then
    Exit;
  ReceiptPath := ExpandConstant('{localappdata}\CodexControlOtherDevices\state\post-install-activation.json');
  Parameters := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Activate-CcodRemoteFix.ps1') + '" -AppRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewNoWait, ResultCode) then
    RaiseException('CodexRemote-fix activation process could not be started.');
  ProcessHandle := OpenProcess(PROCESS_SYNCHRONIZE, False, LongWord(ResultCode));
  if ProcessHandle = 0 then
    RaiseException('CodexRemote-fix activation process could not be monitored.');
  try
    while WaitForSingleObject(ProcessHandle, 50) = WAIT_TIMEOUT do
    begin
      UpdateActivationPresentation(ReceiptPath);
      WizardForm.Update;
      Sleep(50);
    end;
  finally
    CloseHandle(ProcessHandle);
  end;
  if not ReadActivationTerminal(ReceiptPath, TerminalPhase, ActivationId) then
    RaiseException('CodexRemote-fix activation ended without a valid Ready or Failed receipt.');
  if TerminalPhase = apFailed then
  begin
    SuppressibleMsgBox('CodexRemote-fix activation failed safely. Use the support code in post-install-activation.log.', mbError, MB_OK, IDOK);
    RaiseException('CodexRemote-fix activation reported Failed.');
  end;
  if TerminalPhase = apReady then
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
  end;
end;

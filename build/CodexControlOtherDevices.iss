[Setup]
#ifndef ProjectVersion
#error ProjectVersion must be supplied by the release builder
#endif
#ifndef InstallerPackagePath
#error InstallerPackagePath must be supplied by the release builder
#endif
#ifndef InstallerPackageManifestPath
#error InstallerPackageManifestPath must be supplied by the release builder
#endif
#ifndef InstallerPackageSha256
#error InstallerPackageSha256 must be supplied by the release builder
#endif
#ifndef InstallerPackageManifestSha256
#error InstallerPackageManifestSha256 must be supplied by the release builder
#endif
#define InstallerPackageManifestSha256First Copy(InstallerPackageManifestSha256, 1, 32)
#define InstallerPackageManifestSha256Last Copy(InstallerPackageManifestSha256, 33, 32)
#ifndef ActivationBootstrapPath
#error ActivationBootstrapPath must be supplied by the release builder
#endif
#ifndef ActivationBootstrapSha256
#error ActivationBootstrapSha256 must be supplied by the release builder
#endif
#define ActivationBootstrapSha256First Copy(ActivationBootstrapSha256, 1, 32)
#define ActivationBootstrapSha256Last Copy(ActivationBootstrapSha256, 33, 32)
#ifndef SetupGitCommit
#error SetupGitCommit must be supplied by the release builder
#endif
#ifndef SetupProvenancePath
#error SetupProvenancePath must be supplied by the release builder
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
VersionInfoTextVersion={#ProjectVersion}.0
VersionInfoProductName={#ActivationBootstrapSha256Last}
VersionInfoProductTextVersion={#InstallerPackageManifestSha256First}
VersionInfoDescription={#InstallerPackageManifestSha256Last}
VersionInfoCompany={#SetupGitCommit}
VersionInfoCopyright={#InstallerPackageSha256}
VersionInfoOriginalFileName={#ActivationBootstrapSha256First}
DefaultDirName={localappdata}\CodexControlOtherDevices
CreateAppDir=no
Uninstallable=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=CodexRemote-fix-{#ProjectVersion}-setup
SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico
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
Source: "{#InstallerPackagePath}"; DestName: "ccod-installer-package.zip"; Flags: dontcopy
Source: "{#InstallerPackageManifestPath}"; DestName: "ccod-installer-package.manifest.json"; Flags: dontcopy
Source: "{#ActivationBootstrapPath}"; DestName: "ccod-activation-bootstrap.ps1"; Flags: dontcopy
Source: "{#SetupProvenancePath}"; DestName: "ccod-setup-provenance.json"; Flags: dontcopy

[Code]
// CCOD_INSTALLER_DESTINATION_INVENTORY
const
  CCOD_GENERIC_READ = $80000000;
  CCOD_FILE_SHARE_READ = $00000001;
  CCOD_OPEN_EXISTING = 3;
  CCOD_FILE_ATTRIBUTE_NORMAL = $00000080;
  CCOD_INVALID_HANDLE_VALUE = -1;
  CCOD_EXPECTED_PACKAGE_SHA256 = '{#InstallerPackageSha256}';
  CCOD_EXPECTED_PACKAGE_MANIFEST_SHA256 = '{#InstallerPackageManifestSha256}';
  CCOD_EXPECTED_BOOTSTRAP_SHA256 = '{#ActivationBootstrapSha256}';

var
  CcodInputHandles: array of Integer;
  CcodPackagePath: String;
  CcodPackageManifestPath: String;
  CcodBootstrapPath: String;

function CreateFileW(const FileName: String; DesiredAccess, ShareMode,
  SecurityAttributes, CreationDisposition, FlagsAndAttributes,
  TemplateFile: Cardinal): Integer;
  external 'CreateFileW@kernel32.dll stdcall';
function CloseHandle(Handle: Integer): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function CoCreateGuid(var Guid: TGUID): HResult;
  external 'CoCreateGuid@ole32.dll stdcall';
function StringFromGUID2(var Guid: TGUID; GuidString: String;
  MaxCharacters: Integer): Integer;
  external 'StringFromGUID2@ole32.dll stdcall';

procedure CloseCcodInputHandles();
var
  Index: Integer;
begin
  for Index := GetArrayLength(CcodInputHandles) - 1 downto 0 do
    if CcodInputHandles[Index] <> CCOD_INVALID_HANDLE_VALUE then
      CloseHandle(CcodInputHandles[Index]);
  SetArrayLength(CcodInputHandles, 0);
end;

function LockCcodInput(const Path, ExpectedSha256: String): Boolean;
var
  Handle: Integer;
  Count: Integer;
begin
  Result := False;
  if Lowercase(GetSHA256OfFile(Path)) <> ExpectedSha256 then Exit;
  Handle := CreateFileW(Path, CCOD_GENERIC_READ, CCOD_FILE_SHARE_READ, 0,
    CCOD_OPEN_EXISTING, CCOD_FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = CCOD_INVALID_HANDLE_VALUE then Exit;
  if Lowercase(GetSHA256OfFile(Path)) <> ExpectedSha256 then
  begin
    CloseHandle(Handle);
    Exit;
  end;
  Count := GetArrayLength(CcodInputHandles);
  SetArrayLength(CcodInputHandles, Count + 1);
  CcodInputHandles[Count] := Handle;
  Result := True;
end;

function ExtractAndLockCcodInputs(): Boolean;
begin
  Result := False;
  ExtractTemporaryFile('ccod-installer-package.zip');
  ExtractTemporaryFile('ccod-installer-package.manifest.json');
  ExtractTemporaryFile('ccod-activation-bootstrap.ps1');
  ExtractTemporaryFile('ccod-setup-provenance.json');
  CcodPackagePath := ExpandConstant('{tmp}\ccod-installer-package.zip');
  CcodPackageManifestPath := ExpandConstant('{tmp}\ccod-installer-package.manifest.json');
  CcodBootstrapPath := ExpandConstant('{tmp}\ccod-activation-bootstrap.ps1');
  if not LockCcodInput(CcodPackagePath, CCOD_EXPECTED_PACKAGE_SHA256) then Exit;
  if not LockCcodInput(CcodPackageManifestPath, CCOD_EXPECTED_PACKAGE_MANIFEST_SHA256) then Exit;
  if not LockCcodInput(CcodBootstrapPath, CCOD_EXPECTED_BOOTSTRAP_SHA256) then Exit;
  Result := True;
end;

function NewActivationId(): String;
var
  Guid: TGUID;
  Value: String;
  Length: Integer;
begin
  if CoCreateGuid(Guid) <> 0 then RaiseException('CCOD_SETUP_ACTIVATION_ID_FAILED');
  SetLength(Value, 39);
  Length := StringFromGUID2(Guid, Value, 39);
  if Length <> 39 then RaiseException('CCOD_SETUP_ACTIVATION_ID_FAILED');
  SetLength(Value, 38);
  Result := Lowercase(Copy(Value, 2, 36));
end;

function GetCcodBootstrapParameters(const ActivationId: String;
  ValidateOnly: Boolean): String;
begin
  Result := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
    CcodBootstrapPath + '" -PackagePath "' + CcodPackagePath +
    '" -PackageManifestPath "' + CcodPackageManifestPath +
    '" -ExpectedPackageSha256 "{#InstallerPackageSha256}' +
    '" -ExpectedPackageManifestSha256 "{#InstallerPackageManifestSha256}' +
    '" -ExpectedVersion "{#ProjectVersion}' +
    '" -ExpectedGitCommit "{#SetupGitCommit}' +
    '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') +
    '" -ActivationId "' + ActivationId + '"';
  if ValidateOnly then Result := Result + ' -ValidateReceiptOnly';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  CloseCcodInputHandles();
  try
    if not ExtractAndLockCcodInputs() then
      Result := 'CCOD_SETUP_INPUT_BINDING_INVALID';
  except
    Result := 'CCOD_SETUP_INPUT_BINDING_INVALID';
  end;
  if Result <> '' then CloseCcodInputHandles();
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ActivationId, Parameters: String;
  ActivationResultCode, ValidationResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  if GetArrayLength(CcodInputHandles) <> 3 then
    RaiseException('CCOD_SETUP_INPUT_BINDING_INVALID');
  ActivationId := NewActivationId();
  Parameters := GetCcodBootstrapParameters(ActivationId, False);
  if (not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
      '', SW_HIDE, ewWaitUntilTerminated, ActivationResultCode)) or
      (ActivationResultCode <> 0) then RaiseException('CCOD_SETUP_ACTIVATION_FAILED');
  Parameters := GetCcodBootstrapParameters(ActivationId, True);
  if (not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
      '', SW_HIDE, ewWaitUntilTerminated, ValidationResultCode)) or
      (ValidationResultCode <> 0) then RaiseException('CCOD_SETUP_READY_VALIDATION_FAILED');
  WizardForm.StatusLabel.Caption := 'CodexRemote-fix activation is ready.';
  WizardForm.ProgressGauge.Position := 100;
end;

procedure DeinitializeSetup();
begin
  CloseCcodInputHandles();
end;

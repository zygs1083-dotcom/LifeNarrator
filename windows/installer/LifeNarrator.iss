#ifndef AppVersion
  #define AppVersion "0.8.5"
#endif

[Setup]
AppId=LifeNarrator
AppName=LifeNarrator
AppVersion={#AppVersion}
AppPublisher=LifeNarrator
AppPublisherURL=https://github.com/zygs1083-dotcom/LifeNarrator
DefaultDirName={localappdata}\Programs\LifeNarrator
DefaultGroupName=LifeNarrator
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir=..\..\artifacts
OutputBaseFilename=LifeNarrator-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\LifeNarrator.exe
AppMutex=Local\LifeNarrator.Windows
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\..\artifacts\shell\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LifeNarrator"; Filename: "{app}\LifeNarrator.exe"

[Run]
Filename: "{app}\LifeNarrator.exe"; Description: "{cm:LaunchProgram,LifeNarrator}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "LifeNarrator"; Flags: uninsdeletevalue

[UninstallRun]
Filename: "{app}\LifeNarrator.exe"; Parameters: "--delete-user-data"; Flags: runhidden waituntilterminated; Check: DeleteUserData

[Code]
var
  RemoveData: Boolean;

function InitializeUninstall(): Boolean;
begin
  RemoveData := False;
  if not UninstallSilent then
    if GetUILanguage = $0804 then
      RemoveData := MsgBox('同时删除设置、本地历史和 API 密钥吗？选择“否”会保留它们。', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES
    else
      RemoveData := MsgBox('Also delete settings, local history and API keys? Choose No to keep them.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
  Result := True;
end;

function DeleteUserData(): Boolean;
begin
  Result := RemoveData;
end;

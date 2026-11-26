; CryptLok installer (Inno Setup 6).  Build with installer\build-installer.cmd, or open this file in the
; Inno Setup compiler.  It packs out\CryptLok.exe, the GnuPG runtime from pgp-samples\bin and the licence files.
;
; Never touched by install or uninstall: %USERPROFILE%\.cryptlok (your keyring and settings).

#define AppName "CryptLok"
#define AppVersion "0.3.0"
#define AppPublisher "Level103"
#define AppURL "https://www.level103.com"
#define GpgSource "..\pgp-samples\bin"

[Setup]
AppId={{5B1D7E0A-3C52-4E6B-9A57-C1F0A2D8E103}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
VersionInfoVersion={#AppVersion}.0
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\out
OutputBaseFilename=CryptLok-Setup-{#AppVersion}
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\CryptLok.exe
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; the running program (it may sit in the tray) holds this mutex: setup asks to close it first
AppMutex=Level103.CryptLok.SingleInstance
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
Name: "explorer"; Description: "Add CryptLok to &Explorer (right-click Encrypt, Shred, Sign and Verify; .sig file type and icon)"; GroupDescription: "Explorer:"

[Files]
Source: "..\out\CryptLok.exe"; DestDir: "{app}"; Flags: ignoreversion
; GnuPG runtime: the program looks for GnuPG\bin\gpg.exe next to itself first
Source: "{#GpgSource}\*"; DestDir: "{app}\GnuPG\bin"; Excludes: "*.tmp"; Flags: ignoreversion recursesubdirs
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\NOTICE"; DestDir: "{app}"; DestName: "NOTICE.txt"; Flags: ignoreversion
Source: "..\ART-LICENSE.md"; DestDir: "{app}"; DestName: "ART-LICENSE.txt"; Flags: ignoreversion
Source: "..\THIRD-PARTY.md"; DestDir: "{app}"; DestName: "THIRD-PARTY.txt"; Flags: ignoreversion
Source: "GnuPG-COPYING.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\CryptLok.exe"
Name: "{group}\Licence and notices"; Filename: "{app}\THIRD-PARTY.txt"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\CryptLok.exe"; Tasks: desktopicon

[Run]
; per-user Explorer entries (HKCU): written as the user who ran setup, not the elevated admin account
Filename: "{app}\CryptLok.exe"; Parameters: "/installshell"; StatusMsg: "Adding CryptLok to Explorer..."; Flags: runasoriginaluser waituntilterminated; Tasks: explorer
Filename: "{app}\CryptLok.exe"; Description: "Start {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; stop the GnuPG background programs for the user's keyring, and take back the Explorer menu entries
Filename: "{app}\GnuPG\bin\gpgconf.exe"; Parameters: "--homedir ""{%USERPROFILE}\.cryptlok\gnupg"" --kill all"; Flags: runhidden; RunOnceId: "StopGpgAgent"
Filename: "{app}\CryptLok.exe"; Parameters: "/removeshell"; Flags: runhidden; RunOnceId: "RemoveShell"

[Code]
function VeraCryptFound: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf64}\VeraCrypt\VeraCrypt.exe')) or
            FileExists(ExpandConstant('{commonpf32}\VeraCrypt\VeraCrypt.exe'));
end;

{ Before any file is copied: stop the GnuPG background programs of an older copy (they have no window, so
  Windows cannot ask them to close and logs a warning when setup tries) }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Gpgconf: String;
  Code: Integer;
begin
  Result := '';
  Gpgconf := ExpandConstant('{app}\GnuPG\bin\gpgconf.exe');
  if FileExists(Gpgconf) then
    Exec(Gpgconf, '--homedir "' + ExpandConstant('{%USERPROFILE}') + '\.cryptlok\gnupg" --kill all', '',
      SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (not VeraCryptFound) then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'VeraCrypt was not found on this computer. Keys, Zip and Viewer work without it; the Disk pages ' +
      'need the free VeraCrypt from https://veracrypt.fr/';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    if not UninstallSilent then
      MsgBox('CryptLok has been removed.' + #13#10#13#10 +
        'Your keys and settings in ' + ExpandConstant('{%USERPROFILE}\.cryptlok') +
        ' were NOT deleted. Delete that folder yourself only if you no longer need those keys.',
        mbInformation, MB_OK);
end;

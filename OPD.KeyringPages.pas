unit OPD.KeyringPages;

{ Key Management (sidebar): back up the keyring, restore a backup, and keep the keyring in another folder.

  The keyring lives in a "data folder" that holds gnupg\ (GnuPG's files) and settings.ini.  The default data
  folder is %USERPROFILE%\.cryptlok; another one is recorded in %USERPROFILE%\.cryptlok\location.ini (see
  OPD.Engine.CryptLokDataFolder).  Moving copies everything, checks the copy with GnuPG, records the new folder
  and restarts CryptLok, so nothing is left half-switched. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  OPD.Theme, OPD.Engine;

type
  TRestartProc = reference to procedure;

  { a page whose controls are stacked top to bottom and whose text wraps to the window width }
  TFlowPage = class(TPanel)
  private
    FFlow: TArray<TControl>;
    FGap: TArray<Integer>;      { space above the control; -1 = on the same row as the one before }
    procedure Reflow;
  protected
    procedure Resize; override;
    procedure AddFlow(C: TControl; AGap: Integer);
    function Heading(const ACap: string; AGap: Integer): TLabel;
    function Body(const ACap: string; AGap: Integer): TLabel;
    function Btn(const ACap: string; AW, AGap: Integer; AClick: TNotifyEvent): TButton;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TBackupPage = class(TFlowPage)
  private
    FEngine: IKeyEngine;
    FLast: TLabel;
    FOnRestart: TRestartProc;
    procedure BackupClick(Sender: TObject);
    procedure RestoreClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; const AEngine: IKeyEngine; AOnRestart: TRestartProc); reintroduce;
    procedure Prepare;
  end;

  TLocationPage = class(TFlowPage)
  private
    FEngine: IKeyEngine;
    FFolder: TEdit;
    FDefault: TButton;
    FOnRestart: TRestartProc;
    procedure ChangeClick(Sender: TObject);
    procedure DefaultClick(Sender: TObject);
    procedure SwitchTo(const ATarget: string);
  public
    constructor Create(AOwner: TComponent; const AEngine: IKeyEngine; AOnRestart: TRestartProc); reintroduce;
    procedure Prepare;
  end;

{ ---- the work itself (no windows; used by the pages and the tests) ---- }

{ True when AFolder holds a CryptLok/GnuPG keyring (gnupg\pubring.kbx) }
function FolderHasKeyring(const AFolder: string): Boolean;
{ Writes a .zip with everything needed to restore the keyring and settings.  AError explains a failure. }
function BackupKeyring(const AEngine: IKeyEngine; const AZipFile: string; out AError: string): Boolean;
{ Copies the current data folder to ATarget (which must not hold a keyring yet) and checks the copy has the
  same keys.  Does not switch; returns the number of keys found in the copy. }
function CopyKeyringTo(const AEngine: IKeyEngine; const ATarget: string; out AKeys: Integer;
  out AError: string): Boolean;
{ Records ATarget as the data folder (the default folder removes the record). }
procedure SetDataFolder(const ATarget: string);
{ Deletes the keyring files of a data folder that is no longer used (keeps location.ini). }
procedure DeleteOldKeyring(const AFolder: string);

implementation

uses
  Winapi.Windows, System.IOUtils, System.Zip, System.IniFiles, System.StrUtils, System.Math, Vcl.Dialogs,
  Vcl.FileCtrl, OPD.MasterKeys;

const
  PAGE_COLOR = $00948A80;   { same grey-blue content area as the Disk pages }
  PAGE_TEXT = $00E8E0D8;

{ files never copied: GnuPG's lock files and socket stand-ins, and our own pointer file }
function SkipFile(const AName: string): Boolean;
var
  N: string;
begin
  N := LowerCase(ExtractFileName(AName));
  Result := N.EndsWith('.lock') or N.StartsWith('s.') or N.StartsWith('.#lk') or (N = 'location.ini');
end;

function DataFolderOf(const AEngine: IKeyEngine): string;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir));
end;

function FolderHasKeyring(const AFolder: string): Boolean;
begin
  Result := FileExists(TPath.Combine(TPath.Combine(AFolder, 'gnupg'), 'pubring.kbx'));
end;

function ListFiles(const AFolder: string): TArray<string>;
var
  F: string;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    if FileExists(TPath.Combine(AFolder, 'settings.ini')) then
      L.Add(TPath.Combine(AFolder, 'settings.ini'));
    if DirectoryExists(TPath.Combine(AFolder, 'gnupg')) then
      for F in TDirectory.GetFiles(TPath.Combine(AFolder, 'gnupg'), '*', TSearchOption.soAllDirectories) do
        if not SkipFile(F) then
          L.Add(F);
    Result := L.ToStringArray;
  finally
    L.Free;
  end;
end;

function RelPath(const ABase, AFile: string): string;
begin
  Result := Copy(AFile, Length(IncludeTrailingPathDelimiter(ABase)) + 1, MaxInt);
end;

const
  RESTORE_TEXT =
    'CryptLok keyring backup' + #13#10 +
    '=======================' + #13#10#13#10 +
    'This file holds your CryptLok keyring: your public keys, your private keys (still protected by their' + #13#10 +
    'passphrases), trust settings and CryptLok settings.  Keep it somewhere safe.' + #13#10#13#10 +
    'To restore it: CryptLok > Key Management > Backup Keyring > Restore from a Backup..., or unzip it into an' + #13#10 +
    'empty folder and choose that folder in Key Management > Keyring Location.' + #13#10;

function BackupKeyring(const AEngine: IKeyEngine; const AZipFile: string; out AError: string): Boolean;
var
  Z: TZipFile;
  Base, F: string;
begin
  Result := False;
  AError := '';
  Base := DataFolderOf(AEngine);
  AEngine.StopAgent;          { make sure GnuPG has written everything out }
  try
    if FileExists(AZipFile) then
      System.SysUtils.DeleteFile(AZipFile);
    Z := TZipFile.Create;
    try
      Z.Open(AZipFile, zmWrite);
      for F in ListFiles(Base) do
        Z.Add(F, StringReplace(RelPath(Base, F), '\', '/', [rfReplaceAll]));
      Z.Add(TEncoding.UTF8.GetBytes(RESTORE_TEXT), 'README-RESTORE.txt');
      Z.Close;
    finally
      Z.Free;
    end;
    Result := True;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

function CopyKeyringTo(const AEngine: IKeyEngine; const ATarget: string; out AKeys: Integer;
  out AError: string): Boolean;
var
  Base, F, Dest: string;
  Check: IKeyEngine;
  Before: Integer;
begin
  Result := False;
  AKeys := 0;
  AError := '';
  Base := DataFolderOf(AEngine);
  if SameText(ExcludeTrailingPathDelimiter(Base), ExcludeTrailingPathDelimiter(ATarget)) then
  begin
    AError := 'That is already where the keyring is.';
    Exit;
  end;
  if FolderHasKeyring(ATarget) then
  begin
    AError := 'That folder already holds a keyring.';
    Exit;
  end;
  Before := Length(AEngine.ListKeys);
  AEngine.StopAgent;
  try
    for F in ListFiles(Base) do
    begin
      Dest := TPath.Combine(ATarget, RelPath(Base, F));
      ForceDirectories(ExtractFilePath(Dest));
      TFile.Copy(F, Dest, True);
    end;
  except
    on E: Exception do
    begin
      AError := 'Copying failed: ' + E.Message;
      Exit;
    end;
  end;
  { open the copy with GnuPG: it must show the same keys }
  Check := TGpgEngine.Create(TPath.Combine(ATarget, 'gnupg'));
  try
    AKeys := Length(Check.ListKeys);
  finally
    Check.StopAgent;
    Check := nil;
  end;
  if AKeys <> Before then
  begin
    AError := Format('The copy shows %d keys instead of %d.', [AKeys, Before]);
    Exit;
  end;
  Result := True;
end;

procedure SetDataFolder(const ATarget: string);
var
  Ini: TIniFile;
begin
  ForceDirectories(DefaultDataFolder);
  if SameText(ExcludeTrailingPathDelimiter(ATarget), ExcludeTrailingPathDelimiter(DefaultDataFolder)) then
  begin
    System.SysUtils.DeleteFile(LocationFile);
    Exit;
  end;
  Ini := TIniFile.Create(LocationFile);
  try
    Ini.WriteString('Keyring', 'Folder', ExcludeTrailingPathDelimiter(ATarget));
  finally
    Ini.Free;
  end;
end;

procedure DeleteOldKeyring(const AFolder: string);
var
  G: string;
begin
  G := TPath.Combine(AFolder, 'gnupg');
  if DirectoryExists(G) then
    TDirectory.Delete(G, True);
  System.SysUtils.DeleteFile(TPath.Combine(AFolder, 'settings.ini'));
  { remove the folder itself when nothing else is in it (the default one keeps location.ini) }
  if DirectoryExists(AFolder) and (Length(TDirectory.GetFileSystemEntries(AFolder)) = 0) then
    RemoveDir(AFolder);
end;

{ ---- flowing page ---- }

constructor TFlowPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Parent := TWinControl(AOwner);
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := PAGE_COLOR;
  ApplyUiFont(Font, 9);
end;

procedure TFlowPage.AddFlow(C: TControl; AGap: Integer);
begin
  C.Parent := Self;
  FFlow := FFlow + [C];
  FGap := FGap + [AGap];
end;

function TFlowPage.Heading(const ACap: string; AGap: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Font.Style := [fsBold];         { before the caption, so the size is measured in bold }
  Result.Font.Color := clWhite;
  Result.Transparent := True;
  Result.Caption := ACap;
  AddFlow(Result, AGap);
end;

function TFlowPage.Body(const ACap: string; AGap: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.AutoSize := False;      { the height is measured in Reflow for the current width }
  Result.WordWrap := True;
  Result.Font.Color := PAGE_TEXT;
  Result.Transparent := True;
  Result.Caption := ACap;
  AddFlow(Result, AGap);
end;

function TFlowPage.Btn(const ACap: string; AW, AGap: Integer; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.SetBounds(0, 0, DpiScale(AW), DpiScale(28));
  Result.Caption := ACap;
  Result.OnClick := AClick;
  AddFlow(Result, AGap);
end;

procedure TFlowPage.Resize;
begin
  inherited;
  Reflow;
end;

{ height a word-wrapped label needs at width AW }
function WrappedHeight(L: TLabel; AW: Integer): Integer;
var
  R: TRect;
  DC: HDC;
  Old: HFONT;
begin
  if L.Caption = '' then Exit(0);
  R := Rect(0, 0, AW, 0);
  DC := GetDC(0);
  try
    Old := SelectObject(DC, L.Font.Handle);
    DrawText(DC, PChar(L.Caption), -1, R, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    SelectObject(DC, Old);
  finally
    ReleaseDC(0, DC);
  end;
  Result := R.Bottom + 2;
end;

procedure TFlowPage.Reflow;
var
  I, Y, X, W, RowTop, RowBottom: Integer;
  C: TControl;
begin
  W := Max(DpiScale(220), Min(ClientWidth - DpiScale(32), DpiScale(720)));
  Y := DpiScale(12);
  RowTop := Y;
  RowBottom := Y;
  X := DpiScale(16);
  for I := 0 to High(FFlow) do
  begin
    C := FFlow[I];
    if (FGap[I] < 0) and (I > 0) then
    begin
      { next to the previous control }
      X := FFlow[I - 1].Left + FFlow[I - 1].Width + DpiScale(8);
      C.SetBounds(X, RowTop, C.Width, C.Height);
    end
    else
    begin
      RowTop := RowBottom + DpiScale(FGap[I]);
      if (C is TLabel) and TLabel(C).WordWrap then
        C.SetBounds(DpiScale(16), RowTop, W, WrappedHeight(TLabel(C), W))
      else if C is TEdit then
        C.SetBounds(DpiScale(16), RowTop, W, C.Height)
      else
        C.SetBounds(DpiScale(16), RowTop, C.Width, C.Height);
    end;
    RowBottom := Max(RowBottom, C.Top + C.Height);
  end;
end;

{ ---- Backup Keyring ---- }

constructor TBackupPage.Create(AOwner: TComponent; const AEngine: IKeyEngine; AOnRestart: TRestartProc);
begin
  inherited Create(AOwner);
  FEngine := AEngine;
  FOnRestart := AOnRestart;
  Heading('Back Up Your Keyring', 4);
  Body('Saves your keys, trust settings and CryptLok settings to one .zip file. Private keys stay protected by ' +
    'their passphrases. Keep the backup somewhere safe and make a new one after you add keys.', 6);
  Btn('Back Up Now...', 150, 10, BackupClick);
  FLast := Body('', 8);
  Heading('Restore from a Backup', 22);
  Body('Unpacks a backup into a folder you choose and switches CryptLok to it (CryptLok restarts). ' +
    'Your current keyring is not changed.', 6);
  Btn('Restore from a Backup...', 190, 10, RestoreClick);
end;

procedure TBackupPage.Prepare;
var
  Ini: TIniFile;
  Last, When: string;
begin
  Ini := TIniFile.Create(IniPath(FEngine));
  try
    Last := Ini.ReadString('Backup', 'LastFile', '');
    When := Ini.ReadString('Backup', 'LastTime', '');
  finally
    Ini.Free;
  end;
  if Last = '' then
    FLast.Caption := 'No backup made yet.'
  else
    FLast.Caption := 'Last backup: ' + When + sLineBreak + Last;
  Reflow;
end;

procedure TBackupPage.BackupClick(Sender: TObject);
var
  D: TSaveDialog;
  Err: string;
  Ok: Boolean;
  Ini: TIniFile;
begin
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Back Up Keyring';
    D.Filter := 'Zip file (*.zip)|*.zip';
    D.DefaultExt := 'zip';
    D.FileName := 'CryptLok-Keyring-' + FormatDateTime('yyyy-mm-dd', Now) + '.zip';
    D.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    Ok := False;
    RunBusy(procedure begin Ok := BackupKeyring(FEngine, D.FileName, Err); end);
    if not Ok then
    begin
      Application.MessageBox(PChar('The backup was not made: ' + Err), 'Backup', MB_OK or MB_ICONWARNING);
      Exit;
    end;
    Ini := TIniFile.Create(IniPath(FEngine));
    try
      Ini.WriteString('Backup', 'LastFile', D.FileName);
      Ini.WriteString('Backup', 'LastTime', FormatDateTime('yyyy-mm-dd hh:nn', Now));
    finally
      Ini.Free;
    end;
    Prepare;
    Application.MessageBox(PChar('Your keyring was backed up to:' + sLineBreak + D.FileName + sLineBreak + sLineBreak +
      'It contains your private keys (protected by their passphrases). Keep it somewhere safe.'),
      'Backup', MB_OK or MB_ICONINFORMATION);
  finally
    D.Free;
  end;
end;

procedure TBackupPage.RestoreClick(Sender: TObject);
var
  O: TOpenDialog;
  Dir: string;
  Target: string;
begin
  O := TOpenDialog.Create(Self);
  try
    O.Title := 'Choose a CryptLok keyring backup';
    O.Filter := 'Zip file (*.zip)|*.zip';
    O.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not O.Execute then Exit;
    if not TZipFile.IsValid(O.FileName) then
    begin
      Application.MessageBox('That is not a zip file.', 'Restore', MB_OK or MB_ICONWARNING);
      Exit;
    end;
    Dir := '';
    if not SelectDirectory('Choose where to keep the restored keyring', '', Dir,
      [sdNewFolder, sdNewUI, sdValidateDir], Self) then Exit;
    Target := TPath.Combine(Dir, 'CryptLok Keyring ' + FormatDateTime('yyyy-mm-dd', Now));
    if DirectoryExists(Target) and (Length(TDirectory.GetFileSystemEntries(Target)) > 0) then
    begin
      Application.MessageBox(PChar(Target + ' already exists and is not empty. Choose another folder.'),
        'Restore', MB_OK or MB_ICONWARNING);
      Exit;
    end;
    ForceDirectories(Target);
    TZipFile.ExtractZipFile(O.FileName, Target);
    System.SysUtils.DeleteFile(TPath.Combine(Target, 'README-RESTORE.txt'));
    if not FolderHasKeyring(Target) then
    begin
      Application.MessageBox('That zip file is not a CryptLok keyring backup (no gnupg\pubring.kbx inside).',
        'Restore', MB_OK or MB_ICONWARNING);
      TDirectory.Delete(Target, True);
      Exit;
    end;
    if Application.MessageBox(PChar('The backup was unpacked to:' + sLineBreak + Target + sLineBreak + sLineBreak +
      'Switch CryptLok to this keyring now? CryptLok will restart. Your current keyring stays where it is.'),
      'Restore', MB_YESNO or MB_ICONQUESTION) <> IDYES then Exit;
    SetDataFolder(Target);
    if Assigned(FOnRestart) then FOnRestart;
  finally
    O.Free;
  end;
end;

{ ---- Keyring Location ---- }

constructor TLocationPage.Create(AOwner: TComponent; const AEngine: IKeyEngine; AOnRestart: TRestartProc);
begin
  inherited Create(AOwner);
  FEngine := AEngine;
  FOnRestart := AOnRestart;
  Heading('Keyring Location', 4);
  Body('The folder that holds your keyring and CryptLok settings:', 6);
  FFolder := TEdit.Create(Self);
  FFolder.ReadOnly := True;
  FFolder.TabStop := False;          { not focused, so the path is not shown highlighted }
  FFolder.AutoSelect := False;
  AddFlow(FFolder, 4);
  Btn('Change Location...', 150, 10, ChangeClick);
  FDefault := Btn('Use Default Location', 170, -1, DefaultClick);
  Body('Change Location copies the keyring to a folder you choose, checks the copy and restarts CryptLok. ' +
    'If the folder already holds a CryptLok keyring (a USB stick or a restored backup), CryptLok switches to it.', 14);
  Body('A keyring on a removable drive must be connected when CryptLok starts.', 8);
end;

procedure TLocationPage.Prepare;
begin
  FFolder.Text := ExcludeTrailingPathDelimiter(DataFolderOf(FEngine));
  FDefault.Enabled := not SameText(FFolder.Text, ExcludeTrailingPathDelimiter(DefaultDataFolder));  Reflow;
end;

procedure TLocationPage.SwitchTo(const ATarget: string);
var
  Old, Err: string;
  Keys: Integer;
  Ok: Boolean;
  Mr: Integer;
begin
  Old := ExcludeTrailingPathDelimiter(DataFolderOf(FEngine));
  if FolderHasKeyring(ATarget) then
  begin
    if Application.MessageBox(PChar(ATarget + ' already holds a CryptLok keyring.' + sLineBreak + sLineBreak +
      'Switch to that keyring? CryptLok will restart. Your current keyring stays in:' + sLineBreak + Old),
      'Keyring Location', MB_YESNO or MB_ICONQUESTION) <> IDYES then Exit;
    SetDataFolder(ATarget);
    if Assigned(FOnRestart) then FOnRestart;
    Exit;
  end;
  if Application.MessageBox(PChar('Move the keyring and settings to:' + sLineBreak + ATarget + sLineBreak + sLineBreak +
    'CryptLok copies them, checks the copy, then restarts.'), 'Keyring Location',
    MB_OKCANCEL or MB_ICONQUESTION) <> IDOK then Exit;
  Ok := False;
  RunBusy(procedure begin Ok := CopyKeyringTo(FEngine, ATarget, Keys, Err); end);
  if not Ok then
  begin
    Application.MessageBox(PChar('The keyring was not moved: ' + Err + sLineBreak + sLineBreak +
      'Nothing was changed; CryptLok keeps using ' + Old), 'Keyring Location', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  SetDataFolder(ATarget);
  Mr := Application.MessageBox(PChar(Format('The keyring was copied (%d keys) and checked.', [Keys]) + sLineBreak +
    sLineBreak + 'Remove the old copy in ' + Old + '?' + sLineBreak + sLineBreak +
    'Yes = remove it (recommended when you are moving it).' + sLineBreak +
    'No = keep it as a spare copy.'), 'Keyring Location', MB_YESNO or MB_ICONQUESTION or MB_DEFBUTTON2);
  if Mr = IDYES then
  begin
    FEngine.StopAgent;
    try
      DeleteOldKeyring(Old);
    except
      on E: Exception do
        Application.MessageBox(PChar('Some old files could not be removed: ' + E.Message), 'Keyring Location',
          MB_OK or MB_ICONWARNING);
    end;
  end;
  Application.MessageBox('CryptLok will now restart with the keyring in its new place.', 'Keyring Location',
    MB_OK or MB_ICONINFORMATION);
  if Assigned(FOnRestart) then FOnRestart;
end;

procedure TLocationPage.ChangeClick(Sender: TObject);
var
  Dir, Target: string;
begin
  Dir := '';
  if not SelectDirectory('Choose a folder for your keyring', '', Dir, [sdNewFolder, sdNewUI, sdValidateDir], Self) then
    Exit;
  { a folder that already is a keyring is used as it is; otherwise the keyring goes into a CryptLok subfolder }
  if FolderHasKeyring(Dir) then
    Target := Dir
  else if FolderHasKeyring(TPath.Combine(Dir, 'CryptLok')) then
    Target := TPath.Combine(Dir, 'CryptLok')
  else if Length(TDirectory.GetFileSystemEntries(Dir)) = 0 then
    Target := Dir
  else
    Target := TPath.Combine(Dir, 'CryptLok');
  SwitchTo(ExcludeTrailingPathDelimiter(Target));
end;

procedure TLocationPage.DefaultClick(Sender: TObject);
begin
  SwitchTo(ExcludeTrailingPathDelimiter(DefaultDataFolder));
end;

end.

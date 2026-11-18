unit OPD.DiskPages;

{ Disk feature UI: the list of known disks + mount/unmount logic (TDiskController),
  the "New Virtual Disk" page and the "My Disks" page. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics, OPD.Theme, OPD.Engine, OPD.VeraCrypt;

type
  TDiskEntry = record
    Name: string;
    Path: string;
    Letter: Char;      { preferred drive letter }
  end;

  TDiskStatusEvent = procedure(const ATitle, AMessage: string) of object;
  TGetKeysFunc = function: TKeyInfoArray of object;

  TDiskController = class
  private
    FOwner: TComponent;
    FEngine: IKeyEngine;
    FVc: TVeraCrypt;
    FIni: string;
    FDisks: TList<TDiskEntry>;
    FOnStatus: TDiskStatusEvent;
    FOnChanged: TNotifyEvent;
    procedure Load;
    procedure Save;
    procedure Changed;
  public
    constructor Create(AOwner: TComponent; const AEngine: IKeyEngine; AOnStatus: TDiskStatusEvent);
    destructor Destroy; override;
    function Count: Integer;
    function Item(AIndex: Integer): TDiskEntry;
    function Vc: TVeraCrypt;
    procedure Add(const AName, APath: string; ALetter: Char);
    procedure Remove(AIndex: Integer);
    function Mount(AIndex: Integer): Boolean;
    function Unmount(AIndex: Integer): Boolean;
    procedure UnmountAll;
    { drive letter a disk is currently mounted on, or #0 }
    function MountedLetter(AIndex: Integer): Char;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

  TNewDiskPage = class(TPanel)
  private
    FCtl: TDiskController;
    FEngine: IKeyEngine;
    FGetKeys: TGetKeysFunc;
    FName, FFolder, FSize: TEdit;
    FLetter, FUnit, FFormat, FEnc: TComboBox;
    FUsers: TListView;
    FKeys: TKeyInfoArray;
    FChosen: TStringList;
    FBusy: Boolean;
    FProgress: TLabel;          { "Creating the disk..." line while VeraCrypt writes it }
    FProgTimer: TTimer;
    FProgStart: TDateTime;
    FProgSize: string;
    procedure ProgressTick(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure AddUserClick(Sender: TObject);
    procedure RemoveUserClick(Sender: TObject);
    procedure FillUsers;
    function Lbl(const ACaption: string; AY: Integer): TLabel;
  public
    constructor Create(AOwner: TComponent; const AEngine: IKeyEngine; ACtl: TDiskController;
      AGetKeys: TGetKeysFunc); reintroduce;
    destructor Destroy; override;
    procedure Prepare;      { refresh letters and the default key }
    procedure AddUser;
    procedure CreateDisk;
  end;

  TMyDisksPage = class(TPanel)
  private
    FCtl: TDiskController;
    FList: TListView;
    FMount, FUnmount: TButton;
    FTimer: TTimer;
    procedure Rebuild(Sender: TObject);
    procedure MountClick(Sender: TObject);
    procedure UnmountClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure SelChange(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure TimerTick(Sender: TObject);
    procedure UpdateButtons;
  public
    constructor Create(AOwner: TComponent; ACtl: TDiskController); reintroduce;
    procedure RefreshList;
  end;

implementation

uses
  System.IniFiles, System.IOUtils, System.StrUtils, System.Math, Winapi.Windows, Winapi.ShlObj,
  Vcl.Dialogs, Winapi.ShellAPI, OPD.PassphraseDialog, OPD.RecipientDialog;

const
  VERACRYPT_DOWNLOAD = 'https://veracrypt.fr/en/Downloads.html';

{ The disk pages drive a separately installed VeraCrypt.  When it is missing, say so once and offer its
  download page instead of just showing an error.  True when VeraCrypt is missing. }
function OfferVeraCrypt(const AEngine: IKeyEngine; const AVc: TVeraCrypt; const ATitle: string): Boolean;
var
  Info: string;
  D: TFileOpenDialog;
begin
  Result := not AVc.Available(Info);
  if not Result then Exit;
  case Application.MessageBox(PChar('The Disk features need VeraCrypt, which is free and was not found on this ' +
    'computer (CryptLok does not include it).' + sLineBreak + sLineBreak +
    'Yes: open the VeraCrypt download page (install it, then come back here).' + sLineBreak +
    'No: I already have it (portable or in another folder) - let me choose its folder.' + sLineBreak +
    'Cancel: do nothing.'), PChar(ATitle), MB_YESNOCANCEL or MB_ICONINFORMATION) of
    IDYES: ShellExecute(0, 'open', VERACRYPT_DOWNLOAD, nil, nil, SW_SHOWNORMAL);
    IDNO:
      begin
        D := TFileOpenDialog.Create(nil);
        try
          D.Options := [fdoPickFolders, fdoPathMustExist];
          D.Title := 'Choose the folder that holds VeraCrypt.exe';
          if D.Execute then
          begin
            if TVeraCrypt.FolderHasVeraCrypt(D.FileName) then
            begin
              TVeraCrypt.SetManualFolder(AEngine, D.FileName);
              Result := not AVc.Available(Info);      { found now: carry on }
            end
            else
              Application.MessageBox('VeraCrypt was not found in that folder (it needs VeraCrypt.exe or VeraCrypt-x64.exe and the matching Format program).',
                PChar(ATitle), MB_OK or MB_ICONWARNING);
          end;
        finally
          D.Free;
        end;
      end;
  end;
end;

const
  PAGE_COLOR = $00948A80;   { grey-blue content area }

{ ---- helpers ---------------------------------------------------------------- }

function FileSizeText(AFile: string): string;
var
  Sz: Int64;
begin
  if not FileExists(AFile) then Exit('missing');
  Sz := TFile.GetSize(AFile);
  if Sz >= 1024 * 1024 * 1024 then
    Result := Format('%.1f GB', [Sz / (1024 * 1024 * 1024)])
  else
    Result := Format('%d MB', [Sz div (1024 * 1024)]);
end;

{ ---- TDiskController ---------------------------------------------------------- }

constructor TDiskController.Create(AOwner: TComponent; const AEngine: IKeyEngine;
  AOnStatus: TDiskStatusEvent);
begin
  inherited Create;
  FOwner := AOwner;
  FEngine := AEngine;
  FOnStatus := AOnStatus;
  FVc := TVeraCrypt.Create(AEngine);
  FDisks := TList<TDiskEntry>.Create;
  FIni := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir))) +
    'settings.ini';
  Load;
end;

destructor TDiskController.Destroy;
begin
  FDisks.Free;
  FVc.Free;
  inherited;
end;

procedure TDiskController.Load;
var
  Ini: TIniFile;
  I, N: Integer;
  E: TDiskEntry;
  L: string;
begin
  Ini := TIniFile.Create(FIni);
  try
    N := Ini.ReadInteger('Disks', 'Count', 0);
    for I := 1 to N do
    begin
      E.Path := Ini.ReadString('Disks', 'Path' + IntToStr(I), '');
      E.Name := Ini.ReadString('Disks', 'Name' + IntToStr(I), ChangeFileExt(ExtractFileName(E.Path), ''));
      L := Ini.ReadString('Disks', 'Letter' + IntToStr(I), '');
      if L <> '' then E.Letter := UpCase(L[1]) else E.Letter := #0;
      if E.Path <> '' then FDisks.Add(E);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TDiskController.Save;
var
  Ini: TIniFile;
  I: Integer;
begin
  Ini := TIniFile.Create(FIni);
  try
    Ini.EraseSection('Disks');
    Ini.WriteInteger('Disks', 'Count', FDisks.Count);
    for I := 0 to FDisks.Count - 1 do
    begin
      Ini.WriteString('Disks', 'Path' + IntToStr(I + 1), FDisks[I].Path);
      Ini.WriteString('Disks', 'Name' + IntToStr(I + 1), FDisks[I].Name);
      if FDisks[I].Letter <> #0 then
        Ini.WriteString('Disks', 'Letter' + IntToStr(I + 1), FDisks[I].Letter);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TDiskController.Changed;
begin
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

function TDiskController.Count: Integer;
begin
  Result := FDisks.Count;
end;

function TDiskController.Item(AIndex: Integer): TDiskEntry;
begin
  Result := FDisks[AIndex];
end;

function TDiskController.Vc: TVeraCrypt;
begin
  Result := FVc;
end;

procedure TDiskController.Add(const AName, APath: string; ALetter: Char);
var
  E: TDiskEntry;
  I: Integer;
begin
  for I := 0 to FDisks.Count - 1 do
    if SameText(FDisks[I].Path, APath) then Exit;
  E.Name := AName;
  E.Path := APath;
  E.Letter := ALetter;
  FDisks.Add(E);
  Save;
  Changed;
end;

procedure TDiskController.Remove(AIndex: Integer);
begin
  FDisks.Delete(AIndex);
  Save;
  Changed;
end;

function TDiskController.MountedLetter(AIndex: Integer): Char;
begin
  { we only know the letter we mounted it on; check it is still a VeraCrypt drive }
  Result := #0;
  if (FDisks[AIndex].Letter <> #0) and TVeraCrypt.IsMounted(FDisks[AIndex].Letter) then
    Result := FDisks[AIndex].Letter;
end;

function TDiskController.Mount(AIndex: Integer): Boolean;
var
  E: TDiskEntry;
  L: string;
  Letter: Char;
  Pass: TBytes;
  Res: TDiskResult;
  Tries: Integer;
  Mr: TModalResult;
begin
  Result := False;
  E := FDisks[AIndex];
  if MountedLetter(AIndex) <> #0 then Exit(True);
  if OfferVeraCrypt(FEngine, FVc, 'Mount Disk') then Exit;
  L := TVeraCrypt.FreeLetters;
  Letter := E.Letter;
  if (Letter = #0) or (Pos(Letter, L) = 0) then
  begin
    if L = '' then
    begin
      Application.MessageBox('There is no free drive letter.', 'Mount Disk', MB_OK or MB_ICONWARNING);
      Exit;
    end;
    Letter := L[1];
  end;
  Tries := 0;
  repeat
    Inc(Tries);
    Application.BringToFront;
    Mr := AskPassphrase(FOwner, E.Name,
      'Enter the passphrase of your key to open this disk.', False, Pass);
    if Mr <> mrOk then Exit;
    try
      RunBusy(procedure begin Res := FVc.Mount(E.Path, Letter, Pass); end);
    finally
      WipeBytes(Pass);
    end;
    if not Res.Ok then
      Application.MessageBox(PChar(Res.Error), 'Mount Disk', MB_OK or MB_ICONWARNING);
  until Res.Ok or (Res.Error <> 'Wrong passphrase') or (Tries >= 3);
  if Res.Ok then
  begin
    E.Letter := Letter;
    FDisks[AIndex] := E;
    Save;
    if Assigned(FOnStatus) then
      FOnStatus('Disk mounted', E.Name + ' is now drive ' + Letter + ':');
    Changed;
    Result := True;
  end;
end;

function TDiskController.Unmount(AIndex: Integer): Boolean;
var
  L: Char;
  Res: TDiskResult;
begin
  Result := False;
  L := MountedLetter(AIndex);
  if L = #0 then Exit(True);
  Res := FVc.Unmount(L, False);
  if not Res.Ok then
  begin
    if Application.MessageBox(PChar(Res.Error + sLineBreak + sLineBreak +
      'Force the disk to unmount? Unsaved data on it can be lost.'), 'Unmount Disk',
      MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON2) = IDYES then
      Res := FVc.Unmount(L, True);
  end;
  Result := Res.Ok;
  if Result and Assigned(FOnStatus) then
    FOnStatus('Disk unmounted', FDisks[AIndex].Name + ' (' + L + ':) is closed.');
  Changed;
end;

procedure TDiskController.UnmountAll;
var
  I: Integer;
begin
  for I := 0 to FDisks.Count - 1 do
    if MountedLetter(I) <> #0 then
      FVc.Unmount(MountedLetter(I), False);
  Changed;
end;

{ ---- TNewDiskPage ------------------------------------------------------------- }

function TNewDiskPage.Lbl(const ACaption: string; AY: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.AutoSize := False;
  Result.Alignment := taRightJustify;
  Result.SetBounds(DpiScale(16), DpiScale(AY + 3), DpiScale(170), DpiScale(18));
  Result.Caption := ACaption;
  Result.Font.Color := clWhite;
  Result.Font.Style := [fsBold];
  Result.Transparent := True;
end;

constructor TNewDiskPage.Create(AOwner: TComponent; const AEngine: IKeyEngine;
  ACtl: TDiskController; AGetKeys: TGetKeysFunc);
var
  L: TLabel;
  B: TButton;
  C: TListColumn;
  Docs: string;
  X: Integer;
begin
  inherited Create(AOwner);
  Parent := TWinControl(AOwner);  { needed before child windows are created }
  FEngine := AEngine;
  FCtl := ACtl;
  FGetKeys := AGetKeys;
  FChosen := TStringList.Create;
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := PAGE_COLOR;
  ApplyUiFont(Font, 9);
  X := DpiScale(196);

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(DpiScale(16), DpiScale(14), DpiScale(420), DpiScale(20));
  L.Caption := 'Enter Disk Properties ';
  L.Font.Style := [fsBold];
  L.Font.Color := clWhite;
  L.Transparent := True;

  Lbl('Name', 44);
  FName := TEdit.Create(Self);
  FName.Parent := Self;
  FName.SetBounds(X, DpiScale(44), DpiScale(250), DpiScale(23));
  FName.Text := 'New Disk';

  Lbl('Disk File Location', 76);
  FFolder := TEdit.Create(Self);
  FFolder.Parent := Self;
  FFolder.SetBounds(X, DpiScale(76), DpiScale(330), DpiScale(23));
  Docs := TPath.GetDocumentsPath;
  FFolder.Text := Docs;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(X + DpiScale(340), DpiScale(75), DpiScale(86), DpiScale(25));
  B.Caption := 'Browse...';
  B.OnClick := BrowseClick;

  Lbl('Mount as', 108);
  FLetter := TComboBox.Create(Self);
  FLetter.Parent := Self;
  FLetter.Style := csDropDownList;
  FLetter.SetBounds(X, DpiScale(108), DpiScale(70), DpiScale(24));

  Lbl('Size', 140);
  FSize := TEdit.Create(Self);
  FSize.Parent := Self;
  FSize.SetBounds(X, DpiScale(140), DpiScale(80), DpiScale(23));
  FSize.Text := '1';
  FSize.NumbersOnly := True;
  FUnit := TComboBox.Create(Self);
  FUnit.Parent := Self;
  FUnit.Style := csDropDownList;
  FUnit.SetBounds(X + DpiScale(90), DpiScale(140), DpiScale(70), DpiScale(24));
  FUnit.Items.AddStrings(['MB', 'GB']);
  FUnit.ItemIndex := 1;
  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(X + DpiScale(172), DpiScale(144), DpiScale(270), DpiScale(18));
  L.Caption := '(the whole size is reserved on disk at once)';
  L.Font.Color := $00E8E0D8;
  L.Transparent := True;

  Lbl('Format', 172);
  FFormat := TComboBox.Create(Self);
  FFormat.Parent := Self;
  FFormat.Style := csDropDownList;
  FFormat.SetBounds(X, DpiScale(172), DpiScale(130), DpiScale(24));
  FFormat.Items.AddStrings(['exFAT', 'FAT']);
  FFormat.ItemIndex := 0;

  Lbl('Encryption', 204);
  FEnc := TComboBox.Create(Self);
  FEnc.Parent := Self;
  FEnc.Style := csDropDownList;
  FEnc.SetBounds(X, DpiScale(204), DpiScale(200), DpiScale(24));
  FEnc.Items.AddStrings(['AES', 'Serpent', 'Twofish', 'Camellia', 'AES(Twofish)',
    'AES(Twofish(Serpent))']);
  FEnc.ItemIndex := 0;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(DpiScale(16), DpiScale(250), DpiScale(420), DpiScale(20));
  L.Caption := 'User Access ';
  L.Font.Style := [fsBold];
  L.Font.Color := clWhite;
  L.Transparent := True;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(DpiScale(16), DpiScale(272), DpiScale(600), DpiScale(34));
  L.AutoSize := False;
  L.WordWrap := True;
  L.Caption := 'The disk opens with the passphrase of any key listed here. ' +
    'Keep the small .key.gpg file next to the disk: without it the disk cannot be opened.';
  L.Font.Color := $00E8E0D8;
  L.Transparent := True;

  FUsers := TListView.Create(Self);
  FUsers.Parent := Self;
  FUsers.SetBounds(DpiScale(16), DpiScale(312), DpiScale(430), DpiScale(150));
  FUsers.ViewStyle := vsReport;
  FUsers.ReadOnly := True;
  FUsers.RowSelect := True;
  C := FUsers.Columns.Add; C.Caption := 'Name'; C.Width := DpiScale(150);
  C := FUsers.Columns.Add; C.Caption := 'Email'; C.Width := DpiScale(170);
  C := FUsers.Columns.Add; C.Caption := 'Key ID'; C.Width := DpiScale(90);

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(DpiScale(458), DpiScale(312), DpiScale(150), DpiScale(28));
  B.Caption := 'Add User Key...';
  B.OnClick := AddUserClick;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(DpiScale(458), DpiScale(346), DpiScale(150), DpiScale(28));
  B.Caption := 'Delete User';
  B.OnClick := RemoveUserClick;

  FProgress := TLabel.Create(Self);
  FProgress.Parent := Self;
  FProgress.SetBounds(DpiScale(16), DpiScale(470), DpiScale(600), DpiScale(36));
  FProgress.AutoSize := False;
  FProgress.WordWrap := True;
  FProgress.Font.Color := clWhite;
  FProgress.Font.Style := [fsBold];
  FProgress.Transparent := True;
  FProgress.Caption := '';
  FProgTimer := TTimer.Create(Self);
  FProgTimer.Enabled := False;
  FProgTimer.Interval := 1000;
  FProgTimer.OnTimer := ProgressTick;
end;

procedure TNewDiskPage.ProgressTick(Sender: TObject);
var
  Secs: Int64;
begin
  { VeraCrypt reserves the whole file at once and fills it in place, so only the time can be shown }
  Secs := Round((Now - FProgStart) * SecsPerDay);
  FProgress.Caption := Format('Creating the disk (%s)... %d:%.2d elapsed. Please keep CryptLok open until it finishes.',
    [FProgSize, Secs div 60, Secs mod 60]);
end;

destructor TNewDiskPage.Destroy;
begin
  FChosen.Free;
  inherited;
end;

procedure TNewDiskPage.Prepare;
var
  L: string;
  C: Char;
  I: Integer;
begin
  FLetter.Items.Clear;
  L := TVeraCrypt.FreeLetters;
  for C in L do
    FLetter.Items.Add(C + ':');
  if FLetter.Items.Count > 0 then FLetter.ItemIndex := 0;
  FKeys := FGetKeys;
  if FChosen.Count = 0 then
    for I := 0 to High(FKeys) do
      if FKeys[I].HasSecret and CanEncryptTo(FKeys[I]) then
      begin
        FChosen.Add(FKeys[I].Fingerprint);
        Break;
      end;
  FillUsers;
end;

procedure TNewDiskPage.FillUsers;
var
  F: string;
  I: Integer;
  LI: TListItem;
begin
  FUsers.Items.Clear;
  for F in FChosen do
    for I := 0 to High(FKeys) do
      if SameText(FKeys[I].Fingerprint, F) then
      begin
        LI := FUsers.Items.Add;
        LI.Caption := FKeys[I].DisplayName;
        LI.SubItems.Add(FKeys[I].DisplayEmail);
        LI.SubItems.Add(FKeys[I].ShortId);
        LI.Data := Pointer(I);
      end;
end;

procedure TNewDiskPage.BrowseClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(Self);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Where should the disk file be stored?';
    if DirectoryExists(FFolder.Text) then D.DefaultFolder := FFolder.Text;
    if D.Execute then FFolder.Text := D.FileName;
  finally
    D.Free;
  end;
end;

procedure TNewDiskPage.AddUser;
begin
  AddUserClick(nil);
end;

procedure TNewDiskPage.AddUserClick(Sender: TObject);
var
  Fprs: TArray<string>;
  F: string;
begin
  FKeys := FGetKeys;
  if SelectRecipients(Self, FKeys, Fprs) then
  begin
    for F in Fprs do
      if FChosen.IndexOf(F) < 0 then FChosen.Add(F);
    FillUsers;
  end;
end;

procedure TNewDiskPage.RemoveUserClick(Sender: TObject);
var
  I: Integer;
begin
  for I := FUsers.Items.Count - 1 downto 0 do
    if FUsers.Items[I].Selected then
      FChosen.Delete(FChosen.IndexOf(FKeys[Integer(FUsers.Items[I].Data)].Fingerprint));
  FillUsers;
end;

procedure TNewDiskPage.CreateDisk;
var
  P: TDiskParams;
  Nm, Msg, Path: string;
  Size: Int64;
  Res: TDiskResult;
  Letter: Char;
  I: Integer;
  FreeAvail, TotalBytes: UInt64;

  function MBText(AMB: Int64): string;
  begin
    if AMB >= 1024 then Result := Format('%.1f GB', [AMB / 1024]) else Result := Format('%d MB', [AMB]);
  end;

begin
  if FBusy then Exit;
  if OfferVeraCrypt(FEngine, FCtl.Vc, 'New Virtual Disk') then Exit;
  Nm := Trim(FName.Text);
  if (Nm = '') or (Nm.IndexOfAny(TPath.GetInvalidFileNameChars) >= 0) then
  begin
    Application.MessageBox('Please enter a disk name without special characters.', 'New Virtual Disk',
      MB_OK or MB_ICONWARNING);
    Exit;
  end;
  if not DirectoryExists(FFolder.Text) then
  begin
    Application.MessageBox('The disk file location does not exist.', 'New Virtual Disk',
      MB_OK or MB_ICONWARNING);
    Exit;
  end;
  Size := StrToInt64Def(FSize.Text, 0);
  if FUnit.ItemIndex = 1 then Size := Size * 1024;
  if (Size < 1) or (Size > 1024 * 1024) then
  begin
    Application.MessageBox('Please enter a size between 1 MB and 1 TB.', 'New Virtual Disk',
      MB_OK or MB_ICONWARNING);
    Exit;
  end;
  if FChosen.Count = 0 then
  begin
    Application.MessageBox('Add at least one user key that may open the disk.', 'New Virtual Disk',
      MB_OK or MB_ICONWARNING);
    Exit;
  end;
  if SameText(ExtractFileExt(Nm), '.hc') then Nm := ChangeFileExt(Nm, '');
  Path := TPath.Combine(FFolder.Text, Nm + '.hc');
  if FileExists(Path) then
  begin
    Application.MessageBox(PChar(Format('%s already exists. Choose another name or location.', [Path])),
      'New Virtual Disk', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  { the whole size is written at once: check the space first (with a little room to spare) }
  if GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(FFolder.Text)), FreeAvail, TotalBytes, nil) and
     (FreeAvail < UInt64(Size + 64) * 1024 * 1024) then
  begin
    Application.MessageBox(PChar(Format('There is not enough free space for a %s disk in %s.' + sLineBreak +
      sLineBreak + 'Free: %s. Choose a smaller size (at most about %s) or another location.',
      [MBText(Size), FFolder.Text, MBText(FreeAvail div (1024 * 1024)),
       MBText(Int64(FreeAvail div (1024 * 1024)) - 64)])), 'New Virtual Disk', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  if (Size >= 1024) and
     (Application.MessageBox(PChar(Format('Create a %d GB disk? The whole size is written to the drive now, ' +
       'which can take a while (roughly a minute per 5-10 GB, longer on USB drives). Keep CryptLok open until it finishes.',
       [Size div 1024])),
       'New Virtual Disk', MB_YESNO or MB_ICONQUESTION) <> IDYES) then
    Exit;

  P.Path := Path;
  P.SizeMB := Size;
  P.FileSystem := FFormat.Text;
  P.Encryption := FEnc.Text;
  P.Hash := 'sha512';
  SetLength(P.Recipients, FChosen.Count);
  for I := 0 to FChosen.Count - 1 do P.Recipients[I] := FChosen[I];

  FBusy := True;
  FProgStart := Now;
  FProgSize := MBText(Size);
  ProgressTick(nil);
  FProgTimer.Enabled := True;
  try
    RunBusy(procedure begin Res := FCtl.Vc.CreateVolume(P); end);
  finally
    FProgTimer.Enabled := False;
    FProgress.Caption := '';
    FBusy := False;
  end;
  if not Res.Ok then
  begin
    Application.MessageBox(PChar('The disk was not created: ' + Res.Error), 'New Virtual Disk',
      MB_OK or MB_ICONWARNING);
    Exit;
  end;
  if FLetter.ItemIndex >= 0 then Letter := FLetter.Text[1] else Letter := #0;
  FCtl.Add(Nm, Path, Letter);
  Msg := Format('"%s" was created.' + sLineBreak + sLineBreak + 'Disk file: %s' + sLineBreak +
    'Key file: %s' + sLineBreak + sLineBreak + 'Mount it now?', [Nm, Path, TVeraCrypt.KeyFilePath(Path)]);
  if Application.MessageBox(PChar(Msg), 'New Virtual Disk', MB_YESNO or MB_ICONINFORMATION) = IDYES then
    FCtl.Mount(FCtl.Count - 1);
  Prepare;
end;

{ ---- TMyDisksPage -------------------------------------------------------------- }

constructor TMyDisksPage.Create(AOwner: TComponent; ACtl: TDiskController);
var
  C: TListColumn;
  B: TButton;
  X: Integer;
begin
  inherited Create(AOwner);
  Parent := TWinControl(AOwner);  { needed before child windows are created }
  FCtl := ACtl;
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := PAGE_COLOR;
  ApplyUiFont(Font, 9);

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.AlignWithMargins := True;
  FList.Margins.SetBounds(DpiScale(12), DpiScale(12), DpiScale(12), DpiScale(56));
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.OnSelectItem := SelChange;
  FList.OnDblClick := MountClick;
  C := FList.Columns.Add; C.Caption := 'Name'; C.Width := DpiScale(170);
  C := FList.Columns.Add; C.Caption := 'Drive'; C.Width := DpiScale(60);
  C := FList.Columns.Add; C.Caption := 'Status'; C.Width := DpiScale(90);
  C := FList.Columns.Add; C.Caption := 'Size'; C.Width := DpiScale(80);
  C := FList.Columns.Add; C.Caption := 'File'; C.Width := DpiScale(420);

  X := DpiScale(12);
  FMount := TButton.Create(Self);
  FMount.Parent := Self;
  FMount.SetBounds(X, Height - DpiScale(44), DpiScale(100), DpiScale(30));
  FMount.Anchors := [akLeft, akBottom];
  FMount.Caption := 'Mount...';
  FMount.OnClick := MountClick;
  Inc(X, DpiScale(108));
  FUnmount := TButton.Create(Self);
  FUnmount.Parent := Self;
  FUnmount.SetBounds(X, Height - DpiScale(44), DpiScale(100), DpiScale(30));
  FUnmount.Anchors := [akLeft, akBottom];
  FUnmount.Caption := 'Unmount';
  FUnmount.OnClick := UnmountClick;
  Inc(X, DpiScale(108));
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(X, Height - DpiScale(44), DpiScale(130), DpiScale(30));
  B.Anchors := [akLeft, akBottom];
  B.Caption := 'Add Existing...';
  B.OnClick := AddClick;
  Inc(X, DpiScale(138));
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(X, Height - DpiScale(44), DpiScale(130), DpiScale(30));
  B.Anchors := [akLeft, akBottom];
  B.Caption := 'Remove from List';
  B.OnClick := RemoveClick;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 3000;
  FTimer.OnTimer := TimerTick;
  FCtl.OnChanged := Rebuild;
end;

procedure TMyDisksPage.Rebuild(Sender: TObject);
begin
  RefreshList;
end;

procedure TMyDisksPage.TimerTick(Sender: TObject);
begin
  if Visible then RefreshList;
end;

procedure TMyDisksPage.RefreshList;
var
  I, Sel: Integer;
  E: TDiskEntry;
  L: Char;
  LI: TListItem;
begin
  Sel := -1;
  if FList.Selected <> nil then Sel := FList.Selected.Index;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to FCtl.Count - 1 do
    begin
      E := FCtl.Item(I);
      L := FCtl.MountedLetter(I);
      LI := FList.Items.Add;
      LI.Caption := E.Name;
      LI.SubItems.Add(IfThen(L <> #0, L + ':', ''));
      LI.SubItems.Add(IfThen(L <> #0, 'Mounted', IfThen(FileExists(E.Path), 'Locked', 'File missing')));
      LI.SubItems.Add(FileSizeText(E.Path));
      LI.SubItems.Add(E.Path);
    end;
    if (Sel >= 0) and (Sel < FList.Items.Count) then FList.Items[Sel].Selected := True;
  finally
    FList.Items.EndUpdate;
  end;
  UpdateButtons;
end;

procedure TMyDisksPage.UpdateButtons;
var
  I: Integer;
begin
  I := -1;
  if FList.Selected <> nil then I := FList.Selected.Index;
  FMount.Enabled := (I >= 0) and (FCtl.MountedLetter(I) = #0);
  FUnmount.Enabled := (I >= 0) and (FCtl.MountedLetter(I) <> #0);
end;

procedure TMyDisksPage.SelChange(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  UpdateButtons;
end;

procedure TMyDisksPage.MountClick(Sender: TObject);
begin
  if (FList.Selected <> nil) and FMount.Enabled then
    FCtl.Mount(FList.Selected.Index);
  RefreshList;
end;

procedure TMyDisksPage.UnmountClick(Sender: TObject);
begin
  if FList.Selected <> nil then
    FCtl.Unmount(FList.Selected.Index);
  RefreshList;
end;

procedure TMyDisksPage.AddClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Add Existing Disk';
    D.Filter := 'Disk files (*.hc)|*.hc|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then
    begin
      if not FileExists(TVeraCrypt.KeyFilePath(D.FileName)) then
        Application.MessageBox(PChar('Added, but the key file ' + ExtractFileName(TVeraCrypt.KeyFilePath(D.FileName)) +
          ' was not found next to the disk. It cannot be opened without it.'), 'Add Existing Disk',
          MB_OK or MB_ICONWARNING);
      FCtl.Add(ChangeFileExt(ExtractFileName(D.FileName), ''), D.FileName, #0);
    end;
  finally
    D.Free;
  end;
end;

procedure TMyDisksPage.RemoveClick(Sender: TObject);
begin
  if FList.Selected = nil then Exit;
  if FCtl.MountedLetter(FList.Selected.Index) <> #0 then
  begin
    Application.MessageBox('Unmount the disk first.', 'Remove from List', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  if Application.MessageBox('Remove this disk from the list? The disk file itself is not deleted.',
    'Remove from List', MB_YESNO or MB_ICONQUESTION) = IDYES then
    FCtl.Remove(FList.Selected.Index);
end;

end.

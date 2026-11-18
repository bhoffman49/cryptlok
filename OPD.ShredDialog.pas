unit OPD.ShredDialog;

{ "Shred Files": pick files and folders, choose the number of passes, confirm, destroy.  The limits
  of overwriting on SSDs and NTFS are stated in plain words in the window. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Winapi.Windows, Winapi.Messages, Winapi.ShellAPI,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Dialogs,
  OPD.Theme, OPD.Engine, OPD.Shredder;

procedure ShowShredDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AInitial: TArray<string>);

{ Shreds with the saved number of passes after asking once (used by the Zip wizard's "Shred originals"). }
function ShredAfterConfirm(AOwner: TComponent; const AEngine: IKeyEngine; const APaths: TArray<string>;
  out ASummary: string): Boolean;

function SavedShredPasses(const AEngine: IKeyEngine): Integer;

implementation

uses
  System.StrUtils, System.Math, System.IniFiles, System.IOUtils;

const
  NOTE =
    'Shredding overwrites a file with random data, then zeros, and then deletes it. On an SSD, USB stick or ' +
    'memory card the drive can keep older copies that Windows cannot erase; BitLocker (full-disk encryption) is ' +
    'the real protection there. On any disk, wiping the free space afterwards removes most traces: use ' +
    'Tools > Wipe Free Space. Files already in the Recycle Bin are not shredded until you shred them here.';

function IniPath(const AEngine: IKeyEngine): string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir))) +
    'settings.ini';
end;

function SavedShredPasses(const AEngine: IKeyEngine): Integer;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Result := EnsureRange(Ini.ReadInteger('Shredder', 'Passes', DEFAULT_PASSES), MIN_PASSES, MAX_PASSES);
  finally
    Ini.Free;
  end;
end;

function Describe(const AR: TShredResult): string;
var
  S: string;
begin
  Result := Format('%d file(s) and %d folder(s) shredded.', [AR.Files, AR.Folders]);
  if AR.Cancelled then
    Result := 'Cancelled. ' + Result;
  if Length(AR.Failed) > 0 then
  begin
    Result := Result + sLineBreak + sLineBreak + 'These could not be shredded:';
    for S in AR.Failed do
      Result := Result + sLineBreak + '  ' + S;
  end;
  if Length(AR.Warnings) > 0 then
  begin
    Result := Result + sLineBreak + sLineBreak + 'Shredded, but note:';
    for S in AR.Warnings do
      Result := Result + sLineBreak + '  ' + S;
  end;
end;

function ConfirmShred(AOwner: TComponent; ACount: Integer): Boolean;
begin
  Result := Application.MessageBox(PChar(Format(
    'Permanently destroy %d item(s)?' + sLineBreak + sLineBreak +
    'This cannot be undone, not even with a file recovery program.', [ACount])),
    'Shred', MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON2) = IDYES;
end;

type
  TShredForm = class(TOPDForm)
  private
    FEngine: IKeyEngine;
    FList: TListBox;
    FPasses: TEdit;
    FUpDown: TUpDown;
    FWarn: TCheckBox;
    FShred, FCancel, FClose, FRemove: TButton;
    FProgress: TProgressBar;
    FStatus: TLabel;
    FReport: TMemo;
    FTimer: TTimer;
    FLock: TCriticalSection;
    FPct: Integer;
    FFile: string;
    FStop: Boolean;
    FBusy: Boolean;
    procedure AddFilesClick(Sender: TObject);
    procedure AddFolderClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure ShredClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure ListChange(Sender: TObject);
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    procedure AddPath(const AP: string);
    procedure SaveSettings;
  protected
    procedure CreateWnd; override;
  public
    constructor CreateDlg(AOwner: TComponent; const AEngine: IKeyEngine; const AInitial: TArray<string>);
    destructor Destroy; override;
  end;

constructor TShredForm.CreateDlg(AOwner: TComponent; const AEngine: IKeyEngine; const AInitial: TArray<string>);
var
  L: TLabel;
  B: TButton;
  Ini: TIniFile;
  P: string;
begin
  inherited CreateNew(AOwner);
  FEngine := AEngine;
  FLock := TCriticalSection.Create;
  Caption := 'Shred Files';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 600;
  ClientHeight := 520;
  Font.Name := UiFontName;
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 12, 568, 36);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'Drag files and folders here, or use the buttons. Everything in the list is overwritten and ' +
    'permanently deleted.';

  FList := TListBox.Create(Self); FList.Parent := Self; FList.SetBounds(16, 52, 568, 150);
  FList.OnClick := ListChange;
  FList.ExtendedSelect := True; FList.MultiSelect := True;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(16, 210, 110, 28);
  B.Caption := 'Add Files...'; B.OnClick := AddFilesClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(132, 210, 110, 28);
  B.Caption := 'Add Folder...'; B.OnClick := AddFolderClick;
  FRemove := TButton.Create(Self); FRemove.Parent := Self; FRemove.SetBounds(248, 210, 90, 28);
  FRemove.Caption := 'Remove'; FRemove.OnClick := RemoveClick; FRemove.Enabled := False;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 256, 150, 18);
  L.Caption := 'Number of passes:'; L.Transparent := False; L.Color := clBtnFace;
  FPasses := TEdit.Create(Self); FPasses.Parent := Self; FPasses.SetBounds(130, 252, 50, 24);
  FPasses.Text := IntToStr(SavedShredPasses(AEngine));
  FUpDown := TUpDown.Create(Self); FUpDown.Parent := Self;
  FUpDown.Min := MIN_PASSES; FUpDown.Max := MAX_PASSES;
  FUpDown.Associate := FPasses;
  FUpDown.Position := SavedShredPasses(AEngine);
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(200, 256, 384, 18);
  L.Caption := '3 is plenty for ordinary use (the last pass writes zeros)'; L.Font.Color := clGrayText;
  L.Transparent := False; L.Color := clBtnFace;

  FWarn := TCheckBox.Create(Self); FWarn.Parent := Self; FWarn.SetBounds(16, 284, 400, 20);
  FWarn.Caption := 'Always ask me before shredding';
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    FWarn.Checked := Ini.ReadBool('Shredder', 'Warn', True);
  finally
    Ini.Free;
  end;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 314, 568, 88);
  L.AutoSize := False; L.WordWrap := True; L.Font.Size := 8; L.Font.Color := clGrayText;
  L.Transparent := False; L.Color := clBtnFace; L.Caption := NOTE;

  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.SetBounds(16, 410, 568, 18);
  FStatus.Transparent := False; FStatus.Color := clBtnFace;
  FProgress := TProgressBar.Create(Self); FProgress.Parent := Self; FProgress.SetBounds(16, 432, 568, 16);
  FProgress.Max := 100;

  FReport := TMemo.Create(Self); FReport.Parent := Self; FReport.SetBounds(16, 410, 568, 40);
  FReport.ReadOnly := True; FReport.ScrollBars := ssVertical; FReport.Visible := False;

  FShred := TButton.Create(Self); FShred.Parent := Self; FShred.SetBounds(16, 478, 120, 30);
  FShred.Caption := 'Shred'; FShred.OnClick := ShredClick; FShred.Enabled := False;
  FCancel := TButton.Create(Self); FCancel.Parent := Self; FCancel.SetBounds(144, 478, 90, 30);
  FCancel.Caption := 'Stop'; FCancel.OnClick := CancelClick; FCancel.Enabled := False;
  FClose := TButton.Create(Self); FClose.Parent := Self; FClose.SetBounds(480, 478, 104, 30);
  FClose.Caption := 'Close'; FClose.ModalResult := mrOk; FClose.Cancel := True;

  FTimer := TTimer.Create(Self); FTimer.Enabled := False; FTimer.Interval := 120; FTimer.OnTimer := TimerTick;
  for P in AInitial do AddPath(P);
end;

destructor TShredForm.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TShredForm.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TShredForm.AddPath(const AP: string);
var
  P: string;
begin
  P := ExcludeTrailingPathDelimiter(AP);
  if (P = '') or not (FileExists(P) or DirectoryExists(P)) then Exit;
  if FList.Items.IndexOf(P) >= 0 then Exit;
  FList.Items.Add(P);
  FShred.Enabled := True;
end;

procedure TShredForm.WMDropFiles(var Msg: TWMDropFiles);
var
  N, I: Integer;
  Buf: array[0..MAX_PATH * 2] of Char;
begin
  try
    if not FBusy then
    begin
      N := DragQueryFile(Msg.Drop, $FFFFFFFF, nil, 0);
      for I := 0 to N - 1 do
      begin
        DragQueryFile(Msg.Drop, I, Buf, Length(Buf));
        AddPath(Buf);
      end;
    end;
  finally
    DragFinish(Msg.Drop);
  end;
  Msg.Result := 0;
end;

procedure TShredForm.AddFilesClick(Sender: TObject);
var
  D: TOpenDialog;
  F: string;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Options := [ofAllowMultiSelect, ofFileMustExist, ofPathMustExist, ofEnableSizing];
    D.Title := 'Add files to shred';
    if D.Execute then
      for F in D.Files do AddPath(F);
  finally
    D.Free;
  end;
end;

procedure TShredForm.AddFolderClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(Self);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Add a folder to shred';
    if D.Execute then AddPath(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TShredForm.ListChange(Sender: TObject);
begin
  FRemove.Enabled := FList.SelCount > 0;
end;

procedure TShredForm.RemoveClick(Sender: TObject);
var
  I: Integer;
begin
  for I := FList.Items.Count - 1 downto 0 do
    if FList.Selected[I] then FList.Items.Delete(I);
  FShred.Enabled := FList.Items.Count > 0;
  FRemove.Enabled := False;
end;

procedure TShredForm.SaveSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(FEngine));
  try
    Ini.WriteInteger('Shredder', 'Passes', EnsureRange(StrToIntDef(FPasses.Text, DEFAULT_PASSES), MIN_PASSES, MAX_PASSES));
    Ini.WriteBool('Shredder', 'Warn', FWarn.Checked);
  finally
    Ini.Free;
  end;
end;

procedure TShredForm.CancelClick(Sender: TObject);
begin
  FStop := True;
  FCancel.Enabled := False;
end;

procedure TShredForm.TimerTick(Sender: TObject);
begin
  FLock.Enter;
  try
    FProgress.Position := FPct;
    FStatus.Caption := 'Shredding ' + ExtractFileName(FFile);
  finally
    FLock.Leave;
  end;
end;

procedure TShredForm.ShredClick(Sender: TObject);
var
  Paths: TArray<string>;
  I, Passes: Integer;
  Res: TShredResult;
begin
  SetLength(Paths, FList.Items.Count);
  for I := 0 to High(Paths) do Paths[I] := FList.Items[I];
  if Length(Paths) = 0 then Exit;
  Passes := EnsureRange(StrToIntDef(FPasses.Text, DEFAULT_PASSES), MIN_PASSES, MAX_PASSES);
  FPasses.Text := IntToStr(Passes);
  SaveSettings;
  if FWarn.Checked and not ConfirmShred(Self, Length(Paths)) then Exit;

  FBusy := True; FStop := False;
  FShred.Enabled := False; FCancel.Enabled := True; FClose.Enabled := False; FRemove.Enabled := False;
  FReport.Visible := False; FProgress.Visible := True; FStatus.Visible := True;
  FProgress.Position := 0; FPct := 0;
  FTimer.Enabled := True;
  try
    RunBusy(
      procedure
      begin
        Res := ShredPaths(Paths, Passes,
          procedure(const AFile: string; ADone, ATotal: Int64)
          begin
            FLock.Enter;
            try
              FFile := AFile;
              if ATotal > 0 then FPct := Integer(Min(Int64(100), ADone * 100 div ATotal));
            finally
              FLock.Leave;
            end;
          end, @FStop);
      end);
  finally
    FTimer.Enabled := False;
    FBusy := False;
    FClose.Enabled := True;
    FCancel.Enabled := False;
  end;
  FProgress.Position := 100;
  FStatus.Caption := '';
  FStatus.Visible := False;
  FProgress.Visible := False;
  FReport.Visible := True;
  FReport.Lines.Text := Describe(Res);
  { whatever is left in the list (failures, cancelled items) stays; the rest is gone }
  for I := FList.Items.Count - 1 downto 0 do
    if not (FileExists(FList.Items[I]) or DirectoryExists(FList.Items[I])) then
      FList.Items.Delete(I);
  FShred.Enabled := FList.Items.Count > 0;
end;

procedure ShowShredDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AInitial: TArray<string>);
var
  F: TShredForm;
begin
  F := TShredForm.CreateDlg(AOwner, AEngine, AInitial);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function ShredAfterConfirm(AOwner: TComponent; const AEngine: IKeyEngine; const APaths: TArray<string>;
  out ASummary: string): Boolean;
var
  Res: TShredResult;
  Passes: Integer;
begin
  Result := False;
  ASummary := '';
  if Length(APaths) = 0 then Exit;
  if not ConfirmShred(AOwner, Length(APaths)) then Exit;
  Passes := SavedShredPasses(AEngine);
  RunBusy(procedure begin Res := ShredPaths(APaths, Passes, nil, nil); end);
  ASummary := Describe(Res);
  Result := (Length(Res.Failed) = 0) and not Res.Cancelled;
end;

end.

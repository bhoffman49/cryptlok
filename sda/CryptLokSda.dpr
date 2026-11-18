program CryptLokSda;

{ Self-decrypting archive stub.
  The builder appends a passphrase-encrypted OpenPGP message and a 16-byte footer
  (payload length as UInt64 + 'CLOKSDA1') to a copy of this program.  Run it, type the
  passphrase, pick a folder, and the files appear.  Nothing needs to be installed.

  Test aids (not documented to users): /pass:<file with the passphrase> /out:<folder> make it run
  without windows; the exit code is 0 on success. }

{$R SdaStub.res}

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Math,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.Dialogs,
  Vcl.Graphics,
  OPD.PgpSym in '..\OPD.PgpSym.pas',
  OPD.Tar in '..\OPD.Tar.pas';

const
  MAGIC: array[0..7] of AnsiChar = ('C', 'L', 'O', 'K', 'S', 'D', 'A', '1');
  TITLE = 'CryptLok Self-Decrypting Archive';

type
  TSdaResult = record
    Status: TSymStatus;
    Error: string;
    Count: Integer;
    Skipped: Integer;
    Single: string;
  end;

function S(AValue: Integer): Integer;
begin
  Result := MulDiv(AValue, Screen.PixelsPerInch, 96);
end;

{ ---- the archive inside this exe ------------------------------------------------------- }

function FindPayload(out AStart, ALength: Int64): Boolean;
var
  F: TFileStream;
  Foot: array[0..15] of Byte;
  Len: UInt64;
begin
  Result := False;
  F := TFileStream.Create(ParamStr(0), fmOpenRead or fmShareDenyNone);
  try
    if F.Size < 16 + 64 then Exit;
    F.Position := F.Size - 16;
    F.ReadBuffer(Foot, 16);
    if not CompareMem(@Foot[8], @MAGIC[0], 8) then Exit;
    Len := 0;
    Move(Foot[0], Len, 8);
    if Int64(Len) > F.Size - 16 then Exit;
    ALength := Int64(Len);
    AStart := F.Size - 16 - ALength;
    Result := ALength > 0;
  finally
    F.Free;
  end;
end;

function Run(const APass: TBytes; const ADest: string; AOverwrite: Boolean;
  const AProgress: TSymProgress): TSdaResult;
var
  Start, Len: Int64;
  Tmp, PlainFile, Inner, Err, Target: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Status := sdCorrupt;
  if not FindPayload(Start, Len) then
  begin
    Result.Error := 'This program does not contain an archive.';
    Exit;
  end;
  Tmp := IncludeTrailingPathDelimiter(TPath.GetTempPath) + 'clk-sda-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '');
  ForceDirectories(Tmp);
  PlainFile := '';
  try
    Result.Status := SymDecrypt(ParamStr(0), Start, Len, APass, Tmp, PlainFile, Inner, Err, AProgress);
    if Result.Status <> sdOk then
    begin
      Result.Error := Err;
      Exit;
    end;
    try
      ForceDirectories(ADest);
      if LooksLikeTar(PlainFile) and Inner.EndsWith('.tar', True) then
        Result.Count := TarExtract(PlainFile, ADest, AOverwrite, Result.Skipped)
      else
      begin
        Target := IncludeTrailingPathDelimiter(ADest) + SafeRelativePath(ExtractFileName(Inner));
        if ExtractFileName(Target) = '' then
          Target := IncludeTrailingPathDelimiter(ADest) + 'decrypted.bin';
        Result.Single := Target;
        if FileExists(Target) and not AOverwrite then
          Result.Skipped := 1
        else
        begin
          TFile.Copy(PlainFile, Target, True);
          Result.Count := 1;
        end;
      end;
    except
      on E: Exception do
      begin
        Result.Status := sdCorrupt;
        Result.Error := E.Message;
      end;
    end;
  finally
    if PlainFile <> '' then
    begin
      try
        { overwrite the decrypted copy before deleting it }
        with TFileStream.Create(PlainFile, fmOpenWrite or fmShareExclusive) do
        try
          var Z: TBytes;
          SetLength(Z, 65536);
          var Left := Size;
          while Left > 0 do
          begin
            WriteBuffer(Z[0], Integer(Min(Int64(Length(Z)), Left)));
            Dec(Left, Length(Z));
          end;
        finally
          Free;
        end;
      except
      end;
      DeleteFile(PChar(PlainFile));
    end;
    RemoveDir(Tmp);
  end;
end;

{ ---- the window --------------------------------------------------------------------------- }

type
  TSdaForm = class(TForm)
  private
    FDir: TEdit;
    FPass: TEdit;
    FHide: TCheckBox;
    FOk, FCancel, FBrowse: TButton;
    FProgress: TProgressBar;
    FStatus: TLabel;
    FPct: Integer;
    FBusy: Boolean;
    procedure BrowseClick(Sender: TObject);
    procedure HideClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure SetBusy(ABusy: Boolean);
  public
    constructor CreateSda(AOwner: TComponent);
  end;

constructor TSdaForm.CreateSda(AOwner: TComponent);
var
  L: TLabel;
begin
  inherited CreateNew(AOwner);
  Scaled := False;
  Caption := TITLE;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := S(480);
  ClientHeight := S(250);
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(S(16), S(14), S(440), S(18));
  L.Caption := 'Place output inside this directory:';
  FDir := TEdit.Create(Self); FDir.Parent := Self; FDir.SetBounds(S(16), S(36), S(350), S(24));
  FDir.Text := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  FBrowse := TButton.Create(Self); FBrowse.Parent := Self; FBrowse.SetBounds(S(374), S(34), S(90), S(28));
  FBrowse.Caption := 'Browse...'; FBrowse.OnClick := BrowseClick;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(S(16), S(80), S(330), S(18));
  L.Caption := 'This archive is protected. Enter the passphrase:';
  FHide := TCheckBox.Create(Self); FHide.Parent := Self; FHide.SetBounds(S(360), S(80), S(104), S(20));
  FHide.Caption := 'Hide Typing'; FHide.Checked := True; FHide.OnClick := HideClick;
  FPass := TEdit.Create(Self); FPass.Parent := Self; FPass.SetBounds(S(16), S(104), S(448), S(24));
  FPass.PasswordChar := '*';

  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.SetBounds(S(16), S(148), S(448), S(18));
  FStatus.Caption := '';
  FProgress := TProgressBar.Create(Self); FProgress.Parent := Self;
  FProgress.SetBounds(S(16), S(170), S(448), S(16)); FProgress.Visible := False;

  FOk := TButton.Create(Self); FOk.Parent := Self; FOk.SetBounds(S(290), S(204), S(84), S(30));
  FOk.Caption := 'OK'; FOk.Default := True; FOk.OnClick := OkClick;
  FCancel := TButton.Create(Self); FCancel.Parent := Self; FCancel.SetBounds(S(380), S(204), S(84), S(30));
  FCancel.Caption := 'Cancel'; FCancel.Cancel := True; FCancel.ModalResult := mrCancel;
  ActiveControl := FPass;
end;

procedure TSdaForm.BrowseClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(Self);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Place output inside this directory';
    D.DefaultFolder := FDir.Text;
    if D.Execute then
      FDir.Text := D.FileName;
  finally
    D.Free;
  end;
end;

procedure TSdaForm.HideClick(Sender: TObject);
begin
  if FHide.Checked then FPass.PasswordChar := '*' else FPass.PasswordChar := #0;
end;

procedure TSdaForm.SetBusy(ABusy: Boolean);
begin
  FBusy := ABusy;
  FOk.Enabled := not ABusy;
  FCancel.Enabled := not ABusy;
  FBrowse.Enabled := not ABusy;
  FPass.Enabled := not ABusy;
  FDir.Enabled := not ABusy;
  FProgress.Visible := ABusy;
  if ABusy then
    FStatus.Caption := 'Decrypting...'
  else
    FStatus.Caption := '';
end;

procedure TSdaForm.OkClick(Sender: TObject);
var
  Pass: TBytes;
  Res: TSdaResult;
  Thread: TThread;
  Dest, Msg, PassText: string;
  Overwrite: Boolean;
  Pct: Integer;
begin
  Dest := Trim(FDir.Text);
  if Dest = '' then
  begin
    MessageBox(Handle, 'Choose the folder to place the files in.', TITLE, MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  PassText := FPass.Text;
  if PassText = '' then
  begin
    MessageBox(Handle, 'Enter the passphrase.', TITLE, MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  Pass := TEncoding.UTF8.GetBytes(PassText);
  FillChar(PassText[1], Length(PassText) * SizeOf(Char), 0);
  Overwrite := False;
  repeat
    SetBusy(True);
    FPct := 0;
    Thread := TThread.CreateAnonymousThread(
      procedure
      begin
        Res := Run(Pass, Dest, Overwrite,
          procedure(APercent: Integer)
          begin
            FPct := APercent;
          end);
      end);
    Thread.FreeOnTerminate := False;
    Thread.Start;
    while not Thread.Finished do
    begin
      Pct := FPct;
      if FProgress.Position <> Pct then FProgress.Position := Pct;
      Application.ProcessMessages;
      Sleep(20);
    end;
    Thread.Free;
    SetBusy(False);
    if (Res.Status = sdOk) and (Res.Skipped > 0) and not Overwrite then
    begin
      case MessageBox(Handle, PChar(Format('%d file(s) already exist in that folder. Replace them?',
        [Res.Skipped])), TITLE, MB_YESNOCANCEL or MB_ICONQUESTION) of
        IDYES: begin Overwrite := True; Continue; end;
        IDCANCEL: Break;
      end;
    end;
    Break;
  until False;
  if Length(Pass) > 0 then
    FillChar(Pass[0], Length(Pass), 0);
  if Res.Status = sdOk then
  begin
    if Res.Skipped > 0 then
      Msg := Format('%d file(s) were extracted to %s, %d existing file(s) were left alone.',
        [Res.Count, Dest, Res.Skipped])
    else
      Msg := Format('%d file(s) were extracted to %s.', [Res.Count, Dest]);
    if MessageBox(Handle, PChar(Msg + sLineBreak + sLineBreak + 'Open the folder now?'), TITLE,
      MB_YESNO or MB_ICONINFORMATION) = IDYES then
      ShellExecute(0, 'open', PChar(Dest), nil, nil, SW_SHOWNORMAL);
    ModalResult := mrOk;
  end
  else if Res.Status = sdWrongPassphrase then
  begin
    MessageBox(Handle, 'That passphrase is not correct.', TITLE, MB_OK or MB_ICONWARNING);
    FPass.Text := '';
    FPass.SetFocus;
  end
  else if Res.Error <> '' then
    MessageBox(Handle, PChar(Res.Error), TITLE, MB_OK or MB_ICONWARNING);
end;

{ ---- start ------------------------------------------------------------------------------- }

procedure RunUnattended(const APassFile, ADest: string);
var
  Pass: TBytes;
  Res: TSdaResult;
begin
  Pass := TFile.ReadAllBytes(APassFile);
  while (Length(Pass) > 0) and (Pass[High(Pass)] in [10, 13]) do
    SetLength(Pass, Length(Pass) - 1);
  Res := Run(Pass, ADest, True, nil);
  { no console in a windowed program: the exit code is the only report }
  if Res.Status = sdOk then
    Halt(0)
  else
    Halt(1);
end;

var
  PassFile, OutDir: string;
  Start, Len: Int64;
  F: TSdaForm;

begin
  if FindCmdLineSwitch('pass', PassFile, True, [clstValueNextParam, clstValueAppended]) and
     FindCmdLineSwitch('out', OutDir, True, [clstValueNextParam, clstValueAppended]) then
  try
      RunUnattended(PassFile, OutDir);
    except
      Halt(3);
    end;
  Application.Initialize;
  Application.Title := TITLE;
  if not FindPayload(Start, Len) then
  begin
    MessageBox(0, 'This is the empty self-decrypting archive program. It does not contain any files.',
      TITLE, MB_OK or MB_ICONINFORMATION);
    Halt(2);
  end;
  F := TSdaForm.CreateSda(Application);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end.

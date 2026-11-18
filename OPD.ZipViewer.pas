unit OPD.ZipViewer;

{ Opens a Zip archive: asks for the passphrase, shows the contents and the signature check,
  and extracts to a folder.  The decrypted data lives in a private work folder until the window
  closes, then it is overwritten and removed. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ComCtrls, Vcl.Dialogs, Vcl.Graphics, OPD.Theme, OPD.Engine;

{ APreferText = True shows a decrypted text file in the Viewer window instead of the archive list. }
procedure OpenZipFile(AOwner: TComponent; const AEngine: IKeyEngine; const AFile: string;
  APreferText: Boolean = False);

implementation

uses
  System.StrUtils, System.IOUtils, OPD.PassphraseDialog, OPD.PgpZip, OPD.Tar, OPD.ViewerDialog;

type
  TZipViewer = class(TOPDForm)
  private
    FList: TListView;
    FPlain, FInner: string;
    FSigText: TLabel;
    procedure ExtractClick(Sender: TObject);
  public
    constructor CreateViewer(AOwner: TComponent; const AFile, APlain, AInner: string;
      const ASig: TCryptoResult);
    procedure FormCleanup;
  end;

function SizeText(ASize: Int64): string;
begin
  if ASize < 1024 then Result := Format('%d bytes', [ASize])
  else if ASize < 1024 * 1024 then Result := Format('%.1f KB', [ASize / 1024])
  else if ASize < Int64(1024) * 1024 * 1024 then Result := Format('%.1f MB', [ASize / (1024 * 1024)])
  else Result := Format('%.2f GB', [ASize / (1024.0 * 1024 * 1024)]);
end;

function SigLine(const R: TCryptoResult): string;
begin
  case R.Sig of
    ssGood: Result := 'Good signature from ' + R.SignedBy;
    ssExpired: Result := 'Good signature from ' + R.SignedBy + ' (the signing key has expired)';
    ssBad: Result := 'WARNING: the signature is not valid. The files may have been changed.';
    ssNoKey: Result := 'Signed by ' + R.SignedBy + ' (that public key is not on your keyring, so it cannot be checked)';
  else
    Result := 'Not signed';
  end;
end;

constructor TZipViewer.CreateViewer(AOwner: TComponent; const AFile, APlain, AInner: string;
  const ASig: TCryptoResult);
var
  Ents: TTarEntries;
  E: TTarEntry;
  Li: TListItem;
  C: TListColumn;
  B: TButton;
  L: TLabel;
begin
  inherited CreateNew(AOwner);
  FPlain := APlain;
  FInner := AInner;
  Caption := 'CryptLok Zip - ' + ExtractFileName(AFile);
  BorderStyle := bsSizeable;
  Position := poScreenCenter;
  ClientWidth := 600;
  ClientHeight := 420;
  Constraints.MinWidth := 420;
  Constraints.MinHeight := 300;
  Font.Name := UiFontName;
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(12, 10, 576, 18);
  L.Caption := 'Contents of ' + ExtractFileName(AFile);
  L.Font.Style := [fsBold];
  L.Anchors := [akLeft, akTop, akRight];
  FSigText := TLabel.Create(Self); FSigText.Parent := Self; FSigText.SetBounds(12, 30, 576, 18);
  FSigText.Caption := SigLine(ASig);
  FSigText.Anchors := [akLeft, akTop, akRight];
  if ASig.Sig in [ssBad] then
    FSigText.Font.Color := clRed
  else if ASig.Sig in [ssGood, ssExpired] then
    FSigText.Font.Color := RGB(0, 120, 40);

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.SetBounds(12, 54, 576, 310);
  FList.Anchors := [akLeft, akTop, akRight, akBottom];
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  C := FList.Columns.Add; C.Caption := 'Name'; C.Width := 360;
  C := FList.Columns.Add; C.Caption := 'Size'; C.Width := 90; C.Alignment := taRightJustify;
  C := FList.Columns.Add; C.Caption := 'Type'; C.Width := 100;

  Ents := ZipEntries(APlain, AInner);
  for E in Ents do
  begin
    Li := FList.Items.Add;
    Li.Caption := E.Name;
    if E.IsDir then
    begin
      Li.SubItems.Add('');
      Li.SubItems.Add('Folder');
    end
    else
    begin
      Li.SubItems.Add(SizeText(E.Size));
      Li.SubItems.Add(IfThen(ExtractFileExt(E.Name) = '', 'File',
        UpperCase(Copy(ExtractFileExt(E.Name), 2, 10)) + ' file'));
    end;
  end;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(12, 378, 120, 28);
  B.Anchors := [akLeft, akBottom];
  B.Caption := 'Extract All...'; B.OnClick := ExtractClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(504, 378, 84, 28);
  B.Anchors := [akRight, akBottom];
  B.Caption := 'Close'; B.ModalResult := mrCancel; B.Cancel := True;
end;

procedure TZipViewer.FormCleanup;
begin
  ZipCleanup(FPlain);
  FPlain := '';
end;

procedure TZipViewer.ExtractClick(Sender: TObject);
var
  D: TFileOpenDialog;
  Dest: string;
  N, Skipped: Integer;
  Overwrite: Boolean;
  Err: string;
begin
  D := TFileOpenDialog.Create(Self);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Extract to folder';
    if not D.Execute then Exit;
    Dest := D.FileName;
  finally
    D.Free;
  end;
  Overwrite := False;
  N := 0;
  Skipped := 0;
  Err := '';
  try
    RunBusy(procedure begin
      try
        N := ZipExtract(FPlain, FInner, Dest, False, Skipped);
      except
        on E: Exception do Err := E.Message;
      end;
    end);
    if (Err = '') and (Skipped > 0) then
      if Application.MessageBox(PChar(Format('%d file(s) already exist in that folder. Replace them?',
        [Skipped])), 'Extract', MB_YESNO or MB_ICONQUESTION) = IDYES then
      begin
        Overwrite := True;
        RunBusy(procedure begin
          try
            N := ZipExtract(FPlain, FInner, Dest, Overwrite, Skipped);
          except
            on E: Exception do Err := E.Message;
          end;
        end);
      end;
  except
    on E: Exception do Err := E.Message;
  end;
  if Err <> '' then
    Application.MessageBox(PChar('Could not extract: ' + Err), 'Extract', MB_OK or MB_ICONWARNING)
  else
    Application.MessageBox(PChar(Format('Extracted %d file(s) to %s', [N, Dest])), 'Extract',
      MB_OK or MB_ICONINFORMATION);
end;

procedure OpenZipFile(AOwner: TComponent; const AEngine: IKeyEngine; const AFile: string;
  APreferText: Boolean);
var
  TextBytes: TBytes;
  Pass: TBytes;
  R: TCryptoResult;
  Plain, Inner: string;
  V: TZipViewer;
  M: TModalResult;
  Tries: Integer;
begin
  { a file that is only signed needs no passphrase: try without one first }
  R.Ok := False;
  RunBusy(procedure begin R := ZipDecrypt(AEngine, AFile, nil, Plain, Inner); end);
  if (not R.Ok) and (ContainsText(R.Error, 'not an OpenPGP') or ContainsText(R.Error, 'does not contain encrypted data')) then
  begin
    Application.MessageBox(PChar(R.Error), 'Open Zip', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  Tries := 0;
  while (not R.Ok) and (Tries < 5) do
  begin
    M := AskPassphraseFor(AOwner, ExtractFileName(AFile),
      'Enter the passphrase of your key, or the passphrase of the archive.',
      DescribeRecipients(AEngine.ListKeys, AEngine.FileRecipients(AFile)), Pass);
    if M <> mrOk then Exit;
    R.Ok := False;
    try
      RunBusy(procedure begin R := ZipDecrypt(AEngine, AFile, Pass, Plain, Inner); end);
    finally
      WipeBytes(Pass);
    end;
    if R.Ok then Break;
    Inc(Tries);
    Application.MessageBox(PChar(IfThen(R.WrongPassphrase, 'That passphrase is not correct.', R.Error)),
      'Open Zip', MB_OK or MB_ICONWARNING);
    if not R.WrongPassphrase then Exit;
  end;
  if not R.Ok then Exit;
  if APreferText and not (LooksLikeTar(Plain) and Inner.EndsWith('.tar', True)) and
     (TFile.GetSize(Plain) <= 4 * 1024 * 1024) then
  begin
    TextBytes := TFile.ReadAllBytes(Plain);
    if LooksLikeText(TextBytes) then
    begin
      try
        ShowTextViewer(AOwner, 'CryptLok Viewer - ' + ExtractFileName(AFile), SignatureLine(R),
          TEncoding.UTF8.GetString(TextBytes), R.Sig in [ssGood, ssExpired], R.Sig = ssBad);
      finally
        if Length(TextBytes) > 0 then FillChar(TextBytes[0], Length(TextBytes), 0);
        ZipCleanup(Plain);
      end;
      Exit;
    end;
  end;
  V := TZipViewer.CreateViewer(AOwner, AFile, Plain, Inner, R);
  try
    V.ShowModal;
  finally
    V.FormCleanup;
    V.Free;
  end;
end;

end.

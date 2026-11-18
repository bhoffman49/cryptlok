unit OPD.ViewerDialog;

{ The Viewer: reads decrypted text in a window instead of saving it to disk or leaving it on the
  clipboard.  Used for encrypted text files (.asc, .pgp, .gpg) and for a message on the clipboard. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.Graphics,
  OPD.Theme, OPD.Engine;

{ AInfo is the signature line; AGood/ABad colour it green or red. }
procedure ShowTextViewer(AOwner: TComponent; const ATitle, AInfo, AText: string; AGood, ABad: Boolean);

{ True when the bytes read as ordinary text (so they can be shown in a window). }
function LooksLikeText(const ABytes: TBytes): Boolean;

function SignatureLine(const R: TCryptoResult): string;

procedure ViewClipboard(AOwner: TComponent; const AEngine: IKeyEngine);

{ Shows what differs between two texts: removed words red and struck through, added words green and bold. }
procedure ShowTextDiff(AOwner: TComponent; const AOriginal, AViewed: string);

implementation

uses
  System.StrUtils, System.IOUtils, Vcl.Clipbrd, Vcl.ComCtrls, Vcl.Dialogs, OPD.PassphraseDialog, OPD.TextDiff;

function LooksLikeText(const ABytes: TBytes): Boolean;
var
  I, Ctrl, N: Integer;
  S: string;
begin
  N := Length(ABytes);
  if N = 0 then Exit(True);
  Ctrl := 0;
  for I := 0 to N - 1 do
  begin
    if ABytes[I] = 0 then Exit(False);
    if (ABytes[I] < 9) or ((ABytes[I] > 13) and (ABytes[I] < 32)) then Inc(Ctrl);
  end;
  if Ctrl * 100 > N then Exit(False);
  try
    S := TEncoding.UTF8.GetString(ABytes);
  except
    Exit(False);
  end;
  I := Pos(#$FFFD, S);
  Result := (I = 0) or (S.CountChar(#$FFFD) * 100 <= Length(S));
end;

function SignatureLine(const R: TCryptoResult): string;
begin
  case R.Sig of
    ssGood: Result := 'Good signature from ' + R.SignedBy;
    ssExpired: Result := 'Good signature from ' + R.SignedBy + ' (the signing key has expired)';
    ssBad: Result := 'WARNING: the signature is not valid. The text may have been changed.';
    ssNoKey: Result := 'Signed by ' + R.SignedBy + ' (that public key is not on your keyring, so it cannot be checked)';
  else
    Result := 'Not signed';
  end;
end;

type
  TTextViewer = class(TOPDForm)
  private
    FMemo: TMemo;
    procedure CopyClick(Sender: TObject);
    procedure CompareClick(Sender: TObject);
  public
    constructor CreateViewer(AOwner: TComponent; const ATitle, AInfo, AText: string; AGood, ABad: Boolean);
    destructor Destroy; override;
  end;

constructor TTextViewer.CreateViewer(AOwner: TComponent; const ATitle, AInfo, AText: string; AGood, ABad: Boolean);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(AOwner);
  Caption := ATitle;
  BorderStyle := bsSizeable;
  Position := poScreenCenter;
  ClientWidth := 680;
  ClientHeight := 480;
  Constraints.MinWidth := 420;
  Constraints.MinHeight := 280;
  Font.Name := UiFontName;
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(12, 10, 656, 20);
  L.Anchors := [akLeft, akTop, akRight];
  L.Caption := AInfo; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  if ABad then L.Font.Color := clRed
  else if AGood then L.Font.Color := RGB(0, 120, 40);

  FMemo := TMemo.Create(Self); FMemo.Parent := Self; FMemo.SetBounds(12, 36, 656, 392);
  FMemo.Anchors := [akLeft, akTop, akRight, akBottom];
  FMemo.ReadOnly := True; FMemo.ScrollBars := ssBoth; FMemo.WordWrap := False;
  FMemo.Font.Name := 'Consolas'; FMemo.Font.Size := 10;
  FMemo.Text := AText;
  if ABad then
  begin
    { a message whose signature failed: nothing in it can be trusted, so it should look wrong }
    FMemo.Color := RGB(255, 236, 236);
    FMemo.Font.Color := RGB(170, 0, 0);
    FMemo.Font.Style := [fsBold];
  end;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(12, 440, 140, 28);
  B.Anchors := [akLeft, akBottom]; B.Caption := 'Copy to Clipboard'; B.OnClick := CopyClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(160, 440, 190, 28);
  B.Anchors := [akLeft, akBottom]; B.Caption := 'Compare with original...'; B.OnClick := CompareClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(584, 440, 84, 28);
  B.Anchors := [akRight, akBottom]; B.Caption := 'Close'; B.ModalResult := mrOk; B.Default := True; B.Cancel := True;
end;

destructor TTextViewer.Destroy;
begin
  { the decrypted text should not linger in the control }
  if FMemo <> nil then FMemo.Text := StringOfChar('x', Length(FMemo.Text));
  inherited;
end;

procedure TTextViewer.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := FMemo.Text;
end;

{ Reads a text file as UTF-8 (with or without a byte-order mark), falling back to the system code page. }
function ReadTextFile(const AFile: string): string;
var
  B: TBytes;
  Skip: Integer;
begin
  B := TFile.ReadAllBytes(AFile);
  Skip := 0;
  if (Length(B) >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then Skip := 3;
  try
    Result := TEncoding.UTF8.GetString(B, Skip, Length(B) - Skip);
    if Pos(#$FFFD, Result) > 0 then
      Result := TEncoding.Default.GetString(B, Skip, Length(B) - Skip);
  except
    Result := TEncoding.Default.GetString(B, Skip, Length(B) - Skip);
  end;
end;

procedure TTextViewer.CompareClick(Sender: TObject);
var
  D: TOpenDialog;
  Orig: string;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Choose the original text to compare with';
    D.Filter := 'Text (*.txt;*.asc)|*.txt;*.asc|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    if TFile.GetSize(D.FileName) > 4 * 1024 * 1024 then
    begin
      Application.MessageBox('That file is too large to compare here.', 'Compare', MB_OK or MB_ICONINFORMATION);
      Exit;
    end;
    Orig := ReadTextFile(D.FileName);
  finally
    D.Free;
  end;
  ShowTextDiff(Self, Orig, FMemo.Text);
end;

procedure ShowTextDiff(AOwner: TComponent; const AOriginal, AViewed: string);
var
  F: TOPDForm;
  Pieces: TDiffPieces;
  Err: string;
  Removed, Added: Integer;
  RE: TRichEdit;
  L: TLabel;
  B: TButton;
  P: TDiffPiece;
begin
  if not DiffTexts(AOriginal, AViewed, Pieces, Err) then
  begin
    Application.MessageBox(PChar(Err), 'Compare', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  DiffSummary(Pieces, Removed, Added);
  F := TOPDForm.CreateNew(AOwner);
  try
    F.Caption := 'Compare with original';
    F.BorderStyle := bsSizeable;
    F.Position := poScreenCenter;
    F.ClientWidth := 680;
    F.ClientHeight := 480;
    F.Constraints.MinWidth := 420;
    F.Constraints.MinHeight := 280;
    F.Font.Name := UiFontName;
    F.Font.Size := 9;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(12, 10, 656, 20); L.Anchors := [akLeft, akTop, akRight];
    L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
    if (Removed = 0) and (Added = 0) then
      L.Caption := 'The two texts are identical.'
    else
      L.Caption := Format('%d word(s) in the original are missing or changed, %d word(s) are new.', [Removed, Added]);
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(12, 32, 656, 18); L.Anchors := [akLeft, akTop, akRight];
    L.Transparent := False; L.Color := clBtnFace;
    L.Caption := 'Red and struck through: only in the original.   Green and bold: only in the message you are viewing.';
    L.Font.Color := clGrayText;
    RE := TRichEdit.Create(F); RE.Parent := F; RE.SetBounds(12, 58, 656, 370);
    RE.Anchors := [akLeft, akTop, akRight, akBottom];
    RE.ReadOnly := True; RE.ScrollBars := ssBoth; RE.WordWrap := True;
    RE.Font.Name := 'Consolas'; RE.Font.Size := 10;
    for P in Pieces do
    begin
      RE.SelStart := RE.GetTextLen;
      case P.Op of
        doRemoved:
          begin
            RE.SelAttributes.Color := RGB(190, 0, 0);
            RE.SelAttributes.Style := [fsStrikeOut];
          end;
        doAdded:
          begin
            RE.SelAttributes.Color := RGB(0, 130, 40);
            RE.SelAttributes.Style := [fsBold];
          end;
      else
        RE.SelAttributes.Color := clWindowText;
        RE.SelAttributes.Style := [];
      end;
      RE.SelText := P.Text.Replace(#10, sLineBreak);
    end;
    RE.SelStart := 0;
    B := TButton.Create(F); B.Parent := F; B.SetBounds(584, 440, 84, 28); B.Anchors := [akRight, akBottom];
    B.Caption := 'Close'; B.ModalResult := mrOk; B.Default := True; B.Cancel := True;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure ShowTextViewer(AOwner: TComponent; const ATitle, AInfo, AText: string; AGood, ABad: Boolean);
var
  F: TTextViewer;
begin
  F := TTextViewer.CreateViewer(AOwner, ATitle, AInfo, AText, AGood, ABad);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure ViewClipboard(AOwner: TComponent; const AEngine: IKeyEngine);
var
  Text: string;
  Pass: TBytes;
  R: TCryptoResult;
  M: TModalResult;
  Tries: Integer;
begin
  try
    Text := Clipboard.AsText;
  except
    Text := '';
  end;
  if not Text.Contains('-----BEGIN PGP') then
  begin
    Application.MessageBox('The clipboard does not contain an encrypted or signed message. Copy a block that starts with ' +
      '"-----BEGIN PGP MESSAGE-----" first.', 'Viewer', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  { signed-only messages need no passphrase; a message for our keys always does, and asking gpg without one
    makes it report "no secret key" for a locked key, so only try without a passphrase when no key is named }
  FillChar(R, SizeOf(R), 0);
  if Length(AEngine.MessageRecipients(Text)) = 0 then
    R := AEngine.DecryptText(Text, nil);
  Tries := 0;
  while not R.Ok do
  begin
    if (not R.WrongPassphrase) and (R.Error <> '') and not ContainsText(R.Error, 'passphrase') then
    begin
      if ContainsText(R.Error, 'None of your private keys') or ContainsText(R.Error, 'not contain') then
      begin
        Application.MessageBox(PChar(R.Error), 'Viewer', MB_OK or MB_ICONWARNING);
        Exit;
      end;
    end;
    M := AskPassphraseFor(AOwner, 'the message on the clipboard',
      'Enter the passphrase of your key, or the passphrase of the message.',
      DescribeRecipients(AEngine.ListKeys, AEngine.MessageRecipients(Text)), Pass);
    if M <> mrOk then Exit;
    try
      R := AEngine.DecryptText(Text, Pass);
    finally
      WipeBytes(Pass);
    end;
    Inc(Tries);
    if (not R.Ok) and R.WrongPassphrase then
    begin
      Application.MessageBox('That passphrase is not correct.', 'Viewer', MB_OK or MB_ICONWARNING);
      if Tries >= 5 then Exit;
      Continue;
    end;
    if not R.Ok then
    begin
      Application.MessageBox(PChar(R.Error), 'Viewer', MB_OK or MB_ICONWARNING);
      Exit;
    end;
  end;
  ShowTextViewer(AOwner, 'CryptLok Viewer - clipboard message', SignatureLine(R), R.Text,
    R.Sig in [ssGood, ssExpired], R.Sig = ssBad);
  WipeString(R.Text);
end;

end.

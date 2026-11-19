unit OPD.SigFiles;

{ Detached signatures: check a .sig / .asc file against the file it belongs to, and sign a file
  (writes the signature next to it).  The file itself is never changed. }

interface

uses
  System.SysUtils, System.Classes, OPD.Engine;

{ True for a detached signature file: an armored "BEGIN PGP SIGNATURE" block, or a binary .sig file. }
function IsSignatureFile(const AFile: string): Boolean;

{ Finds the signed file (same name without the extension), asks when it is not there, then reports
  whether the signature is good. }
procedure VerifySignatureFile(AOwner: TComponent; const AEngine: IKeyEngine; const ASigFile: string);

{ Signs a file (AFile = '' asks which). True when a signature file was written. }
function RunSignFileDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AFile: string): Boolean;

implementation

uses
  System.StrUtils, System.IOUtils, System.Generics.Collections, Winapi.Windows, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics, OPD.Theme, OPD.PassphraseDialog, OPD.PassCache;

function IsSignatureFile(const AFile: string): Boolean;
var
  F: TFileStream;
  Buf: TBytes;
  N: Integer;
  S: string;
begin
  Result := False;
  try
    F := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, 120);
      N := F.Read(Buf[0], Length(Buf));
      SetLength(Buf, N);
    finally
      F.Free;
    end;
    if N = 0 then Exit;
    S := TEncoding.ASCII.GetString(Buf);
    if S.TrimLeft.StartsWith('-----BEGIN PGP SIGNATURE-----') then Exit(True);
    { a binary signature packet (old or new format); only trusted for the .sig extension }
    if SameText(ExtractFileExt(AFile), '.sig') and (Buf[0] in [$88, $89, $8A, $C2]) then
      Result := True;
  except
    Result := False;
  end;
end;

function FormatWhen(AWhen: TDateTime): string;
begin
  if AWhen = 0 then Result := 'unknown' else Result := FormatDateTime('mmmm d, yyyy "at" h:nn AM/PM', AWhen);
end;

function FindSignedFile(AOwner: TComponent; const ASigFile: string): string;
var
  Base: string;
  D: TOpenDialog;
begin
  Result := '';
  Base := ChangeFileExt(ASigFile, '');
  if (Base <> ASigFile) and FileExists(Base) then Exit(Base);
  D := TOpenDialog.Create(AOwner);
  try
    D.Title := 'Which file is "' + ExtractFileName(ASigFile) + '" the signature of?';
    D.InitialDir := ExtractFilePath(ASigFile);
    D.Filter := 'All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then Result := D.FileName;
  finally
    D.Free;
  end;
end;

procedure VerifySignatureFile(AOwner: TComponent; const AEngine: IKeyEngine; const ASigFile: string);
var
  Data, Msg, Who: string;
  R: TCryptoResult;
begin
  Data := FindSignedFile(AOwner, ASigFile);
  if Data = '' then Exit;
  Screen.Cursor := crHourGlass;
  try
    R := AEngine.VerifyDetached(ASigFile, Data);
  finally
    Screen.Cursor := crDefault;
  end;
  Who := R.SignedBy;
  case R.Sig of
    ssGood, ssExpired:
      begin
        Msg := 'Good signature.' + sLineBreak + sLineBreak +
          'Signed by:  ' + Who + sLineBreak +
          'Made on:  ' + FormatWhen(R.SignedOn) + sLineBreak + sLineBreak +
          'The file "' + ExtractFileName(Data) + '" has not been changed since it was signed.';
        if R.Sig = ssExpired then
          Msg := Msg + sLineBreak + sLineBreak + 'Note: the signing key has expired since.';
        if R.Sig = ssExpired then
          Application.MessageBox(PChar(Msg), 'Verify Signature', MB_OK or MB_ICONWARNING)
        else
          Application.MessageBox(PChar(Msg), 'Verify Signature', MB_OK or MB_ICONINFORMATION);
      end;
    ssBad:
      Application.MessageBox(PChar('BAD signature.' + sLineBreak + sLineBreak +
        'The file "' + ExtractFileName(Data) + '" does not match this signature. It was changed after it was ' +
        'signed, is damaged, or this is the signature of a different file.' + sLineBreak + sLineBreak +
        'Do not trust this file.'), 'Verify Signature', MB_OK or MB_ICONERROR);
    ssNoKey:
      Application.MessageBox(PChar('This file was signed by ' + Who + ', which is not in your keyring, so the ' +
        'signature cannot be checked.' + sLineBreak + sLineBreak +
        'Import the signer''s public key (Keys > Import Keys) and open the signature again.'),
        'Verify Signature', MB_OK or MB_ICONWARNING);
  else
    Application.MessageBox(PChar('Not checked: ' + R.Error), 'Verify Signature', MB_OK or MB_ICONWARNING);
  end;
end;

{ ---- Sign a file --------------------------------------------------------------------- }

type
  TSignFileForm = class(TOPDForm)
  private
    FFile: TEdit;
    procedure BrowseClick(Sender: TObject);
  public
    Signers: TComboBox;
    Kind: TRadioGroup;
    constructor CreateDialog(AOwner: TComponent; const AFile: string; const ASignerNames: TArray<string>);
    property FileName: TEdit read FFile;
  end;

procedure TSignFileForm.BrowseClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Choose the file to sign';
    D.Filter := 'All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then FFile.Text := D.FileName;
  finally
    D.Free;
  end;
end;

constructor TSignFileForm.CreateDialog(AOwner: TComponent; const AFile: string;
  const ASignerNames: TArray<string>);
var
  L: TLabel;
  B: TButton;
  S: string;
begin
  inherited CreateNew(AOwner);
  Caption := 'Sign File';
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  ClientWidth := 540;
  ClientHeight := 340;
  Font.Name := UiFontName;
  Font.Size := 9;
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(14, 12, 512, 18);
  L.Caption := 'File to sign'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  FFile := TEdit.Create(Self); FFile.Parent := Self; FFile.SetBounds(14, 34, 420, 24);
  FFile.Text := AFile; FFile.ReadOnly := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(442, 33, 84, 26);
  B.Caption := 'Browse...'; B.OnClick := BrowseClick;
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(14, 72, 512, 36);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'The file is not changed. A separate signature file is created next to it; send both files, and ' +
    'the receiver can check with your public key that the file really is from you and was not altered.';
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(14, 120, 512, 18);
  L.Caption := 'Sign with your key'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  Signers := TComboBox.Create(Self); Signers.Parent := Self; Signers.SetBounds(14, 142, 512, 24);
  Signers.Style := csDropDownList;
  for S in ASignerNames do Signers.Items.Add(S);
  Signers.ItemIndex := 0;
  Kind := TRadioGroup.Create(Self); Kind.Parent := Self; Kind.SetBounds(14, 184, 512, 80);
  Kind.Caption := ' Signature file ';
  Kind.Items.Add('Binary signature  (name.ext.sig) - smallest');
  Kind.Items.Add('Text signature  (name.ext.asc) - can be pasted into an email');
  Kind.ItemIndex := 0;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(358, 290, 84, 28);
  B.Caption := 'Sign'; B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(450, 290, 84, 28);
  B.Caption := 'Cancel'; B.ModalResult := mrCancel; B.Cancel := True;
end;

function RunSignFileDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AFile: string): Boolean;
var
  Own: TList<TKeyInfo>;
  K, Signer: TKeyInfo;
  Names: TArray<string>;
  F: TSignFileForm;
  Target, Out_: string;
  Armor: Boolean;
  Pass: TBytes;
  R: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
begin
  Result := False;
  Own := TList<TKeyInfo>.Create;
  try
    for K in AEngine.ListKeys do
      if K.HasSecret and not K.Revoked and not K.Expired and not K.Disabled and
         (Pos('s', LowerCase(K.Caps)) > 0) then
        Own.Add(K);
    if Own.Count = 0 then
    begin
      Application.MessageBox('You need a private key of your own to sign a file. Create one with Keys > New Key Pair.',
        'Sign File', MB_OK or MB_ICONINFORMATION);
      Exit;
    end;
    SetLength(Names, Own.Count);
    for Tries := 0 to Own.Count - 1 do
      Names[Tries] := Own[Tries].DisplayName +
        IfThen(Own[Tries].DisplayEmail <> '', ' <' + Own[Tries].DisplayEmail + '>', '') + '  ' + Own[Tries].ShortId;

    F := TSignFileForm.CreateDialog(AOwner, AFile, Names);
    try
      if (AFile = '') then
      begin
        F.FileName.Text := '';
      end;
      while True do
      begin
        if F.ShowModal <> mrOk then Exit;
        if (F.FileName.Text <> '') and FileExists(F.FileName.Text) then Break;
        Application.MessageBox('Choose the file to sign first (Browse...).', 'Sign File', MB_OK or MB_ICONINFORMATION);
      end;
      Target := F.FileName.Text;
      Signer := Own[F.Signers.ItemIndex];
      Armor := F.Kind.ItemIndex = 1;
    finally
      F.Free;
    end;

    Out_ := Target + IfThen(Armor, '.asc', '.sig');
    if FileExists(Out_) then
      if Application.MessageBox(PChar('"' + ExtractFileName(Out_) + '" already exists. Replace it?'),
        'Sign File', MB_YESNO or MB_ICONQUESTION or MB_DEFBUTTON2) <> IDYES then Exit;

    Tries := 0;
    repeat
      Inc(Tries);
      Mr := AskPassCached(AOwner, Signer.KeyId, Signer.DisplayName + ' ' + Signer.ShortId,
        'Enter the passphrase of your key to sign the file.', Pass);
      if Mr <> mrOk then Exit;
      Screen.Cursor := crHourGlass;
      try
        R := AEngine.SignFile(Target, Signer.Fingerprint, Out_, Armor, Pass);
        NotePassphrase(Signer.KeyId, Pass, R.Ok, R.WrongPassphrase);
      finally
        Screen.Cursor := crDefault;
        WipeBytes(Pass);
      end;
      if R.WrongPassphrase then
        Application.MessageBox('That passphrase was not accepted.', 'Passphrase', MB_OK or MB_ICONWARNING);
    until (not R.WrongPassphrase) or (Tries >= 3);
    if R.Ok then
    begin
      Result := True;
      Application.MessageBox(PChar('Signed.' + sLineBreak + sLineBreak + 'Signature file:' + sLineBreak + Out_ +
        sLineBreak + sLineBreak + 'Send it together with "' + ExtractFileName(Target) + '".'),
        'Sign File', MB_OK or MB_ICONINFORMATION);
    end
    else
      Application.MessageBox(PChar('Not signed: ' + R.Error), 'Sign File', MB_OK or MB_ICONWARNING);
  finally
    Own.Free;
  end;
end;

end.

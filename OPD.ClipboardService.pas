unit OPD.ClipboardService;

{ Clipboard encrypt / sign / decrypt+verify.  Text is handled as UTF-8, the
  result replaces the clipboard contents.  Decrypted text can be cleared again
  after N seconds (only when the clipboard still holds exactly that text). }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.ExtCtrls, OPD.Engine;

type
  TClipOp = (cpEncrypt, cpSign, cpEncryptSign, cpDecrypt);
  TNotifyEvent2 = procedure(const ATitle, AMessage: string) of object;

  TClipboardService = class
  private
    FOwner: TComponent;
    FEngine: IKeyEngine;
    FNotify: TNotifyEvent2;
    FTimer: TTimer;
    FExpected: string;
    FAutoClear: Integer;
    FIni: string;
    FOnKeysChanged: TNotifyEvent;
    function ImportKeyBlock(const AText: string): Boolean;
    procedure TimerTick(Sender: TObject);
    function ClipText: string;
    procedure SetClip(const AText: string);
    function AskPass(const ALabel, AHint: string; out APass: TBytes): TModalResult;
    procedure Decrypt;
    procedure EncryptOrSign(AOp: TClipOp);
    procedure SetAutoClear(AValue: Integer);
  public
    constructor Create(AOwner: TComponent; const AEngine: IKeyEngine;
      ANotify: TNotifyEvent2);
    destructor Destroy; override;
    procedure Execute(AOp: TClipOp);
    procedure ClearClipboard;
    procedure EditClipboard;
    property AutoClearSeconds: Integer read FAutoClear write SetAutoClear;
    { called after a key block from the clipboard was imported, so the key list can refresh }
    property OnKeysChanged: TNotifyEvent read FOnKeysChanged write FOnKeysChanged;
  end;

implementation

uses
  System.IniFiles, System.StrUtils, Vcl.Clipbrd, Vcl.Forms, Vcl.StdCtrls, Vcl.Graphics,
  System.IOUtils, Winapi.Windows, OPD.Theme, OPD.PassphraseDialog, OPD.RecipientDialog, OPD.MasterKeys,
  OPD.ImportDialog, OPD.ViewerDialog, OPD.PassCache;

{ A public or private key block (not an encrypted message) is imported, not decrypted. }
function TClipboardService.ImportKeyBlock(const AText: string): Boolean;
var
  F: string;
  Raw: TBytes;
  Zero: TBytes;
begin
  Result := (Pos('-----BEGIN PGP PUBLIC KEY BLOCK-----', AText) > 0) or
            (Pos('-----BEGIN PGP PRIVATE KEY BLOCK-----', AText) > 0);
  if not Result then Exit;
  F := TPath.Combine(TPath.GetTempPath, 'cryptlok-keyblock-' + TGUID.NewGuid.ToString.Substring(1, 8) + '.asc');
  Raw := TEncoding.UTF8.GetBytes(AText);
  TFile.WriteAllBytes(F, Raw);
  try
    { the same preview / import / report window as Keys > Import }
    if RunImportFlow(FOwner, FEngine, [F]) and Assigned(FOnKeysChanged) then
      FOnKeysChanged(Self);
  finally
    { the temporary file may hold a private key: overwrite it before deleting }
    try
      SetLength(Zero, Length(Raw));
      TFile.WriteAllBytes(F, Zero);
    except
    end;
    try
      TFile.Delete(F);
    except
    end;
    FillChar(Raw[0], Length(Raw), 0);
  end;
end;

constructor TClipboardService.Create(AOwner: TComponent; const AEngine: IKeyEngine;
  ANotify: TNotifyEvent2);
var
  Ini: TIniFile;
begin
  inherited Create;
  FOwner := AOwner;
  FEngine := AEngine;
  FNotify := ANotify;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.OnTimer := TimerTick;
  FIni := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir))) +
    'settings.ini';
  Ini := TIniFile.Create(FIni);
  try
    FAutoClear := Ini.ReadInteger('Clipboard', 'AutoClearSeconds', 0);
  finally
    Ini.Free;
  end;
end;

destructor TClipboardService.Destroy;
begin
  FTimer.Free;
  FExpected := '';
  inherited;
end;

procedure TClipboardService.SetAutoClear(AValue: Integer);
var
  Ini: TIniFile;
begin
  FAutoClear := AValue;
  Ini := TIniFile.Create(FIni);
  try
    Ini.WriteInteger('Clipboard', 'AutoClearSeconds', AValue);
  finally
    Ini.Free;
  end;
end;

function TClipboardService.ClipText: string;
begin
  Result := '';
  try
    if Clipboard.HasFormat(CF_UNICODETEXT) then
      Result := Clipboard.AsText;
  except
  end;
end;

procedure TClipboardService.SetClip(const AText: string);
begin
  Clipboard.AsText := AText;
end;

procedure TClipboardService.TimerTick(Sender: TObject);
begin
  FTimer.Enabled := False;
  if (FExpected <> '') and (ClipText = FExpected) then
  begin
    Clipboard.Clear;
    FNotify('Clipboard', 'The decrypted text was cleared from the clipboard.');
  end;
  FExpected := '';
end;

procedure TClipboardService.ClearClipboard;
begin
  Clipboard.Clear;
  FExpected := '';
  FTimer.Enabled := False;
  FNotify('Clipboard', 'Clipboard cleared.');
end;

function TClipboardService.AskPass(const ALabel, AHint: string; out APass: TBytes): TModalResult;
begin
  Application.BringToFront;
  Result := AskPassphrase(FOwner, ALabel, AHint, False, APass);
end;

procedure TClipboardService.Execute(AOp: TClipOp);
begin
  if AOp = cpDecrypt then
    Decrypt
  else
    EncryptOrSign(AOp);
end;

procedure TClipboardService.EncryptOrSign(AOp: TClipOp);
var
  Text, Signer, SignerLabel: string;
  Keys: TKeyInfoArray;
  Recips: TArray<string>;
  Pass: TBytes;
  Res: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
begin
  Text := ClipText;
  if Text = '' then
  begin
    FNotify('Clipboard', 'The clipboard does not contain any text.');
    Exit;
  end;
  Application.BringToFront;
  Keys := ListKeysOrExplain(FEngine);
  if AOp in [cpEncrypt, cpEncryptSign] then
    if not SelectRecipients(FOwner, Keys, Recips, UsableMasterKeys(FEngine, Keys)) then
      Exit
    else
      Recips := WithMasterKeysIn(FEngine, Keys, Recips);   { master key list: always included }
  Signer := '';
  if AOp in [cpSign, cpEncryptSign] then
    if not SelectSigner(FOwner, Keys, Signer, SignerLabel) then
      Exit;

  if Signer = '' then
  begin
    Res := FEngine.EncryptText(Text, Recips, '', nil);
  end
  else
  begin
    Tries := 0;
    repeat
      Inc(Tries);
      Application.BringToFront;
      Mr := AskPassCached(FOwner, KeyIdOf(Signer), SignerLabel, 'Enter the passphrase of your signing key.', Pass);
      if Mr <> mrOk then Exit;
      try
        if AOp = cpSign then
          Res := FEngine.SignText(Text, Signer, Pass)
        else
          Res := FEngine.EncryptText(Text, Recips, Signer, Pass);
        NotePassphrase(KeyIdOf(Signer), Pass, Res.Ok, Res.WrongPassphrase);
      finally
        WipeBytes(Pass);
      end;
      if Res.WrongPassphrase then
        Application.MessageBox('That passphrase was not accepted.', 'Passphrase',
          MB_OK or MB_ICONWARNING);
    until (not Res.WrongPassphrase) or (Tries >= 3);
  end;

  if Res.Ok then
  begin
    SetClip(Res.Text);
    case AOp of
      cpEncrypt: FNotify('Clipboard', 'Encrypted text is on the clipboard.');
      cpSign: FNotify('Clipboard', 'Signed text is on the clipboard.');
    else
      FNotify('Clipboard', 'Encrypted and signed text is on the clipboard.');
    end;
  end
  else
    Application.MessageBox(PChar('Not done: ' + Res.Error), 'Clipboard',
      MB_OK or MB_ICONWARNING);
end;

procedure TClipboardService.Decrypt;
var
  Text, KeyLabel, OwnId: string;
  Rec: TArray<string>;
  Keys: TKeyInfoArray;
  K, S, R: Integer;
  Pass: TBytes;
  Res: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
begin
  Text := ClipText;
  if Text = '' then
  begin
    FNotify('Clipboard', 'The clipboard does not contain any text.');
    Exit;
  end;
  Application.BringToFront;
  if ImportKeyBlock(Text) then Exit;
  Rec := FEngine.MessageRecipients(Text);
  FillChar(Res, SizeOf(Res), 0);
  if Length(Rec) = 0 then
    Res := FEngine.DecryptText(Text, nil)  { signed-only messages: verify, no passphrase }
  else
  begin
    KeyLabel := 'Private key';
    Keys := FEngine.ListKeys;
    for K := 0 to High(Keys) do
      if Keys[K].HasSecret then
        for R := 0 to High(Rec) do
        begin
          if SameText(Keys[K].KeyId, Rec[R]) then
            KeyLabel := Keys[K].DisplayName + ' ' + Keys[K].ShortId;
          for S := 0 to High(Keys[K].SubKeys) do
            if SameText(Keys[K].SubKeys[S].KeyId, Rec[R]) then
              KeyLabel := Keys[K].DisplayName + ' ' + Keys[K].ShortId;
        end;
    OwnId := OwnKeyFor(Keys, Rec);
    Tries := 0;
    repeat
      Inc(Tries);
      Mr := AskPassForCached(FOwner, OwnId, KeyLabel, 'Enter the passphrase to decrypt this message.',
        DescribeRecipients(Keys, Rec), Pass);
      if Mr <> mrOk then Exit;
      try
        Res := FEngine.DecryptText(Text, Pass);
        NotePassphrase(OwnId, Pass, Res.Ok, Res.WrongPassphrase);
      finally
        WipeBytes(Pass);
      end;
      if Res.WrongPassphrase then
        Application.MessageBox('That passphrase was not accepted.', 'Passphrase',
          MB_OK or MB_ICONWARNING);
    until (not Res.WrongPassphrase) or (Tries >= 3);
  end;

  if not Res.Ok then
  begin
    Application.MessageBox(PChar('Not done: ' + Res.Error), 'Clipboard', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  { shown in the built-in text window (with a Copy to Clipboard button) instead of replacing the clipboard }
  ShowTextViewer(FOwner, 'Text Viewer', SignatureLine(Res), Res.Text,
    Res.Sig in [ssGood, ssExpired], Res.Sig = ssBad);
  WipeString(Res.Text);
end;

procedure TClipboardService.EditClipboard;
var
  F: TOPDForm;
  M: TMemo;
  B: TButton;
begin
  F := TOPDForm.CreateNew(FOwner);
  try
    F.Caption := 'Edit Clipboard';
    F.Position := poScreenCenter;
    F.ClientWidth := 640;
    F.ClientHeight := 420;
    F.Font.Name := 'Segoe UI';
    F.Font.Size := 9;
    M := TMemo.Create(F);
    M.Parent := F;
    M.SetBounds(12, 12, 616, 358);
    M.Anchors := [akLeft, akTop, akRight, akBottom];
    M.ScrollBars := ssBoth;
    M.Font.Name := 'Consolas';
    M.WordWrap := False;
    M.Text := ClipText;
    B := TButton.Create(F);
    B.Parent := F;
    B.SetBounds(452, 380, 84, 28);
    B.Anchors := [akRight, akBottom];
    B.Caption := 'Apply';
    B.ModalResult := mrOk;
    B.Default := True;
    B := TButton.Create(F);
    B.Parent := F;
    B.SetBounds(544, 380, 84, 28);
    B.Anchors := [akRight, akBottom];
    B.Caption := 'Cancel';
    B.ModalResult := mrCancel;
    B.Cancel := True;
    Application.BringToFront;
    if F.ShowModal = mrOk then
      SetClip(M.Text);
  finally
    F.Free;
  end;
end;

end.

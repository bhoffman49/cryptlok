unit OPD.PrefsDialog;

{ Key Properties > Edit Preferences: which ciphers, hashes and compression methods a key tells other people to use
  when they encrypt to it (in order of preference), and the preferred keyserver.  Checked entries are offered, in
  the order shown; unchecked ones are not. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.CheckLst,
  Vcl.Graphics, OPD.Theme, OPD.Engine;

{ True when the key was changed. }
function EditKeyPreferences(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo;
  const ACurrent: TKeyPrefs): Boolean;

implementation

uses
  System.StrUtils, OPD.PassphraseDialog;

const
  ALL_CIPHERS: array[0..9] of string = ('AES256', 'AES192', 'AES128', 'Twofish', 'Camellia256', 'Camellia192',
    'Camellia128', 'CAST5', '3DES', 'IDEA');
  ALL_HASHES: array[0..5] of string = ('SHA512', 'SHA384', 'SHA256', 'SHA224', 'SHA1', 'RIPEMD160');
  ALL_ZIPS: array[0..3] of string = ('ZLIB', 'BZip2', 'ZIP', 'Uncompressed');

{ the name gpg wants for a display name }
function GpgName(const ADisplay: string): string;
begin
  if SameText(ADisplay, 'AES128') then Result := 'AES'
  else Result := UpperCase(ADisplay);
  if SameText(ADisplay, 'Uncompressed') then Result := 'Uncompressed';
end;

type
  TPrefsForm = class(TOPDForm)
  private
    FCipher, FHash, FZip: TCheckListBox;
    FKeyserver: TEdit;
    procedure Fill(AList: TCheckListBox; const ACurrent: string; const AAll: array of string);
    procedure Move(AList: TCheckListBox; ADelta: Integer);
    procedure UpClick(Sender: TObject);
    procedure DownClick(Sender: TObject);
    function Checked(AList: TCheckListBox): TArray<string>;
  public
    constructor CreateDlg(AOwner: TComponent; const AKey: TKeyInfo; const APrefs: TKeyPrefs);
  end;

procedure TPrefsForm.Fill(AList: TCheckListBox; const ACurrent: string; const AAll: array of string);
var
  Cur: TArray<string>;
  S, A: string;
  Known: Boolean;
begin
  AList.Items.Clear;
  Cur := ACurrent.Split([',']);
  for S in Cur do
    if Trim(S) <> '' then
      AList.Checked[AList.Items.Add(Trim(S))] := True;     { current order, checked }
  for A in AAll do
  begin
    Known := False;
    for S in Cur do
      if SameText(Trim(S), A) then
        Known := True;
    if not Known then
      AList.Items.Add(A);                                  { everything else, unchecked }
  end;
end;

constructor TPrefsForm.CreateDlg(AOwner: TComponent; const AKey: TKeyInfo; const APrefs: TKeyPrefs);
var
  L: TLabel;
  B: TButton;
  X, I: Integer;
  Lists: array[0..2] of TCheckListBox;
  Titles: array[0..2] of string;
begin
  inherited CreateNew(AOwner);
  Caption := AKey.DisplayName + ' - Preferences';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 640;
  ClientHeight := 470;
  Font.Name := UiFontName;
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 12, 608, 50);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'These tell other people which algorithms to use when they encrypt to this key. Checked entries are ' +
    'offered, in the order shown (top = most preferred). Use the arrows to change the order. Keep the strong ones first.';

  Titles[0] := 'Ciphers'; Titles[1] := 'Hashes'; Titles[2] := 'Compression';
  for I := 0 to 2 do
  begin
    X := 16 + I * 204;
    L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(X, 70, 190, 18);
    L.Caption := Titles[I]; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
    Lists[I] := TCheckListBox.Create(Self); Lists[I].Parent := Self; Lists[I].SetBounds(X, 92, 190, 230);
    B := TButton.Create(Self); B.Parent := Self; B.SetBounds(X, 328, 92, 26);
    B.Caption := 'Move Up'; B.Tag := I; B.OnClick := UpClick;
    B := TButton.Create(Self); B.Parent := Self; B.SetBounds(X + 98, 328, 92, 26);
    B.Caption := 'Move Down'; B.Tag := I; B.OnClick := DownClick;
  end;
  FCipher := Lists[0]; FHash := Lists[1]; FZip := Lists[2];
  Fill(FCipher, APrefs.Cipher, ALL_CIPHERS);
  Fill(FHash, APrefs.Hash, ALL_HASHES);
  Fill(FZip, APrefs.Compression, ALL_ZIPS);

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 376, 200, 18);
  L.Caption := 'Preferred keyserver (optional)'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  FKeyserver := TEdit.Create(Self); FKeyserver.Parent := Self; FKeyserver.SetBounds(16, 398, 608, 24);
  FKeyserver.Text := APrefs.Keyserver;
  FKeyserver.TextHint := 'for example hkps://keys.openpgp.org';

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(448, 432, 84, 28);
  B.Caption := 'OK'; B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(540, 432, 84, 28);
  B.Caption := 'Cancel'; B.ModalResult := mrCancel; B.Cancel := True;
end;

procedure TPrefsForm.Move(AList: TCheckListBox; ADelta: Integer);
var
  I, J: Integer;
  T1, T2: string;
  C1, C2: Boolean;
begin
  I := AList.ItemIndex;
  J := I + ADelta;
  if (I < 0) or (J < 0) or (J >= AList.Items.Count) then Exit;
  T1 := AList.Items[I]; C1 := AList.Checked[I];
  T2 := AList.Items[J]; C2 := AList.Checked[J];
  AList.Items[I] := T2; AList.Checked[I] := C2;
  AList.Items[J] := T1; AList.Checked[J] := C1;
  AList.ItemIndex := J;
end;

procedure TPrefsForm.UpClick(Sender: TObject);
begin
  case TButton(Sender).Tag of
    0: Move(FCipher, -1);
    1: Move(FHash, -1);
  else
    Move(FZip, -1);
  end;
end;

procedure TPrefsForm.DownClick(Sender: TObject);
begin
  case TButton(Sender).Tag of
    0: Move(FCipher, 1);
    1: Move(FHash, 1);
  else
    Move(FZip, 1);
  end;
end;

function TPrefsForm.Checked(AList: TCheckListBox): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, 0);
  for I := 0 to AList.Items.Count - 1 do
    if AList.Checked[I] then
      Result := Result + [GpgName(AList.Items[I])];
end;

function EditKeyPreferences(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo;
  const ACurrent: TKeyPrefs): Boolean;
var
  D: TPrefsForm;
  Pass: TBytes;
  R: TCryptoResult;
  Ks: string;
begin
  Result := False;
  D := TPrefsForm.CreateDlg(AOwner, AKey, ACurrent);
  try
    if D.ShowModal <> mrOk then Exit;
    if Length(D.Checked(D.FCipher)) = 0 then
    begin
      Application.MessageBox('Keep at least one cipher checked.', 'Preferences', MB_OK or MB_ICONWARNING);
      Exit;
    end;
    Ks := Trim(D.FKeyserver.Text);
    if SameText(Ks, ACurrent.Keyserver) then
      Ks := ''                                  { unchanged }
    else if Ks = '' then
      Ks := 'none';                             { removed }
    if AskPassphrase(AOwner, AKey.DisplayName + ' ' + AKey.ShortId,
      'Enter the passphrase of this key to update its preferences.', False, Pass) <> mrOk then Exit;
    try
      RunBusy(procedure
        begin
          R := AEngine.SetKeyPreferences(AKey.Fingerprint, D.Checked(D.FCipher), D.Checked(D.FHash),
            D.Checked(D.FZip), Ks, Pass);
        end);
    finally
      WipeBytes(Pass);
    end;
    if R.Ok then
      Result := True
    else
      Application.MessageBox(PChar(IfThen(R.WrongPassphrase, 'That passphrase is not correct.', R.Error)),
        'Preferences', MB_OK or MB_ICONWARNING);
  finally
    D.Free;
  end;
end;

end.

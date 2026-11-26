unit OPD.KeyDialogs;

{ Key Properties window (classic layout: banner, two columns of fields,
  fingerprint, subkeys, user IDs) and the New Key Pair dialog. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.ComCtrls, Vcl.Graphics, Vcl.Imaging.jpeg, Vcl.Dialogs, OPD.Theme, OPD.Engine;

{ True when something was changed (trust). }
function ShowKeyProperties(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean;

{ Lists who has signed (certified) the user IDs of a key. }
procedure ShowCertifications(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo);

{ Signs (certifies) someone else's key with one of our own. True when it was signed. }
function RunSignKeyDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo): Boolean;

{ True when a key pair was created. }
function RunNewKeyDialog(AOwner: TComponent; const AEngine: IKeyEngine;
  out AFingerprint: string): Boolean;

implementation

uses
  System.StrUtils, System.Math, System.DateUtils, System.Generics.Collections, System.IOUtils, Vcl.Clipbrd, Winapi.Windows,
  OPD.PassphraseDialog, OPD.PhotoId, OPD.PrefsDialog, OPD.PassCache;

const
  BANNER_COLOR = $00706257;
  PANEL_COLOR = $00F0F0F0;

function Fmt(ADate: TDateTime; const ANever: string): string;
begin
  if ADate = 0 then Result := ANever else Result := FormatDateTime('m/d/yyyy', ADate);
end;

function UsageText(const ACaps: string): string;
var
  C: Char;
begin
  Result := '';
  { gpg lists a key's own capabilities in lower case and the whole key's in upper case: show each once }
  for C in ['s', 'c', 'e', 'a'] do
    if Pos(C, LowerCase(ACaps)) > 0 then
      case C of
        's': Result := Result + ', Sign';
        'c': Result := Result + ', Certify';
        'e': Result := Result + ', Encrypt';
        'a': Result := Result + ', Authenticate';
      end;
  Delete(Result, 1, 2);
end;

function FormatFingerprint(const AFpr: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AFpr) do
  begin
    Result := Result + AFpr[I];
    if (I mod 4 = 0) and (I < Length(AFpr)) then
      Result := Result + IfThen(I mod 20 = 0, '  ', ' ');
  end;
end;

{ ---- Key Properties ---------------------------------------------------------- }

const
  PQ_NOTE = 'Your key is now post-quantum. Messages encrypted to it use Kyber together with a classic ' +
    'elliptic curve, so they stay safe even against a future quantum computer.' + sLineBreak + sLineBreak +
    'Good to know:' + sLineBreak +
    '- People can encrypt to this key with CryptLok 0.3 or newer, or with GnuPG 2.5 or newer. Older programs ' +
    '(for example Gpg4win 4.x, which has GnuPG 2.4) cannot use it; give them an RSA key as well if needed.' + sLineBreak +
    '- Signatures made with this key are classic (Ed25519/Ed448); post-quantum signatures come later.' + sLineBreak +
    '- It is a LibrePGP key, not an RFC 9580 (version 6) key such as those from Proton or PGPony.';


type
  TPropsDialog = class(TOPDForm)
  private
    FEngine: IKeyEngine;
    FKey: TKeyInfo;
    procedure ChangePassClick(Sender: TObject);
    procedure AddEmailClick(Sender: TObject);
    procedure UidOpClick(Sender: TObject);
    procedure AddPhotoClick(Sender: TObject);
    procedure EditPrefsClick(Sender: TObject);
    procedure SignaturesClick(Sender: TObject);
    procedure AddPqClick(Sender: TObject);
    procedure RemovePhotoClick(Sender: TObject);
    procedure ShowPhotos;
  private
    FPhotoImg: TImage;
    FPhotoAdd, FPhotoRemove: TButton;
    FPhotos: TArray<TBytes>;
    FPrefs: TKeyPrefs;
    FUids: TListView;
    FPrimaryIdx: Integer;
    FMakePrimary, FRevokeUid: TButton;    { act on the User IDs tab; hidden on the Subkeys tab }
    procedure ListTabChange(Sender: TObject);
  public
    Changed: Boolean;
    Trust: TComboBox;
    constructor CreateDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo);
  end;

{ shows the first photo ID of the key instead of the key picture, and enables Remove }
procedure TPropsDialog.ShowPhotos;
var
  MS: TMemoryStream;
  J: TJPEGImage;
begin
  if (Length(FPhotos) > 0) and (Length(FPhotos[0]) > 100) then
  begin
    MS := TMemoryStream.Create;
    J := TJPEGImage.Create;
    try
      try
        MS.WriteBuffer(FPhotos[0][0], Length(FPhotos[0]));
        MS.Position := 0;
        J.LoadFromStream(MS);
        FPhotoImg.SetBounds(15, 14, 120, 144);
        FPhotoImg.Stretch := True;
        FPhotoImg.Proportional := True;
        FPhotoImg.Picture.Assign(J);
      except
        { a photo that cannot be shown keeps the key picture }
      end;
    finally
      J.Free;
      MS.Free;
    end;
  end;
  if FPhotoRemove <> nil then
    FPhotoRemove.Enabled := Length(FPhotos) > 0;
  if FPhotoAdd <> nil then
    FPhotoAdd.Caption := IfThen(Length(FPhotos) > 0, 'Change...', 'Add Photo...');
end;

procedure TPropsDialog.ListTabChange(Sender: TObject);
begin
  if FMakePrimary <> nil then
  begin
    FMakePrimary.Visible := TPageControl(Sender).ActivePageIndex = 0;
    FRevokeUid.Visible := FMakePrimary.Visible;
  end;
end;

{ Adds a Kyber encryption subkey to one of your own keys: your fingerprint and the signatures on your key stay
  the same, and senders with CryptLok 0.3+ / GnuPG 2.5+ encrypt to the new quantum-safe subkey. }
procedure TPropsDialog.AddPqClick(Sender: TObject);
var
  F: TOPDForm;
  L: TLabel;
  Cb: TComboBox;
  B: TButton;
  Strong: Boolean;
  Pass: TBytes;
  Res: TCryptoResult;
  Days, Tries: Integer;
begin
  F := TOPDForm.CreateNew(Self);
  try
    F.Caption := 'Add Post-Quantum Key';
    F.BorderStyle := bsDialog;
    F.Position := poOwnerFormCenter;
    F.ClientWidth := 470;
    F.ClientHeight := 210;
    F.Font.Name := 'Segoe UI';
    F.Font.Size := 9;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(16, 12, 440, 80); L.AutoSize := False; L.WordWrap := True;
    L.Caption := 'Adds a quantum-safe encryption part (Kyber, combined with a classic curve) to ' + FKey.DisplayName +
      '. Your fingerprint and the signatures on your key stay the same. People who use CryptLok 0.3+ or ' +
      'GnuPG 2.5+ will encrypt to the new part; older programs keep using your current encryption key.';
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(16, 104, 80, 18); L.Caption := 'Strength';
    Cb := TComboBox.Create(F); Cb.Parent := F; Cb.Style := csDropDownList; Cb.SetBounds(100, 100, 350, 24);
    Cb.Items.AddStrings(['Standard: Kyber-768 + X25519', 'Strong: Kyber-1024 + X448']);
    Cb.ItemIndex := 0;
    B := TButton.Create(F); B.Parent := F; B.SetBounds(274, 166, 84, 28); B.Caption := 'Add';
    B.ModalResult := mrOk; B.Default := True;
    B := TButton.Create(F); B.Parent := F; B.SetBounds(366, 166, 84, 28); B.Caption := 'Cancel';
    B.ModalResult := mrCancel; B.Cancel := True;
    if F.ShowModal <> mrOk then Exit;
    Strong := Cb.ItemIndex = 1;
  finally
    F.Free;
  end;
  { the new part expires with the key }
  if FKey.Expires > 0 then Days := Max(1, Trunc(FKey.Expires - Now)) else Days := 0;
  Tries := 0;
  repeat
    Inc(Tries);
    if AskPassphrase(Self, FKey.DisplayName + ' ' + FKey.ShortId,
      'Enter the passphrase of this key to add the post-quantum part.', False, Pass) <> mrOk then Exit;
    try
      RunBusy(procedure begin Res := FEngine.AddEncryptionSubkey(FKey.Fingerprint, PQ_SUBKEY[Strong], Days, Pass); end);
    finally
      WipeBytes(Pass);
    end;
    if Res.WrongPassphrase then
      Application.MessageBox('That passphrase was not accepted.', 'Passphrase', MB_OK or MB_ICONWARNING);
  until (not Res.WrongPassphrase) or (Tries >= 3);
  if not Res.Ok then
  begin
    if not Res.WrongPassphrase then
      Application.MessageBox(PChar('The post-quantum part was not added: ' + Res.Error), 'Add Post-Quantum Key',
        MB_OK or MB_ICONWARNING);
    Exit;
  end;
  Changed := True;
  Application.MessageBox(PChar(PQ_NOTE), 'Add Post-Quantum Key', MB_OK or MB_ICONINFORMATION);
  ModalResult := mrCancel;          { closes, so the key is read fresh next time }
end;

procedure TPropsDialog.SignaturesClick(Sender: TObject);
begin
  ShowCertifications(Self, FEngine, FKey);
end;

procedure TPropsDialog.EditPrefsClick(Sender: TObject);
begin
  if EditKeyPreferences(Self, FEngine, FKey, FPrefs) then
  begin
    Changed := True;
    ModalResult := mrCancel;       { the window closes so the new values are read fresh next time }
  end;
end;

procedure TPropsDialog.AddPhotoClick(Sender: TObject);
var
  D: TOpenDialog;
  Jpeg: TBytes;
  Err, Tmp: string;
  Pass: TBytes;
  R: TCryptoResult;
  I: Integer;
  Prefs: TKeyPrefs;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Choose a picture for the photo ID';
    D.Filter := 'Pictures (*.jpg;*.jpeg;*.png;*.bmp;*.gif)|*.jpg;*.jpeg;*.png;*.bmp;*.gif|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    if not PrepareJpeg(D.FileName, Jpeg, Err) then
    begin
      Application.MessageBox(PChar(Err), 'Photo ID', MB_OK or MB_ICONWARNING);
      Exit;
    end;
  finally
    D.Free;
  end;
  if Length(FPhotos) > 0 then
    if Application.MessageBox('This key already has a photo. Replace it?', 'Photo ID',
      MB_YESNO or MB_ICONQUESTION) <> IDYES then Exit;
  if AskPassphrase(Self, FKey.DisplayName + ' ' + FKey.ShortId,
    'Enter the passphrase of this key to add the photo.', False, Pass) <> mrOk then Exit;
  Tmp := TPath.Combine(TPath.GetTempPath, 'clk-photo-' + IntToStr(GetTickCount) + '.jpg');
  try
    TFile.WriteAllBytes(Tmp, Jpeg);
    try
      RunBusy(procedure begin R := FEngine.AddPhotoId(FKey.Fingerprint, Tmp, Pass); end);
    finally
      WipeBytes(Pass);
    end;
  finally
    SecureDeleteFile(Tmp);
  end;
  if not R.Ok then
  begin
    Application.MessageBox(PChar(IfThen(R.WrongPassphrase, 'That passphrase is not correct.', R.Error)),
      'Photo ID', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  { a replaced photo: remove the older ones, newest stays }
  if Length(FPhotos) > 0 then
    for I := Length(FPhotos) - 1 downto 0 do
      FEngine.RemovePhotoId(FKey.Fingerprint, I);
  FEngine.ReadKeyExtras(FKey.Fingerprint, FPhotos, Prefs);
  Changed := True;
  ShowPhotos;
end;

procedure TPropsDialog.RemovePhotoClick(Sender: TObject);
var
  R: TCryptoResult;
  I: Integer;
  Prefs: TKeyPrefs;
begin
  if Length(FPhotos) = 0 then Exit;
  if Application.MessageBox('Remove the photo from this key?', 'Photo ID', MB_YESNO or MB_ICONQUESTION) <> IDYES then Exit;
  for I := Length(FPhotos) - 1 downto 0 do
  begin
    R := FEngine.RemovePhotoId(FKey.Fingerprint, I);
    if not R.Ok then
    begin
      Application.MessageBox(PChar(R.Error), 'Photo ID', MB_OK or MB_ICONWARNING);
      Break;
    end;
  end;
  FEngine.ReadKeyExtras(FKey.Fingerprint, FPhotos, Prefs);
  Changed := True;
  if Length(FPhotos) = 0 then
  begin
    FPhotoImg.SetBounds(11, 46, 128, 108);
    FPhotoImg.Stretch := False;
    FPhotoImg.Picture.Graphic := LoadPng('IC_BAND_64');
  end;
  ShowPhotos;
end;

function RunChangePassphrase(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean; forward;
function RunAddEmail(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean; forward;
function RunUidOp(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo;
  const AUid: string; ARevoke: Boolean): Boolean; forward;

constructor TPropsDialog.CreateDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo);
var
  Banner, Side: TPanel;
  Img: TImage;
  L: TLabel;
  LV: TListView;
  Col: TListColumn;
  B: TButton;
  I, Y: Integer;
  LI: TListItem;
  Fpr: TMemo;
  Prefs: TKeyPrefs;

  function Lbl(AParent: TWinControl; const ACap: string; AX, AY, AW: Integer; ABold: Boolean = False;
    AAlign: TAlignment = taLeftJustify): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := AParent;
    Result.AutoSize := False;
    Result.SetBounds(AX, AY, AW, 18);
    Result.Caption := ACap;
    Result.Alignment := AAlign;
    if ABold then Result.Font.Style := [fsBold];
    Result.Transparent := True;
  end;

  { first three items of a "a, b, c, d" list, then "..." }
  function ShortList(const S: string): string;
  var
    I, N: Integer;
  begin
    N := 0;
    for I := 1 to Length(S) do
      if S[I] = ',' then
      begin
        Inc(N);
        if N = 3 then
          Exit(Copy(S, 1, I - 1) + ', ...');
      end;
    Result := S;
  end;

  { a bold caption and its value on a tab page: left column at 4, right column at 256 }
  procedure Row(AParent: TWinControl; const ACaption, AValue: string; AX, AY: Integer);
  var
    V: TLabel;
  begin
    Lbl(AParent, ACaption, AX, AY, 78, True, taRightJustify);
    V := Lbl(AParent, AValue, AX + 86, AY, 160);
    V.EllipsisPosition := epEndEllipsis;
    V.ShowHint := True;
    V.Hint := AValue;
  end;

  function Sheet(APc: TPageControl; const ACaption: string): TTabSheet;
  begin
    Result := TTabSheet.Create(Self);
    Result.PageControl := APc;
    Result.Caption := ACaption;
  end;

  function NewList(AParent: TWinControl): TListView;
  begin
    Result := TListView.Create(Self);
    Result.Parent := AParent;
    Result.Align := alClient;
    Result.ViewStyle := vsReport;
    Result.ReadOnly := True;
    Result.RowSelect := True;
  end;

var
  Pc, PcTop: TPageControl;
  Tab: TTabSheet;
begin
  inherited CreateNew(AOwner);
  FEngine := AEngine;
  FKey := AKey;
  Caption := AKey.DisplayName + ' - Key Properties';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 700;
  ClientHeight := 492;
  Color := clWhite;
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  { left picture panel }
  Side := TPanel.Create(Self);
  Side.Parent := Self;
  Side.SetBounds(12, 12, 150, 200);
  Side.BevelOuter := bvNone;
  Side.ParentBackground := False;
  Side.Color := BANNER_COLOR;
  Img := TImage.Create(Self);
  Img.Parent := Side;
  Img.SetBounds(11, 46, 128, 108);
  Img.Center := True;
  Img.Picture.Graphic := LoadPng('IC_BAND_64');
  FPhotoImg := Img;
  if AKey.HasSecret then
  begin
    FPhotoAdd := TButton.Create(Self);
    FPhotoAdd.Parent := Side;
    FPhotoAdd.SetBounds(6, 170, 82, 24);
    FPhotoAdd.Caption := 'Add Photo...';
    FPhotoAdd.OnClick := AddPhotoClick;
    FPhotoRemove := TButton.Create(Self);
    FPhotoRemove.Parent := Side;
    FPhotoRemove.SetBounds(92, 170, 52, 24);
    FPhotoRemove.Caption := 'Remove';
    FPhotoRemove.OnClick := RemovePhotoClick;
    FPhotoRemove.Enabled := False;
  end;

  { name banner }
  Banner := TPanel.Create(Self);
  Banner.Parent := Self;
  Banner.SetBounds(172, 12, 516, 44);
  Banner.BevelOuter := bvNone;
  Banner.ParentBackground := False;
  Banner.Color := BANNER_COLOR;
  L := Lbl(Banner, AKey.DisplayName, 16, 12, 330, True);
  L.Font.Size := 12;
  L.Font.Color := clWhite;
  L := Lbl(Banner, AKey.DisplayEmail, 250, 14, 256, False, taRightJustify);
  L.Font.Color := clWhite;

  { three tabs beside the picture: General, Validity, Preferences }
  Pc := TPageControl.Create(Self);
  Pc.Parent := Self;
  Pc.SetBounds(172, 62, 516, 150);

  Tab := Sheet(Pc, 'General');
  Row(Tab, 'Key ID', AKey.ShortId, 4, 12);
  Row(Tab, 'Size', AKey.SizeText, 4, 38);
  Row(Tab, 'Type', AKey.AlgoName + IfThen(AKey.HasSecret, ' (key pair)', ' (public key)'), 4, 64);
  Row(Tab, 'Status', IfThen(AKey.Revoked, 'Revoked', IfThen(AKey.Expired, 'Expired', 'Valid')), 256, 12);
  Row(Tab, 'Key Usage', UsageText(AKey.Caps), 256, 38);
  Row(Tab, 'Quantum-safe', IfThen(AKey.IsPostQuantum, 'Yes, ' + AKey.PostQuantumText, 'No'), 4, 90);
  if AKey.HasSecret and not AKey.IsPostQuantum and not AKey.Revoked and not AKey.Expired then
  begin
    B := TButton.Create(Self);
    B.Parent := Tab;
    B.SetBounds(296, 90, 170, 26);
    B.Caption := 'Add Post-Quantum Key...';
    B.OnClick := AddPqClick;
  end;

  { preferences and photo, read from the key itself }
  FEngine.ReadKeyExtras(AKey.Fingerprint, FPhotos, Prefs);
  FPrefs := Prefs;
  if AKey.HasSecret and Prefs.Valid then
  begin
    B := TButton.Create(Self);
    B.Parent := Tab;
    B.SetBounds(296, 62, 170, 26);
    B.Caption := 'Edit Preferences...';
    B.OnClick := EditPrefsClick;
  end;

  Tab := Sheet(Pc, 'Validity');
  Row(Tab, 'Keyserver', IfThen(Prefs.Valid and (Prefs.Keyserver <> ''), Prefs.Keyserver, 'None'), 4, 12);
  Row(Tab, 'Created', Fmt(AKey.Created, ''), 4, 38);
  Lbl(Tab, 'Trust', 4, 64, 78, True, taRightJustify);
  Trust := TComboBox.Create(Self);
  Trust.Parent := Tab;
  Trust.Style := csDropDownList;
  Trust.SetBounds(90, 61, 130, 24);
  Trust.Items.AddStrings(['Untrusted', 'None', 'Marginal', 'Complete', 'Implicit']);
  case AKey.OwnerTrust of
    'n': Trust.ItemIndex := 0;
    'm': Trust.ItemIndex := 2;
    'f': Trust.ItemIndex := 3;
    'u': Trust.ItemIndex := 4;
  else
    Trust.ItemIndex := 1;
  end;
  Row(Tab, 'Expires', Fmt(AKey.Expires, 'Never'), 256, 12);
  Row(Tab, 'Enabled', IfThen(AKey.Disabled, 'No', 'Yes'), 256, 38);
  Row(Tab, 'Verified', IfThen(AKey.IsVerified, 'Yes', 'No'), 256, 64);

  Tab := Sheet(Pc, 'Preferences');
  if Prefs.Valid then
  begin
    Row(Tab, 'Cipher', ShortList(Prefs.Cipher), 4, 12);
    Row(Tab, 'Hash', ShortList(Prefs.Hash), 4, 38);
    Row(Tab, 'Encoding', IfThen(Prefs.Encoding = '', 'Default', Prefs.Encoding), 256, 12);
    Row(Tab, 'Compression', ShortList(Prefs.Compression), 256, 38);
  end
  else
    Lbl(Tab, 'This key does not list any preferred algorithms.', 12, 12, 480);
  Pc.ActivePageIndex := 0;
  PcTop := Pc;
  ShowPhotos;

  { fingerprint }
  Lbl(Self, 'Fingerprint', 12, 222, 200, True);
  Fpr := TMemo.Create(Self);
  Fpr.Parent := Self;
  Fpr.SetBounds(12, 243, 590, 22);
  Fpr.ReadOnly := True;
  Fpr.BorderStyle := bsNone;
  Fpr.Color := PANEL_COLOR;
  Fpr.Font.Name := 'Consolas';
  Fpr.WordWrap := False;
  Fpr.Text := FormatFingerprint(AKey.Fingerprint);
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(612, 240, 76, 26);
  B.Caption := 'Copy';
  B.Tag := 0;
  B.OnClick := TNotifyEvent(nil);
  { copy handled through an anonymous-free approach: store text in Hint }
  B.Hint := AKey.Fingerprint;
  B.ShowHint := False;

  { user IDs and subkeys, as two tabs }
  Pc := TPageControl.Create(Self);
  Pc.Parent := Self;
  Pc.SetBounds(12, 280, 676, 160);
  Pc.OnChange := ListTabChange;

  Tab := Sheet(Pc, 'User IDs');
  FPrimaryIdx := -1;
  for I := 0 to High(AKey.UserIds) do
    if not AKey.UserIds[I].IsPhoto and not AKey.UserIds[I].Revoked then
    begin
      FPrimaryIdx := I;  { gpg treats the first usable user ID as the primary one }
      Break;
    end;
  LV := NewList(Tab);
  FUids := LV;
  Col := LV.Columns.Add; Col.Caption := 'Name'; Col.Width := 250;
  Col := LV.Columns.Add; Col.Caption := 'Email'; Col.Width := 250;
  Col := LV.Columns.Add; Col.Caption := 'Status'; Col.Width := 140;
  for I := 0 to High(AKey.UserIds) do
  begin
    LI := LV.Items.Add;
    if AKey.UserIds[I].IsPhoto then
    begin
      LI.Caption := '(photo ID)';
      LI.SubItems.Add('');
    end
    else
    begin
      LI.Caption := AKey.UserIds[I].Name;
      LI.SubItems.Add(AKey.UserIds[I].Email);
    end;
    LI.Data := Pointer(I);
    LI.SubItems.Add(IfThen(AKey.UserIds[I].Revoked, 'Revoked',
      IfThen(CharInSet(AKey.UserIds[I].Validity, ['m', 'f', 'u']), 'Verified', 'Not verified')) +
      IfThen(I = FPrimaryIdx, ', primary', ''));
  end;

  Tab := Sheet(Pc, 'Subkeys');
  LV := NewList(Tab);
  Col := LV.Columns.Add; Col.Caption := 'ID'; Col.Width := 100;
  Col := LV.Columns.Add; Col.Caption := 'Valid from'; Col.Width := 100;
  Col := LV.Columns.Add; Col.Caption := 'Expires'; Col.Width := 100;
  Col := LV.Columns.Add; Col.Caption := 'Size'; Col.Width := 70;
  Col := LV.Columns.Add; Col.Caption := 'Type'; Col.Width := 80;
  Col := LV.Columns.Add; Col.Caption := 'Usage'; Col.Width := 190;
  for I := 0 to High(AKey.SubKeys) do
  begin
    LI := LV.Items.Add;
    LI.Caption := '0x' + Copy(AKey.SubKeys[I].KeyId, Length(AKey.SubKeys[I].KeyId) - 7, 8);
    LI.SubItems.Add(Fmt(AKey.SubKeys[I].Created, ''));
    LI.SubItems.Add(Fmt(AKey.SubKeys[I].Expires, 'Never'));
    LI.SubItems.Add(IntToStr(AKey.SubKeys[I].Bits));
    LI.SubItems.Add(AlgoLabel(AKey.SubKeys[I].Algo));
    LI.SubItems.Add(UsageText(AKey.SubKeys[I].Caps) +
      IfThen(AKey.SubKeys[I].Revoked, ' (revoked)', IfThen(AKey.SubKeys[I].Expired, ' (expired)', '')));
  end;
  Pc.ActivePageIndex := 0;

  { Make Primary / Revoke sit on the tab row, right of the tabs (created after the tabs so they are drawn
    over the empty part of the tab strip) }
  if AKey.HasSecret then
  begin
    FMakePrimary := TButton.Create(Self);
    FMakePrimary.Parent := Self;
    FMakePrimary.SetBounds(508, 276, 94, 24);
    FMakePrimary.Caption := 'Make Primary';
    FMakePrimary.Tag := 0;
    FMakePrimary.OnClick := UidOpClick;
    FRevokeUid := TButton.Create(Self);
    FRevokeUid.Parent := Self;
    FRevokeUid.SetBounds(610, 276, 78, 24);
    FRevokeUid.Caption := 'Revoke';
    FRevokeUid.Tag := 1;
    FRevokeUid.OnClick := UidOpClick;
  end;
  { testing aid: /proptab:N opens upper tab N, /listtab:N lower tab N }
  for I := 1 to ParamCount do
    if StartsText('/proptab:', ParamStr(I)) then
      PcTop.ActivePageIndex := StrToIntDef(Copy(ParamStr(I), 10, 2), 0)
    else if StartsText('/listtab:', ParamStr(I)) then
    begin
      Pc.ActivePageIndex := StrToIntDef(Copy(ParamStr(I), 10, 2), 0);
      ListTabChange(Pc);
    end;

  Y := 452;
  if AKey.HasSecret then
  begin
    B := TButton.Create(Self);
    B.Parent := Self;
    B.SetBounds(12, Y, 150, 28);
    B.Caption := 'Change Passphrase...';
    B.OnClick := ChangePassClick;
    B := TButton.Create(Self);
    B.Parent := Self;
    B.SetBounds(170, Y, 150, 28);
    B.Caption := 'Add Email Address...';
    B.OnClick := AddEmailClick;
  end;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(IfThen(AKey.HasSecret, 328, 12), Y, 120, 28);
  B.Caption := 'Signatures...';
  B.OnClick := SignaturesClick;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(512, Y, 84, 28);
  B.Caption := 'OK';
  B.ModalResult := mrOk;
  B.Default := True;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(604, Y, 84, 28);
  B.Caption := 'Cancel';
  B.ModalResult := mrCancel;
  B.Cancel := True;
end;

type
  TCopyHelper = class
    class procedure Click(Sender: TObject);
  end;

class procedure TCopyHelper.Click(Sender: TObject);
begin
  Clipboard.AsText := TButton(Sender).Hint;
end;

function ShowKeyProperties(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean;
var
  D: TPropsDialog;
  Old, New: Char;
  Res: TCryptoResult;
  I: Integer;
begin
  Result := False;
  D := TPropsDialog.CreateDialog(AOwner, AEngine, AKey);
  try
    { wire the Copy button }
    for I := 0 to D.ControlCount - 1 do
      if (D.Controls[I] is TButton) and (TButton(D.Controls[I]).Caption = 'Copy') then
        TButton(D.Controls[I]).OnClick := TCopyHelper.Click;
    if D.ShowModal <> mrOk then
    begin
      Result := D.Changed;  { e.g. an email address or a photo was added }
      Exit;
    end;
    if D.Changed then Result := True;
    Old := AKey.OwnerTrust;
    case D.Trust.ItemIndex of
      0: New := 'n';
      2: New := 'm';
      3: New := 'f';
      4: New := 'u';
    else
      New := '-';
    end;
    if (New <> Old) and not ((New = '-') and CharInSet(Old, ['-', 'o', 'q'])) then
    begin
      Res := AEngine.SetOwnerTrust(AKey.Fingerprint, New);
      if Res.Ok then
        Result := True
      else
        Application.MessageBox(PChar('The trust level was not changed: ' + Res.Error), 'Key Properties',
          MB_OK or MB_ICONWARNING);
    end;
  finally
    D.Free;
  end;
end;

{ ---- Signatures on a key ------------------------------------------------------------- }

procedure ShowCertifications(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo);
var
  F: TOPDForm;
  LV: TListView;
  LI: TListItem;
  B: TButton;
  L: TLabel;
  Certs: TArray<TCertInfo>;
  C: TCertInfo;
  N: Integer;
begin
  Certs := AEngine.ListCertifications(AKey.Fingerprint);
  F := TOPDForm.CreateNew(AOwner);
  try
    F.Caption := 'Signatures on ' + AKey.DisplayName;
    F.Position := poScreenCenter;
    F.BorderStyle := bsSizeable;
    F.ClientWidth := 760;
    F.ClientHeight := 380;
    F.Constraints.MinWidth := 520;
    F.Constraints.MinHeight := 240;
    F.Font.Name := UiFontName;
    F.Font.Size := 9;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(12, 10, 736, 36);
    L.Anchors := [akLeft, akTop, akRight]; L.AutoSize := False; L.WordWrap := True;
    L.Transparent := False; L.Color := clBtnFace;
    L.Caption := 'Everyone who has signed (certified) a user ID of this key, including the key''s own signature. ' +
      'A signature from you means you vouched for this key.';
    LV := TListView.Create(F); LV.Parent := F; LV.SetBounds(12, 52, 736, 274);
    LV.Anchors := [akLeft, akTop, akRight, akBottom];
    LV.ViewStyle := vsReport; LV.ReadOnly := True; LV.RowSelect := True;
    with LV.Columns.Add do begin Caption := 'Signed by'; Width := 240; end;
    with LV.Columns.Add do begin Caption := 'Key ID'; Width := 90; end;
    with LV.Columns.Add do begin Caption := 'User ID signed'; Width := 200; end;
    with LV.Columns.Add do begin Caption := 'Date'; Width := 80; end;
    with LV.Columns.Add do begin Caption := 'Kind'; Width := 110; end;
    N := 0;
    for C in Certs do
    begin
      LI := LV.Items.Add;
      if C.Self then LI.Caption := 'The key itself (self-signature)'
      else if C.SignerName <> '' then LI.Caption := C.SignerName
      else LI.Caption := 'Unknown key (not in your keyring)';
      LI.SubItems.Add('0x' + Copy(C.SignerKeyId, Length(C.SignerKeyId) - 7, 8));
      LI.SubItems.Add(C.UserId);
      LI.SubItems.Add(Fmt(C.Created, ''));
      LI.SubItems.Add(IfThen(C.Revoked, 'Revoked',
        IfThen(C.LocalOnly, 'Local only', IfThen(C.Self, 'Self', 'Signature'))) +
        IfThen(C.Valid, '', ' (not checked)'));
      if not C.Self then Inc(N);
    end;
    if Length(Certs) = 0 then
      L.Caption := 'No signatures were found for this key.'
    else if N = 0 then
      L.Caption := L.Caption + sLineBreak + 'Nobody else has signed this key yet.';
    B := TButton.Create(F); B.Parent := F; B.SetBounds(664, 340, 84, 28); B.Anchors := [akRight, akBottom];
    B.Caption := 'Close'; B.ModalResult := mrOk; B.Default := True; B.Cancel := True;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

{ ---- Sign a key -------------------------------------------------------------------- }

function RunSignKeyDialog(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo): Boolean;
var
  Own: TList<TKeyInfo>;
  All: TKeyInfoArray;
  K: TKeyInfo;
  F: TOPDForm;
  L: TLabel;
  Cb: TComboBox;
  Local: TCheckBox;
  B: TButton;
  Pass: TBytes;
  Res: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
  Signer: TKeyInfo;
  LocalOnly: Boolean;
begin
  Result := False;
  Own := TList<TKeyInfo>.Create;
  try
    All := AEngine.ListKeys;
    for K in All do
      if K.HasSecret and not K.Revoked and not K.Expired and not K.Disabled and
         (Pos('c', LowerCase(K.Caps)) > 0) and not SameText(K.Fingerprint, AKey.Fingerprint) then
        Own.Add(K);
    if Own.Count = 0 then
    begin
      Application.MessageBox('You need a private key of your own (one that can certify) to sign someone else''s key. ' +
        'You cannot sign your own key this way.', 'Sign Key', MB_OK or MB_ICONINFORMATION);
      Exit;
    end;

    F := TOPDForm.CreateNew(AOwner);
    try
      F.Caption := 'Sign Key';
      F.Position := poScreenCenter;
      F.BorderStyle := bsDialog;
      F.ClientWidth := 520;
      F.ClientHeight := 320;
      F.Font.Name := UiFontName;
      F.Font.Size := 9;
      L := TLabel.Create(F); L.Parent := F; L.SetBounds(14, 12, 492, 20);
      L.Caption := 'Sign the key of ' + AKey.DisplayName + IfThen(AKey.DisplayEmail <> '', ' <' + AKey.DisplayEmail + '>', '');
      L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
      L := TLabel.Create(F); L.Parent := F; L.SetBounds(14, 36, 492, 18);
      L.Caption := 'Fingerprint:'; L.Transparent := False; L.Color := clBtnFace;
      L := TLabel.Create(F); L.Parent := F; L.SetBounds(14, 54, 492, 36);
      L.AutoSize := False; L.WordWrap := True; L.Font.Name := 'Consolas';
      L.Caption := FormatFingerprint(AKey.Fingerprint); L.Transparent := False; L.Color := clBtnFace;
      L := TLabel.Create(F); L.Parent := F; L.SetBounds(14, 96, 492, 62);
      L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
      L.Caption := 'Your signature says you checked that this key really belongs to this person, for example by ' +
        'comparing the fingerprint above with the one they gave you in person or by phone. Do not sign a key ' +
        'you have not verified.';
      L := TLabel.Create(F); L.Parent := F; L.SetBounds(14, 170, 492, 18);
      L.Caption := 'Sign with your key'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
      Cb := TComboBox.Create(F); Cb.Parent := F; Cb.SetBounds(14, 192, 492, 24); Cb.Style := csDropDownList;
      for K in Own do
        Cb.Items.Add(K.DisplayName + IfThen(K.DisplayEmail <> '', ' <' + K.DisplayEmail + '>', '') + '  ' + K.ShortId);
      Cb.ItemIndex := 0;
      Local := TCheckBox.Create(F); Local.Parent := F; Local.SetBounds(14, 228, 492, 20);
      Local.Caption := 'Keep this signature only in my keyring (it will not be exported with the key)';
      B := TButton.Create(F); B.Parent := F; B.SetBounds(330, 276, 84, 28);
      B.Caption := 'Sign'; B.ModalResult := mrOk; B.Default := True;
      B := TButton.Create(F); B.Parent := F; B.SetBounds(422, 276, 84, 28);
      B.Caption := 'Cancel'; B.ModalResult := mrCancel; B.Cancel := True;
      if F.ShowModal <> mrOk then Exit;
      Signer := Own[Cb.ItemIndex];
      LocalOnly := Local.Checked;
    finally
      F.Free;
    end;

    Tries := 0;
    repeat
      Inc(Tries);
      Mr := AskPassCached(AOwner, Signer.KeyId, Signer.DisplayName + ' ' + Signer.ShortId,
        'Enter the passphrase of your key to sign.', Pass);
      if Mr <> mrOk then Exit;
      try
        Res := AEngine.SignKey(AKey.Fingerprint, Signer.Fingerprint, LocalOnly, Pass);
        NotePassphrase(Signer.KeyId, Pass, Res.Ok, Res.WrongPassphrase);
      finally
        WipeBytes(Pass);
      end;
      if Res.WrongPassphrase then
        Application.MessageBox('That passphrase was not accepted.', 'Passphrase', MB_OK or MB_ICONWARNING);
    until (not Res.WrongPassphrase) or (Tries >= 3);
    if Res.Ok then
    begin
      Result := True;
      Application.MessageBox(PChar('The key of ' + AKey.DisplayName + ' is signed.'), 'Sign Key',
        MB_OK or MB_ICONINFORMATION);
    end
    else
      Application.MessageBox(PChar('Not signed: ' + Res.Error), 'Sign Key', MB_OK or MB_ICONWARNING);
  finally
    Own.Free;
  end;
end;

{ ---- Change Passphrase ------------------------------------------------------------ }

type
  TChangePassDialog = class(TOPDForm)
  public
    EOld, ENew, EConf: TEdit;
    Hide: TCheckBox;
    procedure HideClick(Sender: TObject);
    constructor CreateDialog(AOwner: TComponent; const AKeyLabel: string);
  end;

procedure TChangePassDialog.HideClick(Sender: TObject);
var
  C: Char;
begin
  if Hide.Checked then C := '*' else C := #0;
  EOld.PasswordChar := C;
  ENew.PasswordChar := C;
  EConf.PasswordChar := C;
end;

constructor TChangePassDialog.CreateDialog(AOwner: TComponent; const AKeyLabel: string);
var
  L: TLabel;
  B: TButton;

  function Add(const ACap: string; AY: Integer): TEdit;
  begin
    L := TLabel.Create(Self);
    L.Parent := Self;
    L.AutoSize := False;
    L.Alignment := taRightJustify;
    L.SetBounds(12, AY + 3, 140, 18);
    L.Caption := ACap;
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(160, AY, 270, 24);
    Result.PasswordChar := '*';
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'Change Passphrase';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 450;
  ClientHeight := 270;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(16, 12, 420, 36);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Caption := 'Change the passphrase that protects the private key:' + sLineBreak + AKeyLabel;
  L.Font.Style := [fsBold];
  EOld := Add('Current passphrase', 62);
  ENew := Add('New passphrase', 98);
  EConf := Add('Confirm new passphrase', 130);
  Hide := TCheckBox.Create(Self);
  Hide.Parent := Self;
  Hide.SetBounds(160, 164, 200, 18);
  Hide.Caption := 'Hide Typing';
  Hide.Checked := True;
  Hide.OnClick := HideClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(262, 218, 84, 28); B.Caption := 'OK';
  B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(354, 218, 84, 28); B.Caption := 'Cancel';
  B.ModalResult := mrCancel; B.Cancel := True;
  ActiveControl := EOld;
end;

function RunChangePassphrase(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean;
var
  D: TChangePassDialog;
  POld, PNew: TBytes;
  SOld, SNew, SConf: string;
  Res: TCryptoResult;
  Ok: Boolean;
begin
  Result := False;
  D := TChangePassDialog.CreateDialog(AOwner, AKey.DisplayName + '  ' + AKey.ShortId);
  try
    repeat
      Ok := True;
      if D.ShowModal <> mrOk then Exit;
      SOld := D.EOld.Text;
      SNew := D.ENew.Text;
      SConf := D.EConf.Text;
      try
        if SNew <> SConf then
        begin
          Application.MessageBox('The new passphrases do not match.', 'Change Passphrase', MB_OK or MB_ICONWARNING);
          Ok := False;
        end
        else if Length(SNew) < 8 then
        begin
          Application.MessageBox('Use a new passphrase of at least 8 characters.', 'Change Passphrase',
            MB_OK or MB_ICONWARNING);
          Ok := False;
        end
        else if SNew = SOld then
        begin
          Application.MessageBox('The new passphrase is the same as the current one.', 'Change Passphrase',
            MB_OK or MB_ICONWARNING);
          Ok := False;
        end;
        if Ok then
        begin
          POld := PassphraseToBytes(SOld);
          PNew := PassphraseToBytes(SNew);
        end;
      finally
        WipeString(SOld);
        WipeString(SNew);
        WipeString(SConf);
      end;
      if not Ok then
      begin
        D.EOld.Text := ''; D.ENew.Text := ''; D.EConf.Text := '';
      end;
    until Ok;
    D.EOld.Text := StringOfChar('x', 40); D.ENew.Text := StringOfChar('x', 40); D.EConf.Text := StringOfChar('x', 40);
    D.EOld.Text := ''; D.ENew.Text := ''; D.EConf.Text := '';
    try
      RunBusy(procedure begin Res := AEngine.ChangePassphrase(AKey.Fingerprint, POld, PNew); end);
      ForgetPass(AKey.KeyId);       { a cached copy of the old passphrase would no longer work }
    finally
      WipeBytes(POld);
      WipeBytes(PNew);
    end;
    if Res.Ok then
    begin
      Application.MessageBox('The passphrase was changed. Use the new one from now on.', 'Change Passphrase',
        MB_OK or MB_ICONINFORMATION);
      Result := True;
    end
    else
      Application.MessageBox(PChar('The passphrase was not changed: ' + Res.Error), 'Change Passphrase',
        MB_OK or MB_ICONWARNING);
  finally
    D.Free;
  end;
end;

procedure TPropsDialog.ChangePassClick(Sender: TObject);
begin
  RunChangePassphrase(Self, FEngine, FKey);
end;

procedure TPropsDialog.UidOpClick(Sender: TObject);
var
  Idx: Integer;
  U: TUserIdInfo;
begin
  if (FUids.Selected = nil) then
  begin
    Application.MessageBox('Select a user ID in the list first.', 'User IDs', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  Idx := Integer(FUids.Selected.Data);
  U := FKey.UserIds[Idx];
  if U.IsPhoto or U.Revoked then
  begin
    Application.MessageBox('That entry cannot be changed here.', 'User IDs', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  { gpg answers "General error" when asked to make the current primary user ID primary again }
  if (TButton(Sender).Tag = 0) and (Idx = FPrimaryIdx) then
  begin
    Application.MessageBox('That user ID is already the primary one. Select a different user ID to make it primary.',
      'User IDs', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  if TButton(Sender).Tag = 1 then
    if Application.MessageBox(PChar('Revoke "' + U.UserId + '"?' + sLineBreak + sLineBreak +
      'People who have your public key will see this address as revoked once they get the updated key. ' +
      'This cannot be undone.'), 'Revoke User ID', MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON2) <> IDYES then
      Exit;
  if RunUidOp(Self, FEngine, FKey, U.UserId, TButton(Sender).Tag = 1) then
  begin
    Changed := True;
    ModalResult := mrCancel;
  end;
end;

procedure TPropsDialog.AddEmailClick(Sender: TObject);
begin
  if RunAddEmail(Self, FEngine, FKey) then
  begin
    { the key changed: close so the list reloads }
    Changed := True;
    ModalResult := mrCancel;
  end;
end;

{ ---- Add Email Address ------------------------------------------------------------ }

type
  TAddEmailDialog = class(TOPDForm)
  public
    EName, EEmail: TEdit;
    constructor CreateDialog(AOwner: TComponent; const ADefaultName: string);
  end;

constructor TAddEmailDialog.CreateDialog(AOwner: TComponent; const ADefaultName: string);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(AOwner);
  Caption := 'New User Name';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 440;
  ClientHeight := 200;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 14, 400, 18);
  L.Caption := 'New name to add to key:';
  EName := TEdit.Create(Self); EName.Parent := Self; EName.SetBounds(16, 34, 408, 24);
  EName.Text := ADefaultName;
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 72, 400, 18);
  L.Caption := 'New email address to add to key:';
  EEmail := TEdit.Create(Self); EEmail.Parent := Self; EEmail.SetBounds(16, 92, 408, 24);
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(252, 152, 84, 28); B.Caption := 'OK';
  B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(344, 152, 84, 28); B.Caption := 'Cancel';
  B.ModalResult := mrCancel; B.Cancel := True;
  ActiveControl := EEmail;
end;

function RunAddEmail(AOwner: TComponent; const AEngine: IKeyEngine;
  const AKey: TKeyInfo): Boolean;
var
  D: TAddEmailDialog;
  Nm, Em: string;
  Pass: TBytes;
  Res: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
  Ok: Boolean;
begin
  Result := False;
  D := TAddEmailDialog.CreateDialog(AOwner, AKey.DisplayName);
  try
    repeat
      Ok := True;
      if D.ShowModal <> mrOk then Exit;
      Nm := Trim(D.EName.Text);
      Em := Trim(D.EEmail.Text);
      if (Nm = '') and (Em = '') then
      begin
        Application.MessageBox('Enter a name or an email address.', 'New User Name', MB_OK or MB_ICONWARNING);
        Ok := False;
      end
      else if (Em <> '') and ((Pos('@', Em) < 2) or (Pos('<', Em) > 0)) then
      begin
        Application.MessageBox('That does not look like an email address.', 'New User Name', MB_OK or MB_ICONWARNING);
        Ok := False;
      end;
    until Ok;
  finally
    D.Free;
  end;
  { adding a user ID signs it with the private key, so the passphrase is needed }
  Tries := 0;
  repeat
    Inc(Tries);
    Mr := AskPassphrase(AOwner, AKey.DisplayName + '  ' + AKey.ShortId,
      'Enter the passphrase of this key to add the new user name.', False, Pass);
    if Mr <> mrOk then Exit;
    try
      RunBusy(procedure begin Res := AEngine.AddUserId(AKey.Fingerprint, Nm, Em, Pass); end);
    finally
      WipeBytes(Pass);
    end;
    if Res.WrongPassphrase then
      Application.MessageBox('That passphrase was not accepted.', 'Passphrase', MB_OK or MB_ICONWARNING);
  until (not Res.WrongPassphrase) or (Tries >= 3);
  if Res.Ok then
  begin
    Application.MessageBox('The new user name was added to the key.', 'New User Name',
      MB_OK or MB_ICONINFORMATION);
    Result := True;
  end
  else
    Application.MessageBox(PChar('The user name was not added: ' + Res.Error), 'New User Name',
      MB_OK or MB_ICONWARNING);
end;

function RunUidOp(AOwner: TComponent; const AEngine: IKeyEngine; const AKey: TKeyInfo;
  const AUid: string; ARevoke: Boolean): Boolean;
var
  Pass: TBytes;
  Res: TCryptoResult;
  Tries: Integer;
  Mr: TModalResult;
begin
  Result := False;
  Tries := 0;
  repeat
    Inc(Tries);
    Mr := AskPassphrase(AOwner, AKey.DisplayName + '  ' + AKey.ShortId,
      'Enter the passphrase of this key to ' + IfThen(ARevoke, 'revoke', 'change') + ' the user name.',
      False, Pass);
    if Mr <> mrOk then Exit;
    try
      if ARevoke then
        RunBusy(procedure begin Res := AEngine.RevokeUserId(AKey.Fingerprint, AUid, Pass); end)
      else
        RunBusy(procedure begin Res := AEngine.SetPrimaryUserId(AKey.Fingerprint, AUid, Pass); end);
    finally
      WipeBytes(Pass);
    end;
    if Res.WrongPassphrase then
      Application.MessageBox('That passphrase was not accepted.', 'Passphrase', MB_OK or MB_ICONWARNING);
  until (not Res.WrongPassphrase) or (Tries >= 3);
  if Res.Ok then
  begin
    Application.MessageBox(PChar(IfThen(ARevoke, 'The user name was revoked.', 'That user name is now the primary one.')),
      'User IDs', MB_OK or MB_ICONINFORMATION);
    Result := True;
  end
  else
    Application.MessageBox(PChar('Not done: ' + Res.Error), 'User IDs', MB_OK or MB_ICONWARNING);
end;

{ ---- New Key Pair ---------------------------------------------------------------- }

type
  TNewKeyDialog = class(TOPDForm)
  public
    EName, EEmail, EPass, EPass2: TEdit;
    Bits, Expire: TComboBox;
    Hide: TCheckBox;
    procedure HideClick(Sender: TObject);
    constructor CreateDialog(AOwner: TComponent);
  end;

procedure TNewKeyDialog.HideClick(Sender: TObject);
var
  C: Char;
begin
  if Hide.Checked then C := '*' else C := #0;
  EPass.PasswordChar := C;
  EPass2.PasswordChar := C;
end;

constructor TNewKeyDialog.CreateDialog(AOwner: TComponent);
var
  L: TLabel;
  B: TButton;
  Y: Integer;

  function Add(const ACap: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.AutoSize := False;
    Result.Alignment := taRightJustify;
    Result.SetBounds(12, Y + 3, 130, 18);
    Result.Caption := ACap;
  end;

  function Edit: TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(152, Y, 290, 24);
  end;

begin
  inherited CreateNew(AOwner);
  Caption := 'New Key Pair';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 470;
  ClientHeight := 330;
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(16, 12, 440, 36);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Caption := 'Create a new key pair. Others use your public key to send you encrypted ' +
    'messages; your private key and its passphrase stay on this computer.';

  Y := 60;  Add('Full name');  EName := Edit;
  Y := 92;  Add('Email address');  EEmail := Edit;
  Y := 124; Add('Key type');
  Bits := TComboBox.Create(Self); Bits.Parent := Self; Bits.Style := csDropDownList;
  Bits.SetBounds(152, Y, 290, 24);
  Bits.Items.AddStrings(['RSA 2048 bits', 'RSA 3072 bits', 'RSA 4096 bits',
    'Post-quantum: Ed25519 + Kyber-768', 'Post-quantum (strong): Ed448 + Kyber-1024']);
  Bits.ItemIndex := 1;
  Y := 156; Add('Expires');
  Expire := TComboBox.Create(Self); Expire.Parent := Self; Expire.Style := csDropDownList;
  Expire.SetBounds(152, Y, 160, 24);
  Expire.Items.AddStrings(['Never', 'In 1 year', 'In 2 years', 'In 5 years']);
  Expire.ItemIndex := 0;
  Y := 192; Add('Passphrase');  EPass := Edit; EPass.PasswordChar := '*';
  Y := 224; Add('Confirm');  EPass2 := Edit; EPass2.PasswordChar := '*';
  Hide := TCheckBox.Create(Self);
  Hide.Parent := Self;
  Hide.SetBounds(152, 254, 200, 18);
  Hide.Caption := 'Hide Typing';
  Hide.Checked := True;
  Hide.OnClick := HideClick;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(286, 288, 84, 28); B.Caption := 'Create';
  B.ModalResult := mrNone; B.Default := True; B.Tag := 1;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(378, 288, 84, 28); B.Caption := 'Cancel';
  B.ModalResult := mrCancel; B.Cancel := True;
  ActiveControl := EName;
end;

function RunNewKeyDialog(AOwner: TComponent; const AEngine: IKeyEngine;
  out AFingerprint: string): Boolean;
var
  D: TNewKeyDialog;
  Pass: TBytes;
  Bits, Days, I: Integer;
  Res: TCryptoResult;
  Name, Email, P1, P2: string;
  Done, PQ, Strong: Boolean;
begin
  Result := False;
  AFingerprint := '';
  D := TNewKeyDialog.CreateDialog(AOwner);
  try
    { the Create button validates before closing }
    for I := 0 to D.ControlCount - 1 do
      if (D.Controls[I] is TButton) and (TButton(D.Controls[I]).Tag = 1) then
        TButton(D.Controls[I]).ModalResult := mrOk;
    repeat
      Done := True;
      if D.ShowModal <> mrOk then Exit;
      Name := Trim(D.EName.Text);
      Email := Trim(D.EEmail.Text);
      P1 := D.EPass.Text;
      P2 := D.EPass2.Text;
      try
        if (Name = '') and (Email = '') then
        begin
          Application.MessageBox('Enter a name or an email address.', 'New Key Pair', MB_OK or MB_ICONWARNING);
          Done := False;
        end
        else if (Email <> '') and ((Pos('@', Email) < 2) or (Pos('<', Email) > 0)) then
        begin
          Application.MessageBox('That does not look like an email address.', 'New Key Pair', MB_OK or MB_ICONWARNING);
          Done := False;
        end
        else if Length(P1) < 8 then
        begin
          Application.MessageBox('Use a passphrase of at least 8 characters. A longer phrase is stronger.',
            'New Key Pair', MB_OK or MB_ICONWARNING);
          Done := False;
        end
        else if P1 <> P2 then
        begin
          Application.MessageBox('The two passphrases do not match.', 'New Key Pair', MB_OK or MB_ICONWARNING);
          Done := False;
        end;
      finally
        WipeString(P2);
        if not Done then WipeString(P1);
      end;
      if not Done then
      begin
        D.EPass.Text := '';
        D.EPass2.Text := '';
      end;
    until Done;

    PQ := D.Bits.ItemIndex >= 3;
    Strong := D.Bits.ItemIndex = 4;
    case D.Bits.ItemIndex of
      0: Bits := 2048;
      2: Bits := 4096;
    else
      Bits := 3072;
    end;
    case D.Expire.ItemIndex of
      1: Days := 365;
      2: Days := 730;
      3: Days := 1825;
    else
      Days := 0;
    end;
    Pass := PassphraseToBytes(P1);
    WipeString(P1);
    D.EPass.Text := StringOfChar('x', 40);
    D.EPass.Text := '';
    D.EPass2.Text := '';
    try
      if PQ then
        RunBusy(procedure begin
          Res := AEngine.GenerateKeyAlgo(Name, Email, PQ_PRIMARY[Strong], PQ_SUBKEY[Strong], Days, Pass); end)
      else
        RunBusy(procedure begin Res := AEngine.GenerateKey(Name, Email, Bits, Days, Pass); end);
    finally
      WipeBytes(Pass);
    end;
    if Res.Ok then
    begin
      AFingerprint := Res.Text;
      Result := True;
      if PQ then
        Application.MessageBox(PChar(PQ_NOTE), 'New Key Pair', MB_OK or MB_ICONINFORMATION);
    end
    else
      Application.MessageBox(PChar('The key was not created: ' + Res.Error), 'New Key Pair',
        MB_OK or MB_ICONWARNING);
  finally
    D.Free;
  end;
end;

end.

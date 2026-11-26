unit OPD.RecipientDialog;

{ "Recipient Selection" (key source | key card | keys to add) and a small
  signing-key chooser. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.ImgList,
  OPD.Theme, OPD.Engine;

{ Keys that can be used to encrypt to (not expired/revoked/disabled, with an encryption key). }
function CanEncryptTo(const AKey: TKeyInfo): Boolean;

{ Lists the keyring; when nothing comes back it tells the user what gpg said. }
function ListKeysOrExplain(const AEngine: IKeyEngine): TKeyInfoArray;

{ Returns fingerprints of the chosen recipients. }
function SelectRecipients(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprints: TArray<string>): Boolean; overload;
{ The same, with the master keys already in "Keys to add" (shown as "(master key)", cannot be removed). }
function SelectRecipients(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprints: TArray<string>; const ALocked: TArray<string>): Boolean; overload;

{ Picks one of your private keys (skips the dialog when there is only one). }
function SelectSigner(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprint, ALabel: string): Boolean;

implementation

uses
  System.StrUtils, System.Math, Winapi.Windows;

function CanEncryptTo(const AKey: TKeyInfo): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AKey.Revoked or AKey.Expired or AKey.Disabled then Exit;
  if Pos('e', LowerCase(AKey.Caps)) > 0 then Exit(True);
  for I := 0 to High(AKey.SubKeys) do
    if (Pos('e', LowerCase(AKey.SubKeys[I].Caps)) > 0) and not AKey.SubKeys[I].Revoked and
       not AKey.SubKeys[I].Expired then
      Exit(True);
end;

type
  TRecipientDialog = class(TOPDForm)
  private
    FKeys: TKeyInfoArray;
    FChosen: TList<Integer>;
    FLocked: TList<Integer>;      { master keys: always included, cannot be removed }
    FFind: TEdit;
    FSource, FTarget: TListView;
    FImages: TImageList;
    FAdd, FRemove: TButton;
    FId, FType, FSize, FVerified, FCount: TLabel;
    procedure FillSource;
    procedure FillTarget;
    procedure FindChange(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure SelChange(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure ShowCard(AIndex: Integer);
    procedure AddIcon(const AName: string);
  public
    constructor CreateDialog(AOwner: TComponent; const AKeys: TKeyInfoArray);
    destructor Destroy; override;
    function Fingerprints: TArray<string>;
    procedure SetLocked(const AFingerprints: TArray<string>);
  end;

procedure TRecipientDialog.AddIcon(const AName: string);
var
  P: TPngImage;
  B: Vcl.Graphics.TBitmap;
begin
  P := LoadPng('IC_' + AName, 16);
  B := Vcl.Graphics.TBitmap.Create;
  try
    B.Assign(P);
    FImages.Add(B, nil);
  finally
    B.Free;
    P.Free;
  end;
end;

constructor TRecipientDialog.CreateDialog(AOwner: TComponent; const AKeys: TKeyInfoArray);
var
  L: TLabel;
  B: TButton;
  Img: TImage;
  Col: TListColumn;
  I: Integer;
begin
  inherited CreateNew(AOwner);
  FKeys := AKeys;
  FChosen := TList<Integer>.Create;
  FLocked := TList<Integer>.Create;
  Caption := 'Recipient Selection';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 800;
  ClientHeight := 470;
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  FImages := TImageList.Create(Self);
  FImages.ColorDepth := cd32Bit;
  FImages.Width := 16;
  FImages.Height := 16;
  AddIcon('KEYPAIR');
  AddIcon('PUBKEY');

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(16, 14, 80, 18);
  L.Caption := 'Find:';
  FFind := TEdit.Create(Self);
  FFind.Parent := Self;
  FFind.SetBounds(56, 11, 220, 24);
  FFind.OnChange := FindChange;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(16, 48, 200, 18);
  L.Font.Style := [fsBold];
  L.Caption := 'Key source';
  FSource := TListView.Create(Self);
  FSource.Parent := Self;
  FSource.SetBounds(16, 68, 290, 330);
  FSource.ViewStyle := vsReport;
  FSource.ReadOnly := True;
  FSource.RowSelect := True;
  FSource.SmallImages := FImages;
  FSource.MultiSelect := True;
  FSource.ShowColumnHeaders := False;
  Col := FSource.Columns.Add; Col.Width := 150;
  Col := FSource.Columns.Add; Col.Width := 120;
  FSource.OnSelectItem := SelChange;
  FSource.OnDblClick := AddClick;

  { key card }
  Img := TImage.Create(Self);
  Img.Parent := Self;
  Img.SetBounds(332, 62, 136, 116);
  Img.Center := True;
  Img.Picture.Graphic := LoadPng('IC_BAND_112');
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(332, 190, 40, 16); L.Caption := 'ID'; L.Alignment := taRightJustify; L.AutoSize := False;
  FId := TLabel.Create(Self); FId.Parent := Self; FId.SetBounds(380, 190, 110, 16);
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(332, 210, 40, 16); L.Caption := 'Verified'; L.Alignment := taRightJustify; L.AutoSize := False;
  FVerified := TLabel.Create(Self); FVerified.Parent := Self; FVerified.SetBounds(380, 210, 110, 16);
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(332, 230, 40, 16); L.Caption := 'Type'; L.Alignment := taRightJustify; L.AutoSize := False;
  FType := TLabel.Create(Self); FType.Parent := Self; FType.SetBounds(380, 230, 110, 16);
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(332, 250, 40, 16); L.Caption := 'Size'; L.Alignment := taRightJustify; L.AutoSize := False;
  FSize := TLabel.Create(Self); FSize.Parent := Self; FSize.SetBounds(380, 250, 110, 16);
  FCount := TLabel.Create(Self); FCount.Parent := Self; FCount.SetBounds(332, 380, 150, 16);
  FCount.Font.Color := clGrayText;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(332, 300, 150, 28); B.Caption := 'Add >';
  B.OnClick := AddClick; FAdd := B;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(332, 336, 150, 28); B.Caption := '< Remove';
  B.OnClick := RemoveClick; FRemove := B;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(500, 48, 200, 18);
  L.Font.Style := [fsBold];
  L.Caption := 'Keys to add';
  FTarget := TListView.Create(Self);
  FTarget.Parent := Self;
  FTarget.SetBounds(500, 68, 284, 330);
  FTarget.ViewStyle := vsReport;
  FTarget.ReadOnly := True;
  FTarget.RowSelect := True;
  FTarget.SmallImages := FImages;
  FTarget.MultiSelect := True;
  FTarget.ShowColumnHeaders := False;
  Col := FTarget.Columns.Add; Col.Width := 175;
  Col := FTarget.Columns.Add; Col.Width := 95;
  FTarget.OnDblClick := RemoveClick;

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(604, 428, 84, 28); B.Caption := 'OK';
  B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(700, 428, 84, 28); B.Caption := 'Cancel';
  B.ModalResult := mrCancel; B.Cancel := True;

  FillSource;
  FillTarget;
  I := 0;
  if I = 0 then ActiveControl := FFind;
end;

procedure TRecipientDialog.SetLocked(const AFingerprints: TArray<string>);
var
  F: string;
  I: Integer;
begin
  for F in AFingerprints do
    for I := 0 to High(FKeys) do
      if SameText(FKeys[I].Fingerprint, F) and CanEncryptTo(FKeys[I]) then
      begin
        if FChosen.IndexOf(I) < 0 then FChosen.Add(I);
        if FLocked.IndexOf(I) < 0 then FLocked.Add(I);
        Break;
      end;
  FillSource;
  FillTarget;
end;

destructor TRecipientDialog.Destroy;
begin
  FLocked.Free;
  FChosen.Free;
  inherited;
end;

procedure TRecipientDialog.FillSource;
var
  I: Integer;
  Q: string;
  LI: TListItem;
begin
  Q := LowerCase(Trim(FFind.Text));
  FSource.Items.BeginUpdate;
  try
    FSource.Items.Clear;
    for I := 0 to High(FKeys) do
    begin
      if not CanEncryptTo(FKeys[I]) then Continue;
      if FChosen.IndexOf(I) >= 0 then Continue;
      if (Q <> '') and (Pos(Q, LowerCase(FKeys[I].DisplayName + ' ' + FKeys[I].DisplayEmail +
         ' ' + FKeys[I].KeyId)) = 0) then Continue;
      LI := FSource.Items.Add;
      LI.Caption := FKeys[I].DisplayName + IfThen(FKeys[I].IsPostQuantum, '  (PQ)', '');
      LI.SubItems.Add(FKeys[I].DisplayEmail);
      LI.ImageIndex := IfThen(FKeys[I].HasSecret, 0, 1);
      LI.Data := Pointer(I);
    end;
  finally
    FSource.Items.EndUpdate;
  end;
end;

procedure TRecipientDialog.FillTarget;
var
  I: Integer;
  LI: TListItem;
begin
  FTarget.Items.Clear;
  for I in FChosen do
  begin
    LI := FTarget.Items.Add;
    LI.Caption := FKeys[I].DisplayName + IfThen(FKeys[I].IsPostQuantum, '  (PQ)', '') +
      IfThen(FLocked.IndexOf(I) >= 0, '  (master key)', '');
    LI.SubItems.Add(FKeys[I].DisplayEmail);
    LI.ImageIndex := IfThen(FKeys[I].HasSecret, 0, 1);
    LI.Data := Pointer(I);
  end;
  FCount.Caption := Format('(%d selected)', [FChosen.Count]);
end;

procedure TRecipientDialog.FindChange(Sender: TObject);
begin
  FillSource;
end;

procedure TRecipientDialog.AddClick(Sender: TObject);
var
  I: Integer;
  Idx: TList<Integer>;
begin
  Idx := TList<Integer>.Create;
  try
    for I := 0 to FSource.Items.Count - 1 do
      if FSource.Items[I].Selected then
        Idx.Add(Integer(FSource.Items[I].Data));
    for I in Idx do
      if FChosen.IndexOf(I) < 0 then FChosen.Add(I);
  finally
    Idx.Free;
  end;
  FillSource;
  FillTarget;
end;

procedure TRecipientDialog.RemoveClick(Sender: TObject);
var
  I: Integer;
  Idx: TList<Integer>;
begin
  Idx := TList<Integer>.Create;
  try
    for I := 0 to FTarget.Items.Count - 1 do
      if FTarget.Items[I].Selected then
        Idx.Add(Integer(FTarget.Items[I].Data));
    for I in Idx do
      if FLocked.IndexOf(I) < 0 then      { master keys stay }
        FChosen.Remove(I);
  finally
    Idx.Free;
  end;
  FillSource;
  FillTarget;
end;

procedure TRecipientDialog.ShowCard(AIndex: Integer);
begin
  if AIndex < 0 then
  begin
    FId.Caption := ''; FVerified.Caption := ''; FType.Caption := ''; FSize.Caption := '';
    Exit;
  end;
  FId.Caption := FKeys[AIndex].ShortId;
  FVerified.Caption := IfThen(FKeys[AIndex].IsVerified, 'Yes', 'No');
  FType.Caption := FKeys[AIndex].AlgoName + IfThen(FKeys[AIndex].IsPostQuantum, ' + Kyber', '');
  FSize.Caption := FKeys[AIndex].SizeText;
end;

procedure TRecipientDialog.SelChange(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected and (Item <> nil) then
    ShowCard(Integer(Item.Data));
end;

function TRecipientDialog.Fingerprints: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, FChosen.Count);
  for I := 0 to FChosen.Count - 1 do
    Result[I] := FKeys[FChosen[I]].Fingerprint;
end;

function ListKeysOrExplain(const AEngine: IKeyEngine): TKeyInfoArray;
var
  Msg: string;
begin
  Result := AEngine.ListKeys;
  if Length(Result) = 0 then
  begin
    Msg := 'GnuPG returned no keys from the keyring.';
    if AEngine.LastListError <> '' then
      Msg := Msg + sLineBreak + sLineBreak + 'gpg said:' + sLineBreak + AEngine.LastListError
    else
      Msg := Msg + sLineBreak + 'It reported no error. If you have not imported keys yet, use File > Import Keys.';
    Application.MessageBox(PChar(Msg), 'Keys', MB_OK or MB_ICONWARNING);
  end;
end;

function SelectRecipients(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprints: TArray<string>): Boolean;
begin
  Result := SelectRecipients(AOwner, AKeys, AFingerprints, nil);
end;

function SelectRecipients(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprints: TArray<string>; const ALocked: TArray<string>): Boolean;
var
  D: TRecipientDialog;
begin
  AFingerprints := nil;
  if Length(AKeys) = 0 then
    Exit(False);  { the caller already explained (ListKeysOrExplain) }
  D := TRecipientDialog.CreateDialog(AOwner, AKeys);
  try
    if Length(ALocked) > 0 then
      D.SetLocked(ALocked);
    Result := (D.ShowModal = mrOk) and (D.FChosen.Count > 0);
    if Result then
      AFingerprints := D.Fingerprints;
  finally
    D.Free;
  end;
end;

{ ---- signer chooser ------------------------------------------------------- }

type
  TSignerDialog = class(TOPDForm)
  public
    Combo: TComboBox;
    constructor CreateDialog(AOwner: TComponent);
  end;

constructor TSignerDialog.CreateDialog(AOwner: TComponent);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(AOwner);
  Caption := 'Choose Signing Key';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 420;
  ClientHeight := 130;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 16, 380, 18);
  L.Caption := 'Sign with which of your private keys?';
  Combo := TComboBox.Create(Self); Combo.Parent := Self; Combo.SetBounds(16, 40, 388, 24);
  Combo.Style := csDropDownList;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(228, 86, 84, 28); B.Caption := 'OK';
  B.ModalResult := mrOk; B.Default := True;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(320, 86, 84, 28); B.Caption := 'Cancel';
  B.ModalResult := mrCancel; B.Cancel := True;
end;

function SelectSigner(AOwner: TComponent; const AKeys: TKeyInfoArray;
  out AFingerprint, ALabel: string): Boolean;
var
  I: Integer;
  Idx: TList<Integer>;
  D: TSignerDialog;
begin
  Result := False;
  AFingerprint := '';
  ALabel := '';
  Idx := TList<Integer>.Create;
  try
    for I := 0 to High(AKeys) do
      if AKeys[I].HasSecret and not AKeys[I].Revoked and not AKeys[I].Expired and
         not AKeys[I].Disabled then
        Idx.Add(I);
    if Idx.Count = 0 then
    begin
      Application.MessageBox('You have no private key that can sign. Import one first.',
        'Signing key', MB_OK or MB_ICONINFORMATION);
      Exit;
    end;
    if Idx.Count = 1 then
    begin
      AFingerprint := AKeys[Idx[0]].Fingerprint;
      ALabel := AKeys[Idx[0]].DisplayName + ' ' + AKeys[Idx[0]].ShortId;
      Exit(True);
    end;
    D := TSignerDialog.CreateDialog(AOwner);
    try
      for I in Idx do
        D.Combo.Items.Add(AKeys[I].DisplayName + '  <' + AKeys[I].DisplayEmail + '>  ' + AKeys[I].ShortId);
      D.Combo.ItemIndex := 0;
      if D.ShowModal = mrOk then
      begin
        AFingerprint := AKeys[Idx[D.Combo.ItemIndex]].Fingerprint;
        ALabel := AKeys[Idx[D.Combo.ItemIndex]].DisplayName + ' ' + AKeys[Idx[D.Combo.ItemIndex]].ShortId;
        Result := True;
      end;
    finally
      D.Free;
    end;
  finally
    Idx.Free;
  end;
end;

end.

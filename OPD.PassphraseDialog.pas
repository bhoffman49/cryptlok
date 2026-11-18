unit OPD.PassphraseDialog;

{ Classic "Enter passphrase" dialog.  The passphrase leaves the dialog only as
  UTF-8 TBytes (caller wipes them); the edit control and the temporary string
  are overwritten before the dialog closes. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Graphics, OPD.Theme, OPD.Engine;

type
  TPassphraseDialog = class(TOPDForm)
  private
    FEdit: TEdit;
    FHide: TCheckBox;
    procedure HideClick(Sender: TObject);
  public
    constructor CreateDialog(AOwner: TComponent; const ATitle, AKeyLabel, AHint: string;
      AAllowSkip: Boolean; const ARecipients: TArray<string> = nil);
    function TakePassphrase: TBytes;
  end;

{ "Name <email> (RSA/2048)" for each key id a message or file was encrypted to; ids that are not in the keyring
  are listed as such. }
function DescribeRecipients(const AKeys: TKeyInfoArray; const AKeyIds: TArray<string>): TArray<string>;

{ The same dialog with the list "This object was encrypted to the following public key(s)" on top. }
function AskPassphraseFor(AOwner: TComponent; const AKeyLabel, AHint: string;
  const ARecipients: TArray<string>; out APass: TBytes): TModalResult;

{ Returns mrOk (APass filled), mrCancel (stop everything) or mrIgnore (skip this key). }
function AskPassphrase(AOwner: TComponent; const AKeyLabel, AHint: string;
  AAllowSkip: Boolean; out APass: TBytes): TModalResult;

implementation

uses
  System.StrUtils, Winapi.Windows;

function DescribeRecipients(const AKeys: TKeyInfoArray; const AKeyIds: TArray<string>): TArray<string>;
var
  Id, Line, Mail: string;
  K, S: Integer;
begin
  Result := nil;
  for Id in AKeyIds do
  begin
    Line := '';
    for K := 0 to High(AKeys) do
    begin
      if Line <> '' then Break;
      Mail := IfThen(AKeys[K].DisplayEmail = '', '', ' <' + AKeys[K].DisplayEmail + '>');
      for S := 0 to High(AKeys[K].SubKeys) do
        if SameText(AKeys[K].SubKeys[S].KeyId, Id) then
        begin
          Line := AKeys[K].DisplayName + Mail + ' (' + AlgoLabel(AKeys[K].SubKeys[S].Algo) + '/' +
            IntToStr(AKeys[K].SubKeys[S].Bits) + ')';
          Break;
        end;
      if (Line = '') and SameText(AKeys[K].KeyId, Id) then
        Line := AKeys[K].DisplayName + Mail + ' (' + AKeys[K].AlgoName + '/' + IntToStr(AKeys[K].Bits) + ')';
    end;
    if Line = '' then
      Line := 'Unknown key 0x' + Copy(Id, Length(Id) - 7, 8) + ' (not in your keyring)';
    Result := Result + [Line];
  end;
end;

constructor TPassphraseDialog.CreateDialog(AOwner: TComponent;
  const ATitle, AKeyLabel, AHint: string; AAllowSkip: Boolean; const ARecipients: TArray<string>);
var
  Img: TImage;
  L: TLabel;
  B: TButton;
  LB: TListBox;
  X, Off, H: Integer;
  Line: string;
begin
  inherited CreateNew(AOwner);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  ClientWidth := 440;
  Off := 0;
  if Length(ARecipients) > 0 then
  begin
    H := Length(ARecipients) * 17 + 8;
    if H < 56 then H := 56;
    if H > 110 then H := 110;
    Off := 22 + H + 10;
  end;
  ClientHeight := 204 + Off;
  Color := clBtnFace;
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  if Off > 0 then
  begin
    L := TLabel.Create(Self);
    L.Parent := Self;
    L.SetBounds(16, 12, 410, 16);
    L.Caption := 'This object was encrypted to the following public key(s):';
    LB := TListBox.Create(Self);
    LB.Parent := Self;
    LB.SetBounds(16, 32, 408, H);
    LB.Style := lbStandard;
    LB.ExtendedSelect := False;
    for Line in ARecipients do
      LB.Items.Add(Line);
  end;

  Img := TImage.Create(Self);
  Img.Parent := Self;
  Img.SetBounds(16, 16 + Off, 32, 32);
  Img.Stretch := True;
  Img.Proportional := True;
  Img.Picture.Graphic := LoadPng('IC_SEC_KEYS', 32);

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(64, 12 + Off, 360, 50);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Caption := AHint;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(64, 66 + Off, 360, 18);
  L.AutoSize := False;
  L.Font.Style := [fsBold];
  L.Caption := AKeyLabel;
  L.ShowHint := True;
  L.Hint := AKeyLabel;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(64, 90 + Off, 200, 16);
  L.Caption := 'Enter passphrase:';

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.SetBounds(64, 108 + Off, 360, 24);
  FEdit.PasswordChar := '*';
  FEdit.MaxLength := 255;

  FHide := TCheckBox.Create(Self);
  FHide.Parent := Self;
  FHide.SetBounds(64, 140 + Off, 200, 18);
  FHide.Caption := 'Hide Typing';
  FHide.Checked := True;
  FHide.OnClick := HideClick;

  X := 424;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(X - 80, 166 + Off, 80, 26);
  B.Caption := 'Cancel';
  B.ModalResult := mrCancel;
  B.Cancel := True;
  Dec(X, 88);
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(X - 80, 166 + Off, 80, 26);
  B.Caption := 'OK';
  B.ModalResult := mrOk;
  B.Default := True;
  if AAllowSkip then
  begin
    Dec(X, 88);
    B := TButton.Create(Self);
    B.Parent := Self;
    B.SetBounds(X - 80, 166 + Off, 80, 26);
    B.Caption := 'Skip Key';
    B.ModalResult := mrIgnore;
  end;
  ActiveControl := FEdit;
end;

procedure TPassphraseDialog.HideClick(Sender: TObject);
begin
  if FHide.Checked then
    FEdit.PasswordChar := '*'
  else
    FEdit.PasswordChar := #0;
end;

function TPassphraseDialog.TakePassphrase: TBytes;
var
  S: string;
  N: Integer;
begin
  S := FEdit.Text;
  Result := PassphraseToBytes(S);
  WipeString(S);
  N := Length(FEdit.Text);
  FEdit.Text := StringOfChar('x', N);  { overwrite the control's buffer }
  FEdit.Text := '';
end;

function AskPassphraseFor(AOwner: TComponent; const AKeyLabel, AHint: string;
  const ARecipients: TArray<string>; out APass: TBytes): TModalResult;
var
  D: TPassphraseDialog;
begin
  APass := nil;
  D := TPassphraseDialog.CreateDialog(AOwner, 'Enter Passphrase', AKeyLabel, AHint, False, ARecipients);
  try
    Result := D.ShowModal;
    if Result = mrOk then
      APass := D.TakePassphrase;
  finally
    D.Free;
  end;
end;

function AskPassphrase(AOwner: TComponent; const AKeyLabel, AHint: string;
  AAllowSkip: Boolean; out APass: TBytes): TModalResult;
var
  D: TPassphraseDialog;
begin
  APass := nil;
  D := TPassphraseDialog.CreateDialog(AOwner, 'Enter Passphrase', AKeyLabel, AHint, AAllowSkip);
  try
    Result := D.ShowModal;
    if Result = mrOk then
      APass := D.TakePassphrase;
  finally
    D.Free;
  end;
end;

end.

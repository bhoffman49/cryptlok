unit OPD.OptionsDialog;

{ Tools > Options.  One tab for now: Master Keys (keys added to everything you encrypt), laid out like the
  classic PGP Options window so more tabs can follow. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Graphics, OPD.Theme, OPD.Engine;

procedure ShowOptions(AOwner: TComponent; const AEngine: IKeyEngine);

implementation

uses
  System.StrUtils, Vcl.Dialogs, OPD.MasterKeys, OPD.RecipientDialog, OPD.VeraCrypt;

const
  EXPLAIN =
    'Master Keys are keys that you want to include each time you encrypt, create a disk, or make a Zip. ' +
    'You may want to list your own private key and any additional decryption keys (for example a company ' +
    'recovery key) here.';

type
  TOptionsForm = class(TOPDForm)
  private
    FEngine: IKeyEngine;
    FKeys: TKeyInfoArray;
    FUse: TCheckBox;
    FList: TListBox;
    FPrints: TStringList;
    FDefault: TComboBox;
    FDefaultPrints: TStringList;
    FVcFolder: TEdit;
    FVcStatus: TLabel;
    FAddVersion: TCheckBox;
    FComment: TEdit;
    FCloseToTray: TCheckBox;
    FAdd, FRemove: TButton;
    procedure VcBrowseClick(Sender: TObject);
    procedure VcChanged(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure UseClick(Sender: TObject);
    procedure ListClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure Fill;
    function NameOf(const AFingerprint: string): string;
  public
    constructor CreateDlg(AOwner: TComponent; const AEngine: IKeyEngine);
    destructor Destroy; override;
  end;

constructor TOptionsForm.CreateDlg(AOwner: TComponent; const AEngine: IKeyEngine);
var
  Tabs: TPageControl;
  Sheet, Sheet2, Sheet3, Sheet4, Sheet5: TTabSheet;
  AddVer: Boolean;
  Cmt: string;
  K: TKeyInfo;
  K2: Integer;
  Want: string;
  L: TLabel;
  B: TButton;
  M: TMasterKeys;
  F: string;
begin
  inherited CreateNew(AOwner);
  FEngine := AEngine;
  FPrints := TStringList.Create;
  FDefaultPrints := TStringList.Create;
  Caption := 'Options';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 500;
  ClientHeight := 440;
  Font.Name := UiFontName;
  Font.Size := 9;

  Tabs := TPageControl.Create(Self);
  Tabs.Parent := Self;
  Tabs.SetBounds(8, 8, 484, 384);
  Sheet := TTabSheet.Create(Tabs);
  Sheet.PageControl := Tabs;
  Sheet.Caption := 'Master Keys';

  FUse := TCheckBox.Create(Self); FUse.Parent := Sheet; FUse.SetBounds(14, 14, 440, 20);
  FUse.Caption := 'Use Master Key List'; FUse.OnClick := UseClick;
  L := TLabel.Create(Self); L.Parent := Sheet; L.SetBounds(14, 42, 450, 64);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace; L.Caption := EXPLAIN;
  FList := TListBox.Create(Self); FList.Parent := Sheet; FList.SetBounds(14, 112, 450, 190);
  FList.OnClick := ListClick;
  FAdd := TButton.Create(Self); FAdd.Parent := Sheet; FAdd.SetBounds(290, 312, 82, 28);
  FAdd.Caption := 'Add...'; FAdd.OnClick := AddClick;
  FRemove := TButton.Create(Self); FRemove.Parent := Sheet; FRemove.SetBounds(380, 312, 84, 28);
  FRemove.Caption := 'Remove'; FRemove.OnClick := RemoveClick; FRemove.Enabled := False;

  { Keys tab: which private key is "you" }
  Sheet2 := TTabSheet.Create(Tabs);
  Sheet2.PageControl := Tabs;
  Sheet2.Caption := 'Keys';
  L := TLabel.Create(Self); L.Parent := Sheet2; L.SetBounds(14, 14, 450, 20);
  L.Caption := 'Default key (the key that is "you")'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  L := TLabel.Create(Self); L.Parent := Sheet2; L.SetBounds(14, 40, 450, 64);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'This is the key CryptLok adds to your own archives so that you can always open them, and ' +
    'the one it shows as "(you)". Choose one of your private keys, or leave it on automatic.';
  FDefault := TComboBox.Create(Self); FDefault.Parent := Sheet2; FDefault.SetBounds(14, 112, 450, 24);
  FDefault.Style := csDropDownList;

  Sheet3 := TTabSheet.Create(Tabs);
  Sheet3.PageControl := Tabs;
  Sheet3.Caption := 'Disk';
  L := TLabel.Create(Self); L.Parent := Sheet3; L.SetBounds(14, 14, 450, 20);
  L.Caption := 'VeraCrypt folder'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  L := TLabel.Create(Self); L.Parent := Sheet3; L.SetBounds(14, 40, 450, 80);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'The Disk pages use VeraCrypt (free, installed separately). CryptLok finds it in Program Files ' +
    'by itself. If you run it from somewhere else, for example a portable copy you extracted, choose that ' +
    'folder here. A portable VeraCrypt needs administrator rights, so Windows will ask for them each time a ' +
    'disk is created, mounted or unmounted.';
  FVcFolder := TEdit.Create(Self); FVcFolder.Parent := Sheet3; FVcFolder.SetBounds(14, 130, 360, 24);
  FVcFolder.TextHint := 'Automatic (leave empty)';
  FVcFolder.OnChange := VcChanged;
  B := TButton.Create(Self); B.Parent := Sheet3; B.SetBounds(382, 129, 82, 26);
  B.Caption := 'Browse...'; B.OnClick := VcBrowseClick;
  FVcStatus := TLabel.Create(Self); FVcStatus.Parent := Sheet3; FVcStatus.SetBounds(14, 166, 450, 40);
  FVcStatus.AutoSize := False; FVcStatus.WordWrap := True; FVcStatus.Transparent := False; FVcStatus.Color := clBtnFace;
  FVcFolder.Text := TVeraCrypt.ManualFolder(AEngine);
  VcChanged(nil);

  Sheet4 := TTabSheet.Create(Tabs);
  Sheet4.PageControl := Tabs;
  Sheet4.Caption := 'Messages';
  L := TLabel.Create(Self); L.Parent := Sheet4; L.SetBounds(14, 14, 450, 20);
  L.Caption := 'Text added to encrypted messages, signatures and exported keys'; L.Font.Style := [fsBold];
  L.Transparent := False; L.Color := clBtnFace;
  L := TLabel.Create(Self); L.Parent := Sheet4; L.SetBounds(14, 40, 450, 50);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := 'These lines appear at the top of every PGP block CryptLok creates for the clipboard or exports ' +
    '("Version:" and "Comment:"). They are not part of what is signed or encrypted.';
  FAddVersion := TCheckBox.Create(Self); FAddVersion.Parent := Sheet4; FAddVersion.SetBounds(14, 100, 450, 20);
  FAddVersion.Caption := 'Add the program name and version (Version: CryptLok ...)';
  L := TLabel.Create(Self); L.Parent := Sheet4; L.SetBounds(14, 140, 450, 20);
  L.Caption := 'Comment (optional)'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  FComment := TEdit.Create(Self); FComment.Parent := Sheet4; FComment.SetBounds(14, 164, 450, 24);
  FComment.MaxLength := 200;
  FComment.TextHint := 'for example: This is the key of Brian Hoffman';
  L := TLabel.Create(Self); L.Parent := Sheet4; L.SetBounds(14, 196, 450, 36);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace; L.Font.Color := clGrayText;
  L.Caption := 'A single line. Leave it empty for no comment. It is visible to everyone who gets the block, so ' +
    'do not put anything private in it.';
  LoadArmorSettings(AEngine, AddVer, Cmt);
  FAddVersion.Checked := AddVer;
  FComment.Text := Cmt;

  Sheet5 := TTabSheet.Create(Tabs);
  Sheet5.PageControl := Tabs;
  Sheet5.Caption := 'General';
  L := TLabel.Create(Self); L.Parent := Sheet5; L.SetBounds(14, 14, 450, 20);
  L.Caption := 'Closing the window'; L.Font.Style := [fsBold]; L.Transparent := False; L.Color := clBtnFace;
  FCloseToTray := TCheckBox.Create(Self); FCloseToTray.Parent := Sheet5; FCloseToTray.SetBounds(14, 44, 450, 20);
  FCloseToTray.Caption := 'The X button keeps CryptLok running in the tray';
  FCloseToTray.Checked := LoadCloseToTray(AEngine);
  L := TLabel.Create(Self); L.Parent := Sheet5; L.SetBounds(14, 72, 450, 50);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace; L.Font.Color := clGrayText;
  L.Caption := 'The tray icon holds the clipboard commands (encrypt, decrypt, sign). Turn this off to make X quit ' +
    'the program completely. File > Exit and the tray menu always quit.';

  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(312, 402, 84, 28);
  B.Caption := 'OK'; B.Default := True; B.OnClick := OkClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(404, 402, 84, 28);
  B.Caption := 'Cancel'; B.ModalResult := mrCancel; B.Cancel := True;

  FKeys := FEngine.ListKeys;
  M := LoadMasterKeys(FEngine);
  FUse.Checked := M.Enabled;
  for F in M.Fingerprints do FPrints.Add(F);
  Fill;
  UseClick(nil);
  { default key list: automatic first, then every private key you can use }
  FDefault.Items.Add('Automatic (the first private key on the keyring)');
  FDefaultPrints.Add('');
  Want := LoadDefaultKey(FEngine);
  FDefault.ItemIndex := 0;
  for K in FKeys do
    if K.HasSecret and (not K.Revoked) and (not K.Expired) and (not K.Disabled) then
    begin
      FDefault.Items.Add(K.DisplayName + IfThen(K.DisplayEmail = '', '', ' <' + K.DisplayEmail + '>') + '   ' + K.ShortId);
      FDefaultPrints.Add(K.Fingerprint);
      if SameText(K.Fingerprint, Want) then
        FDefault.ItemIndex := FDefault.Items.Count - 1;
    end;
  { testing aid: /optiontab:1 opens the Keys tab }
  for K2 := 1 to ParamCount do
    if SameText(ParamStr(K2), '/optiontab:1') then Tabs.ActivePageIndex := 1
    else if SameText(ParamStr(K2), '/optiontab:2') then Tabs.ActivePageIndex := 2
    else if SameText(ParamStr(K2), '/optiontab:3') then Tabs.ActivePageIndex := 3;
end;

destructor TOptionsForm.Destroy;
begin
  FPrints.Free;
  FDefaultPrints.Free;
  inherited;
end;

function TOptionsForm.NameOf(const AFingerprint: string): string;
var
  K: TKeyInfo;
begin
  for K in FKeys do
    if SameText(K.Fingerprint, AFingerprint) then
    begin
      Result := K.DisplayName + IfThen(K.DisplayEmail = '', '', ' <' + K.DisplayEmail + '>');
      if K.Revoked then Result := Result + '  - revoked, not used'
      else if K.Expired then Result := Result + '  - expired, not used'
      else if K.Disabled then Result := Result + '  - disabled, not used';
      Exit;
    end;
  Result := '0x' + Copy(AFingerprint, Length(AFingerprint) - 7, 8) + '  - not on your keyring, not used';
end;

procedure TOptionsForm.Fill;
var
  F: string;
begin
  FList.Items.Clear;
  for F in FPrints do
    FList.Items.Add(NameOf(F));
  FRemove.Enabled := False;
end;

procedure TOptionsForm.UseClick(Sender: TObject);
begin
  FList.Enabled := FUse.Checked;
  FAdd.Enabled := FUse.Checked;
  FRemove.Enabled := FUse.Checked and (FList.ItemIndex >= 0);
end;

procedure TOptionsForm.ListClick(Sender: TObject);
begin
  FRemove.Enabled := FUse.Checked and (FList.ItemIndex >= 0);
end;

procedure TOptionsForm.AddClick(Sender: TObject);
var
  Chosen: TArray<string>;
  F: string;
begin
  if SelectRecipients(Self, FKeys, Chosen) then
  begin
    for F in Chosen do
      if FPrints.IndexOf(UpperCase(F)) < 0 then
        FPrints.Add(UpperCase(F));
    Fill;
    UseClick(nil);
  end;
end;

procedure TOptionsForm.RemoveClick(Sender: TObject);
begin
  if FList.ItemIndex >= 0 then
  begin
    FPrints.Delete(FList.ItemIndex);
    Fill;
    UseClick(nil);
  end;
end;

procedure TOptionsForm.VcChanged(Sender: TObject);
var
  Vc: TVeraCrypt;
  Info: string;
begin
  if Trim(FVcFolder.Text) <> '' then
  begin
    if TVeraCrypt.FolderHasVeraCrypt(FVcFolder.Text) then
      FVcStatus.Caption := 'VeraCrypt found in this folder.'
    else
      FVcStatus.Caption := 'VeraCrypt was not found in this folder (it needs VeraCrypt.exe or VeraCrypt-x64.exe, and the matching Format program).';
    Exit;
  end;
  Vc := TVeraCrypt.Create(FEngine);
  try
    if Vc.Available(Info) then
      FVcStatus.Caption := 'Found automatically: ' + Info
    else
      FVcStatus.Caption := 'VeraCrypt was not found. Install it from https://veracrypt.fr/ or choose its folder.';
  finally
    Vc.Free;
  end;
end;

procedure TOptionsForm.VcBrowseClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(nil);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Choose the folder that holds VeraCrypt.exe';
    if D.Execute then
      FVcFolder.Text := D.FileName;
  finally
    D.Free;
  end;
end;

procedure TOptionsForm.OkClick(Sender: TObject);
var
  M: TMasterKeys;
  I: Integer;
begin
  if (Trim(FVcFolder.Text) <> '') and not TVeraCrypt.FolderHasVeraCrypt(FVcFolder.Text) then
  begin
    Application.MessageBox('VeraCrypt was not found in that folder (it needs VeraCrypt.exe or VeraCrypt-x64.exe and the matching Format program). ' +
      'Choose the right folder or clear the box.', 'Options', MB_OK or MB_ICONWARNING);
    Exit;
  end;
  TVeraCrypt.SetManualFolder(FEngine, FVcFolder.Text);
  SaveArmorSettings(FEngine, FAddVersion.Checked, FComment.Text);
  SaveCloseToTray(FEngine, FCloseToTray.Checked);
  ApplyArmorSettings(FEngine);
  M.Enabled := FUse.Checked;
  SetLength(M.Fingerprints, FPrints.Count);
  for I := 0 to FPrints.Count - 1 do
    M.Fingerprints[I] := FPrints[I];
  SaveMasterKeys(FEngine, M);
  if (FDefault.ItemIndex >= 0) and (FDefault.ItemIndex < FDefaultPrints.Count) then
    SaveDefaultKey(FEngine, FDefaultPrints[FDefault.ItemIndex]);
  ModalResult := mrOk;
end;

procedure ShowOptions(AOwner: TComponent; const AEngine: IKeyEngine);
var
  F: TOptionsForm;
begin
  F := TOptionsForm.CreateDlg(AOwner, AEngine);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.

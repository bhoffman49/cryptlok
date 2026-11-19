unit OPD.ZipWizard;

{ The Zip assistant: Select Items -> Encrypt -> (Keys | Passphrase) -> Sign & Save -> Progress/Finish.
  Hand-laid out at 96 DPI like the other dialogs (TOPDForm scales it).  The banner on the left is
  painted here; a designed banner image can replace the placeholder gradient later. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections, Winapi.Windows, Winapi.Messages,
  Winapi.ShellAPI, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Graphics, Vcl.Dialogs, Vcl.Imaging.pngimage, OPD.Theme, OPD.Engine;

{ Runs the assistant.  AInitialItems are files/folders already chosen (Explorer menu, drag and drop).
  Returns True when an archive was created; AOutFile is its path. }
function RunZipWizard(AOwner: TComponent; const AEngine: IKeyEngine;
  const AInitialItems: TArray<string>; out AOutFile: string): Boolean;

implementation

uses
  System.StrUtils, System.Math, System.IOUtils, OPD.RecipientDialog, OPD.PassphraseDialog,
  OPD.PgpZip, OPD.Tar, OPD.ShredDialog, OPD.MasterKeys, OPD.PassCache;

type
  TZipPage = (zpFiles, zpEncrypt, zpKeys, zpPass, zpSign, zpProgress);
  TZipMode = (zmKeys, zmPass, zmSda, zmSign);

  TStepBanner = class(TGraphicControl)
  private
    FSteps: TArray<string>;
    FCurrent: Integer;
    FArt: TBitmap;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetStep(AIndex: Integer; AFinished: Boolean = False);
  end;

  TQualityBar = class(TGraphicControl)
  private
    FPercent: Integer;
  protected
    procedure Paint; override;
  public
    procedure SetPercent(AValue: Integer);
  end;

  TZipWizard = class(TOPDForm)
  private
    FEngine: IKeyEngine;
    FKeys: TKeyInfoArray;
    FBanner: TStepBanner;
    FPages: array[TZipPage] of TPanel;
    FPage: TZipPage;
    FMode: TZipMode;
    FFinished: Boolean;
    FOutFile: string;
    FCreated: Boolean;
    FCompress: Boolean;
    { page widgets }
    FItems: TListView;
    FAddFiles, FAddFolder, FRemoveItem, FOptions: TButton;
    FShredOrig: TCheckBox;
    FRadio: array[TZipMode] of TRadioButton;
    FInfo: TMemo;
    FRecipList: TListBox;
    FRecipPrint: TStringList;
    FOwnPrint: string;
    FMasterPrints: TArray<string>;
    FAddKey, FRemoveKey: TButton;
    FPass1, FPass2: TEdit;
    FShowKeys: TCheckBox;
    FQuality: TQualityBar;
    FSignCombo: TComboBox;
    FSignNote: TLabel;
    FSavePath: TEdit;
    FBrowse: TButton;
    FDetached: TCheckBox;
    FIconLabel: TLabel;
    FIconEdit: TEdit;
    FIconBrowse: TButton;
    FIconFile: string;
    FAutoName: string;
    FSummary: TMemo;
    FProgress: TProgressBar;
    FStatus: TLabel;
    FTimer: TTimer;
    FWorkPct: Integer;
    FWorkStep: string;
    FLock: TCriticalSection;
    { buttons }
    FBack, FNext, FCancel, FHelp: TButton;
    function NewPage(AIndex: TZipPage; const ATitle, ADesc: string): TPanel;
    function Label_(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer;
      const ACaption: string; ABold: Boolean = False): TLabel;
    procedure BuildFiles;
    procedure BuildEncrypt;
    procedure BuildKeys;
    procedure BuildPass;
    procedure BuildSign;
    procedure BuildProgress;
    procedure ShowPage(APage: TZipPage);
    procedure UpdateButtons;
    function StepFor(APage: TZipPage): Integer;
    procedure NextClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure AddFilesClick(Sender: TObject);
    procedure AddFolderClick(Sender: TObject);
    procedure RemoveItemClick(Sender: TObject);
    procedure OptionsClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure AddKeyClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    procedure PassChange(Sender: TObject);
    procedure ShowKeysClick(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure IconBrowseClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure SelectItemsChange(Sender: TObject; Item: TListItem; Change: TItemChange);
    procedure AddItemPath(const APath: string);
    function Validate(APage: TZipPage): Boolean;
    function KeyOrPass: TZipPage;
    function ItemPaths: TArray<string>;
    function SuggestedName: string;
    procedure RefreshSignCombo;
    procedure RefreshRecipients;
    procedure EnsureOwnKey;
    procedure RunCreate;
    procedure ShredOriginals(const AItems: TArray<string>; const AArchive: string);
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
  public
    destructor Destroy; override;
    constructor CreateWizard(AOwner: TComponent; const AEngine: IKeyEngine;
      const AInitialItems: TArray<string>);
  end;

const
  CLIENT_W = 700;
  CLIENT_H = 440;
  BANNER_W = 180;
  BANNER_H = 380;
  PAGE_X = 198;
  PAGE_W = 486;

  ModeInfo: array[TZipMode] of string = (
    'Use this option to encrypt the archive to the public keys of the people who should open it. ' +
    'Only those people, using their private keys and passphrases, can open it. This is the most ' +
    'secure choice. Your own key is always included so that you can open the archive too.',
    'Use this option when you do not have keys for the recipients. Everyone who knows the ' +
    'passphrase can open the archive, and each recipient needs a program that reads OpenPGP ' +
    'files. Share the passphrase through a different channel than the archive.',
    'Creates a self-decrypting archive: a program (.exe) that opens with a passphrase on any ' +
    'Windows computer, with nothing installed. Recipients just double-click it. Some mail systems ' +
    'block .exe attachments; put it inside a .zip or .rar if yours does.',
    'Adds your signature to the files without encrypting them, so recipients can verify that the ' +
    'files came from you and were not changed. This option arrives in a later version.');

function FormatSize(ASize: Int64): string;
begin
  if ASize < 1024 then
    Result := Format('%d bytes', [ASize])
  else if ASize < 1024 * 1024 then
    Result := Format('%.1f KB', [ASize / 1024])
  else if ASize < Int64(1024) * 1024 * 1024 then
    Result := Format('%.1f MB', [ASize / (1024 * 1024)])
  else
    Result := Format('%.2f GB', [ASize / (1024.0 * 1024 * 1024)]);
end;

{ Rough passphrase strength: bits of entropy against a 128-bit random string. }
function PassphraseQuality(const S: string): Integer;
var
  C: Char;
  HasLower, HasUpper, HasDigit, HasOther: Boolean;
  Pool: Integer;
  Bits: Double;
begin
  if S = '' then Exit(0);
  HasLower := False; HasUpper := False; HasDigit := False; HasOther := False;
  for C in S do
    if CharInSet(C, ['a'..'z']) then HasLower := True
    else if CharInSet(C, ['A'..'Z']) then HasUpper := True
    else if CharInSet(C, ['0'..'9']) then HasDigit := True
    else HasOther := True;
  Pool := 0;
  if HasLower then Inc(Pool, 26);
  if HasUpper then Inc(Pool, 26);
  if HasDigit then Inc(Pool, 10);
  if HasOther then Inc(Pool, 33);
  Bits := Length(S) * Log2(Max(Pool, 2)) * 0.75;   { humans are less random than dice }
  Result := EnsureRange(Round(Bits * 100 / 128), 0, 100);
end;

{ ---- banner ---------------------------------------------------------------------------- }

constructor TStepBanner.Create(AOwner: TComponent);
begin
  inherited;
  FSteps := ['Select Items', 'Encrypt', 'Sign & Save', 'Finish'];
end;

procedure TStepBanner.SetStep(AIndex: Integer; AFinished: Boolean);
begin
  FCurrent := AIndex;
  if AFinished then
    FCurrent := Length(FSteps);
  Invalidate;
end;

procedure TStepBanner.Paint;
var
  I, T: Integer;
  R: TRect;
  C1: TColor;
  F: Double;
  Png: TPngImage;

  procedure BuildArt;
  var
    Row: Integer;
  begin
    FArt := TBitmap.Create;
    FArt.PixelFormat := pf24bit;
    FArt.SetSize(Width, Height);
    SetStretchBltMode(FArt.Canvas.Handle, HALFTONE);
    SetBrushOrgEx(FArt.Canvas.Handle, 0, 0, nil);
    try
      Png := LoadPng('WIZ_BANNER');
      try
        FArt.Canvas.StretchDraw(Rect(0, 0, Width, Height), Png);
      finally
        Png.Free;
      end;
    except
      { no banner resource: dark slate gradient }
      for Row := 0 to Height - 1 do
      begin
        F := Row / Max(Height, 1);
        C1 := RGB(Round(58 - 28 * F), Round(66 - 30 * F), Round(82 - 34 * F));
        FArt.Canvas.Pen.Color := C1;
        FArt.Canvas.MoveTo(0, Row);
        FArt.Canvas.LineTo(Width, Row);
      end;
    end;
  end;

begin
  if (FArt = nil) or (FArt.Width <> Width) or (FArt.Height <> Height) then
  begin
    FreeAndNil(FArt);
    BuildArt;
  end;
  Canvas.Draw(0, 0, FArt);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := UiFontName;
  Canvas.Font.Color := clWhite;
  Canvas.Font.Height := -DpiScale(20);
  Canvas.Font.Style := [fsBold];
  Canvas.TextOut(DpiScale(14), DpiScale(18), 'CryptLok');
  Canvas.Font.Height := -DpiScale(11);
  Canvas.Font.Style := [];
  Canvas.Font.Color := RGB(190, 200, 215);
  Canvas.TextOut(DpiScale(14), DpiScale(46), 'OpenPGP Encryption Suite');

  Canvas.Font.Height := -DpiScale(13);
  for I := 0 to High(FSteps) do
  begin
    T := DpiScale(112 + I * 24);
    Canvas.Font.Color := clWhite;
    if I = FCurrent then
      Canvas.Font.Style := [fsUnderline]
    else
      Canvas.Font.Style := [];
    R := Rect(DpiScale(24), T, Width - DpiScale(10), T + DpiScale(20));
    DrawText(Canvas.Handle, PChar(FSteps[I]), -1, R, DT_LEFT or DT_SINGLELINE or DT_NOPREFIX);
    if I < FCurrent then
    begin
      Canvas.Font.Name := 'Segoe UI Symbol';
      Canvas.Font.Color := RGB(70, 220, 90);
      Canvas.Font.Style := [fsBold];
      Canvas.TextOut(DpiScale(24) + Canvas.TextWidth(FSteps[I]) + DpiScale(8), T, #$2713);
      Canvas.Font.Name := UiFontName;
    end;
  end;
end;

destructor TStepBanner.Destroy;
begin
  FArt.Free;
  inherited;
end;

procedure TQualityBar.SetPercent(AValue: Integer);
begin
  FPercent := AValue;
  Invalidate;
end;

procedure TQualityBar.Paint;
var
  R, F: TRect;
  S: string;
  Col: TColor;
begin
  R := Rect(0, 0, Width, Height);
  Canvas.Brush.Color := clWindow;
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Rectangle(R);
  if FPercent < 34 then Col := RGB(230, 90, 70)
  else if FPercent < 67 then Col := RGB(235, 210, 40)
  else Col := RGB(110, 200, 60);
  F := Rect(1, 1, 1 + Round((Width - 2) * FPercent / 100), Height - 1);
  Canvas.Brush.Color := Col;
  Canvas.FillRect(F);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := UiFontName;
  Canvas.Font.Size := 8;
  Canvas.Font.Color := clBlack;
  S := IntToStr(FPercent) + ' %';
  Canvas.TextOut((Width - Canvas.TextWidth(S)) div 2, (Height - Canvas.TextHeight(S)) div 2, S);
end;

{ ---- construction ---------------------------------------------------------------------- }

function TZipWizard.Label_(AParent: TWinControl; ALeft, ATop, AWidth, AHeight: Integer;
  const ACaption: string; ABold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(ALeft, ATop, AWidth, AHeight);
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Transparent := False;
  Result.Color := clBtnFace;
  Result.Caption := ACaption;
  if ABold then
    Result.Font.Style := [fsBold];
end;

function TZipWizard.NewPage(AIndex: TZipPage; const ATitle, ADesc: string): TPanel;
var
  L: TLabel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := Self;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := True;
  Result.SetBounds(PAGE_X, 0, PAGE_W, BANNER_H);
  Result.Visible := False;
  L := Label_(Result, 0, 16, PAGE_W, 24, ATitle, True);
  L.Font.Size := 13;
  Label_(Result, 0, 46, PAGE_W, 32, ADesc);
  FPages[AIndex] := Result;
end;

constructor TZipWizard.CreateWizard(AOwner: TComponent; const AEngine: IKeyEngine;
  const AInitialItems: TArray<string>);
var
  P: string;
  I: Integer;
  Sep: TBevel;
begin
  inherited CreateNew(AOwner);
  FEngine := AEngine;
  FRecipPrint := TStringList.Create;
  FLock := TCriticalSection.Create;
  FCompress := False;
  Caption := 'CryptLok Zip Assistant';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := CLIENT_W;
  ClientHeight := CLIENT_H;
  Font.Name := UiFontName;
  Font.Size := 9;

  FBanner := TStepBanner.Create(Self);
  FBanner.Parent := Self;
  FBanner.SetBounds(0, 0, BANNER_W, BANNER_H);

  BuildFiles;
  BuildEncrypt;
  BuildKeys;
  BuildPass;
  BuildSign;
  BuildProgress;

  Sep := TBevel.Create(Self);
  Sep.Parent := Self;
  Sep.Shape := bsTopLine;
  Sep.SetBounds(PAGE_X, BANNER_H + 8, PAGE_W, 2);

  FBack := TButton.Create(Self); FBack.Parent := Self;
  FBack.SetBounds(CLIENT_W - 4 * 84 - 24, BANNER_H + 20, 76, 28);
  FBack.Caption := '< Back'; FBack.OnClick := BackClick;
  FNext := TButton.Create(Self); FNext.Parent := Self;
  FNext.SetBounds(CLIENT_W - 3 * 84 - 24, BANNER_H + 20, 76, 28);
  FNext.Caption := 'Next >'; FNext.OnClick := NextClick; FNext.Default := True;
  FCancel := TButton.Create(Self); FCancel.Parent := Self;
  FCancel.SetBounds(CLIENT_W - 2 * 84 - 24, BANNER_H + 20, 76, 28);
  FCancel.Caption := 'Cancel'; FCancel.OnClick := CancelClick; FCancel.Cancel := True;
  FHelp := TButton.Create(Self); FHelp.Parent := Self;
  FHelp.SetBounds(CLIENT_W - 84 - 24, BANNER_H + 20, 76, 28);
  FHelp.Caption := 'Help'; FHelp.Enabled := False;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 120;
  FTimer.OnTimer := TimerTick;

  FKeys := ListKeysOrExplain(FEngine);
  EnsureOwnKey;
  for P in AInitialItems do
    AddItemPath(P);
  FMode := zmKeys;
  ShowPage(zpFiles);
  { testing aids: /zipstep:<0..5> jumps to a page; /zipauto:<out.pgp> runs key-based creation unattended }
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)).StartsWith('/zipstep:') then
    begin
      if StrToIntDef(Copy(ParamStr(I), 10, 9), 0) = 3 then
      begin
        FMode := zmPass;
        FPass1.Text := 'Correct horse battery';
        FPass2.Text := 'Correct horse battery';
      end;
      ShowPage(TZipPage(EnsureRange(StrToIntDef(Copy(ParamStr(I), 10, 9), 0), 0, 5)));
    end
    else if LowerCase(ParamStr(I)).StartsWith('/zipsda:') then
    begin
      FMode := zmSda;
      FRadio[zmSda].Checked := True;
      FPass1.Text := 'wizard sda pass 1';
      FPass2.Text := 'wizard sda pass 1';
      ShowPage(zpSign);
      FSavePath.Text := Copy(ParamStr(I), 9, MaxInt);
      RunCreate;
    end
    else if LowerCase(ParamStr(I)).StartsWith('/zipauto:') then
    begin
      ShowPage(zpSign);
      FSavePath.Text := Copy(ParamStr(I), 10, MaxInt);
      RunCreate;
    end;
end;

destructor TZipWizard.Destroy;
begin
  FRecipPrint.Free;
  FLock.Free;
  inherited;
end;

procedure TZipWizard.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TZipWizard.DestroyWnd;
begin
  if HandleAllocated then
    DragAcceptFiles(Handle, False);
  inherited;
end;

procedure TZipWizard.WMDropFiles(var Msg: TWMDropFiles);
var
  N, I: Integer;
  Buf: array[0..MAX_PATH * 2] of Char;
begin
  try
    if FPage = zpFiles then
    begin
      N := DragQueryFile(Msg.Drop, $FFFFFFFF, nil, 0);
      for I := 0 to N - 1 do
      begin
        DragQueryFile(Msg.Drop, I, Buf, Length(Buf));
        AddItemPath(Buf);
      end;
    end;
  finally
    DragFinish(Msg.Drop);
  end;
  Msg.Result := 0;
end;

procedure TZipWizard.BuildFiles;
var
  P: TPanel;
  C: TListColumn;
begin
  P := NewPage(zpFiles, 'New Zip',
    'This assistant helps you secure files and folders for storage or transfer. Drag and drop ' +
    'your files into the box, or use the buttons below to browse for your selection.');
  FItems := TListView.Create(Self);
  FItems.Parent := P;
  FItems.SetBounds(0, 90, PAGE_W, 232);
  FItems.ViewStyle := vsReport;
  FItems.ReadOnly := True;
  FItems.RowSelect := True;
  FItems.MultiSelect := True;
  FItems.HideSelection := False;
  FItems.OnChange := SelectItemsChange;
  C := FItems.Columns.Add; C.Caption := 'Name'; C.Width := 270;
  C := FItems.Columns.Add; C.Caption := 'Size'; C.Width := 90; C.Alignment := taRightJustify;
  C := FItems.Columns.Add; C.Caption := 'Type'; C.Width := 100;
  Label_(P, 0, 332, 330, 18, 'Drag and drop files or folders anywhere in this window.');
  FAddFiles := TButton.Create(Self); FAddFiles.Parent := P;
  FAddFiles.SetBounds(0, 350, 92, 26); FAddFiles.Caption := 'Add Files...';
  FAddFiles.OnClick := AddFilesClick;
  FAddFolder := TButton.Create(Self); FAddFolder.Parent := P;
  FAddFolder.SetBounds(98, 350, 100, 26); FAddFolder.Caption := 'Add Folder...';
  FAddFolder.OnClick := AddFolderClick;
  FRemoveItem := TButton.Create(Self); FRemoveItem.Parent := P;
  FRemoveItem.SetBounds(204, 350, 80, 26); FRemoveItem.Caption := 'Remove';
  FRemoveItem.OnClick := RemoveItemClick; FRemoveItem.Enabled := False;
  FOptions := TButton.Create(Self); FOptions.Parent := P;
  FOptions.SetBounds(PAGE_W - 92, 350, 92, 26); FOptions.Caption := 'Options...';
  FOptions.OnClick := OptionsClick;
  FShredOrig := TCheckBox.Create(Self); FShredOrig.Parent := P;
  FShredOrig.SetBounds(PAGE_W - 150, 328, 150, 20); FShredOrig.Caption := 'Shred originals';
  FShredOrig.Hint := 'After the archive is made, permanently destroy the original files';
  FShredOrig.ShowHint := True;
end;

procedure TZipWizard.BuildEncrypt;
var
  P: TPanel;
  M: TZipMode;
  Y: Integer;
const
  Names: array[TZipMode] of string = ('Recipient keys', 'Passphrase', 'Self-Decrypting Archive',
    'Sign Only');
  Sub: array[TZipMode] of string = (
    'I have keys for all recipients (most secure)',
    'I do not have keys for all recipients, but they all use a program that opens OpenPGP files',
    'Recipients do not need any program (Windows only)',
    'Create a signed file (no encryption)');
begin
  P := NewPage(zpEncrypt, 'Encrypt',
    'Choose how you want to encrypt to your recipients. If you are unsure of a particular ' +
    'option, click it to see an explanation below.');
  Y := 92;
  for M := Low(TZipMode) to High(TZipMode) do
  begin
    FRadio[M] := TRadioButton.Create(Self);
    FRadio[M].Parent := P;
    FRadio[M].SetBounds(0, Y, PAGE_W, 20);
    FRadio[M].Caption := Names[M];
    FRadio[M].Font.Style := [fsBold];
    FRadio[M].Tag := Ord(M);
    FRadio[M].OnClick := ModeClick;
    FRadio[M].Enabled := True;
    Label_(P, 18, Y + 20, PAGE_W - 18, 18, Sub[M]);
    Inc(Y, 52);
  end;
  FRadio[zmKeys].Checked := True;
  FInfo := TMemo.Create(Self);
  FInfo.Parent := P;
  FInfo.SetBounds(0, 304, PAGE_W, 72);
  FInfo.ReadOnly := True;
  FInfo.BorderStyle := bsNone;
  FInfo.Color := clBtnFace;
  FInfo.Lines.Text := ModeInfo[zmKeys];
end;

procedure TZipWizard.BuildKeys;
var
  P: TPanel;
begin
  P := NewPage(zpKeys, 'Add User Keys',
    'Choose the people who may open this archive. Your own key is always included so that you ' +
    'can open it yourself.');
  FRecipList := TListBox.Create(Self);
  FRecipList.Parent := P;
  FRecipList.SetBounds(0, 90, 390, 250);
  FAddKey := TButton.Create(Self); FAddKey.Parent := P;
  FAddKey.SetBounds(400, 90, 86, 26); FAddKey.Caption := 'Add...';
  FAddKey.OnClick := AddKeyClick;
  FRemoveKey := TButton.Create(Self); FRemoveKey.Parent := P;
  FRemoveKey.SetBounds(400, 122, 86, 26); FRemoveKey.Caption := 'Remove';
  FRemoveKey.OnClick := RemoveKeyClick;
  Label_(P, 0, 348, PAGE_W, 28, 'Click Next to continue.');
end;

procedure TZipWizard.BuildPass;
var
  P: TPanel;
begin
  P := NewPage(zpPass, 'Create a passphrase', 'Create a passphrase to secure your items.');
  Label_(P, 0, 100, 200, 18, 'Passphrase:');
  FPass1 := TEdit.Create(Self); FPass1.Parent := P;
  FPass1.SetBounds(0, 120, PAGE_W, 24); FPass1.PasswordChar := '*';
  FPass1.OnChange := PassChange;
  Label_(P, 0, 156, 200, 18, 'Confirm:');
  FPass2 := TEdit.Create(Self); FPass2.Parent := P;
  FPass2.SetBounds(0, 176, PAGE_W, 24); FPass2.PasswordChar := '*';
  FShowKeys := TCheckBox.Create(Self); FShowKeys.Parent := P;
  FShowKeys.SetBounds(PAGE_W - 130, 208, 130, 20); FShowKeys.Caption := 'Show Keystrokes';
  FShowKeys.OnClick := ShowKeysClick;
  Label_(P, 0, 240, 200, 18, 'Passphrase Quality');
  FQuality := TQualityBar.Create(Self); FQuality.Parent := P;
  FQuality.SetBounds(0, 260, PAGE_W, 18);
  Label_(P, 0, 296, PAGE_W, 60,
    'Use a long phrase you can remember. Anyone who has the archive and this passphrase can open ' +
    'it, so share the passphrase through a different channel than the archive itself.');
end;

procedure TZipWizard.BuildSign;
var
  P: TPanel;
  Cb: TCheckBox;
begin
  P := NewPage(zpSign, 'Sign and Save',
    'Signing your archive lets your recipients verify that it came from you. Confirm your ' +
    'signing key and the save location below.');
  Label_(P, 0, 96, 200, 18, 'Signing Key');
  FSignCombo := TComboBox.Create(Self); FSignCombo.Parent := P;
  FSignCombo.SetBounds(0, 116, PAGE_W, 24); FSignCombo.Style := csDropDownList;
  FSignNote := Label_(P, 0, 144, PAGE_W, 34, '');
  Label_(P, 0, 224, 200, 18, 'Save Location');
  FSavePath := TEdit.Create(Self); FSavePath.Parent := P;
  FSavePath.SetBounds(0, 244, PAGE_W - 100, 24);
  FBrowse := TButton.Create(Self); FBrowse.Parent := P;
  FBrowse.SetBounds(PAGE_W - 92, 242, 92, 28); FBrowse.Caption := 'Browse...';
  FBrowse.OnClick := BrowseClick;
  Cb := TCheckBox.Create(Self); Cb.Parent := P;
  Cb.SetBounds(0, 280, 300, 20); Cb.Caption := 'Save Detached Signature(s)';
  Cb.Enabled := False;
  FDetached := Cb;
  FIconLabel := Label_(P, 0, 314, 200, 18, 'Program icon');
  FIconEdit := TEdit.Create(Self); FIconEdit.Parent := P;
  FIconEdit.SetBounds(0, 334, PAGE_W - 100, 24); FIconEdit.ReadOnly := True;
  FIconEdit.Text := '(default CryptLok icon)';
  FIconBrowse := TButton.Create(Self); FIconBrowse.Parent := P;
  FIconBrowse.SetBounds(PAGE_W - 92, 332, 92, 28); FIconBrowse.Caption := 'Choose...';
  FIconBrowse.OnClick := IconBrowseClick;
end;

procedure TZipWizard.BuildProgress;
var
  P: TPanel;
begin
  P := NewPage(zpProgress, 'Progress', 'Now securing items.');
  FSummary := TMemo.Create(Self);
  FSummary.Parent := P;
  FSummary.SetBounds(0, 80, PAGE_W, 220);
  FSummary.ReadOnly := True;
  FSummary.ScrollBars := ssVertical;
  FStatus := Label_(P, 0, 312, PAGE_W, 18, '');
  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := P;
  FProgress.SetBounds(0, 336, PAGE_W, 18);
end;

{ ---- page flow ------------------------------------------------------------------------- }

function TZipWizard.StepFor(APage: TZipPage): Integer;
begin
  case APage of
    zpFiles: Result := 0;
    zpEncrypt, zpKeys, zpPass: Result := 1;
    zpSign: Result := 2;
  else
    Result := 3;
  end;
end;

procedure TZipWizard.ShowPage(APage: TZipPage);
var
  K: TZipPage;
begin
  FPage := APage;
  for K := Low(TZipPage) to High(TZipPage) do
    FPages[K].Visible := K = APage;
  FBanner.SetStep(StepFor(APage), FFinished);
  UpdateButtons;
  case APage of
    zpKeys: RefreshRecipients;
    zpSign:
      begin
        RefreshSignCombo;
        if (FSavePath.Text = '') or (FSavePath.Text = FAutoName) then
        begin
          FAutoName := SuggestedName;
          FSavePath.Text := FAutoName;
        end;
        FIconLabel.Visible := FMode = zmSda;
        FIconEdit.Visible := FMode = zmSda;
        FIconBrowse.Visible := FMode = zmSda;
        FDetached.Visible := FMode <> zmSda;
      end;
  end;
end;

procedure TZipWizard.UpdateButtons;
begin
  FBack.Enabled := not (FPage in [zpFiles, zpProgress]);
  FNext.Caption := IfThen(FPage = zpProgress, 'Finish', 'Next >');
  FNext.Enabled := not ((FPage = zpProgress) and not FFinished);
  FCancel.Enabled := not ((FPage = zpProgress) and not FFinished);
  if FFinished then
    FCancel.Enabled := False;
end;

function TZipWizard.KeyOrPass: TZipPage;
begin
  case FMode of
    zmPass, zmSda: Result := zpPass;
    zmSign: Result := zpSign;
  else
    Result := zpKeys;
  end;
end;

function TZipWizard.ItemPaths: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, FItems.Items.Count);
  for I := 0 to FItems.Items.Count - 1 do
    Result[I] := FItems.Items[I].SubItems[2];
end;

function TZipWizard.SuggestedName: string;
var
  Items: TArray<string>;
begin
  Items := ItemPaths;
  if Length(Items) = 0 then
    Exit('');
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(Items[0])) + DefaultZipName(Items);
  if FMode = zmSign then
    Result := ExtractFilePath(ExcludeTrailingPathDelimiter(Items[0])) +
      ExtractFileName(ExcludeTrailingPathDelimiter(Items[0])) + '.sig'
  else if FMode = zmSda then
    Result := ExtractFilePath(ExcludeTrailingPathDelimiter(Items[0])) +
      ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(Items[0])), '') + '-sda.exe';
end;

function TZipWizard.Validate(APage: TZipPage): Boolean;
var
  Q: string;
begin
  Result := True;
  case APage of
    zpFiles:
      if FItems.Items.Count = 0 then
      begin
        Application.MessageBox('Add at least one file or folder first.', 'CryptLok Zip',
          MB_OK or MB_ICONINFORMATION);
        Result := False;
      end;
    zpKeys:
      if (FRecipPrint.Count = 0) and (FOwnPrint = '') then
      begin
        Application.MessageBox('Choose at least one recipient key.', 'CryptLok Zip',
          MB_OK or MB_ICONINFORMATION);
        Result := False;
      end;
    zpPass:
      begin
        Q := '';
        if Length(FPass1.Text) < 8 then
          Q := 'Use a passphrase of at least 8 characters. A longer phrase is stronger.'
        else if FPass1.Text <> FPass2.Text then
          Q := 'The two passphrases do not match.';
        if Q <> '' then
        begin
          Application.MessageBox(PChar(Q), 'CryptLok Zip', MB_OK or MB_ICONWARNING);
          Result := False;
        end;
      end;
    zpSign:
      begin
        if Trim(FSavePath.Text) = '' then
        begin
          Application.MessageBox('Choose where to save the archive.', 'CryptLok Zip',
            MB_OK or MB_ICONINFORMATION);
          Exit(False);
        end;
        if (FMode = zmSign) and (FSignCombo.ItemIndex < 1) then
        begin
          Application.MessageBox('Choose the key to sign with. Sign Only needs a signing key.', 'CryptLok Zip',
            MB_OK or MB_ICONINFORMATION);
          Exit(False);
        end;
        if (FMode = zmSda) and not SameText(ExtractFileExt(FSavePath.Text), '.exe') then
          FSavePath.Text := FSavePath.Text + '.exe';
        if FileExists(FSavePath.Text) then
          Result := Application.MessageBox(PChar(ExtractFileName(FSavePath.Text) +
            ' already exists. Replace it?'), 'CryptLok Zip', MB_YESNO or MB_ICONQUESTION) = IDYES;
      end;
  end;
end;

procedure TZipWizard.NextClick(Sender: TObject);
begin
  if FPage = zpProgress then
  begin
    ModalResult := IfThen(FCreated, mrOk, mrCancel);
    Exit;
  end;
  if not Validate(FPage) then
    Exit;
  case FPage of
    zpFiles: ShowPage(zpEncrypt);
    zpEncrypt: ShowPage(KeyOrPass);
    zpKeys, zpPass: ShowPage(zpSign);
    zpSign: RunCreate;
  end;
end;

procedure TZipWizard.BackClick(Sender: TObject);
begin
  case FPage of
    zpEncrypt: ShowPage(zpFiles);
    zpKeys, zpPass: ShowPage(zpEncrypt);
    zpSign: if FMode = zmSign then ShowPage(zpEncrypt) else ShowPage(KeyOrPass);
  end;
end;

procedure TZipWizard.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ ---- Select Items ----------------------------------------------------------------------- }

procedure TZipWizard.AddItemPath(const APath: string);
var
  Li: TListItem;
  P: string;
  Size: Int64;
  I: Integer;
begin
  P := ExcludeTrailingPathDelimiter(APath);
  if P = '' then Exit;
  if not (FileExists(P) or DirectoryExists(P)) then Exit;
  for I := 0 to FItems.Items.Count - 1 do
    if SameText(FItems.Items[I].SubItems[2], P) then
      Exit;
  Li := FItems.Items.Add;
  Li.Caption := ExtractFileName(P);
  if DirectoryExists(P) then
  begin
    Size := 0;
    try
      Size := TarSourceSize([P]);
    except
    end;
    Li.SubItems.Add(FormatSize(Size));
    Li.SubItems.Add('Folder');
  end
  else
  begin
    Li.SubItems.Add(FormatSize(TFile.GetSize(P)));
    Li.SubItems.Add(IfThen(ExtractFileExt(P) = '', 'File', UpperCase(Copy(ExtractFileExt(P), 2, 10)) + ' file'));
  end;
  Li.SubItems.Add(P);
  FSavePath.Text := '';
end;

procedure TZipWizard.AddFilesClick(Sender: TObject);
var
  D: TOpenDialog;
  F: string;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Options := [ofAllowMultiSelect, ofFileMustExist, ofPathMustExist, ofEnableSizing];
    D.Title := 'Add Files';
    if D.Execute then
      for F in D.Files do
        AddItemPath(F);
  finally
    D.Free;
  end;
end;

procedure TZipWizard.AddFolderClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(Self);
  try
    D.Options := [fdoPickFolders, fdoPathMustExist];
    D.Title := 'Add Folder';
    if D.Execute then
      AddItemPath(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TZipWizard.RemoveItemClick(Sender: TObject);
var
  I: Integer;
begin
  for I := FItems.Items.Count - 1 downto 0 do
    if FItems.Items[I].Selected then
      FItems.Items.Delete(I);
  FSavePath.Text := '';
end;

procedure TZipWizard.SelectItemsChange(Sender: TObject; Item: TListItem; Change: TItemChange);
begin
  FRemoveItem.Enabled := FItems.SelCount > 0;
end;

procedure TZipWizard.OptionsClick(Sender: TObject);
begin
  FCompress := Application.MessageBox(
    'Compress the files before encrypting?' + sLineBreak + sLineBreak +
    'Yes = smaller archive for documents and text (a little slower).' + sLineBreak +
    'No = fastest, and the same as the classic PGP Zip (best for programs, photos and archives).',
    'Zip Options', MB_YESNO or MB_ICONQUESTION) = IDYES;
end;

{ ---- Encrypt / Keys / Passphrase -------------------------------------------------------- }

procedure TZipWizard.ModeClick(Sender: TObject);
begin
  FMode := TZipMode(TRadioButton(Sender).Tag);
  if FInfo <> nil then
    FInfo.Lines.Text := ModeInfo[FMode];
end;

procedure TZipWizard.EnsureOwnKey;
var
  K: TKeyInfo;
begin
  if FOwnPrint <> '' then Exit;
  FOwnPrint := OwnKeyFingerprint(FEngine, FKeys);     { your default key (Tools > Options > Keys), else the first }
end;

procedure TZipWizard.RefreshRecipients;
var
  I: Integer;
  K: TKeyInfo;
  Fp: string;
begin
  EnsureOwnKey;
  FRecipList.Items.Clear;
  if FOwnPrint <> '' then
    for K in FKeys do
      if SameText(K.Fingerprint, FOwnPrint) then
        FRecipList.Items.Add(K.DisplayName + ' <' + K.DisplayEmail + '>  (you)');
  { master keys (Tools > Options) go on every archive }
  SetLength(FMasterPrints, 0);
  for Fp in UsableMasterKeys(FEngine, FKeys) do
    if (not SameText(Fp, FOwnPrint)) and (FRecipPrint.IndexOf(Fp) < 0) then
    begin
      FMasterPrints := FMasterPrints + [Fp];
      for K in FKeys do
        if SameText(K.Fingerprint, Fp) then
          FRecipList.Items.Add(K.DisplayName + IfThen(K.DisplayEmail = '', '', ' <' + K.DisplayEmail + '>') +
            '  (master key)');
    end;
  for I := 0 to FRecipPrint.Count - 1 do
    for K in FKeys do
      if SameText(K.Fingerprint, FRecipPrint[I]) then
      begin
        FRecipList.Items.Add(K.DisplayName + IfThen(K.DisplayEmail = '', '', ' <' + K.DisplayEmail + '>'));
        Break;
      end;
end;

procedure TZipWizard.AddKeyClick(Sender: TObject);
var
  Chosen: TArray<string>;
  F: string;
begin
  if Length(FKeys) = 0 then
    FKeys := ListKeysOrExplain(FEngine);
  if SelectRecipients(Self, FKeys, Chosen) then
  begin
    for F in Chosen do
      if (FRecipPrint.IndexOf(F) < 0) and not SameText(F, FOwnPrint) then
        FRecipPrint.Add(F);
    RefreshRecipients;
  end;
end;

procedure TZipWizard.RemoveKeyClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := FRecipList.ItemIndex;
  if FOwnPrint <> '' then
    Dec(Idx);            { first row is always the owner's own key }
  Dec(Idx, Length(FMasterPrints));     { then the master keys }
  if (FRecipList.ItemIndex >= 0) and (Idx >= 0) and (Idx < FRecipPrint.Count) then
  begin
    FRecipPrint.Delete(Idx);
    RefreshRecipients;
  end
  else if FRecipList.ItemIndex = 0 then
    Application.MessageBox('Your own key stays in the list so you can always open the archive.',
      'CryptLok Zip', MB_OK or MB_ICONINFORMATION)
  else if (FRecipList.ItemIndex > 0) and (Idx < 0) then
    Application.MessageBox('Master keys are added to everything you encrypt. Change them in Tools > Options.',
      'CryptLok Zip', MB_OK or MB_ICONINFORMATION);
end;

procedure TZipWizard.PassChange(Sender: TObject);
begin
  FQuality.SetPercent(PassphraseQuality(FPass1.Text));
end;

procedure TZipWizard.ShowKeysClick(Sender: TObject);
var
  C: Char;
begin
  if FShowKeys.Checked then C := #0 else C := '*';
  FPass1.PasswordChar := C;
  FPass2.PasswordChar := C;
end;

{ ---- Sign & Save ------------------------------------------------------------------------ }

procedure TZipWizard.RefreshSignCombo;
var
  K: TKeyInfo;
  Keep: Integer;
begin
  Keep := FSignCombo.ItemIndex;
  FSignCombo.Items.BeginUpdate;
  try
    FSignCombo.Items.Clear;
    FSignCombo.Items.Add('<none>');
    for K in FKeys do
      if K.HasSecret and not K.Revoked and not K.Expired and not K.Disabled then
        FSignCombo.Items.Add(K.DisplayName + IfThen(K.DisplayEmail = '', '', ' <' + K.DisplayEmail + '>') +
          '  ' + K.ShortId);
  finally
    FSignCombo.Items.EndUpdate;
  end;
  if (Keep < 0) or (Keep >= FSignCombo.Items.Count) then
    Keep := 0;
  FSignCombo.ItemIndex := Keep;
  if FMode = zmSda then
  begin
    FSignCombo.ItemIndex := 0;
    FSignCombo.Enabled := False;
    FSignNote.Caption := 'A self-decrypting archive is not signed.';
  end
  else
  begin
    FSignCombo.Enabled := True;
    FSignNote.Caption := '';
  end;
end;

procedure TZipWizard.IconBrowseClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Choose the program icon';
    D.Filter := 'Icons (*.ico)|*.ico';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then
    begin
      FIconFile := D.FileName;
      FIconEdit.Text := D.FileName;
    end
    else if FIconFile <> '' then
      if Application.MessageBox('Use the default CryptLok icon again?', 'Program icon',
        MB_YESNO or MB_ICONQUESTION) = IDYES then
      begin
        FIconFile := '';
        FIconEdit.Text := '(default CryptLok icon)';
      end;
  finally
    D.Free;
  end;
end;

procedure TZipWizard.BrowseClick(Sender: TObject);
var
  D: TSaveDialog;
begin
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Save Zip';
    if FMode = zmSign then
    begin
      D.Filter := 'Signed files (*.sig)|*.sig|All files (*.*)|*.*';
      D.DefaultExt := 'sig';
    end
    else if FMode = zmSda then
    begin
      D.Filter := 'Programs (*.exe)|*.exe|All files (*.*)|*.*';
      D.DefaultExt := 'exe';
    end
    else
    begin
      D.Filter := 'Zip archives (*.pgp)|*.pgp|All files (*.*)|*.*';
      D.DefaultExt := 'pgp';
    end;
    D.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    D.FileName := FSavePath.Text;
    if D.Execute then
      FSavePath.Text := D.FileName;
  finally
    D.Free;
  end;
end;

{ ---- create ------------------------------------------------------------------------------ }

procedure TZipWizard.TimerTick(Sender: TObject);
begin
  FLock.Enter;
  try
    FProgress.Position := FWorkPct;
    FStatus.Caption := FWorkStep;
  finally
    FLock.Leave;
  end;
end;

{ Destroys the original items after the archive exists.  An item that contains the archive itself
  (a folder the archive was saved into) is never touched. }
procedure TZipWizard.ShredOriginals(const AItems: TArray<string>; const AArchive: string);
var
  Safe: TArray<string>;
  Item, Prefix, Summary: string;
begin
  SetLength(Safe, 0);
  for Item in AItems do
  begin
    Prefix := IncludeTrailingPathDelimiter(Item);
    if DirectoryExists(Item) and SameText(Copy(ExpandFileName(AArchive), 1, Length(Prefix)), Prefix) then
    begin
      FSummary.Lines.Add('Kept (the archive is inside it): ' + Item);
      Continue;
    end;
    Safe := Safe + [Item];
  end;
  FSummary.Lines.Add('');
  if ShredAfterConfirm(Self, FEngine, Safe, Summary) then
    FSummary.Lines.Add('Original items shredded.')
  else
    FSummary.Lines.Add('Original items were not (all) shredded.');
  FSummary.Lines.Add(Summary);
end;

procedure TZipWizard.RunCreate;
var
  Req: TZipRequest;
  Res: TCryptoResult;
  SignIdx, I: Integer;
  SignKey: TKeyInfo;
  Names: string;
  Pw: TBytes;
  R: TModalResult;
  Items: TArray<string>;
  Item, Tmp: string;
begin
  FillChar(Req, SizeOf(Req), 0);
  Items := ItemPaths;
  Req.Items := Items;
  Req.OutFile := Trim(FSavePath.Text);
  Req.Compress := FCompress;
  Names := '';
  if FMode in [zmPass, zmSda] then
  begin
    Req.SymPass := PassphraseToBytes(FPass1.Text);
    Names := IfThen(FMode = zmSda, 'Self-decrypting archive, protected by a passphrase',
      'Encrypting with a passphrase');
    Req.Sda := FMode = zmSda;
    if Req.Sda then
      Req.SdaIcon := FIconFile;
  end
  else if FMode = zmSign then
    Names := 'Signing only (the files are not encrypted)'
  else
  begin
    if FOwnPrint <> '' then
      Req.Recipients := [FOwnPrint];
    for I := 0 to FRecipPrint.Count - 1 do
      Req.Recipients := Req.Recipients + [FRecipPrint[I]];
    Req.Recipients := WithMasterKeysIn(FEngine, FKeys, Req.Recipients);
    Names := Format('Encrypting to %d key(s)', [Length(Req.Recipients)]);
  end;

  SignIdx := FSignCombo.ItemIndex;
  if (SignIdx > 0) and (FMode <> zmSda) then
  begin
    { the combo lists signing-capable private keys in keyring order }
    I := 0;
    for SignKey in FKeys do
      if SignKey.HasSecret and not SignKey.Revoked and not SignKey.Expired and not SignKey.Disabled then
      begin
        Inc(I);
        if I = SignIdx then
        begin
          Req.Signer := SignKey.Fingerprint;
          Break;
        end;
      end;
    R := AskPassCached(Self, SignKey.KeyId, SignKey.DisplayName + ' ' + SignKey.ShortId,
      'Enter the passphrase of the signing key.', Pw);
    if R <> mrOk then
    begin
      WipeBytes(Req.SymPass);
      Exit;
    end;
    Req.SignerPass := Pw;
  end;

  ShowPage(zpProgress);
  FSummary.Lines.Clear;
  FSummary.Lines.Add('Zip');
  FSummary.Lines.Add('    Creating ' + ExtractFileName(Req.OutFile));
  FSummary.Lines.Add('Reporting');
  FSummary.Lines.Add('    ' + Names + IfThen(Req.Signer <> '', ' and signing', ''));
  FSummary.Lines.Add('Files & Folders');
  for Item in Items do
    FSummary.Lines.Add('    ' + ExtractFileName(ExcludeTrailingPathDelimiter(Item)));
  FProgress.Position := 0;
  FWorkPct := 0;
  FWorkStep := 'Starting';
  FFinished := False;
  UpdateButtons;
  FTimer.Enabled := True;
  try
    RunBusy(
      procedure
      begin
        Res := CreateZip(FEngine, Req,
          procedure(const AStep: string; APercent: Integer)
          begin
            FLock.Enter;
            try
              FWorkStep := AStep;
              FWorkPct := APercent;
            finally
              FLock.Leave;
            end;
          end);
      end);
  finally
    FTimer.Enabled := False;
    if Req.Signer <> '' then
      NotePassphrase(KeyIdOf(Req.Signer), Req.SignerPass, Res.Ok, Res.WrongPassphrase);
    WipeBytes(Req.SymPass);
    WipeBytes(Req.SignerPass);
    Tmp := FPass1.Text;
    WipeString(Tmp);
    FPass1.Text := '';
    FPass2.Text := '';
  end;
  FFinished := True;
  FCreated := Res.Ok;
  if Res.Ok then
  begin
    FOutFile := Req.OutFile;
    FProgress.Position := 100;
    FStatus.Caption := 'Finished';
    TLabel(FPages[zpProgress].Controls[0]).Caption := 'Finished';
    TLabel(FPages[zpProgress].Controls[1]).Caption := 'Your zip is secured.';
    FBanner.SetStep(3, True);
    if FShredOrig.Checked and (FMode <> zmSign) and FileExists(Req.OutFile) and (TFile.GetSize(Req.OutFile) > 0) then
      ShredOriginals(Items, Req.OutFile);
  end
  else
  begin
    FStatus.Caption := 'Failed';
    TLabel(FPages[zpProgress].Controls[0]).Caption := 'Not created';
    TLabel(FPages[zpProgress].Controls[1]).Caption := Res.Error;
    FSummary.Lines.Add('');
    FSummary.Lines.Add('Error: ' + Res.Error);
  end;
  UpdateButtons;
  FNext.Enabled := True;
  FNext.Caption := 'Finish';
end;

function RunZipWizard(AOwner: TComponent; const AEngine: IKeyEngine;
  const AInitialItems: TArray<string>; out AOutFile: string): Boolean;
var
  W: TZipWizard;
begin
  AOutFile := '';
  W := TZipWizard.CreateWizard(AOwner, AEngine, AInitialItems);
  try
    Result := W.ShowModal = mrOk;
    if Result then
      AOutFile := W.FOutFile;
  finally
    W.Free;
  end;
end;

end.

unit OPD.MainForm;

{ Main window: classic key manager look - dark sidebar with collapsible
  sections, header band with search box, and a tree-style key list drawn
  by hand (owner-drawn virtual TListView). }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Menus, Vcl.Dialogs, Vcl.GraphUtil,
  Vcl.Imaging.pngimage, OPD.Theme, OPD.Engine, OPD.ClipboardService, OPD.DiskPages, OPD.KeyringPages;

const
  APP_NAME = 'CryptLok';

type
  TSelectEvent = procedure(ASection, AItem: Integer) of object;

  TSideSection = record
    Title: string;
    Items: TArray<string>;
    Enabled: TArray<Boolean>;
  end;

  TSidebar = class(TCustomControl)
  private
    FSections: TArray<TSideSection>;
    FActive: Integer;
    FItem: Integer;
    FOnSelect: TSelectEvent;
    FIcons: TDictionary<string, TPngImage>;
    FHot: Integer;
    function HeaderHeight: Integer;
    function ItemHeight: Integer;
    function HitTest(X, Y: Integer; out ASection, AItem: Integer): Boolean;
    function SectionTop(ASection: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Select(ASection, AItem: Integer);
    property Active: Integer read FActive;
    property ActiveItem: Integer read FItem;
    property OnSelect: TSelectEvent read FOnSelect write FOnSelect;
  end;

  { the key list: right-clicking the column header offers the column choices }
  TKeyListView = class(TListView)
  private
    FOnHeaderMenu: TNotifyEvent;
    FMenuAt: TPoint;
    procedure WMContextMenu(var Msg: TWMContextMenu); message WM_CONTEXTMENU;
  public
    property OnHeaderMenu: TNotifyEvent read FOnHeaderMenu write FOnHeaderMenu;
    property MenuAt: TPoint read FMenuAt;
  end;

  TRowKind = (rkKey, rkUid, rkSub);
  TRow = record
    Kind: TRowKind;
    Key: Integer;
    Sub: Integer;
  end;

  TColumnDef = record
    Id: string;
    Caption: string;
    Width: Integer;
    Visible: Boolean;
  end;

  TMainForm = class(TForm)
  private
    FEngine: IKeyEngine;
    FKeys: TKeyInfoArray;
    FRows: TList<TRow>;
    FExpanded: TDictionary<string, Boolean>;
    FSidebar: TSidebar;
    FBand: TPanel;
    FBandTitle: TLabel;
    FBandIcon: TImage;
    FSearch: TEdit;
    FList: TListView;
    FPlaceholder: TLabel;
    FEmpty: TPanel;
    FEmptyText: TLabel;
    FEmptyImport, FEmptyNew: TButton;
    FStatus: TStatusBar;
    FMenu: TMainMenu;
    FColDefs: TArray<TColumnDef>;
    FColDefaults: TArray<TColumnDef>;
    FColItems: TArray<TMenuItem>;
    FColPopup: TPopupMenu;
    FColPopupItems: TArray<TMenuItem>;
    FIconCache: TDictionary<string, TPngImage>;
    FPrivateOnly: Boolean;
    FAutoImport: string;
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FClearCacheItem: TMenuItem;
    FPurgeTimer: TTimer;
    FClip: TClipboardService;
    FQuitting: Boolean;
    FDisks: TDiskController;
    FZipPending: TStringList;
    FZipTimer: TTimer;
    FShredPending: TStringList;
    FShredTimer: TTimer;
    FNewDisk: TNewDiskPage;
    FMyDisks: TMyDisksPage;
    FBackupPage: TBackupPage;
    FLocationPage: TLocationPage;
    FBandButton: TButton;
    FDiskMenu: TMenuItem;
    FListMenu: TPopupMenu;
    FAutoItems: TArray<TMenuItem>;
    function KeysNow: TKeyInfoArray;
    procedure CreateDiskClick(Sender: TObject);
    procedure TrayPopup(Sender: TObject);
    procedure ClearCacheClick(Sender: TObject);
    procedure PurgeTick(Sender: TObject);
    procedure DiskMenuClick(Sender: TObject);
    procedure BuildTray;
    procedure BuildClipItems(AParent: TMenuItem);
    procedure ClipClick(Sender: TObject);
    procedure AutoClearClick(Sender: TObject);
    procedure TrayNotify(const ATitle, AMessage: string);
    procedure TrayOpen(Sender: TObject);
    procedure MainClose(Sender: TObject; var Action: TCloseAction);
    function Icon(const AName: string): TPngImage;
    procedure BuildMenu;
    procedure BuildColumns;
    procedure RebuildRows;
    procedure LoadKeys;
    procedure SelectPage(ASection, AItem: Integer);
    procedure UpdateEmptyState;
    procedure LoadColumnPrefs;
    procedure HeaderMenuPopup(Sender: TObject);
    procedure SyncColumnChecks;
    procedure SaveColumnPrefs;
    procedure ResetColumnsClick(Sender: TObject);
    procedure ShredClick(Sender: TObject);
    procedure AutoQuitTick(Sender: TObject);
    procedure WipeClick(Sender: TObject);
    procedure OptionsClick(Sender: TObject);
    procedure ShredTimerTick(Sender: TObject);
    procedure EmptyResize(Sender: TObject);
    procedure StartNewZip(const AItems: TArray<string>);
    procedure StartOpenZip(const AFile: string);
    procedure SignFileClick(Sender: TObject);
    procedure VerifySigClick(Sender: TObject);
    procedure StartViewFile;
    procedure QueueZipItems(const AItems: TArray<string>);
    procedure ZipTimerTick(Sender: TObject);
    procedure HandleLaunchArg(const AArg: string);
    procedure ExplorerClick(Sender: TObject);
    procedure WMCopyData(var Msg: TWMCopyData); message WM_COPYDATA;
    procedure ListData(Sender: TObject; Item: TListItem);
    procedure ListDrawItem(Sender: TCustomListView; Item: TListItem; Rect: TRect;
      State: TOwnerDrawState);
    procedure ListMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer);
    procedure ListDblClick(Sender: TObject);
    function SelectedKey(out AKey: TKeyInfo): Boolean;
    procedure AddCtx(const ACap: string; AClick: TNotifyEvent);
    procedure NewKeyClick(Sender: TObject);
    procedure PropsClick(Sender: TObject);
    procedure CopyKeyClick(Sender: TObject);
    procedure ExportKeyClick(Sender: TObject);
    procedure SignKeyClick(Sender: TObject);
    procedure DeleteKeyClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure RestartApp;
    procedure AboutClick(Sender: TObject);
    procedure ColumnToggle(Sender: TObject);
    procedure ToggleRow(AIndex: Integer);
    procedure DoShowAuto(Sender: TObject);
    procedure DrawBar(ACanvas: TCanvas; const R: TRect; AFraction: Double; AColor: TColor);
    function RowText(const ARow: TRow; const AColId: string): string;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RunImport(const AFiles: TArray<string>);
    procedure ClipKeysChanged(Sender: TObject);
  end;

var
  MainForm: TMainForm;

implementation

uses
  System.StrUtils, System.Math, System.IOUtils, System.IniFiles, Winapi.CommCtrl, Vcl.Clipbrd, OPD.ImportDialog, OPD.RecipientDialog,
  OPD.KeyDialogs, OPD.ZipWizard, OPD.ZipViewer, OPD.AboutDialog, OPD.ShellDialog, OPD.ShredDialog, OPD.WipeDialog, OPD.ViewerDialog, OPD.OptionsDialog, OPD.PrefsDialog, OPD.MasterKeys, OPD.SigFiles, OPD.PassCache;

const
  SIDE_BG = $002C2A28;
  ACTIVE_TOP = $00756B64;
  ACTIVE_BOT = $00565049;
  INACT_TOP = $003A3734;
  INACT_BOT = $002D2B29;
  BAND_TOP = $00423E3B;
  BAND_BOT = $00201E1C;
  NAME_BG = $00F6F6F6;

{ ---- TSidebar ------------------------------------------------------------ }

constructor TSidebar.Create(AOwner: TComponent);
  procedure Add(const T: string; const Its: array of string; const En: array of Boolean);
  var
    S: TSideSection;
    I: Integer;
  begin
    S.Title := T;
    SetLength(S.Items, Length(Its));
    SetLength(S.Enabled, Length(Its));
    for I := 0 to High(Its) do
    begin
      S.Items[I] := Its[I];
      S.Enabled[I] := En[I];
    end;
    SetLength(FSections, Length(FSections) + 1);
    FSections[High(FSections)] := S;
  end;
begin
  inherited;
  DoubleBuffered := True;
  FIcons := TDictionary<string, TPngImage>.Create;
  FHot := -1;
  Add('Keys', ['All Keys', 'My Private Keys', 'Search for Keys'], [True, True, True]);
  Add('Zip', ['New Zip', 'Open a Zip'], [True, True]);
  Add('Disk', ['New Virtual Disk', 'My Disks', 'Encrypt Disk'], [True, True, False]);
  Add('Viewer', ['Open File...', 'View Clipboard'], [True, True]);
  Add('Key Management', ['Backup Keyring', 'Keyring Location'], [True, True]);
  FActive := 0;
  FItem := 0;
end;

destructor TSidebar.Destroy;
var
  P: TPngImage;
begin
  for P in FIcons.Values do P.Free;
  FIcons.Free;
  inherited;
end;

function TSidebar.HeaderHeight: Integer;
begin
  Result := DpiScale(52);
end;

function TSidebar.ItemHeight: Integer;
begin
  Result := DpiScale(26);
end;

function TSidebar.SectionTop(ASection: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to ASection - 1 do
  begin
    Inc(Result, HeaderHeight);
    if I = FActive then
      Inc(Result, Length(FSections[I].Items) * ItemHeight + IfThen(Length(FSections[I].Items) > 0, DpiScale(14), 0));
  end;
end;

function TSidebar.HitTest(X, Y: Integer; out ASection, AItem: Integer): Boolean;
var
  I, T, K: Integer;
begin
  Result := False;
  for I := 0 to High(FSections) do
  begin
    T := SectionTop(I);
    if (Y >= T) and (Y < T + HeaderHeight) then
    begin
      ASection := I;
      AItem := -1;
      Exit(True);
    end;
    if I = FActive then
      for K := 0 to High(FSections[I].Items) do
      begin
        if (Y >= T + HeaderHeight + DpiScale(6) + K * ItemHeight) and
           (Y < T + HeaderHeight + DpiScale(6) + (K + 1) * ItemHeight) then
        begin
          ASection := I;
          AItem := K;
          Exit(True);
        end;
      end;
  end;
end;

procedure TSidebar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  S, I: Integer;
begin
  inherited;
  if (Button = mbLeft) and HitTest(X, Y, S, I) then
  begin
    if I < 0 then
      Select(S, IfThen(Length(FSections[S].Items) > 0, 0, -1))
    else if FSections[S].Enabled[I] then
      Select(S, I);
  end;
end;

procedure TSidebar.Select(ASection, AItem: Integer);
begin
  FActive := ASection;
  FItem := AItem;
  Invalidate;
  if Assigned(FOnSelect) then
    FOnSelect(ASection, AItem);
end;

procedure TSidebar.Paint;
var
  I, K, T, Y: Integer;
  R, TR: TRect;
  Sec: TSideSection;
begin
  Canvas.Brush.Color := SIDE_BG;
  Canvas.FillRect(ClientRect);
  for I := 0 to High(FSections) do
  begin
    Sec := FSections[I];
    T := SectionTop(I);
    R := Rect(0, T, Width, T + HeaderHeight);
    if I = FActive then
      GradientFillCanvas(Canvas, ACTIVE_TOP, ACTIVE_BOT, R, gdVertical)
    else
      GradientFillCanvas(Canvas, INACT_TOP, INACT_BOT, R, gdVertical);
    Canvas.Pen.Color := $00181716;
    Canvas.MoveTo(0, R.Bottom - 1);
    Canvas.LineTo(Width, R.Bottom - 1);
    Canvas.Brush.Style := bsClear;
    ApplyUiFont(Canvas.Font, 10);
    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := IfThen(I = FActive, clWhite, $00C8C4C0);
    TR := Rect(DpiScale(18), R.Top, Width - 4, R.Bottom);
    DrawText(Canvas.Handle, PChar(Sec.Title), -1, TR, DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS);
    if (I = FActive) and (Length(Sec.Items) > 0) then
    begin
      Y := R.Bottom;
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := $00403C39;
      Canvas.FillRect(Rect(0, Y, Width, Y + Length(Sec.Items) * ItemHeight + DpiScale(14)));
      Canvas.Brush.Style := bsClear;
      for K := 0 to High(Sec.Items) do
      begin
        TR := Rect(0, Y + DpiScale(6) + K * ItemHeight, Width, Y + DpiScale(6) + (K + 1) * ItemHeight);
        if (K = FItem) then
        begin
          Canvas.Brush.Style := bsSolid;
          Canvas.Brush.Color := $00585349;
          Canvas.FillRect(TR);
          Canvas.Brush.Style := bsClear;
        end;
        ApplyUiFont(Canvas.Font, 9);
        if K = FItem then Canvas.Font.Style := [fsBold] else Canvas.Font.Style := [];
        if not Sec.Enabled[K] then
          Canvas.Font.Color := $00808078
        else if K = FItem then
          Canvas.Font.Color := clWhite
        else
          Canvas.Font.Color := $00D8D4D0;
        TR.Left := DpiScale(40);
        DrawText(Canvas.Handle, PChar(Sec.Items[K]), -1, TR, DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS);
        { small icon }
        if not FIcons.ContainsKey('IC_SEC_KEYS_16') then
          FIcons.Add('IC_SEC_KEYS_16', LoadPng('IC_SEC_KEYS', 16));
        if (I = 0) and Sec.Enabled[K] then
          Canvas.Draw(DpiScale(18), TR.Top + (ItemHeight - 16) div 2, FIcons['IC_SEC_KEYS_16']);
      end;
    end;
  end;
end;

{ ---- TMainForm ------------------------------------------------------------- }

procedure TMainForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WinClassName := 'TMainForm';
end;

constructor TMainForm.Create(AOwner: TComponent);
const
  Defs: array[0..9] of record Id, Cap: string; W: Integer; V: Boolean end = (
    (Id: 'keys'; Cap: 'Keys'; W: 250; V: True),
    (Id: 'email'; Cap: 'Email'; W: 190; V: False),
    (Id: 'validity'; Cap: 'Validity'; W: 72; V: True),
    (Id: 'verified'; Cap: 'Verified'; W: 64; V: False),
    (Id: 'trust'; Cap: 'Trust'; W: 72; V: True),
    (Id: 'size'; Cap: 'Size'; W: 76; V: True),
    (Id: 'desc'; Cap: 'Description'; W: 150; V: True),
    (Id: 'keyid'; Cap: 'Key ID'; W: 86; V: True),
    (Id: 'created'; Cap: 'Creation'; W: 84; V: True),
    (Id: 'expires'; Cap: 'Expiration'; W: 84; V: True));
var
  I: Integer;
  Info: string;
begin
  inherited CreateNew(AOwner);
  Caption := APP_NAME + ' - All Keys';
  Position := poScreenCenter;
  ClientWidth := DpiScale(1120);
  ClientHeight := DpiScale(620);
  Constraints.MinWidth := DpiScale(720);
  Constraints.MinHeight := DpiScale(420);
  ApplyUiFont(Font, 9);
  Color := clWhite;
  FRows := TList<TRow>.Create;
  FExpanded := TDictionary<string, Boolean>.Create;
  FIconCache := TDictionary<string, TPngImage>.Create;
  SetLength(FColDefs, Length(Defs));
  for I := 0 to High(Defs) do
  begin
    FColDefs[I].Id := Defs[I].Id;
    FColDefs[I].Caption := Defs[I].Cap;
    FColDefs[I].Width := Defs[I].W;
    FColDefs[I].Visible := Defs[I].V;
  end;
  { /home:<dir> uses another GnuPG home (testing aid) }
  Info := '';
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)).StartsWith('/home:') then
      Info := Copy(ParamStr(I), 7, MaxInt);
  FEngine := TGpgEngine.Create(Info);
  ApplyArmorSettings(FEngine);
  LoadPassCachePolicy(FEngine);
  FPurgeTimer := TTimer.Create(Self);       { wipes cached passphrases as soon as their time is up }
  FPurgeTimer.Interval := 15000;
  FPurgeTimer.OnTimer := PurgeTick;
  FColDefaults := Copy(FColDefs);
  LoadColumnPrefs;
  FClip := TClipboardService.Create(Self, FEngine, TrayNotify);
  FClip.OnKeysChanged := ClipKeysChanged;
  FZipPending := TStringList.Create;
  FZipTimer := TTimer.Create(Self);
  FZipTimer.Enabled := False;
  FZipTimer.Interval := 700;     { Explorer starts one program per selected file; wait for the rest }
  FZipTimer.OnTimer := ZipTimerTick;
  FShredPending := TStringList.Create;
  FShredTimer := TTimer.Create(Self);
  FShredTimer.Enabled := False;
  FShredTimer.Interval := 700;
  FShredTimer.OnTimer := ShredTimerTick;
  OnClose := MainClose;

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  FStatus.Panels.Add.Width := DpiScale(160);
  FStatus.Panels.Add.Width := DpiScale(700);

  FSidebar := TSidebar.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := alLeft;
  FSidebar.Width := DpiScale(210);
  FSidebar.OnSelect := SelectPage;

  FBand := TPanel.Create(Self);
  FBand.Parent := Self;
  FBand.Align := alTop;
  FBand.Height := DpiScale(56);
  FBand.BevelOuter := bvNone;
  FBand.ParentBackground := False;
  FBand.Color := BAND_BOT;
  FBand.DoubleBuffered := True;

  FBandIcon := TImage.Create(Self);
  FBandIcon.Parent := FBand;
  FBandIcon.SetBounds(DpiScale(10), DpiScale(4), DpiScale(48), DpiScale(48));
  FBandIcon.Stretch := True;
  FBandIcon.Proportional := True;
  FBandIcon.Transparent := True;
  FBandIcon.Picture.Graphic := LoadPng('IC_BAND_64');

  FBandTitle := TLabel.Create(Self);
  FBandTitle.Parent := FBand;
  FBandTitle.Left := DpiScale(60);
  FBandTitle.Top := DpiScale(14);
  FBandTitle.Transparent := True;
  ApplyUiFont(FBandTitle.Font, 12);
  FBandTitle.Font.Style := [fsBold];
  FBandTitle.Font.Color := clWhite;
  FBandTitle.Caption := 'All Keys';

  FSearch := TEdit.Create(Self);
  FSearch.Parent := FBand;
  FSearch.Anchors := [akTop, akRight];
  FSearch.SetBounds(FBand.Width - DpiScale(260), DpiScale(16), DpiScale(240), DpiScale(24));
  FSearch.TextHint := 'Search keys';
  FSearch.OnChange := SearchChange;

  FList := TKeyListView.Create(Self);
  TKeyListView(FList).OnHeaderMenu := HeaderMenuPopup;
  FList.Parent := Self;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.OwnerData := True;
  FList.OwnerDraw := True;
  FList.RowSelect := True;
  FList.ReadOnly := True;
  FList.BorderStyle := bsNone;
  FList.DoubleBuffered := True;
  FList.OnData := ListData;
  FList.OnDrawItem := ListDrawItem;
  FList.OnMouseDown := ListMouseDown;
  FList.OnDblClick := ListDblClick;
  FList.OnColumnClick := nil;
  FList.Font.Size := 9;

  { first-run help: shown instead of an empty key list }
  FEmpty := TPanel.Create(Self);
  FEmpty.Parent := Self;
  FEmpty.Align := alClient;
  FEmpty.BevelOuter := bvNone;
  FEmpty.ParentBackground := False;
  FEmpty.Color := clWindow;
  FEmpty.Visible := False;
  FEmpty.OnResize := EmptyResize;
  FEmptyText := TLabel.Create(Self);
  FEmptyText.Parent := FEmpty;
  FEmptyText.AutoSize := False;
  FEmptyText.WordWrap := True;
  FEmptyText.Alignment := taCenter;
  FEmptyText.Font.Size := 11;
  FEmptyText.Font.Color := clGrayText;
  FEmptyText.Transparent := False;
  FEmptyText.Color := clWindow;
  FEmptyImport := TButton.Create(Self);
  FEmptyImport.Parent := FEmpty;
  FEmptyImport.Caption := 'Import Keys...';
  FEmptyImport.OnClick := ImportClick;
  FEmptyNew := TButton.Create(Self);
  FEmptyNew.Parent := FEmpty;
  FEmptyNew.Caption := 'New Key Pair...';
  FEmptyNew.OnClick := NewKeyClick;

  FPlaceholder := TLabel.Create(Self);
  FPlaceholder.Parent := Self;
  FPlaceholder.Align := alClient;
  FPlaceholder.Alignment := taCenter;
  FPlaceholder.Layout := tlCenter;
  FPlaceholder.Visible := False;
  FPlaceholder.Font.Size := 11;
  FPlaceholder.Font.Color := clGrayText;

  FDisks := TDiskController.Create(Self, FEngine, TrayNotify);
  FNewDisk := TNewDiskPage.Create(Self, FEngine, FDisks, KeysNow);
  FNewDisk.Parent := Self;
  FNewDisk.Align := alClient;
  FNewDisk.Visible := False;
  FMyDisks := TMyDisksPage.Create(Self, FDisks);
  FMyDisks.Parent := Self;
  FMyDisks.Align := alClient;
  FMyDisks.Visible := False;
  FBackupPage := TBackupPage.Create(Self, FEngine, RestartApp);
  FBackupPage.Align := alClient;
  FBackupPage.Visible := False;
  FLocationPage := TLocationPage.Create(Self, FEngine, RestartApp);
  FLocationPage.Align := alClient;
  FLocationPage.Visible := False;
  FBandButton := TButton.Create(Self);
  FBandButton.Parent := FBand;
  FBandButton.Anchors := [akTop, akRight];
  FBandButton.SetBounds(FBand.Width - DpiScale(110), DpiScale(14), DpiScale(90), DpiScale(28));
  FBandButton.Caption := 'Create';
  FBandButton.OnClick := CreateDiskClick;
  FBandButton.Visible := False;
  BuildMenu;
  FListMenu := TPopupMenu.Create(Self);
  AddCtx('Key &Properties...', PropsClick);
  AddCtx('Copy &Public Key', CopyKeyClick);
  AddCtx('&Export Public Key...', ExportKeyClick);
  AddCtx('&Sign Key...', SignKeyClick);
  AddCtx('-', nil);
  AddCtx('&Delete...', DeleteKeyClick);
  FList.PopupMenu := FListMenu;
  BuildTray;
  BuildColumns;
  if FEngine.Available(Info) then
    FStatus.Panels[1].Text := 'Engine: ' + Info + '   Keyring: ' + FEngine.HomeDir
  else
    FStatus.Panels[1].Text := 'WARNING: ' + Info;

  { /import:file1;file2 - starts the import flow on startup (testing aid) }
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)).StartsWith('/import:') then
      FAutoImport := Copy(ParamStr(I), 9, MaxInt);
  OnShow := DoShowAuto;
end;

destructor TMainForm.Destroy;
var
  P: TPngImage;
begin
  if FQuitting and (FEngine <> nil) then
    FEngine.StopAgent;      { gpg-agent and scdaemon would otherwise keep running }
  FClip.Free;
  FZipPending.Free;
  FShredPending.Free;
  FDisks.Free;
  for P in FIconCache.Values do P.Free;
  FIconCache.Free;
  FExpanded.Free;
  FRows.Free;
  inherited;
end;

procedure TMainForm.DoShowAuto(Sender: TObject);
var
  Photos: TArray<TBytes>;
  Prefs: TKeyPrefs;
  Files: TArray<string>;
  Recip: TArray<string>;
  I: Integer;
  Op: string;
begin
  OnShow := nil;
  LoadKeys;
  if FAutoImport <> '' then
  begin
    Files := FAutoImport.Split([';']);
    RunImport(Files);
  end;
  { /page:newdisk|mydisks opens that page on startup (testing aid) }
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)) = '/page:newdisk' then FSidebar.Select(2, 0)
    else if LowerCase(ParamStr(I)) = '/page:mydisks' then FSidebar.Select(2, 1)
    else if LowerCase(ParamStr(I)) = '/page:backup' then FSidebar.Select(4, 0)
    else if LowerCase(ParamStr(I)) = '/page:location' then FSidebar.Select(4, 1)
    else if LowerCase(ParamStr(I)) = '/dlg:options' then ShowOptions(Self, FEngine)
    else if LowerCase(ParamStr(I)) = '/page:adduser' then
    begin
      FSidebar.Select(2, 0);
      FNewDisk.AddUser;
    end
    else if LowerCase(ParamStr(I)) = '/dlg:props' then
    begin
      if Length(FKeys) > 0 then ShowKeyProperties(Self, FEngine, FKeys[0]);
    end
    else if LowerCase(ParamStr(I)) = '/dlg:signfile' then
      RunSignFileDialog(Self, FEngine, '')
    else if LowerCase(ParamStr(I)) = '/dlg:sigs' then
    begin
      if Length(FKeys) > 0 then ShowCertifications(Self, FEngine, FKeys[High(FKeys)]);
    end
    else if LowerCase(ParamStr(I)) = '/dlg:sign' then
    begin
      if Length(FKeys) > 0 then RunSignKeyDialog(Self, FEngine, FKeys[High(FKeys)]);
    end
    else if LowerCase(ParamStr(I)) = '/dlg:prefs' then
    begin
      if Length(FKeys) > 0 then
      begin
        FEngine.ReadKeyExtras(FKeys[0].Fingerprint, Photos, Prefs);
        EditKeyPreferences(Self, FEngine, FKeys[0], Prefs);
      end;
    end
    else if LowerCase(ParamStr(I)) = '/dlg:newkey' then
      RunNewKeyDialog(Self, FEngine, Op)
    else if LowerCase(ParamStr(I)) = '/page:recipients' then
      SelectRecipients(Self, KeysNow, Recip)
    else if LowerCase(ParamStr(I)) = '/dlg:zip' then
      StartNewZip(nil)
    else if LowerCase(ParamStr(I)) = '/dlg:about' then
      AboutClick(nil)
    else if LowerCase(ParamStr(I)) = '/dlg:shell' then
      ExplorerClick(nil)
    else if LowerCase(ParamStr(I)) = '/dlg:shred' then
      ShredClick(nil)
    else if LowerCase(ParamStr(I)) = '/dlg:wipe' then
      WipeClick(nil)
    else if LowerCase(ParamStr(I)) = '/dlg:options' then
      OptionsClick(nil)
    else if LowerCase(ParamStr(I)).StartsWith('/autoquit:') then
    begin
      { testing aid: leave through File > Exit after N seconds }
      with TTimer.Create(Self) do
      begin
        Interval := StrToIntDef(Copy(ParamStr(I), 11, 5), 3) * 1000;
        OnTimer := AutoQuitTick;
        Enabled := True;
      end;
    end
    else if LowerCase(ParamStr(I)) = '/dlg:diff' then
      ShowTextDiff(Self, 'The signing test because we need it done.' + sLineBreak + 'Pay Alice 100 dollars today.',
        'The signing test because we need it done. But then someone changed it.' + sLineBreak + 'Pay Alice 900 dollars today.')
    else if LowerCase(ParamStr(I)) = '/dlg:viewerbad' then
      ShowTextViewer(Self, 'CryptLok Viewer - demo', 'WARNING: the signature is not valid. The text may have been changed.',
        'The signing test because we need it done. But then someone changed it.', False, True)
    else if LowerCase(ParamStr(I)) = '/dlg:viewer' then
      ShowTextViewer(Self, 'CryptLok Viewer - demo', 'Good signature from Claude Test Key <claude@example.org>',
        'This is demo text shown in the Viewer.' + sLineBreak + sLineBreak + 'Line three, with unicode: caf' + #$00E9 + ' ' + #$2713, True, False)
    else if LowerCase(ParamStr(I)).StartsWith('/viewfile:') then
      OpenZipFile(Self, FEngine, Copy(ParamStr(I), 11, MaxInt), True)
    else if LowerCase(ParamStr(I)).StartsWith('/zip:') or LowerCase(ParamStr(I)).StartsWith('/zipopen:') or
      LowerCase(ParamStr(I)).StartsWith('/shred:') or LowerCase(ParamStr(I)).StartsWith('/signfile:') or
      ((ParamStr(I) <> '') and (ParamStr(I)[1] <> '/') and FileExists(ParamStr(I))) then
      HandleLaunchArg(ParamStr(I));
  { /clip:encrypt|sign|encryptsign|decrypt|clear runs a clipboard action on startup }
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)).StartsWith('/clip:') then
    begin
      Op := LowerCase(Copy(ParamStr(I), 7, MaxInt));
      if Op = 'encrypt' then FClip.Execute(cpEncrypt)
      else if Op = 'sign' then FClip.Execute(cpSign)
      else if Op = 'encryptsign' then FClip.Execute(cpEncryptSign)
      else if Op = 'decrypt' then FClip.Execute(cpDecrypt)
      else if Op = 'clear' then FClip.ClearClipboard;
    end;
end;

{ True for exported key files (public/private key blocks) and old keyring files: those are imported. }
function IsKeyFile(const AFile: string): Boolean;
var
  F: TFileStream;
  Buf: TBytes;
  N: Integer;
  S, Ext: string;
begin
  Result := False;
  Ext := LowerCase(ExtractFileExt(AFile));
  if (Ext = '.pkr') or (Ext = '.skr') then Exit(True);
  try
    F := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, 200);
      N := F.Read(Buf[0], Length(Buf));
      SetLength(Buf, N);
    finally
      F.Free;
    end;
    S := TEncoding.ASCII.GetString(Buf);
    Result := S.Contains('BEGIN PGP PUBLIC KEY BLOCK') or S.Contains('BEGIN PGP PRIVATE KEY BLOCK');
  except
    Result := False;
  end;
end;

procedure TMainForm.StartNewZip(const AItems: TArray<string>);
var
  Made: string;
begin
  if RunZipWizard(Self, FEngine, AItems, Made) then
    TrayNotify('Zip created', Made);
end;

procedure TMainForm.StartOpenZip(const AFile: string);
var
  D: TOpenDialog;
  F: string;
begin
  F := AFile;
  if F = '' then
  begin
    D := TOpenDialog.Create(Self);
    try
      D.Title := 'Open a Zip';
      D.Filter := 'Zip archives (*.pgp)|*.pgp|OpenPGP files (*.pgp;*.gpg;*.asc)|*.pgp;*.gpg;*.asc|All files (*.*)|*.*';
      D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
      if not D.Execute then Exit;
      F := D.FileName;
    finally
      D.Free;
    end;
  end;
  if IsKeyFile(F) then
    RunImport([F])
  else if IsSignatureFile(F) then
    VerifySignatureFile(Self, FEngine, F)
  else
    OpenZipFile(Self, FEngine, F);
end;

procedure TMainForm.SignFileClick(Sender: TObject);
begin
  RunSignFileDialog(Self, FEngine, '');
end;

procedure TMainForm.VerifySigClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Choose the signature file to check';
    D.Filter := 'Signature files (*.sig;*.asc)|*.sig;*.asc|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then VerifySignatureFile(Self, FEngine, D.FileName);
  finally
    D.Free;
  end;
end;

procedure TMainForm.StartViewFile;
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Open an encrypted file in the Viewer';
    D.Filter := 'Encrypted or signed text (*.asc;*.pgp;*.gpg;*.txt)|*.asc;*.pgp;*.gpg;*.txt|All files (*.*)|*.*';
    D.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if not D.Execute then Exit;
    OpenZipFile(Self, FEngine, D.FileName, True);
  finally
    D.Free;
  end;
end;

procedure TMainForm.ExplorerClick(Sender: TObject);
begin
  ShowShellIntegration(Self);
end;

procedure TMainForm.AutoQuitTick(Sender: TObject);
begin
  TTimer(Sender).Enabled := False;
  ExitClick(nil);
end;

procedure TMainForm.ShredClick(Sender: TObject);
begin
  ShowShredDialog(Self, FEngine, nil);
end;

procedure TMainForm.WipeClick(Sender: TObject);
begin
  ShowWipeDialog(Self);
end;

procedure TMainForm.OptionsClick(Sender: TObject);
begin
  ShowOptions(Self, FEngine);
end;

procedure TMainForm.ShredTimerTick(Sender: TObject);
var
  Items: TArray<string>;
begin
  FShredTimer.Enabled := False;
  Items := FShredPending.ToStringArray;
  FShredPending.Clear;
  if Length(Items) > 0 then
    ShowShredDialog(Self, FEngine, Items);
end;

{ Explorer starts one process per selected file: each forwards its path here and the wizard opens
  once, shortly after the last one arrived. }
procedure TMainForm.QueueZipItems(const AItems: TArray<string>);
var
  S: string;
begin
  for S in AItems do
    if (S <> '') and (FZipPending.IndexOf(S) < 0) then
      FZipPending.Add(S);
  FZipTimer.Enabled := False;
  FZipTimer.Enabled := True;
end;

procedure TMainForm.ZipTimerTick(Sender: TObject);
var
  Items: TArray<string>;
begin
  FZipTimer.Enabled := False;
  Items := FZipPending.ToStringArray;
  FZipPending.Clear;
  if Length(Items) > 0 then
    StartNewZip(Items);
end;

procedure TMainForm.HandleLaunchArg(const AArg: string);
var
  Path: string;
begin
  if LowerCase(AArg).StartsWith('/zip:') then
  begin
    Path := Copy(AArg, 6, MaxInt);
    if FileExists(Path) or DirectoryExists(Path) then
      QueueZipItems([Path])
    else
      QueueZipItems(Path.Split([';']));     { several items in one argument (testing aid) }
  end
  else if LowerCase(AArg).StartsWith('/shred:') then
  begin
    Path := Copy(AArg, 8, MaxInt);
    if (Path <> '') and (FShredPending.IndexOf(Path) < 0) then
      FShredPending.Add(Path);
    FShredTimer.Enabled := False;
    FShredTimer.Enabled := True;
  end
  else if LowerCase(AArg).StartsWith('/zipopen:') then
  begin
    Path := Copy(AArg, 10, MaxInt);
    TThread.ForceQueue(nil, procedure begin StartOpenZip(Path); end);
  end
  else if LowerCase(AArg).StartsWith('/signfile:') then
  begin
    Path := Copy(AArg, 11, MaxInt);
    TThread.ForceQueue(nil, procedure begin RunSignFileDialog(Self, FEngine, Path); end);
  end
  else if (AArg <> '') and (AArg[1] <> '/') and FileExists(AArg) and
    MatchText(LowerCase(ExtractFileExt(AArg)), ['.sig', '.asc', '.pgp', '.gpg']) then
  begin
    { a plain file name: Windows "Open with" / double-click on a file type that points at the program }
    Path := AArg;
    TThread.ForceQueue(nil, procedure begin StartOpenZip(Path); end);
  end;
end;

procedure TMainForm.WMCopyData(var Msg: TWMCopyData);
var
  S, P: string;
begin
  if (Msg.CopyDataStruct <> nil) and (Msg.CopyDataStruct.dwData = $434C4B31) then
  begin
    SetString(S, PChar(Msg.CopyDataStruct.lpData), Msg.CopyDataStruct.cbData div SizeOf(Char));
    for P in S.Split([#1]) do
      HandleLaunchArg(P);
    Msg.Result := 1;
  end
  else
    inherited;
end;

function TMainForm.Icon(const AName: string): TPngImage;
var
  Key: string;
begin
  Key := AName + '_' + IntToStr(IconPx);
  if not FIconCache.TryGetValue(Key, Result) then
  begin
    Result := LoadPng('IC_' + AName, IconPx);
    FIconCache.Add(Key, Result);
  end;
end;

procedure TMainForm.BuildMenu;
  function Mi(AParent: TMenuItem; const ACap: string; AClick: TNotifyEvent = nil;
    AShort: TShortCut = 0): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACap;
    Result.OnClick := AClick;
    Result.ShortCut := AShort;
    AParent.Add(Result);
  end;
var
  F, E, V, T, K, H, Cols: TMenuItem;
  I: Integer;
begin
  FMenu := TMainMenu.Create(Self);
  F := TMenuItem.Create(Self); F.Caption := '&File'; FMenu.Items.Add(F);
  E := TMenuItem.Create(Self); E.Caption := '&Edit'; FMenu.Items.Add(E);
  V := TMenuItem.Create(Self); V.Caption := '&View'; FMenu.Items.Add(V);
  T := TMenuItem.Create(Self); T.Caption := '&Tools'; FMenu.Items.Add(T);
  K := TMenuItem.Create(Self); K.Caption := '&Keys'; FMenu.Items.Add(K);
  H := TMenuItem.Create(Self); H.Caption := '&Help'; FMenu.Items.Add(H);

  Mi(F, '&Import Keys...', ImportClick, ShortCut(Ord('I'), [ssCtrl]));
  Mi(F, '-');
  Mi(F, 'E&xit', ExitClick);
  Mi(E, '&Copy').Enabled := False;
  Mi(E, 'Select &All').Enabled := False;
  Cols := Mi(V, '&Columns');
  SetLength(FColItems, Length(FColDefs));
  for I := 0 to High(FColDefs) do
  begin
    FColItems[I] := Mi(Cols, FColDefs[I].Caption, ColumnToggle);
    FColItems[I].Tag := I;
    FColItems[I].Checked := FColDefs[I].Visible;
    if I = 0 then FColItems[I].Enabled := False;
  end;
  Mi(Cols, '-');
  Mi(Cols, '&Reset Columns', ResetColumnsClick);
  FColPopup := TPopupMenu.Create(Self);
  SetLength(FColPopupItems, Length(FColDefs));
  for I := 0 to High(FColDefs) do
  begin
    FColPopupItems[I] := TMenuItem.Create(Self);
    FColPopupItems[I].Caption := FColDefs[I].Caption;
    FColPopupItems[I].Tag := I;
    FColPopupItems[I].Checked := FColDefs[I].Visible;
    FColPopupItems[I].Enabled := I > 0;
    FColPopupItems[I].OnClick := ColumnToggle;
    FColPopup.Items.Add(FColPopupItems[I]);
  end;
  FColPopup.Items.Add(TMenuItem.Create(Self));
  FColPopup.Items[FColPopup.Items.Count - 1].Caption := '-';
  FColPopup.Items.Add(TMenuItem.Create(Self));
  FColPopup.Items[FColPopup.Items.Count - 1].Caption := '&Reset Columns';
  FColPopup.Items[FColPopup.Items.Count - 1].OnClick := ResetColumnsClick;
  Mi(V, '-');
  Mi(V, '&Refresh', RefreshClick, VK_F5);
  BuildClipItems(Mi(T, '&Clipboard'));
  Mi(T, '-');
  Mi(T, 'Sign a &File...', SignFileClick);
  Mi(T, 'Verify a Si&gnature File...', VerifySigClick);
  Mi(T, '-');
  Mi(T, '&Shred Files...', ShredClick);
  Mi(T, 'Wipe &Free Space...', WipeClick);
  Mi(T, '&Explorer Integration...', ExplorerClick);
  Mi(T, '&Options...', OptionsClick);
  Mi(K, '&Import Keys...', ImportClick);
  Mi(K, 'New &Key Pair...', NewKeyClick, ShortCut(Ord('N'), [ssCtrl]));
  Mi(K, '-');
  Mi(K, 'Key &Properties...', PropsClick, ShortCut(VK_RETURN, [ssAlt]));
  Mi(K, 'Copy &Public Key', CopyKeyClick);
  Mi(K, '&Export Public Key...', ExportKeyClick);
  Mi(K, '&Sign Key...', SignKeyClick);
  Mi(K, '-');
  Mi(K, '&Delete...', DeleteKeyClick, ShortCut(VK_DELETE, []));
  Mi(H, '&About ' + APP_NAME, AboutClick);
  Menu := FMenu;
end;

procedure TMainForm.BuildColumns;
var
  I: Integer;
  C: TListColumn;
begin
  for I := 0 to FList.Columns.Count - 1 do
    if (FList.Columns[I].Tag >= 0) and (FList.Columns[I].Tag <= High(FColDefs)) and (FList.Columns[I].Width > 0) then
      FColDefs[FList.Columns[I].Tag].Width := MulDiv(FList.Columns[I].Width, 96, UiPPI);
  FList.Columns.BeginUpdate;
  try
    FList.Columns.Clear;
    for I := 0 to High(FColDefs) do
      if FColDefs[I].Visible then
      begin
        C := FList.Columns.Add;
        C.Caption := FColDefs[I].Caption;
        C.Width := DpiScale(FColDefs[I].Width);
        C.Tag := I;
      end;
  finally
    FList.Columns.EndUpdate;
  end;
  FList.Invalidate;
end;

procedure TMainForm.ColumnToggle(Sender: TObject);
var
  I: Integer;
begin
  I := TMenuItem(Sender).Tag;
  FColDefs[I].Visible := not FColDefs[I].Visible;
  SyncColumnChecks;
  BuildColumns;
  SaveColumnPrefs;
end;

procedure TMainForm.SyncColumnChecks;
var
  I: Integer;
begin
  for I := 0 to High(FColDefs) do
  begin
    if I <= High(FColItems) then FColItems[I].Checked := FColDefs[I].Visible;
    if I <= High(FColPopupItems) then FColPopupItems[I].Checked := FColDefs[I].Visible;
  end;
end;

procedure TMainForm.HeaderMenuPopup(Sender: TObject);
begin
  SyncColumnChecks;
  FColPopup.Popup(TKeyListView(FList).MenuAt.X, TKeyListView(FList).MenuAt.Y);
end;

procedure TKeyListView.WMContextMenu(var Msg: TWMContextMenu);
var
  Hdr: HWND;
  R: TRect;
  P: TPoint;
begin
  Hdr := ListView_GetHeader(Handle);
  P := Point(Msg.XPos, Msg.YPos);
  if (Msg.XPos <> -1) and (Hdr <> 0) and GetWindowRect(Hdr, R) and PtInRect(R, P) and Assigned(FOnHeaderMenu) then
  begin
    FMenuAt := P;
    FOnHeaderMenu(Self);
    Msg.Result := 0;
    Exit;
  end;
  inherited;
end;

function ColumnIniPath(const AEngine: IKeyEngine): string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir))) +
    'settings.ini';
end;

{ Which columns are shown and how wide they are is remembered between runs. }
procedure TMainForm.LoadColumnPrefs;
var
  Ini: TIniFile;
  I, W, H, L, T: Integer;
  R: TRect;
begin
  Ini := TIniFile.Create(ColumnIniPath(FEngine));
  try
    if Ini.ValueExists('Window', 'Width') then
    begin
      W := MulDiv(EnsureRange(Ini.ReadInteger('Window', 'Width', 0), 300, 6000), UiPPI, 96);
      H := MulDiv(EnsureRange(Ini.ReadInteger('Window', 'Height', 0), 300, 4000), UiPPI, 96);
      L := Ini.ReadInteger('Window', 'Left', 0);
      T := Ini.ReadInteger('Window', 'Top', 0);
      R := Rect(L, T, L + W, T + H);
      { only when most of it is on a monitor that is still connected }
      if Screen.MonitorFromPoint(Point(L + 60, T + 20), mdNull) <> nil then
      begin
        Position := poDesigned;
        SetBounds(L, T, Max(W, Constraints.MinWidth), Max(H, Constraints.MinHeight));
        if Ini.ReadBool('Window', 'Maximized', False) then
          WindowState := wsMaximized;
      end;
    end;
    for I := 0 to High(FColDefs) do
    begin
      if I > 0 then
        FColDefs[I].Visible := Ini.ReadBool('Columns', 'Show_' + FColDefs[I].Id, FColDefs[I].Visible);
      FColDefs[I].Width := EnsureRange(Ini.ReadInteger('Columns', 'Width_' + FColDefs[I].Id, FColDefs[I].Width), 40, 900);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveColumnPrefs;
var
  Ini: TIniFile;
  I: Integer;
  WP: TWindowPlacement;
begin
  for I := 0 to FList.Columns.Count - 1 do
    if (FList.Columns[I].Tag >= 0) and (FList.Columns[I].Tag <= High(FColDefs)) and (FList.Columns[I].Width > 0) then
      FColDefs[FList.Columns[I].Tag].Width := MulDiv(FList.Columns[I].Width, 96, UiPPI);
  Ini := TIniFile.Create(ColumnIniPath(FEngine));
  try
    if HandleAllocated then
    begin
      WP.length := SizeOf(WP);
      if GetWindowPlacement(Handle, @WP) then
      begin
        Ini.WriteInteger('Window', 'Left', WP.rcNormalPosition.Left);
        Ini.WriteInteger('Window', 'Top', WP.rcNormalPosition.Top);
        Ini.WriteInteger('Window', 'Width', MulDiv(WP.rcNormalPosition.Right - WP.rcNormalPosition.Left, 96, UiPPI));
        Ini.WriteInteger('Window', 'Height', MulDiv(WP.rcNormalPosition.Bottom - WP.rcNormalPosition.Top, 96, UiPPI));
        Ini.WriteBool('Window', 'Maximized', WP.showCmd = SW_SHOWMAXIMIZED);
      end;
    end;
    for I := 0 to High(FColDefs) do
    begin
      Ini.WriteBool('Columns', 'Show_' + FColDefs[I].Id, FColDefs[I].Visible);
      Ini.WriteInteger('Columns', 'Width_' + FColDefs[I].Id, FColDefs[I].Width);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.ResetColumnsClick(Sender: TObject);
var
  I: Integer;
begin
  FColDefs := Copy(FColDefaults);
  SyncColumnChecks;
  BuildColumns;
  SaveColumnPrefs;
end;

procedure TMainForm.LoadKeys;
begin
  Screen.Cursor := crHourGlass;
  try
    FKeys := FEngine.ListKeys;
  finally
    Screen.Cursor := crDefault;
  end;
  RebuildRows;
end;

procedure TMainForm.RebuildRows;
var
  I, J: Integer;
  R: TRow;
  Q, Hay: string;
  Exp: Boolean;
begin
  FRows.Clear;
  Q := LowerCase(Trim(FSearch.Text));
  for I := 0 to High(FKeys) do
  begin
    if FPrivateOnly and not FKeys[I].HasSecret then Continue;
    if Q <> '' then
    begin
      Hay := LowerCase(FKeys[I].DisplayName + ' ' + FKeys[I].DisplayEmail + ' ' + FKeys[I].KeyId);
      for J := 0 to High(FKeys[I].UserIds) do
        Hay := Hay + ' ' + LowerCase(FKeys[I].UserIds[J].UserId);
      if Pos(Q, Hay) = 0 then Continue;
    end;
    R.Kind := rkKey; R.Key := I; R.Sub := -1;
    FRows.Add(R);
    if FExpanded.TryGetValue(FKeys[I].Fingerprint, Exp) and Exp then
    begin
      for J := 0 to High(FKeys[I].UserIds) do
      begin
        R.Kind := rkUid; R.Sub := J;
        FRows.Add(R);
      end;
      for J := 0 to High(FKeys[I].SubKeys) do
      begin
        R.Kind := rkSub; R.Sub := J;
        FRows.Add(R);
      end;
    end;
  end;
  FList.Items.Count := FRows.Count;
  FList.Invalidate;
  FStatus.Panels[0].Text := Format('%d key(s)', [Length(FKeys)]);
  UpdateEmptyState;
end;

procedure TMainForm.EmptyResize(Sender: TObject);
var
  W, Y: Integer;
begin
  W := Min(FEmpty.Width - DpiScale(60), DpiScale(560));
  FEmptyText.SetBounds((FEmpty.Width - W) div 2, FEmpty.Height div 2 - DpiScale(90), W, DpiScale(110));
  Y := FEmptyText.Top + FEmptyText.Height + DpiScale(14);
  FEmptyImport.SetBounds(FEmpty.Width div 2 - DpiScale(150), Y, DpiScale(140), DpiScale(32));
  FEmptyNew.SetBounds(FEmpty.Width div 2 + DpiScale(10), Y, DpiScale(140), DpiScale(32));
end;

{ An empty keyring is explained instead of showing a blank list. }
procedure TMainForm.UpdateEmptyState;
var
  Info: string;
  Show: Boolean;
begin
  Show := FList.Visible and (Length(FKeys) = 0) and (Trim(FSearch.Text) = '');
  if Show then
  begin
    if FEngine.Available(Info) then
    begin
      FEmptyText.Caption := 'No keys yet.' + sLineBreak + sLineBreak +
        'Import your existing keys (CryptLok reads old PGP keyring files and exported key files), ' +
        'or create a new key pair to get started.';
      FEmptyImport.Visible := True;
      FEmptyNew.Visible := True;
    end
    else
    begin
      FEmptyText.Caption := 'GnuPG was not found.' + sLineBreak + sLineBreak +
        'CryptLok needs GnuPG (gpg.exe). Put the GnuPG folder next to CryptLok.exe, or install Gpg4win.' +
        sLineBreak + Info;
      FEmptyImport.Visible := False;
      FEmptyNew.Visible := False;
    end;
    EmptyResize(nil);
    FEmpty.Visible := True;
    FEmpty.BringToFront;
  end
  else
    FEmpty.Visible := False;
end;

function TMainForm.KeysNow: TKeyInfoArray;
begin
  Result := ListKeysOrExplain(FEngine);
end;

procedure TMainForm.CreateDiskClick(Sender: TObject);
begin
  FNewDisk.CreateDisk;
end;

procedure TMainForm.SelectPage(ASection, AItem: Integer);
const
  Titles: array[0..4] of string = ('Keys', 'Zip', 'Disk', 'Viewer', 'Key Management');
  KeyMgmtPages: array[0..1] of string = ('Backup Keyring', 'Keyring Location');
  KeyPages: array[0..2] of string = ('All Keys', 'My Private Keys', 'Search for Keys');
  DiskPages: array[0..1] of string = ('New Virtual Disk', 'My Disks');
var
  T: string;
begin
  FList.Visible := False;
  FEmpty.Visible := False;
  FPlaceholder.Visible := False;
  FNewDisk.Visible := False;
  FMyDisks.Visible := False;
  FBackupPage.Visible := False;
  FLocationPage.Visible := False;
  FBandButton.Visible := False;
  FSearch.Visible := ASection = 0;
  if ASection = 0 then
  begin
    FPrivateOnly := AItem = 1;
    T := KeyPages[Max(AItem, 0)];
    FList.Visible := True;
    RebuildRows;
    if AItem = 2 then
      FSearch.SetFocus;
  end
  else if (ASection = 2) and (AItem in [0, 1]) then
  begin
    T := DiskPages[AItem];
    if AItem = 0 then
    begin
      FNewDisk.Prepare;
      FNewDisk.Visible := True;
      FBandButton.Visible := True;
    end
    else
    begin
      FMyDisks.RefreshList;
      FMyDisks.Visible := True;
    end;
  end
  else if ASection = 4 then
  begin
    T := KeyMgmtPages[Max(AItem, 0)];
    if AItem = 1 then
    begin
      FLocationPage.Prepare;
      FLocationPage.Visible := True;
    end
    else
    begin
      FBackupPage.Prepare;
      FBackupPage.Visible := True;
    end;
  end
  else if ASection = 3 then
  begin
    T := Titles[ASection];
    FPlaceholder.Caption := 'Read an encrypted or signed message in a window, without saving it to disk.' + sLineBreak +
      'Use "Open File..." for a text file, or "View Clipboard" for a message you copied.';
    FPlaceholder.Visible := True;
    TThread.ForceQueue(nil,
      procedure
      begin
        if AItem = 0 then StartViewFile else ViewClipboard(Self, FEngine);
      end);
  end
  else if ASection = 1 then
  begin
    T := Titles[ASection];
    FPlaceholder.Caption := 'Secure files and folders for storage or transfer.' + sLineBreak +
      'Use "New Zip" to create an encrypted archive, or "Open a Zip" to look inside one.';
    FPlaceholder.Visible := True;
    TThread.ForceQueue(nil,
      procedure
      begin
        if AItem = 0 then StartNewZip(nil) else StartOpenZip('');
      end);
  end
  else
  begin
    T := Titles[ASection];
    FPlaceholder.Caption := T + ' is coming in a later version.';
    FPlaceholder.Visible := True;
  end;
  FBandTitle.Caption := T;
  Caption := APP_NAME + ' - ' + T;
end;

procedure TMainForm.ListData(Sender: TObject; Item: TListItem);
begin
  Item.Caption := '';
end;

function FmtDate(ADate: TDateTime; const ANever: string): string;
begin
  if ADate = 0 then Result := ANever else Result := FormatDateTime('m/d/yyyy', ADate);
end;

function TMainForm.RowText(const ARow: TRow; const AColId: string): string;
var
  K: TKeyInfo;
  S: TSubKeyInfo;
  U: TUserIdInfo;
begin
  Result := '';
  K := FKeys[ARow.Key];
  case ARow.Kind of
    rkKey:
      begin
        if AColId = 'keys' then Result := K.DisplayName
        else if AColId = 'email' then Result := K.DisplayEmail
        else if AColId = 'trust' then Result := K.TrustText
        else if AColId = 'size' then Result := K.SizeText
        else if AColId = 'desc' then Result := K.Description
        else if AColId = 'keyid' then Result := K.ShortId
        else if AColId = 'created' then Result := FmtDate(K.Created, '')
        else if AColId = 'expires' then Result := FmtDate(K.Expires, 'Never');
      end;
    rkUid:
      begin
        U := K.UserIds[ARow.Sub];
        if AColId = 'keys' then Result := IfThen(U.Name <> '', U.Name, U.UserId)
        else if AColId = 'email' then Result := U.Email;
      end;
    rkSub:
      begin
        S := K.SubKeys[ARow.Sub];
        if AColId = 'keys' then Result := 'Subkey'
        else if AColId = 'size' then Result := IntToStr(S.Bits)
        else if AColId = 'desc' then Result := AlgoLabel(S.Algo) + ' (' + S.Caps + ')'
        else if AColId = 'keyid' then Result := '0x' + Copy(S.KeyId, Length(S.KeyId) - 7, 8)
        else if AColId = 'created' then Result := FmtDate(S.Created, '')
        else if AColId = 'expires' then Result := FmtDate(S.Expires, 'Never');
      end;
  end;
end;

procedure TMainForm.DrawBar(ACanvas: TCanvas; const R: TRect; AFraction: Double; AColor: TColor);
var
  B: TRect;
begin
  B := Rect(R.Left + 4, R.Top + (R.Height - DpiScale(10)) div 2, R.Right - 8,
    R.Top + (R.Height - DpiScale(10)) div 2 + DpiScale(10));
  ACanvas.Brush.Color := $00F0F0F0;
  ACanvas.Pen.Color := $00A0A0A0;
  ACanvas.Rectangle(B);
  if AFraction > 0 then
  begin
    ACanvas.Brush.Color := AColor;
    ACanvas.Pen.Style := psClear;
    ACanvas.Rectangle(B.Left + 1, B.Top + 1, B.Left + 1 + Round((B.Width - 2) * AFraction) + 1, B.Bottom);
    ACanvas.Pen.Style := psSolid;
  end;
end;

procedure TMainForm.ListDrawItem(Sender: TCustomListView; Item: TListItem; Rect: TRect;
  State: TOwnerDrawState);
var
  Row: TRow;
  K: TKeyInfo;
  I, X, Indent, W, Ic: Integer;
  Cell: TRect;
  Id, Txt, IconName: string;
  Sel, Faded: Boolean;
  C: TCanvas;
  Exp: Boolean;
  Frac: Double;
  Pic: TPngImage;
  Box: TRect;
begin
  C := Sender.Canvas;
  Row := FRows[Item.Index];
  K := FKeys[Row.Key];
  Sel := odSelected in State;
  Faded := (Row.Kind = rkKey) and (K.Expired or K.Revoked or K.Disabled);
  ApplyUiFont(C.Font, 9);
  Ic := IconPx;
  X := Rect.Left;
  for I := 0 to FList.Columns.Count - 1 do
  begin
    W := FList.Columns[I].Width;
    Cell := System.Types.Rect(X, Rect.Top, X + W, Rect.Bottom);
    Id := FColDefs[FList.Columns[I].Tag].Id;
    C.Brush.Style := bsSolid;
    if Sel then
    begin
      C.Brush.Color := clHighlight;
      C.Font.Color := clHighlightText;
    end
    else
    begin
      if Id = 'keys' then C.Brush.Color := NAME_BG else C.Brush.Color := clWhite;
      C.Font.Color := IfThen(Faded, clGrayText, clWindowText);
    end;
    C.FillRect(Cell);
    if Faded and (Id = 'keys') then C.Font.Style := [fsItalic] else C.Font.Style := [];
    Txt := RowText(Row, Id);
    if Id = 'keys' then
    begin
      Indent := Ord(Row.Kind) * DpiScale(18);
      if Row.Kind = rkKey then
      begin
        Box := System.Types.Rect(Cell.Left + 6 + Indent, Cell.Top + (Cell.Height - 9) div 2,
          Cell.Left + 15 + Indent, Cell.Top + (Cell.Height - 9) div 2 + 9);
        if (Length(K.UserIds) + Length(K.SubKeys)) > 0 then
        begin
          C.Pen.Color := $00909090;
          C.Brush.Color := clWhite;
          C.Rectangle(Box);
          C.MoveTo(Box.Left + 2, Box.Top + 4); C.LineTo(Box.Right - 2, Box.Top + 4);
          if not (FExpanded.TryGetValue(K.Fingerprint, Exp) and Exp) then
          begin
            C.MoveTo(Box.Left + 4, Box.Top + 2); C.LineTo(Box.Left + 4, Box.Bottom - 2);
          end;
          C.Brush.Color := IfThen(Sel, clHighlight, NAME_BG);
        end;
      end;
      case Row.Kind of
        rkKey:
          if K.Revoked then IconName := 'REVOKED'
          else if K.Expired or K.Disabled then IconName := 'EXPIRED'
          else if K.HasSecret then IconName := 'KEYPAIR'
          else IconName := 'PUBKEY';
        rkUid:
          if K.UserIds[Row.Sub].IsPhoto then IconName := 'PHOTO' else IconName := 'ENVELOPE';
        rkSub: IconName := 'SUBKEY';
      end;
      Pic := Icon(IconName);
      C.Draw(Cell.Left + 20 + Indent, Cell.Top + (Cell.Height - Ic) div 2, Pic);
      Cell.Left := Cell.Left + 24 + Ic + Indent;
      Cell.Right := Cell.Right - 4;
      C.Brush.Style := bsClear;
      DrawText(C.Handle, PChar(Txt), -1, Cell, DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);
    end
    else if (Id = 'validity') or (Id = 'trust') then
    begin
      if Row.Kind = rkKey then
      begin
        if Id = 'validity' then
          case K.Validity of
            'u', 'f': Frac := 1;
            'm': Frac := 0.5;
          else Frac := 0;
          end
        else
          case K.OwnerTrust of
            'u', 'f': Frac := 1;
            'm': Frac := 0.5;
          else Frac := 0;
          end;
        DrawBar(C, Cell, Frac, IfThen(Id = 'validity', $0046B43C, $00C08040));
      end;
    end
    else if Id = 'verified' then
    begin
      if (Row.Kind = rkKey) or (Row.Kind = rkUid) then
      begin
        if ((Row.Kind = rkKey) and K.IsVerified) or ((Row.Kind = rkUid) and
           CharInSet(K.UserIds[Row.Sub].Validity, ['m', 'f', 'u'])) then
          Pic := Icon('CHECK')
        else
          Pic := Icon('DASH');
        C.Draw(Cell.Left + (Cell.Width - Ic) div 2, Cell.Top + (Cell.Height - Ic) div 2, Pic);
      end;
    end
    else
    begin
      Cell.Left := Cell.Left + 6;
      Cell.Right := Cell.Right - 4;
      C.Brush.Style := bsClear;
      DrawText(C.Handle, PChar(Txt), -1, Cell, DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS or DT_NOPREFIX);
    end;
    Inc(X, W);
  end;
end;

procedure TMainForm.ToggleRow(AIndex: Integer);
var
  K: TKeyInfo;
  Exp: Boolean;
begin
  if (AIndex < 0) or (AIndex >= FRows.Count) or (FRows[AIndex].Kind <> rkKey) then Exit;
  K := FKeys[FRows[AIndex].Key];
  if not FExpanded.TryGetValue(K.Fingerprint, Exp) then Exp := False;
  FExpanded.AddOrSetValue(K.Fingerprint, not Exp);
  RebuildRows;
end;

procedure TMainForm.ListMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Item: TListItem;
  R: TRect;
begin
  Item := FList.GetItemAt(X, Y);
  if (Item = nil) or (Button <> mbLeft) then Exit;
  R := Item.DisplayRect(drBounds);
  if (X - R.Left >= 4) and (X - R.Left <= 18) then
    ToggleRow(Item.Index);
end;

procedure TMainForm.ListDblClick(Sender: TObject);
begin
  { double-click opens the key's properties, like the classic window }
  if FList.Visible and (FList.Selected <> nil) then
    PropsClick(Sender);
end;

procedure TMainForm.AddCtx(const ACap: string; AClick: TNotifyEvent);
var
  M: TMenuItem;
begin
  M := TMenuItem.Create(Self);
  M.Caption := ACap;
  M.OnClick := AClick;
  FListMenu.Items.Add(M);
end;

function TMainForm.SelectedKey(out AKey: TKeyInfo): Boolean;
begin
  Result := False;
  if not FList.Visible or (FList.Selected = nil) or (FList.Selected.Index >= FRows.Count) then
  begin
    Application.MessageBox('Select a key in the list first.', APP_NAME, MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  AKey := FKeys[FRows[FList.Selected.Index].Key];
  Result := True;
end;

procedure TMainForm.NewKeyClick(Sender: TObject);
var
  Fpr: string;
begin
  if RunNewKeyDialog(Self, FEngine, Fpr) then
  begin
    LoadKeys;
    TrayNotify('New key pair', 'Your new key pair was created.');
  end;
end;

procedure TMainForm.PropsClick(Sender: TObject);
var
  K: TKeyInfo;
begin
  if SelectedKey(K) and ShowKeyProperties(Self, FEngine, K) then
    LoadKeys;
end;

procedure TMainForm.CopyKeyClick(Sender: TObject);
var
  K: TKeyInfo;
  R: TCryptoResult;
begin
  if not SelectedKey(K) then Exit;
  R := FEngine.ExportPublicKey(K.Fingerprint);
  if R.Ok then
  begin
    Clipboard.AsText := R.Text;
    TrayNotify('Public key copied', K.DisplayName + ' - ready to paste.');
  end
  else
    Application.MessageBox(PChar('Not copied: ' + R.Error), APP_NAME, MB_OK or MB_ICONWARNING);
end;

procedure TMainForm.ExportKeyClick(Sender: TObject);
var
  K: TKeyInfo;
  R: TCryptoResult;
  D: TSaveDialog;
begin
  if not SelectedKey(K) then Exit;
  R := FEngine.ExportPublicKey(K.Fingerprint);
  if not R.Ok then
  begin
    Application.MessageBox(PChar('Not exported: ' + R.Error), APP_NAME, MB_OK or MB_ICONWARNING);
    Exit;
  end;
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Export Public Key';
    D.Filter := 'Armored public key (*.asc)|*.asc|All files (*.*)|*.*';
    D.DefaultExt := 'asc';
    D.FileName := StringReplace(K.DisplayName, ' ', '_', [rfReplaceAll]) + '-' + K.ShortId + '.asc';
    D.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if D.Execute then
    begin
      TFile.WriteAllText(D.FileName, R.Text, TEncoding.ASCII);
      TrayNotify('Public key exported', D.FileName);
    end;
  finally
    D.Free;
  end;
end;

procedure TMainForm.SignKeyClick(Sender: TObject);
var
  K: TKeyInfo;
begin
  if SelectedKey(K) and RunSignKeyDialog(Self, FEngine, K) then
    LoadKeys;
end;

procedure TMainForm.DeleteKeyClick(Sender: TObject);
var
  K: TKeyInfo;
  Msg: string;
  R: TCryptoResult;
begin
  if not SelectedKey(K) then Exit;
  if K.HasSecret then
    Msg := 'Delete the key PAIR for "' + K.DisplayName + '" ' + K.ShortId + '?' + sLineBreak + sLineBreak +
      'This removes your PRIVATE key. Without it you can no longer decrypt anything sent to this key. ' +
      'This cannot be undone. Make sure you have a backup.'
  else
    Msg := 'Delete the public key for "' + K.DisplayName + '" ' + K.ShortId + ' from your keyring?';
  if Application.MessageBox(PChar(Msg), 'Delete Key', MB_YESNO or MB_ICONWARNING or MB_DEFBUTTON2) <> IDYES then
    Exit;
  R := FEngine.DeleteKey(K.Fingerprint, K.HasSecret);
  if R.Ok then
    LoadKeys
  else
    Application.MessageBox(PChar('Not deleted: ' + R.Error), 'Delete Key', MB_OK or MB_ICONWARNING);
end;

procedure TMainForm.SearchChange(Sender: TObject);
begin
  RebuildRows;
end;

procedure TMainForm.ClipKeysChanged(Sender: TObject);
begin
  LoadKeys;
end;

procedure TMainForm.RunImport(const AFiles: TArray<string>);
begin
  if RunImportFlow(Self, FEngine, AFiles) then
    LoadKeys;
end;

procedure TMainForm.ImportClick(Sender: TObject);
var
  D: TOpenDialog;
  Files: TArray<string>;
  I: Integer;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Import Keys';
    D.Filter := 'Key files (*.pkr;*.skr;*.asc;*.gpg;*.pgp;*.key)|*.pkr;*.skr;*.asc;*.gpg;*.pgp;*.key|All files (*.*)|*.*';
    D.Options := [ofAllowMultiSelect, ofFileMustExist, ofPathMustExist, ofEnableSizing];
    if D.Execute then
    begin
      SetLength(Files, D.Files.Count);
      for I := 0 to D.Files.Count - 1 do
        Files[I] := D.Files[I];
      RunImport(Files);
    end;
  finally
    D.Free;
  end;
end;

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  LoadKeys;
end;

{ Key Management changed where the keyring is: start a fresh CryptLok (it waits for this one to end) and quit }
procedure TMainForm.RestartApp;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
begin
  Cmd := '"' + ParamStr(0) + '" /waitpid:' + IntToStr(GetCurrentProcessId);
  UniqueString(Cmd);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if CreateProcess(nil, PChar(Cmd), nil, nil, False, 0, nil, nil, SI, PI) then
  begin
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
  FQuitting := True;
  Close;
end;

procedure TMainForm.ExitClick(Sender: TObject);
begin
  FQuitting := True;
  Close;
end;

procedure TMainForm.MainClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveColumnPrefs;
  { X keeps CryptLok in the tray (clipboard commands live there) unless Exit was chosen or the option is off }
  if (not FQuitting) and (FTray <> nil) and LoadCloseToTray(FEngine) then
  begin
    Action := caNone;
    Hide;
    TrayNotify(APP_NAME, 'Still running in the tray. Use the tray icon to open it or to exit.');
    Exit;
  end;
  { closing the main window ends the program (Delphi terminates on the main form): make it a clean quit,
    including stopping the GnuPG background programs }
  FQuitting := True;
  Action := caFree;
end;

procedure TMainForm.TrayNotify(const ATitle, AMessage: string);
begin
  if FTray = nil then Exit;
  FTray.BalloonTitle := ATitle;
  FTray.BalloonHint := AMessage;
  FTray.BalloonFlags := bfInfo;
  FTray.ShowBalloonHint;
end;

procedure TMainForm.TrayOpen(Sender: TObject);
begin
  Show;
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  Application.BringToFront;
  SetForegroundWindow(Handle);
end;

procedure TMainForm.ClipClick(Sender: TObject);
begin
  case TMenuItem(Sender).Tag of
    0: FClip.ClearClipboard;
    1: FClip.EditClipboard;
    2: FClip.Execute(cpDecrypt);
    3: FClip.Execute(cpEncryptSign);
    4: FClip.Execute(cpSign);
    5: FClip.Execute(cpEncrypt);
  end;
end;

procedure TMainForm.AutoClearClick(Sender: TObject);
var
  I: Integer;
begin
  FClip.AutoClearSeconds := TMenuItem(Sender).Tag;
  for I := 0 to High(FAutoItems) do
    FAutoItems[I].Checked := FAutoItems[I].Tag = FClip.AutoClearSeconds;
end;

procedure TMainForm.BuildClipItems(AParent: TMenuItem);
  function Mi(AP: TMenuItem; const ACap: string; ATag: Integer; AClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACap;
    Result.Tag := ATag;
    Result.OnClick := AClick;
    AP.Add(Result);
  end;
const
  Secs: array[0..4] of Integer = (0, 30, 60, 120, 300);
  Names: array[0..4] of string = ('Never', 'After 30 seconds', 'After 1 minute',
    'After 2 minutes', 'After 5 minutes');
var
  Sub: TMenuItem;
  I, N: Integer;
begin
  Mi(AParent, 'Clear', 0, ClipClick);
  Mi(AParent, 'Edit...', 1, ClipClick);
  Mi(AParent, '-', -1, nil);
  Mi(AParent, 'Decrypt && Verify', 2, ClipClick);
  Mi(AParent, 'Encrypt && Sign', 3, ClipClick);
  Mi(AParent, 'Sign', 4, ClipClick);
  Mi(AParent, 'Encrypt', 5, ClipClick);
  Mi(AParent, '-', -1, nil);
  Sub := TMenuItem.Create(Self);
  Sub.Caption := 'Clear decrypted text from clipboard';
  AParent.Add(Sub);
  for I := 0 to High(Secs) do
  begin
    N := Length(FAutoItems);
    SetLength(FAutoItems, N + 1);
    FAutoItems[N] := Mi(Sub, Names[I], Secs[I], AutoClearClick);
    FAutoItems[N].RadioItem := True;
    FAutoItems[N].Checked := Secs[I] = FClip.AutoClearSeconds;
  end;
end;

procedure TMainForm.ClearCacheClick(Sender: TObject);
begin
  ClearPassCache;
  TrayNotify(APP_NAME, 'Cached passphrases were cleared.');
end;

procedure TMainForm.PurgeTick(Sender: TObject);
begin
  PurgeExpiredPasses;
end;

procedure TMainForm.TrayPopup(Sender: TObject);
var
  I: Integer;
  M: TMenuItem;
  L: Char;
  Any: Boolean;
begin
  FClearCacheItem.Enabled := CachedPassCount > 0;
  FDiskMenu.Clear;
  Any := False;
  for I := 0 to FDisks.Count - 1 do
  begin
    L := FDisks.MountedLetter(I);
    M := TMenuItem.Create(FDiskMenu);
    if L <> #0 then
      M.Caption := 'Unmount ' + FDisks.Item(I).Name + ' (' + L + ':)'
    else
      M.Caption := 'Mount ' + FDisks.Item(I).Name + '...';
    M.Tag := I;
    M.OnClick := DiskMenuClick;
    FDiskMenu.Add(M);
    if L <> #0 then Any := True;
  end;
  if FDisks.Count = 0 then
  begin
    M := TMenuItem.Create(FDiskMenu);
    M.Caption := '(no disks yet)';
    M.Enabled := False;
    FDiskMenu.Add(M);
  end
  else
  begin
    M := TMenuItem.Create(FDiskMenu);
    M.Caption := '-';
    FDiskMenu.Add(M);
    M := TMenuItem.Create(FDiskMenu);
    M.Caption := 'Unmount All';
    M.Tag := -1;
    M.Enabled := Any;
    M.OnClick := DiskMenuClick;
    FDiskMenu.Add(M);
  end;
end;

procedure TMainForm.DiskMenuClick(Sender: TObject);
var
  I: Integer;
begin
  I := TMenuItem(Sender).Tag;
  if I < 0 then
    FDisks.UnmountAll
  else if FDisks.MountedLetter(I) <> #0 then
    FDisks.Unmount(I)
  else
    FDisks.Mount(I);
  FMyDisks.RefreshList;
end;

procedure TMainForm.BuildTray;
  function Mi(const ACap: string; AClick: TNotifyEvent = nil): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACap;
    Result.OnClick := AClick;
    FTrayMenu.Items.Add(Result);
  end;
var
  M: TMenuItem;
begin
  FTrayMenu := TPopupMenu.Create(Self);
  Mi(APP_NAME).Enabled := False;
  Mi('-');
  Mi('E&xit ' + APP_NAME, ExitClick);
  Mi('-');
  Mi('&About ' + APP_NAME, AboutClick);
  Mi('-');
  M := Mi('&Open ' + APP_NAME, TrayOpen);
  M.Default := True;
  Mi('-');
  BuildClipItems(Mi('&Clipboard'));
  FDiskMenu := Mi('&Disks');
  Mi('-');
  FClearCacheItem := Mi('Clear &Passphrase Cache', ClearCacheClick);
  FTrayMenu.OnPopup := TrayPopup;
  FTray := TTrayIcon.Create(Self);
  FTray.Icon.Assign(Application.Icon);   { the combination lock, same as the program icon }
  FTray.Hint := APP_NAME;
  FTray.PopupMenu := FTrayMenu;
  FTray.OnDblClick := TrayOpen;
  FTray.Visible := True;
end;

procedure TMainForm.AboutClick(Sender: TObject);
begin
  ShowAbout(Self, APP_NAME, AppVersionText,
    'Keyring: ' + FEngine.HomeDir + sLineBreak +
    'Build: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(FileAge(ParamStr(0)))) + sLineBreak +
    'Running from: ' + ParamStr(0));
end;

end.

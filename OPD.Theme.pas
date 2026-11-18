unit OPD.Theme;

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Imaging.pngimage,
  System.Types,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls;


type
  { Base class for every dialog: scales the hand-laid-out controls from the
    96-DPI design size to the system DPI the first time it is shown. }
  TOPDForm = class(TForm)
  private
    FDpiScaled: Boolean;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    function ShowModal: Integer; override;
  end;

{ The system DPI the UI is laid out for ('/dpi:144' on the command line
  simulates another DPI for layout testing). }
function UiPPI: Integer;
function DpiScale(AValue: Integer): Integer;
{ Icon/bitmap size tier for the current DPI: 100, 125, 150 or 200 (percent). }
function DpiTier: Integer;
procedure ScaleForDpi(AForm: TCustomForm);
{ Resource name for the current DPI tier (BASE for 100%, BASE_150 etc.). }
function TieredResName(const ABase: string): string;
{ File version of this exe, e.g. '1.0.0.0'. }
function AppVersionText: string;
{ PNG from RCDATA resource (ASize picks the _16/_20/_24/_32 variant). }
function LoadPng(const AName: string; ASize: Integer = 0): TPngImage;
{ Runs AProc on a worker thread while the UI keeps painting (hourglass cursor). }
procedure RunBusy(const AProc: System.SysUtils.TProc);
{ Icon pixel size for the current DPI: 16, 20, 24 or 32. }
function IconPx: Integer;
function UiFontName: string;
procedure ApplyUiFont(AFont: TFont; ASize: Integer = 9);

implementation

uses
  Winapi.Windows,
  Vcl.ComCtrls,
  Vcl.GraphUtil;

var
  GPPIOverride: Integer = 0;

function UiPPI: Integer;
begin
  if GPPIOverride > 0 then
    Result := GPPIOverride
  else
    Result := Screen.PixelsPerInch;
end;

function DpiScale(AValue: Integer): Integer;
begin
  Result := MulDiv(AValue, UiPPI, 96);
end;

function DpiTier: Integer;
var
  Percent: Integer;
begin
  Percent := MulDiv(UiPPI, 100, 96);
  if Percent < 113 then
    Result := 100
  else if Percent < 138 then
    Result := 125
  else if Percent < 175 then
    Result := 150
  else
    Result := 200;
end;

procedure ScaleForDpi(AForm: TCustomForm);
var
  Controls: TList;
  Saved: array of TAnchors;
  I, J, NewCW, NewCH, MinW, MinH: Integer;
  C: TControl;
  WC: TWinControl;

  procedure Collect(AParent: TWinControl);
  var
    K: Integer;
  begin
    for K := 0 to AParent.ControlCount - 1 do
    begin
      Controls.Add(AParent.Controls[K]);
      if AParent.Controls[K] is TWinControl then
        Collect(TWinControl(AParent.Controls[K]));
    end;
  end;

begin
  if UiPPI = 96 then
    Exit;
  Controls := TList.Create;
  try
    Collect(AForm);
    SetLength(Saved, Controls.Count);
    for I := 0 to Controls.Count - 1 do
    begin
      C := TControl(Controls[I]);
      Saved[I] := C.Anchors;
      C.Anchors := [akLeft, akTop];
    end;
    AForm.DisableAlign;
    try
      NewCW := DpiScale(AForm.ClientWidth);
      NewCH := DpiScale(AForm.ClientHeight);
      MinW := DpiScale(AForm.Constraints.MinWidth);
      MinH := DpiScale(AForm.Constraints.MinHeight);
      { Size first, constraints after: raising the minimum first would grow the
        form and corrupt the client size being scaled. }
      AForm.Constraints.MinWidth := 0;
      AForm.Constraints.MinHeight := 0;
      AForm.SetBounds(AForm.Left, AForm.Top,
        AForm.Width - AForm.ClientWidth + NewCW,
        AForm.Height - AForm.ClientHeight + NewCH);
      AForm.Constraints.MinWidth := MinW;
      AForm.Constraints.MinHeight := MinH;
      for I := 0 to Controls.Count - 1 do
      begin
        C := TControl(Controls[I]);
        if C is TTabSheet then
          Continue;
        case C.Align of
          alTop, alBottom: C.Height := DpiScale(C.Height);
          alLeft, alRight: C.Width := DpiScale(C.Width);
          alClient: ;
        else
          C.SetBounds(DpiScale(C.Left), DpiScale(C.Top), DpiScale(C.Width),
            DpiScale(C.Height));
        end;
        if (C.Align <> alNone) and (C.Align <> alClient) then
          if C.Align in [alTop, alBottom] then
            C.Width := C.Width
          else
            C.Height := C.Height;
        C.Margins.SetBounds(DpiScale(C.Margins.Left), DpiScale(C.Margins.Top),
          DpiScale(C.Margins.Right), DpiScale(C.Margins.Bottom));
        if C is TWinControl then
        begin
          WC := TWinControl(C);
          WC.Padding.SetBounds(DpiScale(WC.Padding.Left),
            DpiScale(WC.Padding.Top), DpiScale(WC.Padding.Right),
            DpiScale(WC.Padding.Bottom));
        end;
        if C is TListView then
          for J := 0 to TListView(C).Columns.Count - 1 do
            if TListView(C).Columns[J].Width > 0 then
              TListView(C).Columns[J].Width :=
                DpiScale(TListView(C).Columns[J].Width);
      end;
    finally
      AForm.EnableAlign;
    end;
    for I := 0 to Controls.Count - 1 do
      TControl(Controls[I]).Anchors := Saved[I];
  finally
    Controls.Free;
  end;
end;

constructor TOPDForm.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Scaled := False; { ScaleForDpi does the scaling }
end;

function TOPDForm.ShowModal: Integer;
begin
  if not FDpiScaled then
  begin
    FDpiScaled := True;
    ScaleForDpi(Self);
  end;
  Result := inherited ShowModal;
end;

function TieredResName(const ABase: string): string;
begin
  Result := ABase;
  if DpiTier > 100 then
    if FindResource(HInstance, PChar(ABase + '_' + IntToStr(DpiTier)),
      RT_RCDATA) <> 0 then
      Result := ABase + '_' + IntToStr(DpiTier);
end;

function AppVersionText: string;
var
  Size, Handle: DWORD;
  Buffer: TBytes;
  Info: PVSFixedFileInfo;
  Len: UINT;
begin
  Result := '1.0.0.0';
  Size := GetFileVersionInfoSize(PChar(ParamStr(0)), Handle);
  if Size = 0 then
    Exit;
  SetLength(Buffer, Size);
  if GetFileVersionInfo(PChar(ParamStr(0)), 0, Size, Buffer) and
     VerQueryValue(Buffer, '\', Pointer(Info), Len) then
    Result := Format('%d.%d.%d.%d', [HiWord(Info.dwFileVersionMS),
      LoWord(Info.dwFileVersionMS), HiWord(Info.dwFileVersionLS),
      LoWord(Info.dwFileVersionLS)]);
end;

procedure ParseDpiOverride;
var
  I, V: Integer;
  P: string;
begin
  for I := 1 to ParamCount do
  begin
    P := LowerCase(ParamStr(I));
    if P.StartsWith('/dpi:') and TryStrToInt(Copy(P, 6, 10), V) and
       (V >= 96) and (V <= 384) then
      GPPIOverride := V;
  end;
end;

function UiFontName: string;
begin
  Result := 'Segoe UI';
  { Windows 11 exposes the variable family as Text / Display / Small. }
  if Screen.Fonts.IndexOf('Segoe UI Variable Text') >= 0 then
    Result := 'Segoe UI Variable Text';
end;

procedure ApplyUiFont(AFont: TFont; ASize: Integer);
begin
  if (ASize >= 14) and (Screen.Fonts.IndexOf('Segoe UI Variable Display') >= 0) then
    AFont.Name := 'Segoe UI Variable Display'
  else
    AFont.Name := UiFontName;
  AFont.PixelsPerInch := UiPPI;
  AFont.Size := ASize;
  AFont.Quality := fqClearTypeNatural;
end;

procedure RunBusy(const AProc: System.SysUtils.TProc);
var
  T: TThread;
begin
  Screen.Cursor := crHourGlass;
  T := TThread.CreateAnonymousThread(AProc);
  T.FreeOnTerminate := False;
  try
    T.Start;
    while not T.Finished do
    begin
      Application.ProcessMessages;
      Sleep(25);
    end;
  finally
    T.Free;
    Screen.Cursor := crDefault;
  end;
end;

function IconPx: Integer;
begin
  case DpiTier of
    100: Result := 16;
    125: Result := 20;
    150: Result := 24;
  else
    Result := 32;
  end;
end;

function LoadPng(const AName: string; ASize: Integer): TPngImage;
var
  RS: TResourceStream;
  N: string;
begin
  if ASize > 0 then
    N := AName + '_' + IntToStr(ASize)
  else
    N := AName;
  RS := TResourceStream.Create(HInstance, N, RT_RCDATA);
  try
    Result := TPngImage.Create;
    Result.LoadFromStream(RS);
  finally
    RS.Free;
  end;
end;

initialization
  ParseDpiOverride;

end.

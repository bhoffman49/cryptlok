unit OPD.WipeDialog;

{ "Wipe Free Space": overwrites the free space of a drive using Windows' own cipher tool, so that
  files deleted earlier can no longer be recovered. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.ExtCtrls, Vcl.Graphics, OPD.Theme, OPD.FreeSpace;

procedure ShowWipeDialog(AOwner: TComponent);

implementation

uses
  System.StrUtils, System.Math;

const
  EXPLAIN =
    'Deleting a file only marks its space as free; the old data stays on the disk until something overwrites ' +
    'it. This fills all free space on the drive you choose with zeros, ones and random data (three passes) ' +
    'and then gives it back. It uses Windows'' own tool, needs no administrator rights, and keeps your files.' + sLineBreak +
    sLineBreak +
    'It can take a long time (hours on a big drive), and the drive is full while it runs, so do not install ' +
    'or save large files on it meanwhile. On an SSD or USB stick this cannot reliably reach every copy and it ' +
    'wears the drive; BitLocker (full-disk encryption) is the better protection there.';

type
  TWipeForm = class(TOPDForm)
  private
    FDrives: TArray<TDriveInfo>;
    FCombo: TComboBox;
    FStart, FStop, FClose: TButton;
    FStatus: TLabel;
    FBar: TProgressBar;
    FTimer: TTimer;
    FWipe: TFreeSpaceWipe;
    FBegan: TDateTime;
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure SetRunning(ARunning: Boolean);
    function Elapsed: string;
  public
    constructor CreateDlg(AOwner: TComponent);
    destructor Destroy; override;
  end;

constructor TWipeForm.CreateDlg(AOwner: TComponent);
var
  L: TLabel;
  D: TDriveInfo;
begin
  inherited CreateNew(AOwner);
  Caption := 'Wipe Free Space';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 600;
  ClientHeight := 400;
  Font.Name := UiFontName;
  Font.Size := 9;
  OnCloseQuery := FormCloseQuery;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 14, 568, 160);
  L.AutoSize := False; L.WordWrap := True; L.Transparent := False; L.Color := clBtnFace;
  L.Caption := EXPLAIN;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 186, 200, 18);
  L.Caption := 'Drive to wipe:'; L.Transparent := False; L.Color := clBtnFace;
  FCombo := TComboBox.Create(Self); FCombo.Parent := Self; FCombo.SetBounds(16, 208, 568, 24);
  FCombo.Style := csDropDownList;
  FDrives := WipeableDrives;
  for D in FDrives do FCombo.Items.Add(D.Caption);
  if FCombo.Items.Count > 0 then FCombo.ItemIndex := 0;

  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.SetBounds(16, 254, 568, 36);
  FStatus.AutoSize := False; FStatus.WordWrap := True; FStatus.Transparent := False; FStatus.Color := clBtnFace;
  FBar := TProgressBar.Create(Self); FBar.Parent := Self; FBar.SetBounds(16, 298, 568, 16);
  FBar.Style := pbstMarquee; FBar.MarqueeInterval := 30; FBar.Visible := False;

  FStart := TButton.Create(Self); FStart.Parent := Self; FStart.SetBounds(16, 356, 130, 30);
  FStart.Caption := 'Start wiping'; FStart.OnClick := StartClick; FStart.Enabled := Length(FDrives) > 0;
  FStop := TButton.Create(Self); FStop.Parent := Self; FStop.SetBounds(154, 356, 90, 30);
  FStop.Caption := 'Stop'; FStop.OnClick := StopClick; FStop.Enabled := False;
  FClose := TButton.Create(Self); FClose.Parent := Self; FClose.SetBounds(480, 356, 104, 30);
  FClose.Caption := 'Close'; FClose.ModalResult := mrCancel; FClose.Cancel := True;

  FTimer := TTimer.Create(Self); FTimer.Enabled := False; FTimer.Interval := 500; FTimer.OnTimer := TimerTick;
end;

destructor TWipeForm.Destroy;
begin
  FWipe.Free;
  inherited;
end;

function TWipeForm.Elapsed: string;
var
  Secs: Int64;
begin
  Secs := Round((Now - FBegan) * 86400);
  Result := Format('%d:%.2d:%.2d', [Secs div 3600, (Secs div 60) mod 60, Secs mod 60]);
end;

procedure TWipeForm.SetRunning(ARunning: Boolean);
begin
  FStart.Enabled := not ARunning;
  FStop.Enabled := ARunning;
  FCombo.Enabled := not ARunning;
  FBar.Visible := ARunning;
  FTimer.Enabled := ARunning;
end;

procedure TWipeForm.StartClick(Sender: TObject);
var
  D: TDriveInfo;
  Err, Win: string;
  Buf: array[0..MAX_PATH] of Char;
  Msg: string;
begin
  if FCombo.ItemIndex < 0 then Exit;
  D := FDrives[FCombo.ItemIndex];
  GetWindowsDirectory(Buf, MAX_PATH);
  Win := string(Buf);
  Msg := 'Wipe the free space on ' + D.Root + ' now?' + sLineBreak + sLineBreak +
    'Your files stay. It can take hours, and the drive is full until it finishes.';
  if SameText(Copy(Win, 1, 3), D.Root) then
    Msg := Msg + sLineBreak + sLineBreak + 'This is the drive Windows is installed on: programs may complain ' +
      'about a full disk while the wipe runs. Close other programs first.';
  if Application.MessageBox(PChar(Msg), 'Wipe Free Space', MB_YESNO or MB_ICONQUESTION) <> IDYES then Exit;

  FreeAndNil(FWipe);
  FWipe := TFreeSpaceWipe.Create(D.Root);
  if not FWipe.Start(Err) then
  begin
    Application.MessageBox(PChar(Err), 'Wipe Free Space', MB_OK or MB_ICONWARNING);
    FreeAndNil(FWipe);
    Exit;
  end;
  FBegan := Now;
  FStatus.Caption := 'Started. Windows is overwriting the free space on ' + D.Root;
  SetRunning(True);
end;

procedure TWipeForm.StopClick(Sender: TObject);
var
  Note: string;
begin
  if FWipe = nil then Exit;
  FTimer.Enabled := False;
  FStatus.Caption := 'Stopping...';
  Application.ProcessMessages;
  Note := FWipe.Stop;
  SetRunning(False);
  FStatus.Caption := 'Stopped after ' + Elapsed + '. Your files are unchanged.' + IfThen(Note = '', '', sLineBreak + Note);
end;

procedure TWipeForm.TimerTick(Sender: TObject);
var
  Last, Tail: string;
  I, Passes: Integer;
begin
  if FWipe = nil then Exit;
  if FWipe.Poll then
  begin
    Last := '';
    if FWipe.Lines.Count > 0 then Last := FWipe.Lines[FWipe.Lines.Count - 1];
    { cipher prints one line per pass ("Writing 0x00", "Writing 0xFF", "Writing Random Numbers") }
    Passes := 0;
    for I := 0 to FWipe.Lines.Count - 1 do
      if StartsText('Writing', FWipe.Lines[I]) then Inc(Passes);
    FStatus.Caption := 'Running for ' + Elapsed +
      IfThen(Passes > 0, Format('   -   pass %d of 3', [Min(Passes, 3)]), '') +
      IfThen(Last = '', '', '   -   ' + Last);
  end
  else
  begin
    SetRunning(False);
    if FWipe.ExitCode = 0 then
    begin
      FWipe.RemoveEmptyTempFolder;
      FStatus.Caption := 'Done in ' + Elapsed + '. The free space on ' + FWipe.Root + ' has been wiped.';
    end
    else
    begin
      Tail := '';
      for I := Max(0, FWipe.Lines.Count - 3) to FWipe.Lines.Count - 1 do
        Tail := Tail + sLineBreak + FWipe.Lines[I];
      FStatus.Caption := 'The wipe did not finish (code ' + IntToStr(FWipe.ExitCode) + ').' + Tail;
      FWipe.Cleanup;
    end;
  end;
end;

procedure TWipeForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if (FWipe <> nil) and FStop.Enabled then
  begin
    if Application.MessageBox('The wipe is still running. Stop it and close?', 'Wipe Free Space',
      MB_YESNO or MB_ICONQUESTION) = IDYES then
      StopClick(nil)
    else
      CanClose := False;
  end;
end;

procedure ShowWipeDialog(AOwner: TComponent);
var
  F: TWipeForm;
begin
  F := TWipeForm.CreateDlg(AOwner);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.

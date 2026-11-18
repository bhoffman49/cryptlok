unit OPD.ShellDialog;

{ The "Explorer Integration" window: says exactly what will be added to the current user's
  Windows settings, and installs or removes it only when the user clicks. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.Graphics, OPD.Theme, OPD.ShellIntegration;

procedure ShowShellIntegration(AOwner: TComponent);

implementation

uses
  System.StrUtils;

type
  TShellForm = class(TOPDForm)
  private
    FSI: TShellIntegration;
    FStatus: TLabel;
    FDefault: TCheckBox;
    FInstall, FRemove: TButton;
    FDetails: TMemo;
    procedure RefreshState;
    procedure InstallClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure DefaultClick(Sender: TObject);
  public
    constructor CreateDlg(AOwner: TComponent);
    destructor Destroy; override;
  end;

const
  SUMMARY =
    'Adds, for your Windows account only (no administrator rights):' + sLineBreak +
    '  - right-click any file or folder:  Encrypt with CryptLok...  and  Shred with CryptLok...' + sLineBreak +
    '  - right-click a .pgp, .gpg or .asc file:  Decrypt/Verify with CryptLok' + sLineBreak +
    '  - a "CryptLok encrypted archive" file type with its own icon, offered under "Open with" for .pgp' + sLineBreak +
    sLineBreak +
    'On Windows 11 these appear under "Show more options" in the right-click menu. ' +
    'Remove puts everything back exactly as it was.';

constructor TShellForm.CreateDlg(AOwner: TComponent);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(AOwner);
  FSI := TShellIntegration.Create(ParamStr(0));
  Caption := 'Explorer Integration';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 620;
  ClientHeight := 496;
  Font.Name := UiFontName;
  Font.Size := 9;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 14, 588, 126);
  L.AutoSize := False; L.WordWrap := True; L.Caption := SUMMARY;
  L.Transparent := False; L.Color := clBtnFace;

  FDefault := TCheckBox.Create(Self); FDefault.Parent := Self; FDefault.SetBounds(16, 150, 588, 20);
  FDefault.Caption := 'Also open .pgp files with CryptLok when I double-click them (unless another program already owns them)';
  FDefault.OnClick := DefaultClick;

  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.SetBounds(16, 178, 588, 36);
  FStatus.AutoSize := False; FStatus.WordWrap := True; FStatus.Font.Style := [fsBold];
  FStatus.Transparent := False; FStatus.Color := clBtnFace;

  L := TLabel.Create(Self); L.Parent := Self; L.SetBounds(16, 220, 588, 18);
  L.Caption := 'Exact registry entries (HKEY_CURRENT_USER\Software\Classes):';
  L.Transparent := False; L.Color := clBtnFace;
  FDetails := TMemo.Create(Self); FDetails.Parent := Self; FDetails.SetBounds(16, 240, 588, 200);
  FDetails.ReadOnly := True; FDetails.ScrollBars := ssBoth; FDetails.WordWrap := False;
  FDetails.Font.Name := 'Consolas'; FDetails.Font.Size := 8;

  FInstall := TButton.Create(Self); FInstall.Parent := Self; FInstall.SetBounds(16, 454, 120, 30);
  FInstall.Caption := 'Install'; FInstall.OnClick := InstallClick;
  FRemove := TButton.Create(Self); FRemove.Parent := Self; FRemove.SetBounds(144, 454, 120, 30);
  FRemove.Caption := 'Remove'; FRemove.OnClick := RemoveClick;
  B := TButton.Create(Self); B.Parent := Self; B.SetBounds(500, 454, 104, 30);
  B.Caption := 'Close'; B.ModalResult := mrOk; B.Default := True; B.Cancel := True;
  RefreshState;
end;

destructor TShellForm.Destroy;
begin
  FSI.Free;
  inherited;
end;

procedure TShellForm.RefreshState;
var
  E: TShellEntry;
  Lines: TStringList;
begin
  case FSI.State of
    ssNotInstalled:
      begin
        FStatus.Caption := 'Not installed.';
        FInstall.Caption := 'Install';
        FRemove.Enabled := False;
      end;
    ssInstalled:
      begin
        FStatus.Caption := 'Installed.' + IfThen(FSI.PgpDefaultIsOurs, ' CryptLok opens .pgp files by default.', '');
        FInstall.Caption := 'Update';
        FRemove.Enabled := True;
      end;
  else
    begin
      FStatus.Caption := 'Installed, but for another copy of CryptLok (a different folder). Click Update to ' +
        'point everything at this copy.';
      FInstall.Caption := 'Update';
      FRemove.Enabled := True;
    end;
  end;
  Lines := TStringList.Create;
  try
    for E in FSI.Entries(FDefault.Checked) do
      Lines.Add(E.KeyPath + '  [' + IfThen(E.ValueName = '', '(Default)', E.ValueName) + ']  =  ' + E.Data);
    FDetails.Lines.Assign(Lines);
  finally
    Lines.Free;
  end;
end;

procedure TShellForm.InstallClick(Sender: TObject);
var
  Note: string;
begin
  try
    Note := FSI.Install(FDefault.Checked);
  except
    on E: Exception do
    begin
      Application.MessageBox(PChar('Could not install: ' + E.Message), 'Explorer Integration',
        MB_OK or MB_ICONWARNING);
      Exit;
    end;
  end;
  RefreshState;
  if Note <> '' then
    Application.MessageBox(PChar(Note), 'Explorer Integration', MB_OK or MB_ICONINFORMATION);
end;

procedure TShellForm.DefaultClick(Sender: TObject);
begin
  RefreshState;
end;

procedure TShellForm.RemoveClick(Sender: TObject);
begin
  FSI.Uninstall;
  RefreshState;
end;

procedure ShowShellIntegration(AOwner: TComponent);
var
  F: TShellForm;
begin
  F := TShellForm.CreateDlg(AOwner);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.

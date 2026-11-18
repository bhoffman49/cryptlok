program CryptLok;

{$R CryptLok.Assets.res}

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.StrUtils,
  Vcl.Forms,
  OPD.Theme in 'OPD.Theme.pas',
  OPD.Engine in 'OPD.Engine.pas',
  OPD.MasterKeys in 'OPD.MasterKeys.pas',
  OPD.PassphraseDialog in 'OPD.PassphraseDialog.pas',
  OPD.ImportDialog in 'OPD.ImportDialog.pas',
  OPD.ClipboardService in 'OPD.ClipboardService.pas',
  OPD.RecipientDialog in 'OPD.RecipientDialog.pas',
  OPD.VeraCrypt in 'OPD.VeraCrypt.pas',
  OPD.DiskPages in 'OPD.DiskPages.pas',
  OPD.PhotoId in 'OPD.PhotoId.pas',
  OPD.PrefsDialog in 'OPD.PrefsDialog.pas',
  OPD.KeyDialogs in 'OPD.KeyDialogs.pas',
  OPD.Tar in 'OPD.Tar.pas',
  OPD.SdaBuilder in 'OPD.SdaBuilder.pas',
  OPD.PgpSym in 'OPD.PgpSym.pas',
  OPD.PgpZip in 'OPD.PgpZip.pas',
  OPD.ZipWizard in 'OPD.ZipWizard.pas',
  OPD.TextDiff in 'OPD.TextDiff.pas',
  OPD.ViewerDialog in 'OPD.ViewerDialog.pas',
  OPD.ZipViewer in 'OPD.ZipViewer.pas',
  OPD.AboutDialog in 'OPD.AboutDialog.pas',
  OPD.ShellIntegration in 'OPD.ShellIntegration.pas',
  OPD.ShellDialog in 'OPD.ShellDialog.pas',
  OPD.OptionsDialog in 'OPD.OptionsDialog.pas',
  OPD.Shredder in 'OPD.Shredder.pas',
  OPD.ShredDialog in 'OPD.ShredDialog.pas',
  OPD.FreeSpace in 'OPD.FreeSpace.pas',
  OPD.WipeDialog in 'OPD.WipeDialog.pas',
  OPD.MainForm in 'OPD.MainForm.pas';

var
  Mutex: THandle;
  Existing: HWND;
  Tries, I: Integer;
  Args: string;
  CD: TCopyDataStruct;
  Res: DWORD_PTR;

begin
  { used by the uninstaller: remove the Explorer menu entries this copy added, then quit }
  if FindCmdLineSwitch('removeshell') then
  begin
    TShellIntegration.Create(ParamStr(0)).Uninstall;
    Exit;
  end;
  { used by the installer (task "Add CryptLok to Explorer"): the same entries as the Install button in
    Tools > Explorer Integration, without taking the .pgp default, then quit }
  if FindCmdLineSwitch('installshell') then
  begin
    with TShellIntegration.Create(ParamStr(0)) do
    try
      Install(False);
    finally
      Free;
    end;
    Exit;
  end;
  { one instance: a second launch hands its command line to the running one (Explorer starts one
    process per selected file) or just brings it back }
  Mutex := CreateMutex(nil, True, 'Level103.CryptLok.SingleInstance');
  if (GetLastError = ERROR_ALREADY_EXISTS) and not FindCmdLineSwitch('multi') then   { /multi: testing aid }
  begin
    Existing := 0;
    for Tries := 1 to 40 do
    begin
      Existing := FindWindow('TMainForm', nil);
      if Existing <> 0 then Break;
      Sleep(150);                      { the first instance may still be starting }
    end;
    if Existing <> 0 then
    begin
      Args := '';
      for I := 1 to ParamCount do
        Args := Args + IfThen(Args = '', '', #1) + ParamStr(I);
      if Args <> '' then
      begin
        AllowSetForegroundWindow(DWORD(-1));        { ASFW_ANY }
        CD.dwData := $434C4B31;
        CD.cbData := Length(Args) * SizeOf(Char);
        CD.lpData := PChar(Args);
        SendMessageTimeout(Existing, WM_COPYDATA, 0, LPARAM(@CD), SMTO_ABORTIFHUNG, 5000, @Res);
      end
      else
      begin
        ShowWindow(Existing, SW_SHOW);
        ShowWindow(Existing, SW_RESTORE);
        SetForegroundWindow(Existing);
      end;
    end;
    Exit;
  end;
  Application.Initialize;
  if FindCmdLineSwitch('tray') then
    Application.ShowMainForm := False;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'CryptLok';
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.

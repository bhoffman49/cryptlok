unit OPD.FreeSpace;

{ Wipes the free space of a drive with Windows' own "cipher /w:<root>" (three passes: zeros, ones,
  random).  cipher fills the free space with temporary files in <root>EFSTMPWP and removes them at the
  end; this class runs it, reports its output lines, and can stop it and remove the leftovers.
  The command line can be replaced so the logic is testable without wiping a real drive. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows;

type
  TFreeSpaceWipe = class
  private
    FRoot: string;
    FCmd: string;
    FProc: THandle;
    FThread: THandle;
    FOutR: THandle;
    FPending: string;
    FLines: TStringList;
    FStarted: Boolean;
    FExitCode: DWORD;
    FStopped: Boolean;
    procedure Drain;
  public
    { ARoot like 'D:\'; ACommandLine = '' runs "<windir>\System32\cipher.exe /w:<root>" }
    constructor Create(const ARoot: string; const ACommandLine: string = '');
    destructor Destroy; override;
    function Start(out AError: string): Boolean;
    { Reads any new output; True while cipher is still running. }
    function Poll: Boolean;
    { Ends cipher and removes the temporary folder it leaves behind; returns '' or a note for the user. }
    function Stop: string;
    function Cleanup: string;
    { After a normal finish: removes cipher's empty EFSTMPWP folder; a folder with anything in it is left alone. }
    procedure RemoveEmptyTempFolder;
    property Lines: TStringList read FLines;
    property ExitCode: DWORD read FExitCode;
    property Stopped: Boolean read FStopped;
    property Root: string read FRoot;
  end;

{ Fixed and removable drives with their free space, for the drive list. }
type
  TDriveInfo = record
    Root: string;       { 'C:\' }
    Caption: string;    { 'C:\  (System, 120.3 GB free)' }
    Removable: Boolean;
  end;

function WipeableDrives: TArray<TDriveInfo>;

implementation

uses
  System.IOUtils, System.StrUtils;

constructor TFreeSpaceWipe.Create(const ARoot, ACommandLine: string);
begin
  inherited Create;
  FRoot := IncludeTrailingPathDelimiter(ARoot);
  FCmd := ACommandLine;
  FLines := TStringList.Create;
end;

destructor TFreeSpaceWipe.Destroy;
begin
  if FProc <> 0 then
  begin
    TerminateProcess(FProc, 1);
    CloseHandle(FProc);
  end;
  if FThread <> 0 then CloseHandle(FThread);
  if FOutR <> 0 then CloseHandle(FOutR);
  FLines.Free;
  inherited;
end;

function TFreeSpaceWipe.Start(out AError: string): Boolean;
var
  SA: TSecurityAttributes;
  OutW: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Win: array[0..MAX_PATH] of Char;
begin
  Result := False;
  AError := '';
  if FStarted then Exit(True);
  Cmd := FCmd;
  if Cmd = '' then
  begin
    GetWindowsDirectory(Win, MAX_PATH);
    Cmd := '"' + IncludeTrailingPathDelimiter(string(Win)) + 'System32\cipher.exe" /w:' + FRoot;
  end;
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(FOutR, OutW, @SA, 0) then
  begin
    AError := 'Could not prepare the wipe';
    Exit;
  end;
  SetHandleInformation(FOutR, HANDLE_FLAG_INHERIT, 0);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdOutput := OutW;
  SI.hStdError := OutW;
  UniqueString(Cmd);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    AError := 'Could not start Windows'' cipher tool: ' + Trim(SysErrorMessage(GetLastError));
    CloseHandle(OutW);
    Exit;
  end;
  CloseHandle(OutW);
  FProc := PI.hProcess;
  FThread := PI.hThread;
  FStarted := True;
  Result := True;
end;

procedure TFreeSpaceWipe.Drain;
var
  Avail, Got: DWORD;
  Buf: TBytes;
  S: string;
  P: Integer;
begin
  if FOutR = 0 then Exit;
  while PeekNamedPipe(FOutR, nil, 0, nil, @Avail, nil) and (Avail > 0) do
  begin
    SetLength(Buf, Avail);
    if not ReadFile(FOutR, Buf[0], Avail, Got, nil) or (Got = 0) then Break;
    SetLength(Buf, Got);
    FPending := FPending + TEncoding.GetEncoding(GetOEMCP).GetString(Buf);
  end;
  { cipher ends its status lines with CR only, or CR LF }
  FPending := FPending.Replace(#13#10, #10).Replace(#13, #10);
  P := Pos(#10, FPending);
  while P > 0 do
  begin
    S := Trim(Copy(FPending, 1, P - 1));
    if S <> '' then FLines.Add(S);
    Delete(FPending, 1, P);
    P := Pos(#10, FPending);
  end;
end;

function TFreeSpaceWipe.Poll: Boolean;
var
  Code: DWORD;
begin
  Result := False;
  if not FStarted then Exit;
  Drain;
  if (FProc <> 0) and GetExitCodeProcess(FProc, Code) then
  begin
    if Code = STILL_ACTIVE then
      Exit(True);
    FExitCode := Code;
    Drain;
    if Trim(FPending) <> '' then
    begin
      FLines.Add(Trim(FPending));
      FPending := '';
    end;
    CloseHandle(FProc); FProc := 0;
    if FThread <> 0 then begin CloseHandle(FThread); FThread := 0; end;
    FStarted := False;
  end;
end;

function TFreeSpaceWipe.Cleanup: string;
var
  Dir: string;
begin
  Result := '';
  Dir := FRoot + 'EFSTMPWP';
  if not DirectoryExists(Dir) then Exit;
  try
    SetFileAttributes(PChar(Dir), FILE_ATTRIBUTE_NORMAL);
    TDirectory.Delete(Dir, True);
  except
    on E: Exception do
      Result := 'Windows left a temporary folder on the drive. Delete it yourself to get the space back: ' + Dir;
  end;
end;

procedure TFreeSpaceWipe.RemoveEmptyTempFolder;
var
  Dir: string;
begin
  Dir := FRoot + 'EFSTMPWP';
  if not DirectoryExists(Dir) then Exit;
  SetFileAttributes(PChar(Dir), FILE_ATTRIBUTE_NORMAL);
  RemoveDirectory(PChar(Dir));       { fails (and keeps the folder) when it is not empty }
end;

function TFreeSpaceWipe.Stop: string;
begin
  FStopped := True;
  if FProc <> 0 then
  begin
    TerminateProcess(FProc, 1);
    WaitForSingleObject(FProc, 5000);
    Poll;
  end;
  Result := Cleanup;
end;

function WipeableDrives: TArray<TDriveInfo>;
var
  Mask: DWORD;
  I: Integer;
  Root: string;
  T: UINT;
  Free, Total, Avail: Int64;
  D: TDriveInfo;
begin
  SetLength(Result, 0);
  Mask := GetLogicalDrives;
  for I := 0 to 25 do
    if (Mask and (DWORD(1) shl I)) <> 0 then
    begin
      Root := Chr(Ord('A') + I) + ':\';
      T := GetDriveType(PChar(Root));
      if not (T in [DRIVE_FIXED, DRIVE_REMOVABLE]) then Continue;
      if not GetDiskFreeSpaceEx(PChar(Root), Avail, Total, @Free) then Continue;
      D.Root := Root;
      D.Removable := T = DRIVE_REMOVABLE;
      D.Caption := Format('%s  (%s%.1f GB free of %.1f GB)', [Root, IfThen(D.Removable, 'removable, ', ''),
        Avail / (1024.0 * 1024 * 1024), Total / (1024.0 * 1024 * 1024)]);
      Result := Result + [D];
    end;
end;

end.

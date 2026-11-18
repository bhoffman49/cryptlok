unit OPD.VeraCrypt;

{ Disk back end: drives the INSTALLED VeraCrypt (never bundled).

  A "virtual disk" is a VeraCrypt file container whose only credential is a
  random keyfile.  The keyfile lives next to the container as <volume>.key.gpg,
  encrypted with GnuPG to the owner's key(s) - so opening the disk needs the
  owner's GnuPG passphrase.  While mounting, the keyfile exists as a temp file
  for a moment and is then overwritten and deleted. }

interface

uses
  System.SysUtils, System.Classes, OPD.Engine;

type
  TDiskResult = record
    Ok: Boolean;
    Error: string;
  end;

  TDiskParams = record
    Path: string;                   { container file, e.g. D:\Vault.hc }
    SizeMB: Integer;
    FileSystem: string;             { FAT or exFAT (NTFS needs a UAC prompt) }
    Encryption: string;             { AES, Serpent, Twofish, ... }
    Hash: string;                   { sha512, sha256, whirlpool, blake2s }
    Recipients: TArray<string>;     { fingerprints that may open the disk }
  end;

  TVeraCrypt = class
  private
    FEngine: IKeyEngine;
    FDir: string;
    FMainExe, FFormatExe: string;     { full paths, set by Locate }
    procedure Locate;
    { ATimeoutMs = INFINITE waits until VeraCrypt ends; AExit = -2 when it was still running at the time limit }
    function RunVc(const AExe: string; const AArgs: string; out AExit: Integer;
      ATimeoutMs: Cardinal = 10 * 60 * 1000): Boolean;
  public
    constructor Create(const AEngine: IKeyEngine);
    function Available(out AInfo: string): Boolean;
    class function KeyFilePath(const AVolume: string): string;
    { The folder chosen in Tools > Options > Disk ('' = find it automatically), and whether a folder holds VeraCrypt. }
    class function ManualFolder(const AEngine: IKeyEngine): string;
    class procedure SetManualFolder(const AEngine: IKeyEngine; const AFolder: string);
    class function FolderHasVeraCrypt(const AFolder: string): Boolean;
    { The two programs inside a folder: the installed names, or the x64 / arm64 names of the portable extract. }
    class function FindPrograms(const AFolder: string; out AMain, AFormat: string): Boolean;
    function CreateVolume(const P: TDiskParams): TDiskResult;
    function Mount(const AVolume: string; ALetter: Char; const APassphrase: TBytes): TDiskResult;
    function Unmount(ALetter: Char; AForce: Boolean = False): TDiskResult;
    class function IsMounted(ALetter: Char): Boolean;
    class function MountedLetters: string;
    class function FreeLetters: string;
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, System.Win.Registry, System.IniFiles, System.IOUtils, System.StrUtils,
  OPD.MasterKeys;

const
  ERROR_ELEVATION_REQUIRED = 740;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte; cbBuffer: ULONG;
  dwFlags: ULONG): Integer; stdcall; external 'bcrypt.dll';

function RandomBytes(ACount: Integer): TBytes;
begin
  SetLength(Result, ACount);
  { BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2 }
  if BCryptGenRandom(nil, @Result[0], ACount, 2) <> 0 then
    raise Exception.Create('The system random generator failed');
end;

constructor TVeraCrypt.Create(const AEngine: IKeyEngine);
begin
  inherited Create;
  FEngine := AEngine;
  FDir := 'C:\Program Files\VeraCrypt\';
end;

class function TVeraCrypt.FindPrograms(const AFolder: string; out AMain, AFormat: string): Boolean;
var
  D, Suffix: string;
  Suffixes: TArray<string>;
begin
  Result := False;
  AMain := '';
  AFormat := '';
  if Trim(AFolder) = '' then Exit;
  D := IncludeTrailingPathDelimiter(Trim(AFolder));
  if SameText(GetEnvironmentVariable('PROCESSOR_ARCHITECTURE'), 'ARM64') or
     SameText(GetEnvironmentVariable('PROCESSOR_ARCHITEW6432'), 'ARM64') then
    Suffixes := ['', '-arm64', '-x64']
  else
    Suffixes := ['', '-x64', '-arm64'];
  for Suffix in Suffixes do
    if FileExists(D + 'VeraCrypt' + Suffix + '.exe') and FileExists(D + 'VeraCrypt Format' + Suffix + '.exe') then
    begin
      AMain := D + 'VeraCrypt' + Suffix + '.exe';
      AFormat := D + 'VeraCrypt Format' + Suffix + '.exe';
      Exit(True);
    end;
end;

class function TVeraCrypt.FolderHasVeraCrypt(const AFolder: string): Boolean;
var
  M, F: string;
begin
  Result := FindPrograms(AFolder, M, F);
end;

class function TVeraCrypt.ManualFolder(const AEngine: IKeyEngine): string;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Result := Ini.ReadString('VeraCrypt', 'Folder', '');
  finally
    Ini.Free;
  end;
end;

class procedure TVeraCrypt.SetManualFolder(const AEngine: IKeyEngine; const AFolder: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    if Trim(AFolder) = '' then
      Ini.DeleteKey('VeraCrypt', 'Folder')
    else
      Ini.WriteString('VeraCrypt', 'Folder', Trim(AFolder));
  finally
    Ini.Free;
  end;
end;

{ Where VeraCrypt is: the folder chosen in Options, else the Program Files folders, else the install location
  that its own installer recorded.  When nothing is found FDir stays at the usual place (for the message). }
procedure TVeraCrypt.Locate;
var
  C: TArray<string>;
  S: string;
  R: TRegistry;
begin
  C := [];
  S := ManualFolder(FEngine);
  if S <> '' then C := C + [S];
  C := C + [GetEnvironmentVariable('ProgramW6432') + '\VeraCrypt', GetEnvironmentVariable('ProgramFiles') + '\VeraCrypt',
    GetEnvironmentVariable('ProgramFiles(x86)') + '\VeraCrypt'];
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    try
      R.RootKey := HKEY_LOCAL_MACHINE;
      if R.OpenKeyReadOnly('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VeraCrypt') then
        if R.ValueExists('InstallLocation') then
          C := C + [R.ReadString('InstallLocation')];
    except
      { no registry entry: the folders above are all there is }
    end;
  finally
    R.Free;
  end;
  for S in C do
    if FindPrograms(S, FMainExe, FFormatExe) then
    begin
      FDir := IncludeTrailingPathDelimiter(Trim(S));
      Exit;
    end;
  FDir := 'C:\Program Files\VeraCrypt\';
  FMainExe := FDir + 'VeraCrypt.exe';
  FFormatExe := FDir + 'VeraCrypt Format.exe';
end;

function TVeraCrypt.Available(out AInfo: string): Boolean;
var
  Sz, H: DWORD;
  Buf: TBytes;
  Info: PVSFixedFileInfo;
  Len: UINT;
  Ver: string;
begin
  Locate;
  Result := FileExists(FMainExe) and FileExists(FFormatExe);
  if not Result then
  begin
    AInfo := 'VeraCrypt is not installed (expected in ' + FDir + ')';
    Exit;
  end;
  Ver := '';
  Sz := GetFileVersionInfoSize(PChar(FMainExe), H);
  if Sz > 0 then
  begin
    SetLength(Buf, Sz);
    if GetFileVersionInfo(PChar(FMainExe), 0, Sz, Buf) and
       VerQueryValue(Buf, '\', Pointer(Info), Len) then
      Ver := Format('%d.%d.%d', [HiWord(Info.dwFileVersionMS), LoWord(Info.dwFileVersionMS),
        HiWord(Info.dwFileVersionLS)]);
  end;
  AInfo := 'VeraCrypt ' + Ver;
end;

class function TVeraCrypt.KeyFilePath(const AVolume: string): string;
begin
  Result := AVolume + '.key.gpg';
end;

function TVeraCrypt.RunVc(const AExe, AArgs: string; out AExit: Integer; ATimeoutMs: Cardinal): Boolean;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Code: DWORD;
  SEI: TShellExecuteInfo;
begin
  AExit := -1;
  Cmd := '"' + AExe + '" ' + AArgs;
  UniqueString(Cmd);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  Result := CreateProcess(nil, PChar(Cmd), nil, nil, False, CREATE_NO_WINDOW, nil, nil, SI, PI);
  if (not Result) and (GetLastError = ERROR_ELEVATION_REQUIRED) then
  begin
    { a portable copy of VeraCrypt needs administrator rights to load its driver: ask Windows for them
      (the UAC prompt appears) just for this one VeraCrypt call }
    FillChar(SEI, SizeOf(SEI), 0);
    SEI.cbSize := SizeOf(SEI);
    SEI.fMask := SEE_MASK_NOCLOSEPROCESS;
    SEI.lpVerb := 'runas';
    SEI.lpFile := PChar(AExe);
    SEI.lpParameters := PChar(AArgs);
    SEI.nShow := SW_HIDE;
    if ShellExecuteEx(@SEI) and (SEI.hProcess <> 0) then
    begin
      try
        if WaitForSingleObject(SEI.hProcess, ATimeoutMs) = WAIT_TIMEOUT then
          AExit := -2
        else
        begin
          GetExitCodeProcess(SEI.hProcess, Code);
          AExit := Integer(Code);
        end;
      finally
        CloseHandle(SEI.hProcess);
      end;
      Exit(True);
    end;
    Exit(False);
  end;
  if not Result then Exit;
  try
    if WaitForSingleObject(PI.hProcess, ATimeoutMs) = WAIT_TIMEOUT then
      AExit := -2
    else
    begin
      GetExitCodeProcess(PI.hProcess, Code);
      AExit := Integer(Code);
    end;
  finally
    CloseHandle(PI.hProcess);
    CloseHandle(PI.hThread);
  end;
end;

function TempKeyFile: string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'k' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '') + '.tmp');
end;

function TVeraCrypt.CreateVolume(const P: TDiskParams): TDiskResult;
var
  Kf, Side, Info: string;
  Raw: TBytes;
  R: TCryptoResult;
  Code: Integer;
  Args: string;
begin
  Result.Ok := False;
  Result.Error := '';
  if not Available(Info) then
  begin
    Result.Error := Info;
    Exit;
  end;
  if FileExists(P.Path) then
  begin
    Result.Error := 'A file with that name already exists';
    Exit;
  end;
  if Length(P.Recipients) = 0 then
  begin
    Result.Error := 'Choose at least one key that may open the disk';
    Exit;
  end;
  if P.SizeMB < 1 then
  begin
    Result.Error := 'The disk must be at least 1 MB';
    Exit;
  end;
  Side := KeyFilePath(P.Path);
  Kf := TempKeyFile;
  try
    { 1. random keyfile, wrapped with GnuPG }
    Raw := RandomBytes(256);
    TFile.WriteAllBytes(Kf, Raw);
    FillChar(Raw[0], Length(Raw), 0);
    R := FEngine.EncryptFile(Kf, Side, WithMasterKeys(FEngine, P.Recipients));
    if not R.Ok then
    begin
      Result.Error := 'Could not protect the keyfile: ' + R.Error;
      Exit;
    end;
    { 2. the container, keyed by that file only.  A large disk is written in full and can take an hour
      or more, so there is no time limit here (a limit used to abandon VeraCrypt half way, exit code 259) }
    Args := Format('/create "%s" /size %dM /k "%s" /password "" /hash %s /encryption %s ' +
      '/filesystem %s /force /silent', [P.Path, P.SizeMB, Kf, P.Hash, P.Encryption, P.FileSystem]);
    if not RunVc(FFormatExe, Args, Code, INFINITE) or (Code <> 0) or
       not FileExists(P.Path) then
    begin
      Result.Error := Format('VeraCrypt could not create the volume (exit code %d)', [Code]);
      System.SysUtils.DeleteFile(Side);
      System.SysUtils.DeleteFile(P.Path);
      Exit;
    end;
    Result.Ok := True;
  finally
    SecureDeleteFile(Kf);
  end;
end;

function TVeraCrypt.Mount(const AVolume: string; ALetter: Char;
  const APassphrase: TBytes): TDiskResult;
var
  Kf, Info: string;
  R: TCryptoResult;
  Code: Integer;
begin
  Result.Ok := False;
  Result.Error := '';
  if not Available(Info) then
  begin
    Result.Error := Info;
    Exit;
  end;
  if not FileExists(AVolume) then
  begin
    Result.Error := 'The disk file was not found';
    Exit;
  end;
  if not FileExists(KeyFilePath(AVolume)) then
  begin
    Result.Error := 'The key file ' + ExtractFileName(KeyFilePath(AVolume)) +
      ' is missing next to the disk';
    Exit;
  end;
  if IsMounted(ALetter) then
  begin
    Result.Error := 'Drive ' + ALetter + ': is already in use';
    Exit;
  end;
  Kf := TempKeyFile;
  try
    R := FEngine.DecryptFile(KeyFilePath(AVolume), Kf, APassphrase);
    if not R.Ok then
    begin
      Result.Error := R.Error;
      Exit;
    end;
    if not RunVc(FMainExe,
      Format('/q /s /v "%s" /l %s /k "%s" /p "" /tryemptypass /m ts', [AVolume, ALetter, Kf]),
      Code) or (Code <> 0) then
    begin
      Result.Error := Format('VeraCrypt could not mount the disk (exit code %d)', [Code]);
      Exit;
    end;
    Result.Ok := IsMounted(ALetter);
    if not Result.Ok then
      Result.Error := 'VeraCrypt finished but the drive did not appear';
  finally
    SecureDeleteFile(Kf);
  end;
end;

function TVeraCrypt.Unmount(ALetter: Char; AForce: Boolean): TDiskResult;
var
  Code: Integer;
begin
  Result.Ok := False;
  Result.Error := '';
  if not IsMounted(ALetter) then
  begin
    Result.Error := 'Drive ' + ALetter + ': is not a mounted disk';
    Exit;
  end;
  Locate;
  RunVc(FMainExe, '/q /s /u ' + ALetter + IfThen(AForce, ' /f', ''), Code);
  Result.Ok := not IsMounted(ALetter);
  if not Result.Ok then
    Result.Error := 'The disk is in use. Close the files on it and try again.';
end;

class function TVeraCrypt.IsMounted(ALetter: Char): Boolean;
var
  Buf: array[0..511] of Char;
begin
  Result := (QueryDosDevice(PChar(UpCase(ALetter) + ':'), Buf, Length(Buf)) > 0) and
    ContainsText(string(Buf), 'VeraCrypt');
end;

class function TVeraCrypt.MountedLetters: string;
var
  C: Char;
begin
  Result := '';
  for C := 'A' to 'Z' do
    if IsMounted(C) then Result := Result + C;
end;

class function TVeraCrypt.FreeLetters: string;
var
  Mask: DWORD;
  I: Integer;
begin
  Result := '';
  Mask := GetLogicalDrives;
  for I := 25 downto 2 do   { Z down to C, like the classic drive picker }
    if Mask and (1 shl I) = 0 then
      Result := Result + Chr(Ord('A') + I);
end;

end.

unit OPD.Shredder;

{ Overwrites files with random data and then zeros, truncates, renames and deletes them.

  What this can and cannot do (the window says the same in plain words):
    - On a hard disk it destroys the data of the file itself.
    - On an SSD, USB stick or memory card the drive may keep older copies in places Windows cannot
      reach (wear levelling, TRIM).  BitLocker (or another full-disk encryption) is the real answer there.
    - NTFS keeps a journal and may keep tiny files inside its own tables.  Wiping free space afterwards
      (Windows' "cipher /w") removes most of what is left.
    - Compressed, sparse or encrypted (EFS) files may be rewritten in new places; a warning is given. }

interface

uses
  System.SysUtils, System.Classes;

type
  TShredProgress = reference to procedure(const AFile: string; ADone, ATotal: Int64);

  TShredResult = record
    Files: Integer;
    Folders: Integer;
    Failed: TArray<string>;    { "path: reason" }
    Warnings: TArray<string>;  { done, but with a caveat (compressed, hard link, ...) }
    Cancelled: Boolean;
  end;

const
  MIN_PASSES = 1;
  MAX_PASSES = 49;
  DEFAULT_PASSES = 3;

{ Total bytes a run would write (size of all files x passes), for progress bars. }
function ShredWorkSize(const APaths: array of string; APasses: Integer): Int64;

{ Shreds every file and folder in APaths.  ACancel may be nil; set it to True from another thread to stop. }
function ShredPaths(const APaths: TArray<string>; APasses: Integer; const AProgress: TShredProgress;
  ACancel: PBoolean): TShredResult;

{ One file.  AKeep = True overwrites but leaves the (zeroed) file in place; used by the tests. }
function ShredFile(const AFile: string; APasses: Integer; AKeep: Boolean; out AError: string;
  out AWarning: string; const AProgress: TShredProgress = nil; AOffsetDone: Int64 = 0; ATotal: Int64 = 0;
  ACancel: PBoolean = nil): Boolean;

implementation

uses
  Winapi.Windows, System.IOUtils, System.Math, System.StrUtils;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte; cbBuffer: ULONG; dwFlags: ULONG): LongInt; stdcall;
  external 'bcrypt.dll';

const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;
  CHUNK = 1024 * 1024;

function LongName(const APath: string): string;
const
  Prefix = '\\?\';
begin
  Result := ExpandFileName(APath);
  if (Length(Result) >= 240) and not Result.StartsWith(Prefix) then
    Result := Prefix + Result;
end;

function IsReparse(const AAttr: DWORD): Boolean;
begin
  Result := (AAttr <> INVALID_FILE_ATTRIBUTES) and ((AAttr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
end;

function LastErr: string;
begin
  Result := Trim(SysErrorMessage(GetLastError));
  if Result = '' then Result := 'Windows error ' + IntToStr(GetLastError);
end;

function RandomName: string;
var
  B: array[0..5] of Byte;
  I: Integer;
begin
  BCryptGenRandom(nil, @B[0], SizeOf(B), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  Result := '';
  for I := 0 to High(B) do
    Result := Result + Chr(Ord('a') + (B[I] mod 26));
end;

function ShredFile(const AFile: string; APasses: Integer; AKeep: Boolean; out AError: string;
  out AWarning: string; const AProgress: TShredProgress; AOffsetDone, ATotal: Int64;
  ACancel: PBoolean): Boolean;
var
  Name: string;
  Attr: DWORD;
  H: THandle;
  Size, Left, Done: Int64;
  Buf: TBytes;
  Pass, N: Integer;
  Written: DWORD;
  NewName: string;
  Info: BY_HANDLE_FILE_INFORMATION;
  Zero: Int64;
begin
  Result := False;
  AError := '';
  AWarning := '';
  APasses := EnsureRange(APasses, MIN_PASSES, MAX_PASSES);
  Name := LongName(AFile);
  Attr := GetFileAttributes(PChar(Name));
  if Attr = INVALID_FILE_ATTRIBUTES then
  begin
    AError := 'cannot find it';
    Exit;
  end;
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
  begin
    AError := 'is a folder';
    Exit;
  end;
  if (Attr and FILE_ATTRIBUTE_SYSTEM) <> 0 then
  begin
    AError := 'is a Windows system file and is left alone';
    Exit;
  end;
  if IsReparse(Attr) then
  begin
    { a link: remove the link itself, never the file it points to }
    if AKeep then Exit(True);
    Result := DeleteFile(PChar(Name));
    if not Result then AError := LastErr;
    Exit;
  end;
  if (Attr and FILE_ATTRIBUTE_READONLY) <> 0 then
    SetFileAttributes(PChar(Name), Attr and not FILE_ATTRIBUTE_READONLY);
  if (Attr and (FILE_ATTRIBUTE_COMPRESSED or FILE_ATTRIBUTE_SPARSE_FILE or FILE_ATTRIBUTE_ENCRYPTED)) <> 0 then
    AWarning := 'is compressed, sparse or encrypted by Windows, so old data may remain elsewhere on the disk';

  H := CreateFile(PChar(Name), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    AError := LastErr + ' (is it open in another program?)';
    Exit;
  end;
  try
    if not GetFileSizeEx(H, Size) then
    begin
      AError := LastErr;
      Exit;
    end;
    if GetFileInformationByHandle(H, Info) and (Info.nNumberOfLinks > 1) then
      AWarning := AWarning + IfThen(AWarning = '', '', '; ') +
        'has other hard links, which now contain overwritten data';
    SetLength(Buf, CHUNK);
    Done := AOffsetDone;
    for Pass := 1 to APasses do
    begin
      if not SetFilePointerEx(H, 0, nil, FILE_BEGIN) then
      begin
        AError := LastErr;
        Exit;
      end;
      Left := Size;
      while Left > 0 do
      begin
        if (ACancel <> nil) and ACancel^ then
        begin
          AError := 'cancelled';
          Exit;
        end;
        N := Integer(Min(Int64(CHUNK), Left));
        if Pass = APasses then
          FillChar(Buf[0], N, 0)                       { last pass: zeros }
        else
          BCryptGenRandom(nil, @Buf[0], N, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if not WriteFile(H, Buf[0], N, Written, nil) or (Integer(Written) <> N) then
        begin
          AError := LastErr;
          Exit;
        end;
        Dec(Left, N);
        Inc(Done, N);
        if Assigned(AProgress) then
          AProgress(AFile, Done, ATotal);
      end;
      FlushFileBuffers(H);
    end;
    if not AKeep then
    begin
      Zero := 0;
      SetFilePointerEx(H, Zero, nil, FILE_BEGIN);
      SetEndOfFile(H);
    end;
  finally
    CloseHandle(H);
  end;
  if AKeep then
    Exit(True);

  { scrub the name, then delete }
  NewName := ExtractFilePath(Name) + RandomName + '.tmp';
  if MoveFile(PChar(Name), PChar(NewName)) then
    Name := NewName;
  if not DeleteFile(PChar(Name)) then
  begin
    AError := LastErr;
    Exit;
  end;
  Result := True;
end;

{ ---- folders ------------------------------------------------------------------------------- }

procedure CollectFiles(const APath: string; AFiles: TStrings; ADirs: TStrings);
var
  SR: System.SysUtils.TSearchRec;
  Base: string;
  Attr: DWORD;
begin
  Attr := GetFileAttributes(PChar(LongName(APath)));
  if Attr = INVALID_FILE_ATTRIBUTES then Exit;
  if (Attr and FILE_ATTRIBUTE_DIRECTORY) = 0 then
  begin
    AFiles.Add(APath);
    Exit;
  end;
  ADirs.Add(APath);
  if IsReparse(Attr) then Exit;            { never walk into a link }
  Base := IncludeTrailingPathDelimiter(APath);
  if System.SysUtils.FindFirst(LongName(Base) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
          CollectFiles(Base + SR.Name, AFiles, ADirs);
      until System.SysUtils.FindNext(SR) <> 0;
    finally
      System.SysUtils.FindClose(SR);
    end;
  end;
end;

function FileSize(const APath: string): Int64;
var
  H: THandle;
begin
  Result := 0;
  H := CreateFile(PChar(LongName(APath)), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if H <> INVALID_HANDLE_VALUE then
  begin
    GetFileSizeEx(H, Result);
    CloseHandle(H);
  end;
end;

function ShredWorkSize(const APaths: array of string; APasses: Integer): Int64;
var
  P, F: string;
  Files, Dirs: TStringList;
begin
  Result := 0;
  Files := TStringList.Create;
  Dirs := TStringList.Create;
  try
    for P in APaths do
      CollectFiles(P, Files, Dirs);
    for F in Files do
      Inc(Result, FileSize(F) * EnsureRange(APasses, MIN_PASSES, MAX_PASSES));
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

function ShredPaths(const APaths: TArray<string>; APasses: Integer; const AProgress: TShredProgress;
  ACancel: PBoolean): TShredResult;
var
  P, F, Err, Warn: string;
  Files, Dirs: TStringList;
  Total, Done, FileWork: Int64;
  I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Files := TStringList.Create;
  Dirs := TStringList.Create;
  try
    for P in APaths do
    begin
      if GetFileAttributes(PChar(LongName(P))) = INVALID_FILE_ATTRIBUTES then
        Result.Failed := Result.Failed + [P + ': cannot find it']
      else
        CollectFiles(P, Files, Dirs);
    end;
    Total := 0;
    for F in Files do
      Inc(Total, FileSize(F) * EnsureRange(APasses, MIN_PASSES, MAX_PASSES));
    Done := 0;
    for F in Files do
    begin
      if (ACancel <> nil) and ACancel^ then
      begin
        Result.Cancelled := True;
        Break;
      end;
      FileWork := FileSize(F) * EnsureRange(APasses, MIN_PASSES, MAX_PASSES);
      if ShredFile(F, APasses, False, Err, Warn, AProgress, Done, Total, ACancel) then
      begin
        Inc(Result.Files);
        if Warn <> '' then
          Result.Warnings := Result.Warnings + [F + ': ' + Warn];
      end
      else if Err = 'cancelled' then
      begin
        Result.Cancelled := True;
        Break;
      end
      else
        Result.Failed := Result.Failed + [F + ': ' + Err];
      Inc(Done, FileWork);
    end;
    { folders last, deepest first; only empty ones can go }
    if not Result.Cancelled then
      for I := Dirs.Count - 1 downto 0 do
        if RemoveDirectory(PChar(LongName(Dirs[I]))) then
          Inc(Result.Folders)
        else if GetLastError <> ERROR_DIR_NOT_EMPTY then
          Result.Failed := Result.Failed + [Dirs[I] + ': ' + LastErr];
  finally
    Files.Free;
    Dirs.Free;
  end;
end;

end.

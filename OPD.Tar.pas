unit OPD.Tar;

{ Minimal GNU tar reader/writer (no compression).
  PGP Zip stores a folder or several items as one tar inside the encrypted message, so this is
  what CryptLok writes and reads.  Names are UTF-8; long names use the GNU "././@LongLink"
  extension on write, and GNU long names plus pax "path=" records are understood on read.
  Extraction refuses absolute paths, drive letters and ".." so a hostile archive cannot write
  outside the chosen folder. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TTarEntry = record
    Name: string;       { as stored, with / separators }
    Size: Int64;
    IsDir: Boolean;
    DataOffset: Int64;  { offset of the file data in the tar }
    MTime: TDateTime;
  end;
  TTarEntries = TArray<TTarEntry>;

  TTarProgress = reference to procedure(const AName: string; ADone, ATotal: Int64);

  TTarWriter = class
  private
    FStream: TFileStream;
    FTotal: Int64;
    FDone: Int64;
    FProgress: TTarProgress;
    procedure PutHeader(const AName: string; ASize: Int64; AIsDir: Boolean; AMTime: TDateTime);
    procedure PutLongName(const AUtf8Name: TBytes);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    { Adds one file or a whole folder tree.  The top entry is stored under ATopName
      (normally the item's own name), so "C:\x\Portable" is stored as "Portable/...". }
    procedure AddPath(const APath: string);
    procedure SetProgress(ATotalBytes: Int64; const AProgress: TTarProgress);
    procedure Finish;
  end;

{ Total size of all files below (or at) these paths, for progress and disk-space checks. }
function TarSourceSize(const APaths: array of string): Int64;

function TarList(const ATarFile: string): TTarEntries;
{ Extracts everything below ADestDir.  Returns the number of files written.
  AOverwrite = False skips (does not replace) files that already exist; ASkipped counts them. }
function TarExtract(const ATarFile, ADestDir: string; AOverwrite: Boolean; out ASkipped: Integer;
  const AProgress: TTarProgress = nil): Integer;
{ True when the file starts like a tar archive (ustar magic in the first header). }
function LooksLikeTar(const AFile: string): Boolean;

{ Turns a stored name into a safe relative Windows path, or '' when the name is not allowed. }
function SafeRelativePath(const AStoredName: string): string;

implementation

uses
  System.IOUtils, System.DateUtils, Winapi.Windows;

const
  BLOCK = 512;

{ ---- helpers ------------------------------------------------------------------------ }

function ToOctal(AValue: Int64; ADigits: Integer): TBytes;
var
  S: string;
  I: Integer;
begin
  S := '';
  if AValue = 0 then
    S := '0';
  while AValue > 0 do
  begin
    S := Char(Ord('0') + (AValue and 7)) + S;
    AValue := AValue shr 3;
  end;
  while Length(S) < ADigits do
    S := '0' + S;
  SetLength(Result, ADigits);
  for I := 0 to ADigits - 1 do
    Result[I] := Ord(S[I + 1]);
end;

procedure PutField(var AHeader: array of Byte; AOffset: Integer; const AData: TBytes);
begin
  if Length(AData) > 0 then
    Move(AData[0], AHeader[AOffset], Length(AData));
end;

function Min64(A, B: Int64): Int64;
begin
  if A < B then Result := A else Result := B;
end;

function ModeFor(AIsDir: Boolean): Int64;
begin
  if AIsDir then Result := $1ED else Result := $1A4;   { 0755 / 0644 }
end;

function UnixTime(ADate: TDateTime): Int64;
begin
  Result := DateTimeToUnix(ADate, False);
  if Result < 0 then
    Result := 0;
end;

function ParseOctal(const AHeader: array of Byte; AOffset, ALen: Integer): Int64;
var
  I: Integer;
  C: Byte;
begin
  Result := 0;
  { GNU base-256 for very large values }
  if (AHeader[AOffset] and $80) <> 0 then
  begin
    Result := AHeader[AOffset] and $7F;
    for I := 1 to ALen - 1 do
      Result := (Result shl 8) or AHeader[AOffset + I];
    Exit;
  end;
  for I := 0 to ALen - 1 do
  begin
    C := AHeader[AOffset + I];
    if (C >= Ord('0')) and (C <= Ord('7')) then
      Result := (Result shl 3) or (C - Ord('0'))
    else if (C = 0) or (C = Ord(' ')) then
    begin
      if Result <> 0 then
        Break;
    end
    else
      Break;
  end;
end;

function ParseName(const AHeader: array of Byte; AOffset, ALen: Integer): string;
var
  N: Integer;
  B: TBytes;
begin
  N := 0;
  while (N < ALen) and (AHeader[AOffset + N] <> 0) do
    Inc(N);
  SetLength(B, N);
  if N > 0 then
    Move(AHeader[AOffset], B[0], N);
  Result := TEncoding.UTF8.GetString(B);
end;

function IsZeroBlock(const ABlock: array of Byte): Boolean;
var
  I: Integer;
begin
  for I := 0 to BLOCK - 1 do
    if ABlock[I] <> 0 then
      Exit(False);
  Result := True;
end;

{ Windows only accepts paths over 259 characters with the extended-length prefix. }
function LongPath(const APath: string): string;
const
  Prefix = '\\?\';
begin
  Result := APath;
  if (Length(Result) >= 240) and not Result.StartsWith(Prefix) then
    Result := Prefix + ExpandFileName(Result);
end;

function SafeRelativePath(const AStoredName: string): string;
var
  Parts: TArray<string>;
  P, Clean: string;
  SB: TStringBuilder;
  C: Char;
begin
  Result := '';
  P := AStoredName.Replace('\', '/');
  if P = '' then Exit;
  if P.StartsWith('/') then Exit;                   { absolute }
  if (Length(P) >= 2) and (P[2] = ':') then Exit;   { drive letter }
  Parts := P.Split(['/']);
  SB := TStringBuilder.Create;
  try
    for Clean in Parts do
    begin
      if (Clean = '') or (Clean = '.') then Continue;
      if Clean = '..' then Exit;                    { traversal }
      for C in Clean do
        if (Ord(C) < 32) or CharInSet(C, ['<', '>', ':', '"', '|', '?', '*']) then
          Exit;
      if SB.Length > 0 then
        SB.Append('\');
      SB.Append(Clean);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ---- sizes -------------------------------------------------------------------------- }

function TreeSize(const APath: string): Int64;
var
  F: string;
begin
  Result := 0;
  if TDirectory.Exists(APath) then
  begin
    for F in TDirectory.GetFiles(APath, '*', TSearchOption.soAllDirectories) do
      Inc(Result, TFile.GetSize(F));
  end
  else if FileExists(APath) then
    Result := TFile.GetSize(APath);
end;

function TarSourceSize(const APaths: array of string): Int64;
var
  P: string;
begin
  Result := 0;
  for P in APaths do
    Inc(Result, TreeSize(P));
end;

{ ---- writer ------------------------------------------------------------------------- }

constructor TTarWriter.Create(const AFileName: string);
begin
  inherited Create;
  FStream := TFileStream.Create(AFileName, fmCreate);
end;

destructor TTarWriter.Destroy;
begin
  FStream.Free;
  inherited;
end;

procedure TTarWriter.SetProgress(ATotalBytes: Int64; const AProgress: TTarProgress);
begin
  FTotal := ATotalBytes;
  FProgress := AProgress;
end;

procedure TTarWriter.PutLongName(const AUtf8Name: TBytes);
var
  H: array[0..BLOCK - 1] of Byte;
  Sum, I: Integer;
  Pad: Integer;
  Zero: array[0..BLOCK - 1] of Byte;
  Name: TBytes;
begin
  FillChar(H, SizeOf(H), 0);
  Name := TEncoding.ASCII.GetBytes('././@LongLink');
  PutField(H, 0, Name);
  PutField(H, 100, ToOctal($1ED, 7));            { mode 0755 }
  PutField(H, 108, ToOctal(0, 7));
  PutField(H, 116, ToOctal(0, 7));
  PutField(H, 124, ToOctal(Length(AUtf8Name) + 1, 11));
  PutField(H, 136, ToOctal(0, 11));
  H[156] := Ord('L');
  PutField(H, 257, TEncoding.ASCII.GetBytes('ustar '));
  H[263] := Ord(' ');
  FillChar(H[148], 8, Ord(' '));
  Sum := 0;
  for I := 0 to BLOCK - 1 do
    Inc(Sum, H[I]);
  PutField(H, 148, ToOctal(Sum, 6));
  H[154] := 0;
  H[155] := Ord(' ');
  FStream.WriteBuffer(H, BLOCK);
  FStream.WriteBuffer(AUtf8Name[0], Length(AUtf8Name));
  FillChar(Zero, SizeOf(Zero), 0);
  Pad := BLOCK - ((Length(AUtf8Name) + 1) mod BLOCK);
  if Pad = BLOCK then
    Pad := 0;
  FStream.WriteBuffer(Zero, 1 + Pad);            { terminating NUL + padding }
end;

procedure TTarWriter.PutHeader(const AName: string; ASize: Int64; AIsDir: Boolean;
  AMTime: TDateTime);
var
  H: array[0..BLOCK - 1] of Byte;
  NameB: TBytes;
  Sum, I: Integer;
  SizeBytes: TBytes;
begin
  NameB := TEncoding.UTF8.GetBytes(AName);
  if Length(NameB) > 99 then
    PutLongName(NameB);
  FillChar(H, SizeOf(H), 0);
  if Length(NameB) > 99 then
    Move(NameB[0], H[0], 99)
  else
    Move(NameB[0], H[0], Length(NameB));
  PutField(H, 100, ToOctal(ModeFor(AIsDir), 7));
  PutField(H, 108, ToOctal(0, 7));
  PutField(H, 116, ToOctal(0, 7));
  if ASize > 8589934591 then
  begin
    SetLength(SizeBytes, 12);
    SizeBytes[0] := $80;
    for I := 11 downto 4 do
    begin
      SizeBytes[I] := Byte(ASize and $FF);
      ASize := ASize shr 8;
    end;
    PutField(H, 124, SizeBytes);
  end
  else
    PutField(H, 124, ToOctal(ASize, 11));
  PutField(H, 136, ToOctal(UnixTime(AMTime), 11));
  if AIsDir then
    H[156] := Ord('5')
  else
    H[156] := Ord('0');
  PutField(H, 257, TEncoding.ASCII.GetBytes('ustar '));
  H[263] := Ord(' ');
  FillChar(H[148], 8, Ord(' '));
  Sum := 0;
  for I := 0 to BLOCK - 1 do
    Inc(Sum, H[I]);
  PutField(H, 148, ToOctal(Sum, 6));
  H[154] := 0;
  H[155] := Ord(' ');
  FStream.WriteBuffer(H, BLOCK);
end;

procedure TTarWriter.AddPath(const APath: string);
var
  Base: string;

  procedure AddFileEntry(const AFull, AArc: string);
  var
    Src: TFileStream;
    Buf: TBytes;
    Got, Pad: Integer;
    Size: Int64;
    Zero: array[0..BLOCK - 1] of Byte;
  begin
    Src := TFileStream.Create(AFull, fmOpenRead or fmShareDenyWrite);
    try
      Size := Src.Size;
      PutHeader(AArc, Size, False, TFile.GetLastWriteTime(AFull));
      SetLength(Buf, 1024 * 1024);
      repeat
        Got := Src.Read(Buf[0], Length(Buf));
        if Got > 0 then
        begin
          FStream.WriteBuffer(Buf[0], Got);
          Inc(FDone, Got);
          if Assigned(FProgress) then
            FProgress(AArc, FDone, FTotal);
        end;
      until Got = 0;
      Pad := (BLOCK - (Size mod BLOCK)) mod BLOCK;
      if Pad > 0 then
      begin
        FillChar(Zero, SizeOf(Zero), 0);
        FStream.WriteBuffer(Zero, Pad);
      end;
    finally
      Src.Free;
    end;
  end;

  procedure Walk(const ADir, AArc: string);
  var
    E: string;
  begin
    PutHeader(AArc + '/', 0, True, TDirectory.GetLastWriteTime(ADir));
    for E in TDirectory.GetFiles(ADir) do
      AddFileEntry(E, AArc + '/' + ExtractFileName(E));
    for E in TDirectory.GetDirectories(ADir) do
      Walk(E, AArc + '/' + ExtractFileName(E));
  end;

begin
  Base := ExtractFileName(ExcludeTrailingPathDelimiter(APath));
  if TDirectory.Exists(APath) then
    Walk(ExcludeTrailingPathDelimiter(APath), Base)
  else
    AddFileEntry(APath, Base);
end;

procedure TTarWriter.Finish;
var
  Zero: array[0..BLOCK * 2 - 1] of Byte;
begin
  FillChar(Zero, SizeOf(Zero), 0);
  FStream.WriteBuffer(Zero, SizeOf(Zero));
end;

{ ---- reader ------------------------------------------------------------------------- }

function ReadHeaders(AStream: TStream; ACallback: TProc<TTarEntry>): Boolean;
var
  H: array[0..BLOCK - 1] of Byte;
  E: TTarEntry;
  Pending, PaxName, S: string;
  Type_: Byte;
  Size, Skip: Int64;
  LongBuf: TBytes;
  Pax, Line: string;
  P: Integer;
  PaxBytes: TBytes;
begin
  Result := True;
  Pending := '';
  PaxName := '';
  while AStream.Position + BLOCK <= AStream.Size do
  begin
    AStream.ReadBuffer(H, BLOCK);
    if IsZeroBlock(H) then
      Break;
    Type_ := H[156];
    Size := ParseOctal(H, 124, 12);
    if Type_ = Ord('L') then       { GNU long name }
    begin
      SetLength(LongBuf, Size);
      if Size > 0 then
        AStream.ReadBuffer(LongBuf[0], Size);
      Skip := (BLOCK - (Size mod BLOCK)) mod BLOCK;
      AStream.Seek(Skip, soCurrent);
      S := TEncoding.UTF8.GetString(LongBuf);
      P := Pos(#0, S);
      if P > 0 then S := Copy(S, 1, P - 1);
      Pending := S;
      Continue;
    end;
    if (Type_ = Ord('x')) or (Type_ = Ord('g')) then   { pax header }
    begin
      SetLength(PaxBytes, Size);
      if Size > 0 then
        AStream.ReadBuffer(PaxBytes[0], Size);
      Skip := (BLOCK - (Size mod BLOCK)) mod BLOCK;
      AStream.Seek(Skip, soCurrent);
      if Type_ = Ord('x') then
      begin
        Pax := TEncoding.UTF8.GetString(PaxBytes);
        for Line in Pax.Split([#10]) do
        begin
          P := Pos(' path=', Line);
          if P > 0 then
            PaxName := Copy(Line, P + 6, MaxInt);
        end;
      end;
      Continue;
    end;
    E.Name := ParseName(H, 0, 100);
    { ustar prefix field (only valid for real "ustar\0" magic) }
    if (H[257] = Ord('u')) and (H[262] = 0) and (H[345] <> 0) then
      E.Name := ParseName(H, 345, 155) + '/' + E.Name;
    if Pending <> '' then
      E.Name := Pending
    else if PaxName <> '' then
      E.Name := PaxName;
    Pending := '';
    PaxName := '';
    E.Size := Size;
    E.IsDir := (Type_ = Ord('5')) or E.Name.EndsWith('/');
    E.DataOffset := AStream.Position;
    E.MTime := UnixToDateTime(ParseOctal(H, 136, 12), False);
    if (Type_ = Ord('0')) or (Type_ = 0) or (Type_ = Ord('5')) then
      ACallback(E);
    if Type_ = Ord('5') then
      Skip := 0
    else
      Skip := Size + (BLOCK - (Size mod BLOCK)) mod BLOCK;
    AStream.Seek(Skip, soCurrent);
  end;
end;

function LooksLikeTar(const AFile: string): Boolean;
var
  F: TFileStream;
  H: array[0..BLOCK - 1] of Byte;
begin
  Result := False;
  if not FileExists(AFile) then Exit;
  F := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    if F.Size < BLOCK then Exit;
    F.ReadBuffer(H, BLOCK);
    Result := (H[257] = Ord('u')) and (H[258] = Ord('s')) and (H[259] = Ord('t')) and
      (H[260] = Ord('a')) and (H[261] = Ord('r'));
  finally
    F.Free;
  end;
end;

function TarList(const ATarFile: string): TTarEntries;
var
  F: TFileStream;
  L: TList<TTarEntry>;
begin
  L := TList<TTarEntry>.Create;
  F := TFileStream.Create(ATarFile, fmOpenRead or fmShareDenyNone);
  try
    ReadHeaders(F, procedure(E: TTarEntry) begin L.Add(E); end);
    Result := L.ToArray;
  finally
    F.Free;
    L.Free;
  end;
end;

function TarExtract(const ATarFile, ADestDir: string; AOverwrite: Boolean; out ASkipped: Integer;
  const AProgress: TTarProgress): Integer;
var
  F: TFileStream;
  Entries: TTarEntries;
  E: TTarEntry;
  Rel, Dest: string;
  Out_: TFileStream;
  Left: Int64;
  Buf: TBytes;
  Got: Integer;
  Count, Skipped: Integer;
  Total, Done: Int64;
begin
  Count := 0;
  Skipped := 0;
  Entries := TarList(ATarFile);
  Total := 0;
  for E in Entries do
    if not E.IsDir then
      Inc(Total, E.Size);
  Done := 0;
  F := TFileStream.Create(ATarFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, 1024 * 1024);
    for E in Entries do
    begin
      Rel := SafeRelativePath(E.Name);
      if Rel = '' then
        raise Exception.CreateFmt('The archive contains an unsafe path ("%s"); nothing was extracted from it.',
          [E.Name]);
      Dest := LongPath(IncludeTrailingPathDelimiter(ExpandFileName(ADestDir)) + Rel);
      if E.IsDir then
      begin
        ForceDirectories(Dest);
        Continue;
      end;
      ForceDirectories(ExtractFilePath(Dest));
      if FileExists(Dest) and not AOverwrite then
      begin
        Inc(Skipped);
        Inc(Done, E.Size);
        Continue;
      end;
      F.Position := E.DataOffset;
      Out_ := TFileStream.Create(Dest, fmCreate);
      try
        Left := E.Size;
        while Left > 0 do
        begin
          Got := F.Read(Buf[0], Integer(Min64(Left, Length(Buf))));
          if Got <= 0 then
            raise Exception.Create('The archive is cut short.');
          Out_.WriteBuffer(Buf[0], Got);
          Dec(Left, Got);
          Inc(Done, Got);
          if Assigned(AProgress) then
            AProgress(Rel, Done, Total);
        end;
      finally
        Out_.Free;
      end;
      TFile.SetLastWriteTime(Dest, E.MTime);
      Inc(Count);
    end;
  finally
    F.Free;
  end;
  ASkipped := Skipped;
  Result := Count;
end;

end.

unit OPD.SdaBuilder;

{ Builds a self-decrypting archive: a copy of the stub program (CryptLokSda.exe, embedded in this
  program as the SDA_STUB resource), an optional new icon, then the encrypted OpenPGP payload and
  a 16-byte footer.  The icon is changed before the payload is appended because updating
  resources rewrites the file. }

interface

uses
  System.SysUtils, System.Classes;

const
  SDA_MAGIC = 'CLOKSDA1';

{ AStubFile = '' uses the embedded stub.  AIconFile = '' uses the embedded default SDA icon
  (a .ico path replaces it).  Returns '' on success, otherwise the reason. }
function BuildSda(const AStubFile, AOutFile, APayloadFile, AIconFile: string): string;

implementation

uses
  Winapi.Windows, System.IOUtils;

function LoadResourceBytes(const AName: string): TBytes;
var
  RS: TResourceStream;
begin
  RS := TResourceStream.Create(HInstance, AName, RT_RCDATA);
  try
    SetLength(Result, RS.Size);
    if RS.Size > 0 then
      RS.ReadBuffer(Result[0], RS.Size);
  finally
    RS.Free;
  end;
end;

function EnumLangProc(hModule: HMODULE; lpType, lpName: PChar; wLanguage: Word; lParam: LPARAM): BOOL; stdcall;
begin
  PWord(lParam)^ := wLanguage;
  Result := False;      { the first language is enough }
end;

{ Language id the stub's MAINICON group was compiled with. }
function GroupIconLanguage(const AExe: string): Word;
var
  M: HMODULE;
begin
  Result := $0409;
  M := LoadLibraryEx(PChar(AExe), 0, LOAD_LIBRARY_AS_DATAFILE);
  if M = 0 then Exit;
  try
    EnumResourceLanguages(M, RT_GROUP_ICON, 'MAINICON', @EnumLangProc, LPARAM(@Result));
  finally
    FreeLibrary(M);
  end;
end;

{ Replaces the stub's MAINICON with every image of an .ico file. }
function SetExeIcon(const AExe: string; const AIco: TBytes): string;
type
  TIconDirEntry = packed record
    Width, Height, Colors, Reserved: Byte;
    Planes, BitCount: Word;
    BytesInRes, ImageOffset: DWORD;
  end;
  TGroupEntry = packed record
    Width, Height, Colors, Reserved: Byte;
    Planes, BitCount: Word;
    BytesInRes: DWORD;
    Id: Word;
  end;
var
  Count, I: Integer;
  Dir: TIconDirEntry;
  H: THandle;
  Group: TBytes;
  GE: TGroupEntry;
  Ok: Boolean;
  Why: string;
  GroupLang: Word;
const
  FIRST_ID = 100;
begin
  Result := '';
  if (Length(AIco) < 22) or (PWord(@AIco[0])^ <> 0) or (PWord(@AIco[2])^ <> 1) then
    Exit('That file is not a valid .ico icon');
  Count := PWord(@AIco[4])^;
  if (Count < 1) or (Count > 40) then
    Exit('That icon file has an unexpected number of images');
  SetLength(Group, 6 + Count * SizeOf(TGroupEntry));
  PWord(@Group[0])^ := 0;
  PWord(@Group[2])^ := 1;
  PWord(@Group[4])^ := Count;
  GroupLang := GroupIconLanguage(AExe);
  H := BeginUpdateResource(PChar(AExe), False);
  if H = 0 then
    Exit('Could not open the archive program to change its icon');
  Ok := True;
  try
    for I := 0 to Count - 1 do
    begin
      if 6 + (I + 1) * SizeOf(TIconDirEntry) > Length(AIco) then
        Exit('The icon file is damaged');
      Move(AIco[6 + I * SizeOf(TIconDirEntry)], Dir, SizeOf(Dir));
      if Int64(Dir.ImageOffset) + Dir.BytesInRes > Length(AIco) then
        Exit('The icon file is damaged');
      GE.Width := Dir.Width; GE.Height := Dir.Height; GE.Colors := Dir.Colors;
      GE.Reserved := 0; GE.Planes := Dir.Planes; GE.BitCount := Dir.BitCount;
      GE.BytesInRes := Dir.BytesInRes; GE.Id := FIRST_ID + I;
      Move(GE, Group[6 + I * SizeOf(GE)], SizeOf(GE));
      if not UpdateResource(H, RT_ICON, MAKEINTRESOURCE(FIRST_ID + I), GroupLang,
        @AIco[Dir.ImageOffset], Dir.BytesInRes) then
      begin
        Ok := False;
        Why := Why + Format(' icon%d:%d', [I, GetLastError]);
      end;
    end;
    { replace the stub's group in place: same name and same language, so there is only one }
    if not UpdateResource(H, RT_GROUP_ICON, 'MAINICON', GroupLang, @Group[0], Length(Group)) then
    begin
      Ok := False;
      Why := Why + Format(' group:%d', [GetLastError]);
    end;
  finally
    if not EndUpdateResource(H, not Ok) then
    begin
      Ok := False;
      Why := Why + Format(' end:%d', [GetLastError]);
    end;
  end;
  if not Ok then
    Result := 'The icon could not be written into the archive program' + Why;
end;

function BuildSda(const AStubFile, AOutFile, APayloadFile, AIconFile: string): string;
var
  Stub, Ico: TBytes;
  Out_, Pay: TFileStream;
  Len: UInt64;
  Magic: TBytes;
begin
  Result := '';
  try
    if AStubFile <> '' then
      Stub := TFile.ReadAllBytes(AStubFile)
    else
      Stub := LoadResourceBytes('SDA_STUB');
    if Length(Stub) < 1024 then
      Exit('The archive program is missing');
    ForceDirectories(ExtractFilePath(ExpandFileName(AOutFile)));
    TFile.WriteAllBytes(AOutFile, Stub);

    if AIconFile <> '' then
      Ico := TFile.ReadAllBytes(AIconFile)
    else
    begin
      try
        Ico := LoadResourceBytes('SDA_ICON');
      except
        Ico := nil;     { no embedded default: keep the stub's own small icon }
      end;
    end;
    if Length(Ico) > 0 then
    begin
      Result := SetExeIcon(AOutFile, Ico);
      if Result <> '' then
      begin
        DeleteFile(PChar(AOutFile));
        Exit;
      end;
    end;

    Pay := TFileStream.Create(APayloadFile, fmOpenRead or fmShareDenyWrite);
    try
      Out_ := TFileStream.Create(AOutFile, fmOpenReadWrite or fmShareExclusive);
      try
        Out_.Seek(0, soEnd);
        Out_.CopyFrom(Pay, 0);
        Len := Pay.Size;
        Out_.WriteBuffer(Len, 8);
        Magic := TEncoding.ASCII.GetBytes(SDA_MAGIC);
        Out_.WriteBuffer(Magic[0], 8);
      finally
        Out_.Free;
      end;
    finally
      Pay.Free;
    end;
  except
    on E: Exception do
    begin
      Result := E.Message;
      DeleteFile(PChar(AOutFile));
    end;
  end;
end;

end.

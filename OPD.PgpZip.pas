unit OPD.PgpZip;

{ PGP Zip compatible archives.
  A .pgp file is a normal OpenPGP message that starts with a "PGP" marker packet.  One file is
  stored as it is (under its own name); a folder or several items are stored as a GNU tar named
  "<name>.tar".  Nothing here is private to CryptLok, so PGP and gpg can open our archives. }

interface

uses
  System.SysUtils, System.Classes, OPD.Engine, OPD.Tar, OPD.SdaBuilder;

type
  TZipProgress = reference to procedure(const AStep: string; APercent: Integer);

  TZipRequest = record
    Items: TArray<string>;          { files and/or folders }
    OutFile: string;                { .pgp to create }
    Recipients: TArray<string>;     { fingerprints; the owner's own key is expected to be included }
    Signer: string;                 { '' = unsigned }
    SignerPass: TBytes;
    SymPass: TBytes;                { passphrase-only archive (no signature yet) }
    Compress: Boolean;              { PGP writes no compression }
    Sda: Boolean;                   { build a self-decrypting .exe instead of a .pgp (needs SymPass) }
    SdaIcon: string;                { .ico for the exe; '' = the default CryptLok SDA icon }
    SdaStubFile: string;            { tests only: use this stub instead of the embedded one }
  end;

const
  PGP_MARKER: array[0..4] of Byte = ($A8, $03, $50, $47, $50);

{ The default file name for a new archive: item name + .pgp }
function DefaultZipName(const AItems: array of string): string;
function CreateZip(const AEngine: IKeyEngine; const AReq: TZipRequest;
  const AProgress: TZipProgress = nil): TCryptoResult;

{ Decrypts an archive into the private work area.  APlainFile must be removed with
  ZipCleanup when you are done with it (it holds decrypted data). }
function ZipDecrypt(const AEngine: IKeyEngine; const AInFile: string; const APass: TBytes;
  out APlainFile, AInnerName: string): TCryptoResult;
{ Entries in a decrypted archive (a single synthetic entry when it is one plain file). }
function ZipEntries(const APlainFile, AInnerName: string): TTarEntries;
{ Writes the contents to ADestDir; returns the number of files written. }
function ZipExtract(const APlainFile, AInnerName, ADestDir: string; AOverwrite: Boolean;
  out ASkipped: Integer; const AProgress: TZipProgress = nil): Integer;
procedure ZipCleanup(const APlainFile: string);

implementation

uses
  System.IOUtils;

function WorkDirFor(const AEngine: IKeyEngine): string;
begin
  Result := IncludeTrailingPathDelimiter(AEngine.HomeDir) + 'tmp-zip-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '');
  ForceDirectories(Result);
end;

function DefaultZipName(const AItems: array of string): string;
begin
  if Length(AItems) = 0 then
    Exit('archive.pgp');
  Result := ExtractFileName(ExcludeTrailingPathDelimiter(AItems[0])) + '.pgp';
end;

function BaseName(const AItems: array of string): string;
begin
  Result := ExtractFileName(ExcludeTrailingPathDelimiter(AItems[0]));
  if Result = '' then
    Result := 'archive';
end;

procedure Report(const AProgress: TZipProgress; const AStep: string; APercent: Integer);
begin
  if Assigned(AProgress) then
    AProgress(AStep, APercent);
end;

function PrependMarker(const ASrc, ADest: string): Boolean;
var
  S, D: TFileStream;
begin
  Result := False;
  S := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyWrite);
  try
    D := TFileStream.Create(ADest, fmCreate);
    try
      D.WriteBuffer(PGP_MARKER, SizeOf(PGP_MARKER));
      D.CopyFrom(S, 0);
      Result := True;
    finally
      D.Free;
    end;
  finally
    S.Free;
  end;
end;

function CreateZip(const AEngine: IKeyEngine; const AReq: TZipRequest;
  const AProgress: TZipProgress): TCryptoResult;
var
  Work, Source, InnerName, Encrypted, Item, SdaErr: string;
  SingleFile: Boolean;
  Tar: TTarWriter;
  Total: Int64;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(AReq.Items) = 0 then
  begin
    Result.Error := 'No files or folders were selected';
    Exit;
  end;
  for Item in AReq.Items do
    if not (FileExists(Item) or DirectoryExists(Item)) then
    begin
      Result.Error := 'Cannot find ' + Item;
      Exit;
    end;
  if AReq.OutFile = '' then
  begin
    Result.Error := 'No output file name';
    Exit;
  end;
  if AReq.Sda and ((Length(AReq.SymPass) = 0) or (AReq.Signer <> '') or (Length(AReq.Recipients) > 0)) then
  begin
    Result.Error := 'A self-decrypting archive is protected by a passphrase only';
    Exit;
  end;

  SingleFile := (Length(AReq.Items) = 1) and FileExists(AReq.Items[0]);
  Work := WorkDirFor(AEngine);
  Encrypted := Work + '\enc.gpg';
  Source := '';
  try
    if SingleFile then
    begin
      Source := AReq.Items[0];
      InnerName := ExtractFileName(Source);
    end
    else
    begin
      InnerName := BaseName(AReq.Items) + '.tar';
      Source := Work + '\' + 'pack.tar';
      Report(AProgress, 'Collecting files', 0);
      Total := TarSourceSize(AReq.Items);
      Tar := TTarWriter.Create(Source);
      try
        Tar.SetProgress(Total,
          procedure(const AName: string; ADone, ATotal: Int64)
          begin
            if ATotal > 0 then
              Report(AProgress, 'Collecting ' + AName, Integer(ADone * 60 div ATotal));
          end);
        for Item in AReq.Items do
          Tar.AddPath(Item);
        Tar.Finish;
      finally
        Tar.Free;
      end;
    end;

    Report(AProgress, 'Encrypting', 65);
    Result := AEngine.EncryptFileAdv(Source, Encrypted, InnerName, AReq.Recipients,
      AReq.Signer, AReq.SignerPass, AReq.SymPass, AReq.Compress);
    if not Result.Ok then
      Exit;

    Report(AProgress, 'Saving', 90);
    ForceDirectories(ExtractFilePath(ExpandFileName(AReq.OutFile)));
    if AReq.Sda then
    begin
      SdaErr := BuildSda(AReq.SdaStubFile, AReq.OutFile, Encrypted, AReq.SdaIcon);
      if SdaErr <> '' then
      begin
        Result.Ok := False;
        Result.Error := SdaErr;
      end;
    end
    else if not PrependMarker(Encrypted, AReq.OutFile) then
    begin
      Result.Ok := False;
      Result.Error := 'Could not write ' + AReq.OutFile;
    end;
    Report(AProgress, 'Done', 100);
  finally
    if not SingleFile then
      SecureDeleteFile(Source);
    SecureDeleteFile(Encrypted);
    RemoveDir(Work);
  end;
end;

function ZipDecrypt(const AEngine: IKeyEngine; const AInFile: string; const APass: TBytes;
  out APlainFile, AInnerName: string): TCryptoResult;
var
  Work: string;
begin
  APlainFile := '';
  AInnerName := '';
  Work := WorkDirFor(AEngine);
  APlainFile := Work + '\plain.bin';
  Result := AEngine.DecryptFileEx(AInFile, APlainFile, APass);
  if Result.Ok then
    AInnerName := Result.Text
  else
  begin
    SecureDeleteFile(APlainFile);
    RemoveDir(Work);
    APlainFile := '';
  end;
end;

function ZipEntries(const APlainFile, AInnerName: string): TTarEntries;
begin
  if LooksLikeTar(APlainFile) and AInnerName.EndsWith('.tar', True) then
    Result := TarList(APlainFile)
  else
  begin
    SetLength(Result, 1);
    Result[0].Name := ExtractFileName(AInnerName);
    Result[0].Size := TFile.GetSize(APlainFile);
    Result[0].IsDir := False;
    Result[0].DataOffset := 0;
    Result[0].MTime := Now;
  end;
end;

function ZipExtract(const APlainFile, AInnerName, ADestDir: string; AOverwrite: Boolean;
  out ASkipped: Integer; const AProgress: TZipProgress): Integer;
var
  Dest, Rel: string;
begin
  ASkipped := 0;
  ForceDirectories(ADestDir);
  if LooksLikeTar(APlainFile) and AInnerName.EndsWith('.tar', True) then
    Result := TarExtract(APlainFile, ADestDir, AOverwrite, ASkipped,
      procedure(const AName: string; ADone, ATotal: Int64)
      begin
        if ATotal > 0 then
          Report(AProgress, AName, Integer(ADone * 100 div ATotal));
      end)
  else
  begin
    Rel := SafeRelativePath(ExtractFileName(AInnerName));
    if Rel = '' then
      Rel := 'decrypted.bin';
    Dest := IncludeTrailingPathDelimiter(ADestDir) + Rel;
    if FileExists(Dest) and not AOverwrite then
    begin
      ASkipped := 1;
      Exit(0);
    end;
    TFile.Copy(APlainFile, Dest, True);
    Result := 1;
  end;
end;

procedure ZipCleanup(const APlainFile: string);
begin
  if APlainFile = '' then
    Exit;
  SecureDeleteFile(APlainFile);
  RemoveDir(ExtractFileDir(APlainFile));
end;

end.

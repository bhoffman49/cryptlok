unit OPD.Engine;

{ Engine layer.  IKeyEngine is the only thing the UI talks to; TGpgEngine is the
  implementation that drives gpg.exe (GnuPG 2.x) through child processes with an
  isolated GnuPG home directory.  Another back end can be dropped in later by
  implementing IKeyEngine.

  Passphrases are only ever handled as TBytes (UTF-8) and are wiped with
  WipeBytes as soon as the call returns. They are never logged. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils;

type
  TUserIdInfo = record
    UserId: string;       { "Name <mail>" as stored }
    Name: string;
    Email: string;
    Validity: Char;       { gpg validity letter }
    IsPhoto: Boolean;
    Revoked: Boolean;
  end;

  TSubKeyInfo = record
    KeyId: string;
    Fingerprint: string;
    Algo: Integer;
    Bits: Integer;
    Created: TDateTime;
    Expires: TDateTime;   { 0 = never }
    Caps: string;
    Revoked: Boolean;
    Expired: Boolean;
  end;

  TKeyInfo = record
    Fingerprint: string;
    KeyId: string;        { 16 hex }
    Algo: Integer;
    Bits: Integer;
    Created: TDateTime;
    Expires: TDateTime;   { 0 = never }
    Validity: Char;       { o - q n m f u e r d }
    OwnerTrust: Char;
    Caps: string;
    HasSecret: Boolean;
    Revoked: Boolean;
    Expired: Boolean;
    Disabled: Boolean;
    UserIds: TArray<TUserIdInfo>;
    SubKeys: TArray<TSubKeyInfo>;
    function DisplayName: string;
    function DisplayEmail: string;
    function ShortId: string;          { 0x + last 8 hex }
    function AlgoName: string;
    function SizeText: string;         { 2048 or 2048/1024 style }
    function Description: string;      { "RSA key pair" ... }
    function TrustText: string;
    function IsVerified: Boolean;
  end;
  TKeyInfoArray = TArray<TKeyInfo>;

  TImportOutcome = (ioNew, ioUpdated, ioUnchanged, ioSkipped, ioFailed);

  TImportItem = record
    Fingerprint: string;
    KeyId: string;
    UserId: string;
    Outcome: TImportOutcome;
    SecretImported: Boolean;
    PassphraseChecked: Boolean;   { true = passphrase proved correct }
    Detail: string;               { why / what }
  end;

  TImportReport = record
    Items: TArray<TImportItem>;
    Notes: TArray<string>;        { general gpg messages, no secrets }
    function Count(AOutcome: TImportOutcome): Integer;
  end;

  { One certification (signature) on a user ID of a key. }
  TCertInfo = record
    UserId: string;       { the user ID that was signed }
    SignerKeyId: string;  { 16 hex }
    SignerName: string;   { empty when that key is not in the keyring }
    Created: TDateTime;
    Self: Boolean;        { the key's own signature }
    LocalOnly: Boolean;   { not exportable }
    Revoked: Boolean;
    Valid: Boolean;       { gpg could check it }
  end;

  TSigStatus = (ssNone, ssGood, ssBad, ssNoKey, ssExpired);

  TCryptoResult = record
    Ok: Boolean;
    Text: string;          { result text (UTF-8 decoded) }
    Error: string;         { human readable reason when not Ok }
    Sig: TSigStatus;       { signature found while decrypting/verifying }
    SignedBy: string;      { "Name <mail>" or key id }
    SignedOn: TDateTime;   { when the signature was made (0 = unknown) }
    SignerKeyId: string;   { 16 hex of the signing key, when known }
    WrongPassphrase: Boolean;
  end;

  { What a key says about the algorithms it prefers (read from its self-signature). }
  TKeyPrefs = record
    Valid: Boolean;
    Cipher: string;        { "AES256, AES192, ..." in preference order }
    Hash: string;
    Compression: string;
    Encoding: string;      { PGP/MIME, PGP inline, ... when the key says so }
    Keyserver: string;     { preferred keyserver URL, '' = none }
  end;

  IKeyEngine = interface
    ['{6E0B7A52-1C1F-4C1E-9E0B-3C5A3B7A8D11}']
    function EngineName: string;
    function Available(out Info: string): Boolean;
    function HomeDir: string;
    { Header lines added to ASCII armor that CryptLok produces (messages, signatures, exported keys):
      "Version: <AVersion>" when AVersion is not empty, and "Comment: <AComment>" when AComment is not empty. }
    procedure SetArmorHeaders(const AVersion, AComment: string);
    function ListKeys: TKeyInfoArray;
    { What gpg said the last time a listing came back empty (for error messages). }
    function LastListError: string;
    { Read a keyring file (.pkr/.skr/.asc/.gpg) without importing it. }
    function PreviewFile(const AFileName: string): TKeyInfoArray;
    { Import a keyring file; the file is only read. }
    function ImportFile(const AFileName: string; const APassphrase: TBytes): TImportReport;
    { True when the file holds a key made with an algorithm this GnuPG does not support (post-quantum, v6 ...) }
    function HasUnsupportedKey(const AFileName: string): Boolean;
    { Proves a passphrase against a secret key (throw-away signature). }
    function CheckPassphrase(const AFingerprint: string; const APassphrase: TBytes;
      out AReason: string): Boolean;
    { Text operations (clipboard).  Text is UTF-8.  ASigner = '' means no signature. }
    function EncryptText(const AText: string; const ARecipients: TArray<string>;
      const ASigner: string; const APassphrase: TBytes): TCryptoResult;
    function SignText(const AText, ASigner: string; const APassphrase: TBytes): TCryptoResult;
    function DecryptText(const AText: string; const APassphrase: TBytes): TCryptoResult;
    { Key IDs (16 hex) a message is encrypted to; empty when it is not encrypted. }
    function MessageRecipients(const AText: string): TArray<string>;
    { The same for an encrypted file (empty for a passphrase-only or unencrypted file). }
    function FileRecipients(const AFileName: string): TArray<string>;
    { Binary file operations (used to wrap a disk keyfile). }
    function EncryptFile(const AInFile, AOutFile: string;
      const ARecipients: TArray<string>): TCryptoResult;
    function DecryptFile(const AInFile, AOutFile: string;
      const APassphrase: TBytes): TCryptoResult;
    { Archive-grade file encryption (PGP Zip).  AInnerName is the file name stored inside the
      message.  Recipients and/or ASymPass: with recipients only, ASignerPass unlocks ASigner;
      with a symmetric passphrase and a signer, the data is signed first and the signed message is then
      encrypted with the passphrase (gpg cannot take two different passphrases in one call).
      ACompress = False writes the data uncompressed, like PGP does. }
    function EncryptFileAdv(const AInFile, AOutFile, AInnerName: string;
      const ARecipients: TArray<string>; const ASigner: string;
      const ASignerPass, ASymPass: TBytes; ACompress: Boolean): TCryptoResult;
    { Decrypts and reports the signature (Sig/SignedBy) and the stored file name (Text). }
    function DecryptFileEx(const AInFile, AOutFile: string;
      const APassphrase: TBytes): TCryptoResult;
    { Key management. }
    function ExportPublicKey(const AFingerprint: string): TCryptoResult;
    function DeleteKey(const AFingerprint: string; AIncludingSecret: Boolean): TCryptoResult;
    { ATrust: 'u' ultimate, 'f' full, 'm' marginal, 'n' never, '-' undefined }
    function SetOwnerTrust(const AFingerprint: string; ATrust: Char): TCryptoResult;
    { Certifies (signs) every user ID of a key with one of our own keys. ALocal = kept in this keyring only. }
    function SignKey(const AFingerprint, ASignerFingerprint: string; ALocal: Boolean;
      const APassphrase: TBytes): TCryptoResult;
    { Who has signed (certified) the user IDs of a key. }
    function ListCertifications(const AFingerprint: string): TArray<TCertInfo>;
    { Checks a detached signature (.sig / .asc) against the file it was made for. }
    function VerifyDetached(const ASigFile, ADataFile: string): TCryptoResult;
    { Makes a detached signature of a file with one of our keys (ASigFile is written). }
    function SignFile(const AFile, ASignerFingerprint, ASigFile: string; AArmor: Boolean;
      const APassphrase: TBytes): TCryptoResult;
    { New RSA key pair with an encryption subkey. AExpireDays = 0 means never. }
    function GenerateKey(const AName, AEmail: string; ABits, AExpireDays: Integer;
      const APassphrase: TBytes): TCryptoResult;
    { Changes the passphrase of a private key (all its parts). }
    function ChangePassphrase(const AFingerprint: string; const AOld, ANew: TBytes): TCryptoResult;
    { Adds another user ID (name + email) to one of your private keys. }
    function AddUserId(const AFingerprint, AName, AEmail: string; const APassphrase: TBytes): TCryptoResult;
    { Make a user ID the primary one / revoke a user ID (AUserId is the full "Name <mail>" string). }
    function SetPrimaryUserId(const AFingerprint, AUserId: string; const APassphrase: TBytes): TCryptoResult;
    function RevokeUserId(const AFingerprint, AUserId: string; const APassphrase: TBytes): TCryptoResult;
    { Ends GnuPG's background agent for this keyring (called when CryptLok really exits). }
    procedure StopAgent;
    { Photo IDs (JPEG data, in key order) and the algorithm preferences of a key. }
    function ReadKeyExtras(const AFingerprint: string; out APhotos: TArray<TBytes>;
      out APrefs: TKeyPrefs): Boolean;
    { Adds a JPEG as a photo ID to one of your private keys (keep it under about 6 KB). }
    function AddPhotoId(const AFingerprint, AJpegFile: string; const APassphrase: TBytes): TCryptoResult;
    { Removes the Nth photo ID (0 = the first one) from one of your private keys. }
    function RemovePhotoId(const AFingerprint: string; APhotoNumber: Integer): TCryptoResult;
    { Changes the preferred algorithms of one of your private keys.  The lists are algorithm names in
      preference order (gpg names: AES256, AES192, AES, TWOFISH, CAST5, 3DES, IDEA / SHA512, SHA384, SHA256,
      SHA224, SHA1, RIPEMD160 / ZLIB, BZIP2, ZIP, Uncompressed).  AKeyserver: '' = leave as it is,
      'none' = remove the preferred keyserver, anything else = set it. }
    function SetKeyPreferences(const AFingerprint: string; const ACiphers, AHashes, ACompression: TArray<string>;
      const AKeyserver: string; const APassphrase: TBytes): TCryptoResult;
  end;

  TGpgEngine = class(TInterfacedObject, IKeyEngine)
  private
    FExe: string;
    FHome: string;
    FArmorVersion, FArmorComment: string;
    FVersion: string;
    FListError: string;
    function AddArmorHeaders(const AArmor: string): string;
    function Run(const AArgs: array of string; const AStdIn: TBytes;
      out AOut, AErr: string; out AExit: Integer): Boolean;
    function RunText(const AArgs: array of string; out AOut, AErr: string): Integer;
    procedure EnsureAgentConfig;
    function RunGpgconf(const AArgs: array of string; out AOut, AErr: string): Boolean;
    function ParseColons(const AText: string): TKeyInfoArray;
    procedure MarkSecrets(var AKeys: TKeyInfoArray);
  public
    constructor Create(const AHomeDir: string = '');
    function EngineName: string;
    function Available(out Info: string): Boolean;
    function HomeDir: string;
    procedure SetArmorHeaders(const AVersion, AComment: string);
    function ListKeys: TKeyInfoArray;
    function LastListError: string;
    function PreviewFile(const AFileName: string): TKeyInfoArray;
    function ImportFile(const AFileName: string; const APassphrase: TBytes): TImportReport;
    { True when the file holds a key made with an algorithm this GnuPG does not support (post-quantum, v6 ...) }
    function HasUnsupportedKey(const AFileName: string): Boolean;
    function CheckPassphrase(const AFingerprint: string; const APassphrase: TBytes;
      out AReason: string): Boolean;
    function EncryptText(const AText: string; const ARecipients: TArray<string>;
      const ASigner: string; const APassphrase: TBytes): TCryptoResult;
    function SignText(const AText, ASigner: string; const APassphrase: TBytes): TCryptoResult;
    function DecryptText(const AText: string; const APassphrase: TBytes): TCryptoResult;
    function MessageRecipients(const AText: string): TArray<string>;
    function FileRecipients(const AFileName: string): TArray<string>;
    function EncryptFile(const AInFile, AOutFile: string;
      const ARecipients: TArray<string>): TCryptoResult;
    function DecryptFile(const AInFile, AOutFile: string;
      const APassphrase: TBytes): TCryptoResult;
    function EncryptFileAdv(const AInFile, AOutFile, AInnerName: string;
      const ARecipients: TArray<string>; const ASigner: string;
      const ASignerPass, ASymPass: TBytes; ACompress: Boolean): TCryptoResult;
    function DecryptFileEx(const AInFile, AOutFile: string;
      const APassphrase: TBytes): TCryptoResult;
    { Key management. }
    function ExportPublicKey(const AFingerprint: string): TCryptoResult;
    function DeleteKey(const AFingerprint: string; AIncludingSecret: Boolean): TCryptoResult;
    { ATrust: 'u' ultimate, 'f' full, 'm' marginal, 'n' never, '-' undefined }
    function SetOwnerTrust(const AFingerprint: string; ATrust: Char): TCryptoResult;
    { Certifies (signs) every user ID of a key with one of our own keys. ALocal = kept in this keyring only. }
    function SignKey(const AFingerprint, ASignerFingerprint: string; ALocal: Boolean;
      const APassphrase: TBytes): TCryptoResult;
    { Who has signed (certified) the user IDs of a key. }
    function ListCertifications(const AFingerprint: string): TArray<TCertInfo>;
    { Checks a detached signature (.sig / .asc) against the file it was made for. }
    function VerifyDetached(const ASigFile, ADataFile: string): TCryptoResult;
    { Makes a detached signature of a file with one of our keys (ASigFile is written). }
    function SignFile(const AFile, ASignerFingerprint, ASigFile: string; AArmor: Boolean;
      const APassphrase: TBytes): TCryptoResult;
    { New RSA key pair with an encryption subkey. AExpireDays = 0 means never. }
    function GenerateKey(const AName, AEmail: string; ABits, AExpireDays: Integer;
      const APassphrase: TBytes): TCryptoResult;
    { Changes the passphrase of a private key (all its parts). }
    function ChangePassphrase(const AFingerprint: string; const AOld, ANew: TBytes): TCryptoResult;
    { Adds another user ID (name + email) to one of your private keys. }
    function AddUserId(const AFingerprint, AName, AEmail: string; const APassphrase: TBytes): TCryptoResult;
    { Make a user ID the primary one / revoke a user ID (AUserId is the full "Name <mail>" string). }
    function SetPrimaryUserId(const AFingerprint, AUserId: string; const APassphrase: TBytes): TCryptoResult;
    function RevokeUserId(const AFingerprint, AUserId: string; const APassphrase: TBytes): TCryptoResult;
    procedure StopAgent;
    function ReadKeyExtras(const AFingerprint: string; out APhotos: TArray<TBytes>;
      out APrefs: TKeyPrefs): Boolean;
    function AddPhotoId(const AFingerprint, AJpegFile: string; const APassphrase: TBytes): TCryptoResult;
    function RemovePhotoId(const AFingerprint: string; APhotoNumber: Integer): TCryptoResult;
    function SetKeyPreferences(const AFingerprint: string; const ACiphers, AHashes, ACompression: TArray<string>;
      const AKeyserver: string; const APassphrase: TBytes): TCryptoResult;
  end;

{ Photo IDs found in binary key data (OpenPGP user-attribute packets with a JPEG image). }
function ExtractPhotoJpegs(const AKeyData: TBytes): TArray<TBytes>;

{ Overwrites a file with zeros and deletes it. }
procedure SecureDeleteFile(const AFile: string);

procedure WipeBytes(var ABytes: TBytes);
{ Overwrites the characters of a string in place (best effort) and empties it. }
procedure WipeString(var S: string);
function PassphraseToBytes(const S: string): TBytes;
{ The GnuPG home inside the current data folder (CryptLokDataFolder + '\gnupg'). }
function DefaultHomeDir: string;
{ %USERPROFILE%\.cryptlok - the default data folder (keyring in gnupg\, settings.ini) and home of location.ini }
function DefaultDataFolder: string;
{ %USERPROFILE%\.cryptlok\location.ini: [Keyring] Folder=<another data folder>, written by Key Management }
function LocationFile: string;
{ The data folder in use: the one in location.ini, else the default. }
function CryptLokDataFolder: string;
function AlgoLabel(AAlgo: Integer): string;

implementation

uses
  Winapi.Windows, System.DateUtils, System.StrUtils, System.Math, System.IniFiles;

procedure WipeBytes(var ABytes: TBytes);
begin
  if Length(ABytes) > 0 then
  begin
    FillChar(ABytes[0], Length(ABytes), 0);
    SetLength(ABytes, 0);
  end;
end;

procedure WipeString(var S: string);
begin
  if Length(S) > 0 then
  begin
    UniqueString(S);
    FillChar(PChar(S)^, Length(S) * SizeOf(Char), 0);
  end;
  S := '';
end;

function PassphraseToBytes(const S: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(S);
end;

function DefaultDataFolder: string;
begin
  { NOT under AppData: programs started from a packaged (MSIX) app such as the
    Claude desktop app get AppData redirected to a private folder, which would
    give them a different (empty) keyring than the same exe started normally. }
  { testing aid: CRYPTLOK_TEST_PROFILE replaces %USERPROFILE% for the data folder only, so tests never touch the
    real keyring or location.ini (overriding USERPROFILE itself confuses GnuPG's agent) }
  Result := GetEnvironmentVariable('CRYPTLOK_TEST_PROFILE');
  if Result = '' then
    Result := GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
    Result := ExtractFilePath(ParamStr(0));
  Result := IncludeTrailingPathDelimiter(Result) + '.cryptlok';
end;

function LocationFile: string;
begin
  Result := IncludeTrailingPathDelimiter(DefaultDataFolder) + 'location.ini';
end;

function CryptLokDataFolder: string;
var
  Ini: TIniFile;
begin
  Result := '';
  if FileExists(LocationFile) then
  begin
    Ini := TIniFile.Create(LocationFile);
    try
      Result := Trim(Ini.ReadString('Keyring', 'Folder', ''));
    finally
      Ini.Free;
    end;
  end;
  if Result = '' then
    Result := DefaultDataFolder;
end;

function DefaultHomeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(CryptLokDataFolder) + 'gnupg';
end;

{ ---- TKeyInfo ----------------------------------------------------------- }

function TKeyInfo.DisplayName: string;
var
  I: Integer;
begin
  for I := 0 to High(UserIds) do
    if not UserIds[I].IsPhoto then
      Exit(IfThen(UserIds[I].Name <> '', UserIds[I].Name, UserIds[I].Email));
  Result := '(no user ID)';
end;

function TKeyInfo.DisplayEmail: string;
var
  I: Integer;
begin
  for I := 0 to High(UserIds) do
    if not UserIds[I].IsPhoto then
      Exit(UserIds[I].Email);
  Result := '';
end;

function TKeyInfo.ShortId: string;
begin
  Result := '0x' + Copy(KeyId, Length(KeyId) - 7, 8);
end;

function AlgoLabel(AAlgo: Integer): string;
begin
  case AAlgo of
    1, 2, 3: Result := 'RSA';
    16, 20: Result := 'Elgamal';
    17: Result := 'DSA';
    18: Result := 'ECDH';
    19: Result := 'ECDSA';
    22: Result := 'EdDSA';
    25: Result := 'X25519';
    27: Result := 'Ed25519';
  else
    Result := 'Algo ' + IntToStr(AAlgo);
  end;
end;

function TKeyInfo.AlgoName: string;
begin
  Result := AlgoLabel(Algo);
end;

function TKeyInfo.SizeText: string;
var
  I, EncBits: Integer;
begin
  Result := IntToStr(Bits);
  { PGP style "signing/encryption" when the encryption subkey differs. }
  EncBits := 0;
  for I := 0 to High(SubKeys) do
    if (Pos('e', SubKeys[I].Caps) > 0) and not SubKeys[I].Revoked then
    begin
      EncBits := SubKeys[I].Bits;
      Break;
    end;
  if EncBits > 0 then
    Result := Result + '/' + IntToStr(EncBits);
end;

function TKeyInfo.Description: string;
var
  I: Integer;
  Enc: string;
begin
  Result := AlgoName;
  for I := 0 to High(SubKeys) do
    if (Pos('e', SubKeys[I].Caps) > 0) and (AlgoLabel(SubKeys[I].Algo) <> AlgoName) then
    begin
      Result := Result + '/' + AlgoLabel(SubKeys[I].Algo);
      Break;
    end;
  Enc := IfThen(HasSecret, ' key pair', ' public key');
  Result := Result + Enc;
end;

function TKeyInfo.TrustText: string;
begin
  case OwnerTrust of
    'u': Result := 'Implicit';
    'f': Result := 'Complete';
    'm': Result := 'Marginal';
    'n': Result := 'Untrusted';
  else
    Result := 'None';
  end;
end;

function TKeyInfo.IsVerified: Boolean;
begin
  Result := CharInSet(Validity, ['m', 'f', 'u']) and not Revoked and not Expired;
end;

function TImportReport.Count(AOutcome: TImportOutcome): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Items) do
    if Items[I].Outcome = AOutcome then
      Inc(Result);
end;

{ ---- helpers ------------------------------------------------------------ }

function EpochToDateTime(const S: string): TDateTime;
var
  V: Int64;
begin
  if (S <> '') and TryStrToInt64(S, V) and (V > 0) then
    Result := UnixToDateTime(V, False)
  else
    Result := 0;
end;

{ gpg escapes ':' etc. as \xHH in colon listings (bytes, UTF-8). }
function UnescapeColon(const S: string): string;
var
  Bytes: TBytes;
  I, N: Integer;
  Raw: TBytes;
begin
  if Pos('\x', S) = 0 then
    Exit(S);
  Raw := TEncoding.UTF8.GetBytes(S);
  SetLength(Bytes, Length(Raw));
  N := 0;
  I := 0;
  while I < Length(Raw) do
  begin
    if (Raw[I] = Ord('\')) and (I + 3 < Length(Raw)) and (Raw[I + 1] = Ord('x')) then
    begin
      Bytes[N] := StrToIntDef('$' + Chr(Raw[I + 2]) + Chr(Raw[I + 3]), Ord('?'));
      Inc(I, 4);
    end
    else
    begin
      Bytes[N] := Raw[I];
      Inc(I);
    end;
    Inc(N);
  end;
  SetLength(Bytes, N);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

procedure SplitUserId(const AUid: string; out AName, AEmail: string);
var
  P, Q: Integer;
begin
  P := LastDelimiter('<', AUid);
  Q := LastDelimiter('>', AUid);
  if (P > 0) and (Q > P) then
  begin
    AEmail := Copy(AUid, P + 1, Q - P - 1);
    AName := Trim(Copy(AUid, 1, P - 1));
  end
  else
  begin
    AName := Trim(AUid);
    AEmail := '';
  end;
end;

function Field(const AFields: TArray<string>; AIndex: Integer): string;
begin
  if AIndex < Length(AFields) then
    Result := AFields[AIndex]
  else
    Result := '';
end;

{ ---- TGpgEngine --------------------------------------------------------- }

function FindGpg: string;
var
  Buf: array[0..MAX_PATH] of Char;
  FilePart: PChar;
  Cand: string;
begin
  { 1. a GnuPG folder next to CryptLok.exe (the bundled / portable layout: GnuPG\bin\gpg.exe)
    2. the Gpg4win / GnuPG 2.5 install, preferred over whatever else is on PATH (e.g. the older
       gpg bundled with Git) }
  Cand := ExtractFilePath(ParamStr(0)) + 'GnuPG\bin\gpg.exe';
  if FileExists(Cand) then
    Exit(Cand);
  for Cand in ['F:\GnuPG\bin\gpg.exe', 'C:\Program Files (x86)\GnuPG\bin\gpg.exe',
    'C:\Program Files\GnuPG\bin\gpg.exe'] do
    if FileExists(Cand) then
      Exit(Cand);
  Result := '';
  if SearchPath(nil, 'gpg.exe', nil, MAX_PATH, Buf, FilePart) > 0 then
    Result := string(Buf);
end;

constructor TGpgEngine.Create(const AHomeDir: string);
begin
  inherited Create;
  FExe := FindGpg;
  if AHomeDir <> '' then
    FHome := AHomeDir
  else
    FHome := DefaultHomeDir;
  ForceDirectories(FHome);
  EnsureAgentConfig;
end;

procedure TGpgEngine.EnsureAgentConfig;
const
  Wanted = '# written by CryptLok: never cache passphrases, so every unlock is checked' + #13#10 +
    'default-cache-ttl 0' + #13#10 + 'max-cache-ttl 0' + #13#10 +
    'default-cache-ttl-ssh 0' + #13#10 + 'max-cache-ttl-ssh 0' + #13#10;
var
  Conf, Current, O, E: string;
begin
  Conf := IncludeTrailingPathDelimiter(FHome) + 'gpg-agent.conf';
  Current := '';
  if FileExists(Conf) then
    Current := TFile.ReadAllText(Conf);
  if Current <> Wanted then
  begin
    TFile.WriteAllText(Conf, Wanted);
    { a running agent keeps its old settings until it is restarted }
    RunGpgconf(['--kill', 'gpg-agent'], O, E);
  end;
end;

function TGpgEngine.RunGpgconf(const AArgs: array of string; out AOut, AErr: string): Boolean;
var
  Saved: string;
  Code: Integer;
begin
  Saved := FExe;
  try
    FExe := ExtractFilePath(Saved) + 'gpgconf.exe';
    Result := FileExists(FExe) and Run(AArgs, nil, AOut, AErr, Code);
  finally
    FExe := Saved;
  end;
end;

function MakeWorkDir(const AHome: string): string; forward;
procedure RemoveWorkDir(const ADir: string; const AFiles: array of string); forward;
function ReadAllBytes(const AFile: string): TBytes; forward;
function PassInput(const APass: TBytes): TBytes; forward;

{ ---- photo IDs and preferences --------------------------------------------------------- }

function ExtractPhotoJpegs(const AKeyData: TBytes): TArray<TBytes>;
var
  P, N, Tag, Len, Hdr, Q: Integer;
  B: Byte;
  Body, Jpg: TBytes;
  SubLen, ImgHdr: Integer;
  L: TList<TBytes>;
begin
  L := TList<TBytes>.Create;
  try
    P := 0;
    N := Length(AKeyData);
    while P < N do
    begin
      B := AKeyData[P]; Inc(P);
      if (B and $80) = 0 then Break;
      if (B and $40) <> 0 then
      begin
        Tag := B and $3F;
        if P >= N then Break;
        Len := AKeyData[P]; Inc(P);
        if Len >= 224 then
        begin
          if Len = 255 then
          begin
            if P + 4 > N then Break;
            Len := (Integer(AKeyData[P]) shl 24) or (Integer(AKeyData[P + 1]) shl 16) or (Integer(AKeyData[P + 2]) shl 8) or AKeyData[P + 3];
            Inc(P, 4);
          end
          else
            Break;                    { partial lengths do not occur in key packets }
        end
        else if Len >= 192 then
        begin
          if P >= N then Break;
          Len := ((Len - 192) shl 8) + AKeyData[P] + 192; Inc(P);
        end;
      end
      else
      begin
        Tag := (B shr 2) and $F;
        case B and 3 of
          0: begin Len := AKeyData[P]; Inc(P); end;
          1: begin Len := (Integer(AKeyData[P]) shl 8) or AKeyData[P + 1]; Inc(P, 2); end;
          2: begin
               Len := (Integer(AKeyData[P]) shl 24) or (Integer(AKeyData[P + 1]) shl 16) or (Integer(AKeyData[P + 2]) shl 8) or AKeyData[P + 3];
               Inc(P, 4);
             end;
        else
          Len := N - P;
        end;
      end;
      if (Len < 0) or (P + Len > N) then Break;
      if Tag = 17 then
      begin
        { user attribute: subpackets, each = length, type, data; type 1 = image }
        Q := P;
        while Q < P + Len do
        begin
          B := AKeyData[Q]; Inc(Q);
          if B < 192 then SubLen := B
          else if B < 255 then begin SubLen := ((B - 192) shl 8) + AKeyData[Q] + 192; Inc(Q); end
          else
          begin
            SubLen := (Integer(AKeyData[Q]) shl 24) or (Integer(AKeyData[Q + 1]) shl 16) or (Integer(AKeyData[Q + 2]) shl 8) or AKeyData[Q + 3];
            Inc(Q, 4);
          end;
          if (SubLen < 2) or (Q + SubLen > P + Len) then Break;
          if AKeyData[Q] = 1 then
          begin
            { image header: 2-byte little-endian header length, version, encoding (1 = JPEG) ... }
            Hdr := Q + 1;
            ImgHdr := AKeyData[Hdr] or (Integer(AKeyData[Hdr + 1]) shl 8);
            if (ImgHdr >= 4) and (AKeyData[Hdr + 3] = 1) and (Hdr + ImgHdr < Q + SubLen) then
            begin
              SetLength(Jpg, Q + SubLen - (Hdr + ImgHdr));
              Move(AKeyData[Hdr + ImgHdr], Jpg[0], Length(Jpg));
              L.Add(Jpg);
            end;
          end;
          Inc(Q, SubLen);
        end;
      end;
      Inc(P, Len);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
  SetLength(Body, 0);
end;

function NameList(const ANumbers: string; AKind: Integer): string;
var
  Part, Nm: string;
  I: Integer;
begin
  Result := '';
  for Part in ANumbers.Split([' ']) do
  begin
    I := StrToIntDef(Trim(Part), -1);
    if I < 0 then Continue;
    Nm := '';
    case AKind of
      0: case I of
           1: Nm := 'IDEA'; 2: Nm := '3DES'; 3: Nm := 'CAST5'; 4: Nm := 'Blowfish';
           7: Nm := 'AES128'; 8: Nm := 'AES192'; 9: Nm := 'AES256'; 10: Nm := 'Twofish';
           11: Nm := 'Camellia128'; 12: Nm := 'Camellia192'; 13: Nm := 'Camellia256';
         end;
      1: case I of
           1: Nm := 'MD5'; 2: Nm := 'SHA1'; 3: Nm := 'RIPEMD160'; 8: Nm := 'SHA256';
           9: Nm := 'SHA384'; 10: Nm := 'SHA512'; 11: Nm := 'SHA224';
         end;
      2: case I of
           0: Nm := 'Uncompressed'; 1: Nm := 'ZIP'; 2: Nm := 'ZLIB'; 3: Nm := 'BZip2';
         end;
    end;
    if Nm = '' then Nm := IntToStr(I);
    Result := Result + IfThen(Result = '', '', ', ') + Nm;
  end;
end;

{ Reads the preferences out of "gpg --list-packets" output (first user ID's self-signature). }
function ParsePrefs(const AText: string): TKeyPrefs;
var
  Line, T: string;
  P, E: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for Line in AText.Split([#10]) do
  begin
    T := Trim(Line);
    if T.Contains(':attribute packet') then Break;     { the first user ID is enough }
    P := Pos('(pref-sym-algos:', T);
    if (P > 0) and (Result.Cipher = '') then
    begin
      E := Pos(')', T, P);
      Result.Cipher := NameList(Copy(T, P + 16, E - P - 16), 0);
    end;
    P := Pos('(pref-hash-algos:', T);
    if (P > 0) and (Result.Hash = '') then
    begin
      E := Pos(')', T, P);
      Result.Hash := NameList(Copy(T, P + 17, E - P - 17), 1);
    end;
    P := Pos('(pref-zip-algos:', T);
    if (P > 0) and (Result.Compression = '') then
    begin
      E := Pos(')', T, P);
      Result.Compression := NameList(Copy(T, P + 16, E - P - 16), 2);
    end;
    P := Pos('preferred-email-encoding@pgp.com=', T);
    if (P > 0) and (Result.Encoding = '') then
    begin
      E := Pos(')', T, P);
      T := Copy(T, P + 33, E - P - 33);
      if SameText(T, 'pgpmime') then Result.Encoding := 'PGP/MIME'
      else if SameText(T, 'pgpinline') then Result.Encoding := 'PGP inline'
      else Result.Encoding := T;
    end;
    P := Pos('(preferred keyserver:', T);
    if (P > 0) and (Result.Keyserver = '') then
    begin
      E := Pos(')', T, P);
      Result.Keyserver := Trim(Copy(T, P + 21, E - P - 21));
    end;
  end;
  Result.Valid := (Result.Cipher <> '') or (Result.Hash <> '') or (Result.Compression <> '');
end;

function TGpgEngine.ReadKeyExtras(const AFingerprint: string; out APhotos: TArray<TBytes>;
  out APrefs: TKeyPrefs): Boolean;
var
  Dir, Exp, O, E: string;
  Code: Integer;
begin
  Result := False;
  SetLength(APhotos, 0);
  FillChar(APrefs, SizeOf(APrefs), 0);
  Dir := MakeWorkDir(FHome);
  Exp := Dir + '\k.bin';
  try
    if Run(['--yes', '--output', Exp, '--export', AFingerprint], nil, O, E, Code) and (Code = 0) and
       FileExists(Exp) then
    begin
      APhotos := ExtractPhotoJpegs(ReadAllBytes(Exp));
      if Run(['--list-packets', Exp], nil, O, E, Code) then
        APrefs := ParsePrefs(O + #10 + E);
      Result := True;
    end;
  finally
    RemoveWorkDir(Dir, [Exp]);
  end;
end;

{ Counts the photo ("uat") entries and returns the 1-based position of each among all user IDs. }
function PhotoPositions(const AColons: string): TArray<Integer>;
var
  Line: string;
  Pos_: Integer;
  L: TList<Integer>;
  Seen: Boolean;
begin
  L := TList<Integer>.Create;
  try
    Pos_ := 0;
    Seen := False;
    for Line in AColons.Split([#10]) do
    begin
      if Line.StartsWith('pub:') then
      begin
        if Seen then Break;                 { only the first key }
        Seen := True;
      end
      else if Line.StartsWith('sub:') then Break
      else if Line.StartsWith('uid:') then Inc(Pos_)
      else if Line.StartsWith('uat:') then
      begin
        Inc(Pos_);
        L.Add(Pos_);
      end;
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function TGpgEngine.AddPhotoId(const AFingerprint, AJpegFile: string; const APassphrase: TBytes): TCryptoResult;
var
  O, E, EditOut, EditErr: string;
  Code: Integer;
  Before, After: TArray<Integer>;
  Input, Prefix, Mid, Suffix: TBytes;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not FileExists(AJpegFile) then
  begin
    Result.Error := 'The picture file was not found';
    Exit;
  end;
  if (Pos(#10, AJpegFile) > 0) or (Pos(#13, AJpegFile) > 0) then
  begin
    Result.Error := 'The file name is not valid';
    Exit;
  end;
  RunText(['--list-keys', '--with-colons', AFingerprint], O, E);
  Before := PhotoPositions(O);
  Prefix := TEncoding.UTF8.GetBytes('addphoto' + #10 + AJpegFile + #10);
  Suffix := TEncoding.ASCII.GetBytes(#10 + 'save' + #10);
  Input := Prefix + APassphrase + Suffix;
  try
    if not Run(['--yes', '--pinentry-mode', 'loopback', '--command-fd', '0', '--status-fd', '1',
      '--edit-key', AFingerprint], Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
  finally
    WipeBytes(Input);
  end;
  EditOut := O;
  EditErr := E;
  RunText(['--list-keys', '--with-colons', AFingerprint], O, E);
  After := PhotoPositions(O);
  if Length(After) = Length(Before) + 1 then
    Result.Ok := True
  else
  begin
    Result.WrongPassphrase := ContainsText(EditErr, 'Bad passphrase') or ContainsText(EditOut, 'BAD_PASSPHRASE') or
      ContainsText(EditErr, 'bad passphrase');
    Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', 'The photo was not added');
  end;
  SetLength(Mid, 0);
end;

function TGpgEngine.RemovePhotoId(const AFingerprint: string; APhotoNumber: Integer): TCryptoResult;
var
  O, E: string;
  Code: Integer;
  Before, After: TArray<Integer>;
  Input: TBytes;
begin
  FillChar(Result, SizeOf(Result), 0);
  RunText(['--list-keys', '--with-colons', AFingerprint], O, E);
  Before := PhotoPositions(O);
  if (APhotoNumber < 0) or (APhotoNumber > High(Before)) then
  begin
    Result.Error := 'This key has no such photo';
    Exit;
  end;
  Input := TEncoding.ASCII.GetBytes('uid ' + IntToStr(Before[APhotoNumber]) + #10 + 'deluid' + #10 + 'y' + #10 +
    'save' + #10);
  if not Run(['--yes', '--pinentry-mode', 'loopback', '--command-fd', '0', '--status-fd', '1',
    '--edit-key', AFingerprint], Input, O, E, Code) then
  begin
    Result.Error := 'Could not start gpg';
    Exit;
  end;
  RunText(['--list-keys', '--with-colons', AFingerprint], O, E);
  After := PhotoPositions(O);
  if Length(After) = Length(Before) - 1 then
    Result.Ok := True
  else
    Result.Error := 'The photo was not removed';
end;

{ Number of user IDs (names and photos) that gpg will have to re-sign: it asks for the passphrase once for each. }
function SignableUserIdCount(const AColons: string): Integer;
var
  Line: string;
  F: TArray<string>;
  Seen: Boolean;
begin
  Result := 0;
  Seen := False;
  for Line in AColons.Split([#10]) do
  begin
    if Line.StartsWith('pub:') then
    begin
      if Seen then Break;
      Seen := True;
    end
    else if Line.StartsWith('sub:') then Break
    else if Line.StartsWith('uid:') or Line.StartsWith('uat:') then
    begin
      F := Line.Split([':']);
      if (Length(F) > 1) and (F[1] <> 'r') then
        Inc(Result);
    end;
  end;
end;

function JoinWords(const AItems: TArray<string>): string;
var
  S: string;
begin
  Result := '';
  for S in AItems do
    if Trim(S) <> '' then
      Result := Result + IfThen(Result = '', '', ' ') + Trim(S);
end;

function TGpgEngine.SetKeyPreferences(const AFingerprint: string; const ACiphers, AHashes, ACompression: TArray<string>;
  const AKeyserver: string; const APassphrase: TBytes): TCryptoResult;
var
  O, E, Cmd: string;
  Code, N, I: Integer;
  Input, Chunk: TBytes;
  Pass: TBytes;
  Before, After: TArray<TBytes>;
  PrefsBefore, PrefsAfter: TKeyPrefs;
begin
  FillChar(Result, SizeOf(Result), 0);
  Cmd := JoinWords(ACiphers) + ' ' + JoinWords(AHashes) + ' ' + JoinWords(ACompression);
  if Trim(JoinWords(ACiphers)) = '' then
  begin
    Result.Error := 'Keep at least one cipher';
    Exit;
  end;
  if Pos('"', Cmd + AKeyserver) + Pos(#10, Cmd + AKeyserver) + Pos(#13, Cmd + AKeyserver) > 0 then
  begin
    Result.Error := 'The preferences contain a character that is not allowed';
    Exit;
  end;
  RunText(['--list-keys', '--with-colons', AFingerprint], O, E);
  N := SignableUserIdCount(O);
  if N < 1 then
  begin
    Result.Error := 'This key has no user ID that can be updated';
    Exit;
  end;
  ReadKeyExtras(AFingerprint, Before, PrefsBefore);
  Pass := PassInput(APassphrase);          { passphrase + LF }
  Input := TEncoding.UTF8.GetBytes('setpref ' + Trim(Cmd) + ' MDC' + #10 + 'y' + #10);
  try
    for I := 1 to N do
      Input := Input + Pass;
    if AKeyserver <> '' then
    begin
      Chunk := TEncoding.UTF8.GetBytes('keyserver' + #10 + AKeyserver + #10);
      Input := Input + Chunk;
      for I := 1 to N do
        Input := Input + Pass;
    end;
    Input := Input + TEncoding.ASCII.GetBytes('save' + #10);
    if not Run(['--yes', '--pinentry-mode', 'loopback', '--command-fd', '0', '--status-fd', '1',
      '--edit-key', AFingerprint], Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
  finally
    WipeBytes(Input);
    WipeBytes(Pass);
  end;
  ReadKeyExtras(AFingerprint, After, PrefsAfter);
  if PrefsAfter.Valid and ((PrefsAfter.Cipher <> PrefsBefore.Cipher) or (PrefsAfter.Hash <> PrefsBefore.Hash) or
     (PrefsAfter.Compression <> PrefsBefore.Compression) or (PrefsAfter.Keyserver <> PrefsBefore.Keyserver)) then
    Result.Ok := True
  else if (PrefsAfter.Cipher = PrefsBefore.Cipher) and (PrefsAfter.Hash = PrefsBefore.Hash) and
          (PrefsAfter.Compression = PrefsBefore.Compression) and (PrefsAfter.Keyserver = PrefsBefore.Keyserver) and
          not (ContainsText(E, 'Bad passphrase') or ContainsText(O, 'BAD_PASSPHRASE')) then
    Result.Ok := True                        { nothing needed to change }
  else
  begin
    Result.WrongPassphrase := ContainsText(E, 'Bad passphrase') or ContainsText(O, 'BAD_PASSPHRASE');
    Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', 'The preferences were not changed');
  end;
end;

{ gpg starts gpg-agent (and scdaemon) in the background and leaves them running; stop them for this keyring. }
procedure TGpgEngine.StopAgent;
var
  O, E: string;
begin
  RunGpgconf(['--kill', 'all'], O, E);
end;

function TGpgEngine.EngineName: string;
begin
  Result := 'GnuPG (gpg.exe)';
end;

function TGpgEngine.HomeDir: string;
begin
  Result := FHome;
end;

function QuoteArg(const S: string): string;
begin
  if (S <> '') and (S.IndexOfAny([' ', #9, '"']) < 0) then
    Exit(S);
  Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"';
end;

function TGpgEngine.Run(const AArgs: array of string; const AStdIn: TBytes;
  out AOut, AErr: string; out AExit: Integer): Boolean;
var
  SA: TSecurityAttributes;
  InR, InW, OutR, OutW, ErrR, ErrW: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  A: string;
  OutB, ErrB: TBytes;
  Buf: array[0..8191] of Byte;
  Avail, Got, Written: DWORD;
  Code: DWORD;
  Alive: Boolean;

  procedure Drain(AHandle: THandle; var ADest: TBytes);
  begin
    while PeekNamedPipe(AHandle, nil, 0, nil, @Avail, nil) and (Avail > 0) do
    begin
      if not ReadFile(AHandle, Buf, SizeOf(Buf), Got, nil) or (Got = 0) then
        Break;
      SetLength(ADest, Length(ADest) + Integer(Got));
      Move(Buf, ADest[Length(ADest) - Integer(Got)], Got);
    end;
  end;

begin
  AOut := '';
  AErr := '';
  AExit := -1;
  Result := False;
  if FExe = '' then
    Exit;
  CmdLine := QuoteArg(FExe) + ' --homedir ' + QuoteArg(FHome);
  if not SameText(ExtractFileName(FExe), 'gpgconf.exe') then
    CmdLine := CmdLine + ' --no-tty --batch';
  for A in AArgs do
    CmdLine := CmdLine + ' ' + QuoteArg(A);

  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(InR, InW, @SA, 0) then Exit;
  if not CreatePipe(OutR, OutW, @SA, 0) then Exit;
  if not CreatePipe(ErrR, ErrW, @SA, 0) then Exit;
  SetHandleInformation(InW, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(OutR, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(ErrR, HANDLE_FLAG_INHERIT, 0);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := InR;
  SI.hStdOutput := OutW;
  SI.hStdError := ErrW;
  UniqueString(CmdLine);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT, nil, nil, SI, PI) then
  begin
    CloseHandle(InR); CloseHandle(InW); CloseHandle(OutR); CloseHandle(OutW);
    CloseHandle(ErrR); CloseHandle(ErrW);
    Exit;
  end;
  CloseHandle(InR);
  CloseHandle(OutW);
  CloseHandle(ErrW);
  try
    if Length(AStdIn) > 0 then
      WriteFile(InW, AStdIn[0], Length(AStdIn), Written, nil);
    CloseHandle(InW);
    repeat
      Drain(OutR, OutB);
      Drain(ErrR, ErrB);
      Alive := WaitForSingleObject(PI.hProcess, 20) = WAIT_TIMEOUT;
    until not Alive;
    Drain(OutR, OutB);
    Drain(ErrR, ErrB);
    GetExitCodeProcess(PI.hProcess, Code);
    AExit := Integer(Code);
    AOut := TEncoding.UTF8.GetString(OutB);
    AErr := TEncoding.UTF8.GetString(ErrB);
    Result := True;
  finally
    CloseHandle(PI.hProcess);
    CloseHandle(PI.hThread);
    CloseHandle(OutR);
    CloseHandle(ErrR);
  end;
end;

function TGpgEngine.RunText(const AArgs: array of string; out AOut, AErr: string): Integer;
begin
  if not Run(AArgs, nil, AOut, AErr, Result) then
    Result := -1;
end;

function TGpgEngine.Available(out Info: string): Boolean;
var
  O, E: string;
begin
  Result := False;
  Info := 'gpg.exe not found';
  if FExe = '' then
    Exit;
  if RunText(['--version'], O, E) = 0 then
  begin
    FVersion := Trim(Copy(O, 1, Pos(#10, O) - 1));
    Info := FVersion + ' (' + FExe + ')';
    Result := True;
  end;
end;

function TGpgEngine.ParseColons(const AText: string): TKeyInfoArray;
var
  Lines: TArray<string>;
  Line: string;
  F: TArray<string>;
  Rec: string;
  Key: TKeyInfo;
  Sub: TSubKeyInfo;
  U: TUserIdInfo;
  Have: Boolean;
  Context: Integer;  { 0 none, 1 primary, 2 sub }
  KeyList: TList<TKeyInfo>;
  Subs: TList<TSubKeyInfo>;
  Uids: TList<TUserIdInfo>;

  procedure Flush;
  begin
    if Have then
    begin
      Key.SubKeys := Subs.ToArray;
      Key.UserIds := Uids.ToArray;
      KeyList.Add(Key);
    end;
    Have := False;
    Subs.Clear;
    Uids.Clear;
  end;

begin
  KeyList := TList<TKeyInfo>.Create;
  Subs := TList<TSubKeyInfo>.Create;
  Uids := TList<TUserIdInfo>.Create;
  try
    Have := False;
    Context := 0;
    Lines := AText.Split([#10]);
    for Line in Lines do
    begin
      if Line = '' then Continue;
      F := TrimRight(Line).Split([':']);
      Rec := F[0];
      if (Rec = 'pub') or (Rec = 'sec') then
      begin
        Flush;
        FillChar(Key, SizeOf(Key), 0);
        Key.UserIds := nil;
        Key.SubKeys := nil;
        Key.Validity := IfThen(Field(F, 1) = '', '-', Field(F, 1))[1];
        Key.Bits := StrToIntDef(Field(F, 2), 0);
        Key.Algo := StrToIntDef(Field(F, 3), 0);
        Key.KeyId := Field(F, 4);
        Key.Created := EpochToDateTime(Field(F, 5));
        Key.Expires := EpochToDateTime(Field(F, 6));
        Key.OwnerTrust := IfThen(Field(F, 8) = '', '-', Field(F, 8))[1];
        Key.Caps := Field(F, 11);
        Key.HasSecret := Rec = 'sec';
        Key.Revoked := Key.Validity = 'r';
        Key.Expired := Key.Validity = 'e';
        Key.Disabled := Pos('D', Key.Caps) > 0;
        Have := True;
        Context := 1;
      end
      else if (Rec = 'sub') or (Rec = 'ssb') then
      begin
        FillChar(Sub, SizeOf(Sub), 0);
        Sub.Bits := StrToIntDef(Field(F, 2), 0);
        Sub.Algo := StrToIntDef(Field(F, 3), 0);
        Sub.KeyId := Field(F, 4);
        Sub.Created := EpochToDateTime(Field(F, 5));
        Sub.Expires := EpochToDateTime(Field(F, 6));
        Sub.Caps := Field(F, 11);
        Sub.Revoked := Field(F, 1) = 'r';
        Sub.Expired := Field(F, 1) = 'e';
        Subs.Add(Sub);
        Context := 2;
      end
      else if (Rec = 'fpr') and Have then
      begin
        if Context = 1 then
          Key.Fingerprint := Field(F, 9)
        else if (Context = 2) and (Subs.Count > 0) then
        begin
          Sub := Subs[Subs.Count - 1];
          Sub.Fingerprint := Field(F, 9);
          Subs[Subs.Count - 1] := Sub;
        end;
      end
      else if ((Rec = 'uid') or (Rec = 'uat')) and Have then
      begin
        FillChar(U, SizeOf(U), 0);
        U.Validity := IfThen(Field(F, 1) = '', '-', Field(F, 1))[1];
        U.Revoked := U.Validity = 'r';
        U.IsPhoto := Rec = 'uat';
        if U.IsPhoto then
          U.UserId := '(photo ID)'
        else
        begin
          U.UserId := UnescapeColon(Field(F, 9));
          SplitUserId(U.UserId, U.Name, U.Email);
        end;
        Uids.Add(U);
      end;
    end;
    Flush;
    Result := KeyList.ToArray;
  finally
    KeyList.Free;
    Subs.Free;
    Uids.Free;
  end;
end;

procedure TGpgEngine.MarkSecrets(var AKeys: TKeyInfoArray);
var
  O, E, Line: string;
  F: TArray<string>;
  Secret: TStringList;
  I: Integer;
begin
  RunText(['--list-secret-keys', '--with-colons', '--fixed-list-mode'], O, E);
  Secret := TStringList.Create;
  try
    Secret.CaseSensitive := False;
    for Line in O.Split([#10]) do
    begin
      F := Line.Split([':']);
      if (Length(F) > 4) and (F[0] = 'sec') then
        Secret.Add(F[4]);
    end;
    for I := 0 to High(AKeys) do
      AKeys[I].HasSecret := Secret.IndexOf(AKeys[I].KeyId) >= 0;
  finally
    Secret.Free;
  end;
end;

function TGpgEngine.ListKeys: TKeyInfoArray;
var
  O, E: string;
  Started: Boolean;
  ExitCode, ExitCode2: Integer;
  O2, E2: string;
begin
  RunText(['--list-keys', '--with-colons', '--fixed-list-mode', '--with-fingerprint'], O, E);
  Result := ParseColons(O);
  if Length(Result) = 0 then
  begin
    { a keyring that is momentarily locked by another gpg process looks empty: retry once }
    Sleep(400);
    Started := Run(['--list-keys', '--with-colons', '--fixed-list-mode', '--with-fingerprint'],
      nil, O, E, ExitCode);
    Result := ParseColons(O);
    if Length(Result) = 0 then
    begin
      { second look with verbose output: shows which keyring gpg really opens }
      Run(['--verbose', '--list-keys', '--with-colons'], nil, O2, E2, ExitCode2);
      FListError := Format('gpg started: %s, exit code: %d, stdout: %d chars, stderr: "%s"' + #13#10 +
        'exe: %s' + #13#10 + 'home: %s (exists: %s, pubring.kbx: %s)',
        [BoolToStr(Started, True), ExitCode, Length(O), Copy(Trim(E), 1, 300), FExe, FHome,
         BoolToStr(DirectoryExists(FHome), True),
         BoolToStr(FileExists(IncludeTrailingPathDelimiter(FHome) + 'pubring.kbx'), True)]) +
        #13#10 + 'verbose: ' + Copy(StringReplace(Trim(E2), #10, ' | ', [rfReplaceAll]), 1, 700) +
        #13#10 + 'stdout: ' + Copy(StringReplace(Trim(O2), #10, ' | ', [rfReplaceAll]), 1, 120);
    end;
  end;
  MarkSecrets(Result);
end;

function TGpgEngine.LastListError: string;
begin
  Result := FListError;
end;

function TGpgEngine.PreviewFile(const AFileName: string): TKeyInfoArray;
var
  O, E: string;
begin
  RunText(['--show-keys', '--with-colons', '--fixed-list-mode', '--with-fingerprint',
    AFileName], O, E);
  Result := ParseColons(O);
end;

function TGpgEngine.HasUnsupportedKey(const AFileName: string): Boolean;
var
  O, E: string;
  Code: Integer;
begin
  Result := False;
  if Run(['--list-packets', AFileName], nil, O, E, Code) then
    Result := ContainsText(O, 'unknown algorithm') or ContainsText(E, 'unsupported public-key algorithm');
end;

function TGpgEngine.ImportFile(const AFileName: string; const APassphrase: TBytes): TImportReport;
var
  Input: TBytes;
  ExitCode: Integer;
  O, E, Line, Tail, Id: string;
  F: TArray<string>;
  Items: TList<TImportItem>;
  Notes: TList<string>;
  It: TImportItem;
  Flags, Idx, I: Integer;
  Msgs: TStringList;  { "KEYID=message" }
  Names: TStringList; { "KEYID=user id" from IMPORTED }

  function Find(const AFpr: string): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    for K := 0 to Items.Count - 1 do
      if SameText(Items[K].Fingerprint, AFpr) then
        Exit(K);
  end;

  function ReasonFor(const AKeyId: string): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to Msgs.Count - 1 do
      if SameText(Msgs.Names[K], AKeyId) then
        Result := Result + IfThen(Result = '', '', '; ') + Msgs.ValueFromIndex[K];
  end;

begin
  Items := TList<TImportItem>.Create;
  Notes := TList<string>.Create;
  Msgs := TStringList.Create;
  Names := TStringList.Create;
  try
    { loopback pinentry: gpg-agent takes the passphrase from stdin instead of a GUI }
    SetLength(Input, Length(APassphrase) + 1);
    if Length(APassphrase) > 0 then
      Move(APassphrase[0], Input[0], Length(APassphrase));
    Input[High(Input)] := 10;
    try
      Run(['--status-fd', '1', '--allow-weak-key-signatures', '--pinentry-mode', 'loopback',
        '--passphrase-fd', '0', '--import', AFileName], Input, O, E, ExitCode);
    finally
      WipeBytes(Input);
    end;
    for Line in O.Split([#10]) do
    begin
      if not Line.StartsWith('[GNUPG:] ') then Continue;
      F := Copy(Line, 10, MaxInt).TrimRight.Split([' ']);
      if Length(F) = 0 then Continue;
      if (F[0] = 'IMPORT_OK') and (Length(F) >= 3) then
      begin
        Flags := StrToIntDef(F[1], 0);
        Idx := Find(F[2]);
        if Idx < 0 then
        begin
          FillChar(It, SizeOf(It), 0);
          It.Fingerprint := F[2];
          It.KeyId := Copy(F[2], Length(F[2]) - 15, 16);
          It.Outcome := ioUnchanged;
          Idx := Items.Count;
          Items.Add(It);
        end;
        It := Items[Idx];
        if Flags and 16 <> 0 then
          It.SecretImported := True;
        if Flags and 1 <> 0 then
          It.Outcome := ioNew
        else if (Flags and 14 <> 0) and (It.Outcome <> ioNew) then
          It.Outcome := ioUpdated;
        Items[Idx] := It;
      end
      else if (F[0] = 'IMPORTED') and (Length(F) >= 2) then
      begin
        Tail := '';
        for I := 2 to High(F) do
          Tail := Tail + IfThen(Tail = '', '', ' ') + F[I];
        Names.Add(F[1] + '=' + Tail);
      end
      else if (F[0] = 'IMPORT_PROBLEM') and (Length(F) >= 3) then
      begin
        Idx := Find(F[2]);
        if Idx < 0 then
        begin
          FillChar(It, SizeOf(It), 0);
          It.Fingerprint := F[2];
          It.KeyId := Copy(F[2], Length(F[2]) - 15, 16);
          Idx := Items.Count;
          Items.Add(It);
        end;
        It := Items[Idx];
        It.Outcome := ioFailed;
        case StrToIntDef(F[1], 0) of
          1: It.Detail := 'invalid certificate';
          2: It.Detail := 'issuer certificate missing';
          4: It.Detail := 'error storing certificate';
        else
          It.Detail := 'problem reported by gpg';
        end;
        Items[Idx] := It;
      end;
    end;

    { Human-readable stderr lines: "gpg: key XXXXXXXXXXXXXXXX: message" }
    for Line in E.Split([#10]) do
    begin
      Tail := Trim(Line);
      if Tail = '' then Continue;
      if Tail.StartsWith('gpg: key ') then
      begin
        Id := Copy(Tail, 10, 16);
        Tail := Trim(Copy(Tail, 28, MaxInt));
        if not (ContainsText(Tail, 'imported') or ContainsText(Tail, 'not changed')) then
          Msgs.Add(Id + '=' + Tail);
      end
      else if not (Tail.StartsWith('gpg: Total') or Tail.StartsWith('gpg:  ') or
        Tail.StartsWith('gpg: keybox') or Tail.StartsWith('gpg: trustdb') or
        ContainsText(Tail, 'secret keys') or ContainsText(Tail, 'imported:') or
        ContainsText(Tail, 'unchanged:') or ContainsText(Tail, 'processed') or ContainsText(Tail, 'ultimately trusted')) then
        Notes.Add(Tail);
    end;

    for I := 0 to Items.Count - 1 do
    begin
      It := Items[I];
      if (It.UserId = '') and (Names.IndexOfName(It.KeyId) >= 0) then
        It.UserId := Names.Values[It.KeyId];
      if It.SecretImported then
      begin
        { your own private keys are ultimately trusted (shown as "Implicit") }
        Input := TEncoding.ASCII.GetBytes(It.Fingerprint + ':6:' + #10);
        Run(['--import-ownertrust'], Input, O, E, ExitCode);
      end;
      Tail := ReasonFor(It.KeyId);
      case It.Outcome of
        ioNew: if It.Detail = '' then
          It.Detail := IfThen(It.SecretImported, 'New key pair imported', 'New public key imported');
        ioUpdated: if It.Detail = '' then It.Detail := 'Existing key updated (new user IDs, signatures or subkeys)';
        ioUnchanged: if It.Detail = '' then It.Detail := 'Already in the keyring, nothing new';
      end;
      if Tail <> '' then
        It.Detail := IfThen(It.Detail = '', '', It.Detail + '; ') + Tail;
      Items[I] := It;
    end;
    Result.Items := Items.ToArray;
    Result.Notes := Notes.ToArray;
  finally
    Items.Free;
    Notes.Free;
    Msgs.Free;
    Names.Free;
  end;
end;

function TGpgEngine.CheckPassphrase(const AFingerprint: string;
  const APassphrase: TBytes; out AReason: string): Boolean;
var
  Probe, OutFile, O, E: string;
  Input: TBytes;
  Code: Integer;
  S: TStringStream;
begin
  Result := False;
  AReason := '';
  Probe := IncludeTrailingPathDelimiter(FHome) + 'probe.tmp';
  OutFile := IncludeTrailingPathDelimiter(FHome) + 'probe.sig';
  S := TStringStream.Create('passphrase check');
  try
    S.SaveToFile(Probe);
  finally
    S.Free;
  end;
  System.SysUtils.DeleteFile(OutFile);
  { stdin = passphrase + LF }
  SetLength(Input, Length(APassphrase) + 1);
  if Length(APassphrase) > 0 then
    Move(APassphrase[0], Input[0], Length(APassphrase));
  Input[High(Input)] := 10;
  try
    if not Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--yes',
      '-u', AFingerprint + '!', '--detach-sign', '-o', OutFile, Probe],
      Input, O, E, Code) then
    begin
      AReason := 'could not start gpg';
      Exit;
    end;
    Result := (Code = 0) and FileExists(OutFile);
    if not Result then
    begin
      if ContainsText(E, 'bad passphrase') or ContainsText(E, 'decryption failed') then
        AReason := 'wrong passphrase'
      else if ContainsText(E, 'unsupported') or ContainsText(E, 'Unknown cipher') then
        AReason := 'unsupported key protection algorithm'
      else if ContainsText(E, 'No secret key') then
        AReason := 'no usable secret key'
      else
        AReason := 'check failed';
    end;
  finally
    WipeBytes(Input);
    System.SysUtils.DeleteFile(Probe);
    System.SysUtils.DeleteFile(OutFile);
  end;
end;

{ ---- text operations -------------------------------------------------------- }

procedure SecureDeleteFile(const AFile: string);
var
  Zero: TBytes;
  FS: TFileStream;
  Size: Int64;
begin
  if not FileExists(AFile) then Exit;
  try
    FS := TFileStream.Create(AFile, fmOpenReadWrite or fmShareExclusive);
    try
      Size := FS.Size;
      SetLength(Zero, 4096);
      while Size > 0 do
      begin
        FS.WriteBuffer(Zero[0], Min(Size, Length(Zero)));
        Dec(Size, Min(Size, Length(Zero)));
      end;
    finally
      FS.Free;
    end;
  except
  end;
  System.SysUtils.DeleteFile(AFile);
end;

function ReadAllBytes(const AFile: string): TBytes;
var
  FS: TFileStream;
begin
  Result := nil;
  if not FileExists(AFile) then Exit;
  FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if Length(Result) > 0 then
      FS.ReadBuffer(Result[0], Length(Result));
  finally
    FS.Free;
  end;
end;

procedure WriteAllBytes(const AFile: string; const ABytes: TBytes);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(AFile, fmCreate);
  try
    if Length(ABytes) > 0 then
      FS.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    FS.Free;
  end;
end;

{ Fills sig/decryption info from gpg --status-fd lines. }
procedure ParseCryptoStatus(const AErr: string; var R: TCryptoResult);
var
  Line, Rest: string;
  F: TArray<string>;
  I: Integer;
  Secs: Int64;
begin
  R.Sig := ssNone;
  for Line in AErr.Split([#10]) do
  begin
    if not Line.StartsWith('[GNUPG:] ') then Continue;
    Rest := TrimRight(Copy(Line, 10, MaxInt));
    F := Rest.Split([' ']);
    if Length(F) = 0 then Continue;
    if (F[0] = 'GOODSIG') or (F[0] = 'EXPKEYSIG') or (F[0] = 'BADSIG') then
    begin
      if F[0] = 'GOODSIG' then R.Sig := ssGood
      else if F[0] = 'EXPKEYSIG' then R.Sig := ssExpired
      else R.Sig := ssBad;
      R.SignedBy := '';
      for I := 2 to High(F) do
        R.SignedBy := R.SignedBy + IfThen(R.SignedBy = '', '', ' ') + F[I];
      if R.SignedBy = '' then R.SignedBy := F[1];
    end
    else if (F[0] = 'ERRSIG') and (Length(F) > 1) then
    begin
      R.Sig := ssNoKey;
      R.SignedBy := 'unknown key 0x' + Copy(F[1], Length(F[1]) - 7, 8);
      R.SignerKeyId := F[1];
      if (Length(F) > 5) and TryStrToInt64(F[5], Secs) then
        R.SignedOn := UnixToDateTime(Secs, False);
    end
    else if (F[0] = 'VALIDSIG') and (Length(F) > 3) then
    begin
      R.SignerKeyId := Copy(F[1], Length(F[1]) - 15, 16);
      if TryStrToInt64(F[3], Secs) then
        R.SignedOn := UnixToDateTime(Secs, False);
    end
    else if F[0] = 'BAD_PASSPHRASE' then
      R.WrongPassphrase := True;
  end;
end;

function GpgReason(const AErr: string): string;
var
  Line, T: string;
begin
  Result := '';
  for Line in AErr.Split([#10]) do
  begin
    T := Trim(Line);
    if T.StartsWith('gpg: ') and not T.StartsWith('gpg-agent') and
       not ContainsText(T, 'WARNING') and not ContainsText(T, 'encrypted with') and
       not ContainsText(T, 'Signature made') and not ContainsText(T, 'using ') then
      Result := Copy(T, 6, MaxInt);
  end;
  if Result = '' then Result := 'gpg reported an error';
end;

function MakeWorkDir(const AHome: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AHome) + 'tmp-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '');
  ForceDirectories(Result);
end;

procedure RemoveWorkDir(const ADir: string; const AFiles: array of string);
var
  F: string;
begin
  for F in AFiles do
    SecureDeleteFile(F);
  RemoveDir(ADir);
end;

function PassInput(const APass: TBytes): TBytes;
begin
  SetLength(Result, Length(APass) + 1);
  if Length(APass) > 0 then
    Move(APass[0], Result[0], Length(APass));
  Result[High(Result)] := 10;
end;

procedure TGpgEngine.SetArmorHeaders(const AVersion, AComment: string);
var
  C: string;
begin
  C := Trim(AComment.Replace(#13#10, ' ').Replace(#13, ' ').Replace(#10, ' '));
  if Length(C) > 200 then
    C := Copy(C, 1, 200);
  FArmorVersion := Trim(AVersion.Replace(#13, ' ').Replace(#10, ' '));
  FArmorComment := C;
end;

{ Puts the Version / Comment lines under each "-----BEGIN PGP ...-----" line of armored data.  The headers are not
  part of what is signed or encrypted.  The line "-----BEGIN PGP SIGNED MESSAGE-----" of a clear-signed text is
  skipped: only a Hash line may follow it there; the signature block at the end gets the lines instead. }
function TGpgEngine.AddArmorHeaders(const AArmor: string): string;
var
  Line: string;
  SB: TStringBuilder;
  First, CrLf: Boolean;
begin
  Result := AArmor;
  if (FArmorVersion = '') and (FArmorComment = '') then Exit;
  CrLf := AArmor.Contains(#13#10);
  SB := TStringBuilder.Create;
  try
    First := True;
    for Line in AArmor.Replace(#13#10, #10).Split([#10]) do
    begin
      if not First then SB.Append(#10);
      First := False;
      SB.Append(Line);
      if Line.StartsWith('-----BEGIN PGP ') and not Line.StartsWith('-----BEGIN PGP SIGNED MESSAGE') then
      begin
        if FArmorVersion <> '' then SB.Append(#10).Append('Version: ').Append(FArmorVersion);
        if FArmorComment <> '' then SB.Append(#10).Append('Comment: ').Append(FArmorComment);
      end;
    end;
    Result := SB.ToString;
    if CrLf then
      Result := Result.Replace(#10, #13#10);
  finally
    SB.Free;
  end;
end;

function TGpgEngine.EncryptText(const AText: string; const ARecipients: TArray<string>;
  const ASigner: string; const APassphrase: TBytes): TCryptoResult;
var
  Dir, InF, OutF, O, E, R: string;
  Args: TList<string>;
  Input: TBytes;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(ARecipients) = 0 then
  begin
    Result.Error := 'No recipients selected';
    Exit;
  end;
  Dir := MakeWorkDir(FHome);
  InF := Dir + '\in.txt';
  OutF := Dir + '\out.asc';
  Args := TList<string>.Create;
  Input := nil;
  try
    WriteAllBytes(InF, TEncoding.UTF8.GetBytes(AText));
    Args.AddRange(['--armor', '--yes', '--trust-model', 'always', '--encrypt']);
    for R in ARecipients do
      Args.AddRange(['-r', R]);
    if ASigner <> '' then
    begin
      Input := PassInput(APassphrase);
      Args.AddRange(['--sign', '-u', ASigner, '--pinentry-mode', 'loopback', '--passphrase-fd', '0']);
    end;
    Args.AddRange(['-o', OutF, InF]);
    if not Run(Args.ToArray, Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
    if (Code = 0) and FileExists(OutF) then
    begin
      Result.Ok := True;
      Result.Text := AddArmorHeaders(TEncoding.UTF8.GetString(ReadAllBytes(OutF)));
    end
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
    Args.Free;
    RemoveWorkDir(Dir, [InF, OutF]);
  end;
end;

function TGpgEngine.SignText(const AText, ASigner: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Dir, InF, OutF, O, E: string;
  Input: TBytes;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Dir := MakeWorkDir(FHome);
  InF := Dir + '\in.txt';
  OutF := Dir + '\out.asc';
  Input := PassInput(APassphrase);
  try
    WriteAllBytes(InF, TEncoding.UTF8.GetBytes(AText));
    if not Run(['--yes', '--clearsign', '-u', ASigner, '--pinentry-mode', 'loopback',
      '--passphrase-fd', '0', '-o', OutF, InF], Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
    if (Code = 0) and FileExists(OutF) then
    begin
      Result.Ok := True;
      Result.Text := AddArmorHeaders(TEncoding.UTF8.GetString(ReadAllBytes(OutF)));
    end
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
    RemoveWorkDir(Dir, [InF, OutF]);
  end;
end;

function TGpgEngine.DecryptText(const AText: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Dir, InF, OutF, O, E: string;
  Input: TBytes;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Dir := MakeWorkDir(FHome);
  InF := Dir + '\in.asc';
  OutF := Dir + '\out.txt';
  Input := PassInput(APassphrase);
  try
    WriteAllBytes(InF, TEncoding.UTF8.GetBytes(AText));
    if not Run(['--yes', '--status-fd', '2', '--pinentry-mode', 'loopback', '--passphrase-fd', '0',
      '-o', OutF, '--decrypt', InF], Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
    ParseCryptoStatus(E, Result);
    if FileExists(OutF) and ((Code = 0) or (Result.Sig <> ssNone)) then
    begin
      Result.Ok := True;
      Result.Text := TEncoding.UTF8.GetString(ReadAllBytes(OutF));
      if (Code <> 0) and (Result.Sig = ssNone) then
        Result.Ok := False;
    end;
    if not Result.Ok then
    begin
      Result.WrongPassphrase := Result.WrongPassphrase or ContainsText(E, 'Bad passphrase') or
        ContainsText(E, 'BAD_PASSPHRASE') or ContainsText(E, 'Bad session key');
      if Result.WrongPassphrase then
        Result.Error := 'Wrong passphrase'
      else if ContainsText(E, 'no valid OpenPGP data') then
        Result.Error := 'The clipboard does not contain an OpenPGP message'
      else if ContainsText(E, 'secret key not available') or ContainsText(E, 'NO_SECKEY') then
        Result.Error := 'None of your private keys can decrypt this message'
      else
        Result.Error := GpgReason(E);
    end;
  finally
    WipeBytes(Input);
    RemoveWorkDir(Dir, [InF, OutF]);
  end;
end;

function TGpgEngine.FileRecipients(const AFileName: string): TArray<string>;
var
  O, E, Line: string;
  Code, P: Integer;
  L: TList<string>;
begin
  L := TList<string>.Create;
  try
    if Run(['--list-packets', '--pinentry-mode', 'cancel', AFileName], nil, O, E, Code) then
      for Line in O.Split([#10]) do
        if Line.StartsWith(':pubkey enc packet:') then
        begin
          P := Pos('keyid ', Line);
          if P > 0 then
            L.Add(Trim(Copy(Line, P + 6, 16)));
        end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function TGpgEngine.MessageRecipients(const AText: string): TArray<string>;
var
  Dir, InF, O, E, Line: string;
  Code, P: Integer;
  L: TList<string>;
begin
  L := TList<string>.Create;
  Dir := MakeWorkDir(FHome);
  InF := Dir + '\in.asc';
  try
    WriteAllBytes(InF, TEncoding.UTF8.GetBytes(AText));
    if Run(['--list-packets', '--pinentry-mode', 'cancel', InF], nil, O, E, Code) then
      for Line in O.Split([#10]) do
        if Line.StartsWith(':pubkey enc packet:') then
        begin
          P := Pos('keyid ', Line);
          if P > 0 then
            L.Add(Trim(Copy(Line, P + 6, 16)));
        end;
    Result := L.ToArray;
  finally
    L.Free;
    RemoveWorkDir(Dir, [InF]);
  end;
end;

function TGpgEngine.EncryptFile(const AInFile, AOutFile: string;
  const ARecipients: TArray<string>): TCryptoResult;
var
  Args: TList<string>;
  R, O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(ARecipients) = 0 then
  begin
    Result.Error := 'No recipients selected';
    Exit;
  end;
  Args := TList<string>.Create;
  try
    Args.AddRange(['--yes', '--trust-model', 'always', '--encrypt']);
    for R in ARecipients do
      Args.AddRange(['-r', R]);
    Args.AddRange(['-o', AOutFile, AInFile]);
    if Run(Args.ToArray, nil, O, E, Code) and (Code = 0) and FileExists(AOutFile) then
      Result.Ok := True
    else
      Result.Error := GpgReason(E);
  finally
    Args.Free;
  end;
end;

function TGpgEngine.DecryptFile(const AInFile, AOutFile: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Input: TBytes;
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Input := PassInput(APassphrase);
  try
    if Run(['--yes', '--pinentry-mode', 'loopback', '--passphrase-fd', '0',
      '-o', AOutFile, '--decrypt', AInFile], Input, O, E, Code) and (Code = 0) and
      FileExists(AOutFile) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      if Result.WrongPassphrase then
        Result.Error := 'Wrong passphrase'
      else if ContainsText(E, 'secret key not available') then
        Result.Error := 'None of your private keys can open this file'
      else
        Result.Error := GpgReason(E);
      SecureDeleteFile(AOutFile);
    end;
  finally
    WipeBytes(Input);
  end;
end;

function TGpgEngine.EncryptFileAdv(const AInFile, AOutFile, AInnerName: string;
  const ARecipients: TArray<string>; const ASigner: string;
  const ASignerPass, ASymPass: TBytes; ACompress: Boolean): TCryptoResult;
var
  Args: TList<string>;
  R, O, E: string;
  Code: Integer;
  Input: TBytes;
  HaveSym, HaveRecip: Boolean;
  Dir, Step1: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  HaveRecip := Length(ARecipients) > 0;
  HaveSym := Length(ASymPass) > 0;
  if (not (HaveRecip or HaveSym)) and (ASigner <> '') then
  begin
    { sign only: one signed (not encrypted) OpenPGP message that contains the data }
    Args := TList<string>.Create;
    try
      Args.AddRange(['--yes', '--pinentry-mode', 'loopback', '--passphrase-fd', '0']);
      if not ACompress then
        Args.AddRange(['--compress-algo', 'none']);
      if AInnerName <> '' then
        Args.AddRange(['--set-filename', AInnerName]);
      Args.AddRange(['--sign', '-u', ASigner, '-o', AOutFile, AInFile]);
      Input := PassInput(ASignerPass);
      try
        if Run(Args.ToArray, Input, O, E, Code) and (Code = 0) and FileExists(AOutFile) then
          Result.Ok := True
        else
        begin
          Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
          Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
          SecureDeleteFile(AOutFile);
        end;
      finally
        WipeBytes(Input);
      end;
    finally
      Args.Free;
    end;
    Exit;
  end;
  if not (HaveRecip or HaveSym) then
  begin
    Result.Error := 'No recipients or passphrase given';
    Exit;
  end;
  if HaveSym and (ASigner <> '') then
  begin
    if HaveRecip then
    begin
      Result.Error := 'Signing together with both recipients and a passphrase is not supported';
      Exit;
    end;
    { two steps, one encrypted layer: sign into a temporary signed message, then encrypt that message
      with the archive passphrase without wrapping it in another literal packet }
    Dir := MakeWorkDir(FHome);
    Step1 := Dir + '\s1.gpg';
    try
      Args := TList<string>.Create;
      try
        Args.AddRange(['--yes', '--compress-algo', 'none', '--pinentry-mode', 'loopback', '--passphrase-fd', '0']);
        if AInnerName <> '' then
          Args.AddRange(['--set-filename', AInnerName]);
        Args.AddRange(['--sign', '-u', ASigner, '-o', Step1, AInFile]);
        Input := PassInput(ASignerPass);
        try
          if not (Run(Args.ToArray, Input, O, E, Code) and (Code = 0) and FileExists(Step1)) then
          begin
            Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
            Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
            Exit;
          end;
        finally
          WipeBytes(Input);
        end;
        Args.Clear;
        Args.AddRange(['--yes', '--no-literal', '--cipher-algo', 'AES256', '--symmetric', '--pinentry-mode',
          'loopback', '--passphrase-fd', '0']);
        if not ACompress then
          Args.AddRange(['--compress-algo', 'none']);
        Args.AddRange(['-o', AOutFile, Step1]);
        Input := PassInput(ASymPass);
        try
          if Run(Args.ToArray, Input, O, E, Code) and (Code = 0) and FileExists(AOutFile) then
            Result.Ok := True
          else
          begin
            Result.Error := GpgReason(E);
            SecureDeleteFile(AOutFile);
          end;
        finally
          WipeBytes(Input);
        end;
      finally
        Args.Free;
      end;
    finally
      RemoveWorkDir(Dir, [Step1]);       { the temporary signed message holds the data: overwritten and removed }
    end;
    Exit;
  end;
  Args := TList<string>.Create;
  try
    Args.AddRange(['--yes', '--trust-model', 'always', '--cipher-algo', 'AES256']);
    if AInnerName <> '' then
      Args.AddRange(['--set-filename', AInnerName]);
    if not ACompress then
      Args.AddRange(['--compress-algo', 'none']);
    if HaveRecip then
    begin
      Args.Add('--encrypt');
      for R in ARecipients do
        Args.AddRange(['-r', R]);
    end;
    if HaveSym then
      Args.Add('--symmetric');
    if ASigner <> '' then
      Args.AddRange(['--sign', '-u', ASigner]);
    if HaveSym or (ASigner <> '') then
      Args.AddRange(['--pinentry-mode', 'loopback', '--passphrase-fd', '0']);
    Args.AddRange(['-o', AOutFile, AInFile]);
    if HaveSym then
      Input := PassInput(ASymPass)
    else if ASigner <> '' then
      Input := PassInput(ASignerPass)
    else
      Input := nil;
    try
      if Run(Args.ToArray, Input, O, E, Code) and (Code = 0) and FileExists(AOutFile) then
        Result.Ok := True
      else
      begin
        Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
        if Result.WrongPassphrase then
          Result.Error := 'Wrong passphrase'
        else
          Result.Error := GpgReason(E);
        SecureDeleteFile(AOutFile);
      end;
    finally
      WipeBytes(Input);
    end;
  finally
    Args.Free;
  end;
end;

function TGpgEngine.DecryptFileEx(const AInFile, AOutFile: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Input: TBytes;
  O, E, Line: string;
  Code: Integer;
  F: TArray<string>;
begin
  FillChar(Result, SizeOf(Result), 0);
  Input := PassInput(APassphrase);
  try
    if not Run(['--yes', '--status-fd', '2', '--pinentry-mode', 'loopback', '--passphrase-fd', '0',
      '-o', AOutFile, '--decrypt', AInFile], Input, O, E, Code) then
    begin
      Result.Error := 'Could not start gpg';
      Exit;
    end;
    ParseCryptoStatus(E, Result);
    for Line in E.Split([#10]) do
      if Line.StartsWith('[GNUPG:] PLAINTEXT ') then
      begin
        { [GNUPG:] PLAINTEXT <fmt> <timestamp> <name, may contain spaces> }
        F := TrimRight(Line).Split([' '], 5);
        if Length(F) >= 5 then
          Result.Text := F[4];
      end;
    if FileExists(AOutFile) and ((Code = 0) or (Result.Sig <> ssNone)) then
      Result.Ok := (Code = 0) or (Result.Sig <> ssNone);
    if not Result.Ok then
    begin
      Result.WrongPassphrase := Result.WrongPassphrase or ContainsText(E, 'Bad passphrase') or
        ContainsText(E, 'BAD_PASSPHRASE') or ContainsText(E, 'Bad session key');
      if Result.WrongPassphrase then
        Result.Error := 'Wrong passphrase'
      else if ContainsText(E, 'no valid OpenPGP data') then
        Result.Error := 'This file is not an OpenPGP archive'
      else if ContainsText(E, 'secret key not available') or ContainsText(E, 'NO_SECKEY') then
        Result.Error := 'None of your private keys can open this archive'
      else
        Result.Error := GpgReason(E);
      SecureDeleteFile(AOutFile);
    end;
  finally
    WipeBytes(Input);
  end;
end;

{ ---- key management ----------------------------------------------------------- }

function TGpgEngine.ExportPublicKey(const AFingerprint: string): TCryptoResult;
var
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Run(['--armor', '--export', AFingerprint], nil, O, E, Code) and (Code = 0) and
     O.Contains('BEGIN PGP PUBLIC KEY BLOCK') then
  begin
    Result.Ok := True;
    Result.Text := AddArmorHeaders(O);
  end
  else
    Result.Error := IfThen(Trim(E) = '', 'Nothing was exported', GpgReason(E));
end;

function TGpgEngine.DeleteKey(const AFingerprint: string; AIncludingSecret: Boolean): TCryptoResult;
var
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  { secret part first: gpg refuses to delete the public key while a secret key exists }
  if AIncludingSecret then
    if not (Run(['--yes', '--delete-secret-keys', AFingerprint + '!'], nil, O, E, Code) and (Code = 0)) then
      if not Run(['--yes', '--delete-secret-keys', AFingerprint], nil, O, E, Code) or (Code <> 0) then
      begin
        Result.Error := GpgReason(E);
        Exit;
      end;
  if Run(['--yes', '--delete-keys', AFingerprint], nil, O, E, Code) and (Code = 0) then
    Result.Ok := True
  else
    Result.Error := GpgReason(E);
end;

function TGpgEngine.SetOwnerTrust(const AFingerprint: string; ATrust: Char): TCryptoResult;
var
  Level: string;
  Input: TBytes;
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  case ATrust of
    'u': Level := '6';
    'f': Level := '5';
    'm': Level := '4';
    'n': Level := '3';
  else
    Level := '2';  { 2 = unknown/undefined }
  end;
  Input := TEncoding.ASCII.GetBytes(AFingerprint + ':' + Level + ':' + #10);
  if Run(['--import-ownertrust'], Input, O, E, Code) and (Code = 0) then
  begin
    Result.Ok := True;
    { make gpg recompute validity right away }
    Run(['--check-trustdb'], nil, O, E, Code);
  end
  else
    Result.Error := GpgReason(E);
end;

function TGpgEngine.SignKey(const AFingerprint, ASignerFingerprint: string; ALocal: Boolean;
  const APassphrase: TBytes): TCryptoResult;
var
  Input: TBytes;
  O, E, Cmd: string;
  Code: Integer;
  Args: TArray<string>;
  K: TKeyInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  if ALocal then Cmd := '--quick-lsign-key' else Cmd := '--quick-sign-key';
  Args := ['--yes', '--batch', '--pinentry-mode', 'loopback', '--passphrase-fd', '0',
    '--local-user', ASignerFingerprint];
  { an old 1024-bit DSA key only takes hashes of 160-224 bits: gpg would pick SHA-256 and fail with
    "Invalid digest algorithm" (SHA-1 is refused by current gpg, SHA-224 works) }
  for K in ListKeys do
    if SameText(K.Fingerprint, ASignerFingerprint) and (K.Algo = 17) and (K.Bits <= 1024) then
      Args := Args + ['--cert-digest-algo', 'SHA224'];
  Args := Args + [Cmd, AFingerprint];
  Input := PassInput(APassphrase);
  try
    if Run(Args, Input, O, E, Code) and (Code = 0) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase') or ContainsText(E, 'bad passphrase');
      if Result.WrongPassphrase then
        Result.Error := 'Wrong passphrase'
      else
        Result.Error := GpgReason(E);
    end;
  finally
    WipeBytes(Input);
  end;
end;

function TGpgEngine.VerifyDetached(const ASigFile, ADataFile: string): TCryptoResult;
var
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not Run(['--status-fd', '2', '--verify', ASigFile, ADataFile], nil, O, E, Code) then
  begin
    Result.Error := 'Could not start gpg';
    Exit;
  end;
  ParseCryptoStatus(E, Result);
  Result.Ok := Result.Sig in [ssGood, ssExpired];
  if Result.Sig = ssNone then
  begin
    if ContainsText(E, 'no valid OpenPGP data') then
      Result.Error := 'This file is not an OpenPGP signature'
    else
      Result.Error := GpgReason(E);
  end;
end;

function TGpgEngine.SignFile(const AFile, ASignerFingerprint, ASigFile: string; AArmor: Boolean;
  const APassphrase: TBytes): TCryptoResult;
var
  Args: TArray<string>;
  Input: TBytes;
  O, E: string;
  Code: Integer;
  K: TKeyInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  Args := ['--yes', '--batch', '--pinentry-mode', 'loopback', '--passphrase-fd', '0',
    '--local-user', ASignerFingerprint];
  { an old 1024-bit DSA key only takes SHA-224 or smaller (see SignKey) }
  for K in ListKeys do
    if SameText(K.Fingerprint, ASignerFingerprint) and (K.Algo = 17) and (K.Bits <= 1024) then
      Args := Args + ['--digest-algo', 'SHA224'];
  if AArmor then Args := Args + ['--armor'];
  Args := Args + ['--detach-sign', '-o', ASigFile, AFile];
  Input := PassInput(APassphrase);
  try
    if Run(Args, Input, O, E, Code) and (Code = 0) and FileExists(ASigFile) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase') or ContainsText(E, 'bad passphrase');
      if Result.WrongPassphrase then
        Result.Error := 'Wrong passphrase'
      else
        Result.Error := GpgReason(E);
    end;
  finally
    WipeBytes(Input);
  end;
end;

function TGpgEngine.ListCertifications(const AFingerprint: string): TArray<TCertInfo>;
var
  O, E, Line, Uid: string;
  F: TArray<string>;
  L: TList<TCertInfo>;
  C: TCertInfo;
  Secs: Int64;
begin
  L := TList<TCertInfo>.Create;
  try
    if RunText(['--check-sigs', '--with-colons', '--fixed-list-mode', AFingerprint], O, E) = 0 then
    begin
      Uid := '';
      for Line in O.Split([#10]) do
      begin
        F := Line.TrimRight.Split([':']);
        if Length(F) < 11 then Continue;
        if F[0] = 'uid' then
          Uid := UnescapeColon(F[9])
        else if F[0] = 'sub' then
          Uid := ''       { signatures after a subkey are its binding, not a certification of a person }
        else if ((F[0] = 'sig') or (F[0] = 'rev')) and (Uid <> '') then
        begin
          FillChar(C, SizeOf(C), 0);
          C.UserId := Uid;
          C.SignerKeyId := F[4];
          C.Valid := F[1] = '!';
          C.Revoked := F[0] = 'rev';
          if TryStrToInt64(F[5], Secs) then
            C.Created := UnixToDateTime(Secs, False);
          C.SignerName := UnescapeColon(F[9]);
          if ContainsText(C.SignerName, 'User ID not found') then C.SignerName := '';
          C.LocalOnly := (Length(F[10]) > 0) and (F[10][Length(F[10])] = 'l');
          C.Self := EndsText(C.SignerKeyId, AFingerprint);
          L.Add(C);
        end;
      end;
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function TGpgEngine.GenerateKey(const AName, AEmail: string; ABits, AExpireDays: Integer;
  const APassphrase: TBytes): TCryptoResult;
var
  Uid, Fpr, Expire, O, E, Line: string;
  Input: TBytes;
  Code: Integer;
  F: TArray<string>;
begin
  FillChar(Result, SizeOf(Result), 0);
  Uid := Trim(AName);
  if Trim(AEmail) <> '' then
    Uid := Uid + ' <' + Trim(AEmail) + '>';
  if Uid = '' then
  begin
    Result.Error := 'Enter a name or an email address';
    Exit;
  end;
  if AExpireDays > 0 then Expire := IntToStr(AExpireDays) + 'd' else Expire := 'never';
  Input := PassInput(APassphrase);
  try
    { primary key: sign + certify }
    if not Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--quick-generate-key',
      Uid, 'rsa' + IntToStr(ABits), 'sign,cert', Expire], Input, O, E, Code) or (Code <> 0) then
    begin
      Result.Error := GpgReason(E);
      Exit;
    end;
  finally
    WipeBytes(Input);
  end;
  { find the fingerprint of the key we just made (newest key with this user ID) }
  Fpr := '';
  Run(['--list-keys', '--with-colons', '--fixed-list-mode', '--with-fingerprint',
    '--with-fingerprint', '=' + Uid], nil, O, E, Code);
  for Line in O.Split([#10]) do
  begin
    F := Line.Split([':']);
    if (Length(F) > 9) and (F[0] = 'fpr') then
    begin
      Fpr := F[9];
      Break;
    end;
  end;
  if Fpr = '' then
  begin
    Result.Error := 'The key was created but could not be found again';
    Exit;
  end;
  { encryption subkey }
  Input := PassInput(APassphrase);
  try
    if not Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--quick-add-key', Fpr,
      'rsa' + IntToStr(ABits), 'encr', Expire], Input, O, E, Code) or (Code <> 0) then
    begin
      Result.Error := 'The key pair was created but adding the encryption subkey failed: ' + GpgReason(E);
      Exit;
    end;
  finally
    WipeBytes(Input);
  end;
  { your own key: ultimately trusted, like imported private keys }
  SetOwnerTrust(Fpr, 'u');
  Result.Ok := True;
  Result.Text := Fpr;
end;

function TGpgEngine.ChangePassphrase(const AFingerprint: string; const AOld, ANew: TBytes): TCryptoResult;
var
  Input: TBytes;
  Prefix, Suffix: TBytes;
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  { gpg reads --passphrase-fd only once (old and new would be the same), so the key editor is
    driven through its command channel: "passwd", old passphrase, new passphrase, "save". }
  Prefix := TEncoding.ASCII.GetBytes('passwd' + #10);
  Suffix := TEncoding.ASCII.GetBytes('save' + #10);
  SetLength(Input, Length(Prefix) + Length(AOld) + 1 + Length(ANew) + 1 + Length(Suffix));
  Move(Prefix[0], Input[0], Length(Prefix));
  if Length(AOld) > 0 then Move(AOld[0], Input[Length(Prefix)], Length(AOld));
  Input[Length(Prefix) + Length(AOld)] := 10;
  if Length(ANew) > 0 then Move(ANew[0], Input[Length(Prefix) + Length(AOld) + 1], Length(ANew));
  Input[Length(Prefix) + Length(AOld) + 1 + Length(ANew)] := 10;
  Move(Suffix[0], Input[Length(Prefix) + Length(AOld) + 1 + Length(ANew) + 1], Length(Suffix));
  try
    if Run(['--pinentry-mode', 'loopback', '--command-fd', '0', '--status-fd', '1', '--edit-key',
      AFingerprint], Input, O, E, Code) and (Code = 0) and not ContainsText(E, 'error changing passphrase') then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
    WipeBytes(Prefix);
  end;
end;

function TGpgEngine.AddUserId(const AFingerprint, AName, AEmail: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Uid, O, E: string;
  Input: TBytes;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Uid := Trim(AName);
  if Trim(AEmail) <> '' then
    Uid := Trim(Uid + ' <' + Trim(AEmail) + '>');
  if Uid = '' then
  begin
    Result.Error := 'Enter a name or an email address';
    Exit;
  end;
  Input := PassInput(APassphrase);
  try
    if Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--quick-add-uid',
      AFingerprint, Uid], Input, O, E, Code) and (Code = 0) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
  end;
end;

function TGpgEngine.SetPrimaryUserId(const AFingerprint, AUserId: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Input: TBytes;
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Input := PassInput(APassphrase);
  try
    if Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--quick-set-primary-uid',
      AFingerprint, AUserId], Input, O, E, Code) and (Code = 0) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
  end;
end;

function TGpgEngine.RevokeUserId(const AFingerprint, AUserId: string;
  const APassphrase: TBytes): TCryptoResult;
var
  Input: TBytes;
  O, E: string;
  Code: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Input := PassInput(APassphrase);
  try
    if Run(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--quick-revoke-uid',
      AFingerprint, AUserId], Input, O, E, Code) and (Code = 0) then
      Result.Ok := True
    else
    begin
      Result.WrongPassphrase := ContainsText(E, 'Bad passphrase');
      Result.Error := IfThen(Result.WrongPassphrase, 'Wrong passphrase', GpgReason(E));
    end;
  finally
    WipeBytes(Input);
  end;
end;

end.

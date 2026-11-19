unit OPD.PassCache;

{ Passphrase caching, as in the classic PGP tray: after a passphrase has worked once, CryptLok can remember it
  so the next decrypt/sign with the same key does not ask again.

    - Off (the default): ask every time.
    - While logged on: kept until CryptLok exits (it lives in the tray for the whole Windows session), or until
      "Clear Passphrase Cache" in the tray menu.
    - For N minutes: forgotten N minutes after it was entered.

  Only passphrases that GnuPG accepted are kept.  They live in this process only, encrypted in memory with
  CryptProtectMemory (DPAPI, same-process key), and are wiped when they expire or are cleared.  GnuPG's own
  agent cache stays off; key-management actions (change passphrase, photos, preferences, import) always ask. }

interface

uses
  System.SysUtils, System.Classes, OPD.Engine;

type
  TPassCacheMode = (pcOff, pcSession, pcMinutes);

{ policy, stored in settings.ini [Passphrase] }
procedure LoadPassCachePolicy(const AEngine: IKeyEngine);
procedure SavePassCachePolicy(const AEngine: IKeyEngine; AMode: TPassCacheMode; AMinutes: Integer);
function PassCacheMode: TPassCacheMode;
function PassCacheMinutes: Integer;

{ Asks for a key's passphrase unless a cached one is available (then returns mrOk at once).
  AKeyId = the long key ID of your own key ('' = never cached, e.g. a passphrase-only archive). }
function AskPassCached(AOwner: TComponent; const AKeyId, AKeyLabel, AHint: string; out APass: TBytes): Integer;
{ the same with the "encrypted to" list of the decrypt dialog }
function AskPassForCached(AOwner: TComponent; const AKeyId, AKeyLabel, AHint: string;
  const ARecipients: TArray<string>; out APass: TBytes): Integer;

{ Call after the operation, before wiping APass: an accepted passphrase is remembered (when caching is on),
  a rejected one is forgotten so the next attempt asks; any other failure leaves the cache alone. }
procedure NotePassphrase(const AKeyId: string; const APass: TBytes; AAccepted, ARejected: Boolean);

{ The primary key ID of the first of your private keys that a message/file is encrypted to ('' = none). }
function OwnKeyFor(const AKeys: TKeyInfoArray; const ARecipients: TArray<string>): string;
{ long key ID from a fingerprint }
function KeyIdOf(const AFingerprint: string): string;

procedure ForgetPass(const AKeyId: string);
procedure ClearPassCache;
procedure PurgeExpiredPasses;
function CachedPassCount: Integer;

implementation

uses
  Winapi.Windows, System.Math, System.IniFiles, System.DateUtils, System.Generics.Collections, Vcl.Controls,
  OPD.MasterKeys, OPD.PassphraseDialog;

const
  CRYPTPROTECTMEMORY_BLOCK_SIZE = 16;
  CRYPTPROTECTMEMORY_SAME_PROCESS = 0;

function CryptProtectMemory(pDataIn: Pointer; cbDataIn, dwFlags: DWORD): BOOL; stdcall; external 'crypt32.dll';
function CryptUnprotectMemory(pDataIn: Pointer; cbDataIn, dwFlags: DWORD): BOOL; stdcall; external 'crypt32.dll';

type
  TEntry = record
    Data: TBytes;          { protected, padded to the DPAPI block size }
    Len: Integer;
    Expires: TDateTime;    { 0 = until CryptLok exits or the cache is cleared }
  end;

var
  GMode: TPassCacheMode = pcOff;
  GMinutes: Integer = 30;
  GCache: TDictionary<string, TEntry> = nil;

procedure Wipe(var B: TBytes);
begin
  if Length(B) > 0 then
    FillChar(B[0], Length(B), 0);
  B := nil;
end;

function NormId(const AKeyId: string): string;
begin
  Result := UpperCase(Trim(AKeyId));
end;

procedure LoadPassCachePolicy(const AEngine: IKeyEngine);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    GMode := TPassCacheMode(EnsureRange(Ini.ReadInteger('Passphrase', 'CacheMode', 0), 0, 2));
    GMinutes := EnsureRange(Ini.ReadInteger('Passphrase', 'CacheMinutes', 30), 1, 24 * 60);
  finally
    Ini.Free;
  end;
  if GMode = pcOff then
    ClearPassCache;
end;

procedure SavePassCachePolicy(const AEngine: IKeyEngine; AMode: TPassCacheMode; AMinutes: Integer);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Ini.WriteInteger('Passphrase', 'CacheMode', Ord(AMode));
    Ini.WriteInteger('Passphrase', 'CacheMinutes', AMinutes);
  finally
    Ini.Free;
  end;
  { a stricter policy applies to what is already cached: off clears, a shorter time shortens }
  if (AMode = pcOff) or (AMode <> GMode) or (AMinutes < GMinutes) then
    ClearPassCache;
  GMode := AMode;
  GMinutes := AMinutes;
end;

function PassCacheMode: TPassCacheMode;
begin
  Result := GMode;
end;

function PassCacheMinutes: Integer;
begin
  Result := GMinutes;
end;

procedure DropEntry(const AId: string);
var
  E: TEntry;
begin
  if (GCache <> nil) and GCache.TryGetValue(AId, E) then
  begin
    Wipe(E.Data);
    GCache.Remove(AId);
  end;
end;

function GetCached(const AKeyId: string; out APass: TBytes): Boolean;
var
  E: TEntry;
  Buf: TBytes;
  Id: string;
begin
  Result := False;
  APass := nil;
  Id := NormId(AKeyId);
  if (Id = '') or (GMode = pcOff) or (GCache = nil) or not GCache.TryGetValue(Id, E) then Exit;
  if (E.Expires <> 0) and (Now >= E.Expires) then
  begin
    DropEntry(Id);
    Exit;
  end;
  Buf := Copy(E.Data);
  if not CryptUnprotectMemory(@Buf[0], Length(Buf), CRYPTPROTECTMEMORY_SAME_PROCESS) then
  begin
    Wipe(Buf);
    DropEntry(Id);
    Exit;
  end;
  APass := Copy(Buf, 0, E.Len);
  Wipe(Buf);
  Result := True;
end;

procedure Remember(const AKeyId: string; const APass: TBytes);
var
  E: TEntry;
  Id: string;
begin
  Id := NormId(AKeyId);
  if (Id = '') or (GMode = pcOff) or (Length(APass) = 0) then Exit;
  if GCache = nil then
    GCache := TDictionary<string, TEntry>.Create;
  DropEntry(Id);
  E.Len := Length(APass);
  SetLength(E.Data, ((E.Len + CRYPTPROTECTMEMORY_BLOCK_SIZE - 1) div CRYPTPROTECTMEMORY_BLOCK_SIZE) *
    CRYPTPROTECTMEMORY_BLOCK_SIZE);
  FillChar(E.Data[0], Length(E.Data), 0);
  Move(APass[0], E.Data[0], E.Len);
  if not CryptProtectMemory(@E.Data[0], Length(E.Data), CRYPTPROTECTMEMORY_SAME_PROCESS) then
  begin
    Wipe(E.Data);            { never keep it unprotected }
    Exit;
  end;
  if GMode = pcMinutes then
    E.Expires := IncMinute(Now, GMinutes)
  else
    E.Expires := 0;
  GCache.Add(Id, E);
end;

function AskPassCached(AOwner: TComponent; const AKeyId, AKeyLabel, AHint: string; out APass: TBytes): Integer;
begin
  if GetCached(AKeyId, APass) then
    Exit(mrOk);
  Result := AskPassphrase(AOwner, AKeyLabel, AHint, False, APass);
end;

function AskPassForCached(AOwner: TComponent; const AKeyId, AKeyLabel, AHint: string;
  const ARecipients: TArray<string>; out APass: TBytes): Integer;
begin
  if GetCached(AKeyId, APass) then
    Exit(mrOk);
  Result := AskPassphraseFor(AOwner, AKeyLabel, AHint, ARecipients, APass);
end;

procedure NotePassphrase(const AKeyId: string; const APass: TBytes; AAccepted, ARejected: Boolean);
begin
  if AAccepted then
    Remember(AKeyId, APass)
  else if ARejected then
    ForgetPass(AKeyId);
end;

function IsRecipient(const AKey: TKeyInfo; const ARecipients: TArray<string>): Boolean;
var
  R, S: Integer;
begin
  for R := 0 to High(ARecipients) do
  begin
    if SameText(AKey.KeyId, ARecipients[R]) then Exit(True);
    for S := 0 to High(AKey.SubKeys) do
      if SameText(AKey.SubKeys[S].KeyId, ARecipients[R]) then Exit(True);
  end;
  Result := False;
end;

function OwnKeyFor(const AKeys: TKeyInfoArray; const ARecipients: TArray<string>): string;
var
  K: Integer;
  Dummy: TBytes;
begin
  Result := '';
  { prefer a key whose passphrase is cached, else the first of yours }
  for K := 0 to High(AKeys) do
    if AKeys[K].HasSecret and IsRecipient(AKeys[K], ARecipients) then
    begin
      if Result = '' then
        Result := AKeys[K].KeyId;
      if GetCached(AKeys[K].KeyId, Dummy) then
      begin
        Wipe(Dummy);
        Exit(AKeys[K].KeyId);
      end;
    end;
end;

function KeyIdOf(const AFingerprint: string): string;
begin
  Result := Copy(AFingerprint, Length(AFingerprint) - 15, 16);
end;

procedure ForgetPass(const AKeyId: string);
begin
  DropEntry(NormId(AKeyId));
end;

procedure ClearPassCache;
var
  Id: string;
begin
  if GCache = nil then Exit;
  for Id in GCache.Keys.ToArray do
    DropEntry(Id);
end;

procedure PurgeExpiredPasses;
var
  Id: string;
  E: TEntry;
begin
  if GCache = nil then Exit;
  for Id in GCache.Keys.ToArray do
    if GCache.TryGetValue(Id, E) and (E.Expires <> 0) and (Now >= E.Expires) then
      DropEntry(Id);
end;

function CachedPassCount: Integer;
begin
  PurgeExpiredPasses;
  if GCache = nil then Result := 0 else Result := GCache.Count;
end;

initialization

finalization
  ClearPassCache;
  FreeAndNil(GCache);

end.

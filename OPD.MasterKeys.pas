unit OPD.MasterKeys;

{ The Master Key list (as in the classic PGP Options > Master Keys): keys that are added to everything you
  encrypt, so you can always open it yourself and, say, a company key can too.  Stored in settings.ini.
  A master key that is missing from the keyring, expired or revoked is skipped when encrypting. }

interface

uses
  System.SysUtils, System.Classes, OPD.Engine;

type
  TMasterKeys = record
    Enabled: Boolean;
    Fingerprints: TArray<string>;
  end;

{ Armor headers: "Version: CryptLok x.y.z" and an optional comment on messages, signatures and exported keys. }
procedure LoadArmorSettings(const AEngine: IKeyEngine; out AAddVersion: Boolean; out AComment: string);
procedure SaveArmorSettings(const AEngine: IKeyEngine; AAddVersion: Boolean; const AComment: string);
{ True (default): the window's X button hides CryptLok to the tray; False: it quits. }
function LoadCloseToTray(const AEngine: IKeyEngine): Boolean;
procedure SaveCloseToTray(const AEngine: IKeyEngine; AValue: Boolean);
{ Reads the settings and tells the engine. }
procedure ApplyArmorSettings(const AEngine: IKeyEngine);
{ settings.ini of this keyring (one folder above the GnuPG home) }
function IniPath(const AEngine: IKeyEngine): string;
function LoadMasterKeys(const AEngine: IKeyEngine): TMasterKeys;
procedure SaveMasterKeys(const AEngine: IKeyEngine; const AMaster: TMasterKeys);

{ Adds the usable master keys to ARecipients (no duplicates).  Does nothing when the list is off or empty. }
function WithMasterKeys(const AEngine: IKeyEngine; const ARecipients: TArray<string>): TArray<string>;

{ The same, for a keyring you already listed. }
function WithMasterKeysIn(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray;
  const ARecipients: TArray<string>): TArray<string>;

{ The key that is "you": your chosen default private key, or else the first private key you can use. }
function LoadDefaultKey(const AEngine: IKeyEngine): string;
procedure SaveDefaultKey(const AEngine: IKeyEngine; const AFingerprint: string);
function OwnKeyFingerprint(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray): string;

{ Fingerprints of the master keys that can be used right now (enabled list only). }
function UsableMasterKeys(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray): TArray<string>;

implementation

uses
  System.IniFiles, System.StrUtils, OPD.Theme;

{ A key you can encrypt to: not revoked/expired/disabled and with a usable encryption key. }
function KeyUsable(const AKey: TKeyInfo): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AKey.Revoked or AKey.Expired or AKey.Disabled then Exit;
  if Pos('e', LowerCase(AKey.Caps)) > 0 then Exit(True);
  for I := 0 to High(AKey.SubKeys) do
    if (Pos('e', LowerCase(AKey.SubKeys[I].Caps)) > 0) and not AKey.SubKeys[I].Revoked and
       not AKey.SubKeys[I].Expired then
      Exit(True);
end;

function IniPath(const AEngine: IKeyEngine): string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ExcludeTrailingPathDelimiter(AEngine.HomeDir))) +
    'settings.ini';
end;

procedure LoadArmorSettings(const AEngine: IKeyEngine; out AAddVersion: Boolean; out AComment: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    AAddVersion := Ini.ReadBool('Armor', 'AddVersion', True);
    AComment := Ini.ReadString('Armor', 'Comment', '');
  finally
    Ini.Free;
  end;
end;

procedure SaveArmorSettings(const AEngine: IKeyEngine; AAddVersion: Boolean; const AComment: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Ini.WriteBool('Armor', 'AddVersion', AAddVersion);
    Ini.WriteString('Armor', 'Comment', Trim(AComment));
  finally
    Ini.Free;
  end;
end;

function LoadCloseToTray(const AEngine: IKeyEngine): Boolean;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Result := Ini.ReadBool('Window', 'CloseToTray', True);
  finally
    Ini.Free;
  end;
end;

procedure SaveCloseToTray(const AEngine: IKeyEngine; AValue: Boolean);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Ini.WriteBool('Window', 'CloseToTray', AValue);
  finally
    Ini.Free;
  end;
end;

procedure ApplyArmorSettings(const AEngine: IKeyEngine);
var
  Add: Boolean;
  Comment, V: string;
  P: TArray<string>;
begin
  LoadArmorSettings(AEngine, Add, Comment);
  V := '';
  if Add then
  begin
    { the file version is 0.1.0.0; the messages say 0.1.0 }
    P := AppVersionText.Split(['.']);
    if (Length(P) = 4) and (P[3] = '0') then
      V := 'CryptLok ' + P[0] + '.' + P[1] + '.' + P[2]
    else
      V := 'CryptLok ' + AppVersionText;
  end;
  AEngine.SetArmorHeaders(V, Comment);
end;

function LoadMasterKeys(const AEngine: IKeyEngine): TMasterKeys;
var
  Ini: TIniFile;
  I, N: Integer;
  F: string;
begin
  Result.Enabled := False;
  SetLength(Result.Fingerprints, 0);
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Result.Enabled := Ini.ReadBool('MasterKeys', 'Use', False);
    N := Ini.ReadInteger('MasterKeys', 'Count', 0);
    for I := 1 to N do
    begin
      F := UpperCase(Trim(Ini.ReadString('MasterKeys', 'Key' + IntToStr(I), '')));
      if F <> '' then
        Result.Fingerprints := Result.Fingerprints + [F];
    end;
  finally
    Ini.Free;
  end;
end;

procedure SaveMasterKeys(const AEngine: IKeyEngine; const AMaster: TMasterKeys);
var
  Ini: TIniFile;
  I, Old: Integer;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Old := Ini.ReadInteger('MasterKeys', 'Count', 0);
    for I := 1 to Old do
      Ini.DeleteKey('MasterKeys', 'Key' + IntToStr(I));
    Ini.WriteBool('MasterKeys', 'Use', AMaster.Enabled);
    Ini.WriteInteger('MasterKeys', 'Count', Length(AMaster.Fingerprints));
    for I := 0 to High(AMaster.Fingerprints) do
      Ini.WriteString('MasterKeys', 'Key' + IntToStr(I + 1), UpperCase(AMaster.Fingerprints[I]));
  finally
    Ini.Free;
  end;
end;

function LoadDefaultKey(const AEngine: IKeyEngine): string;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    Result := UpperCase(Trim(Ini.ReadString('Keys', 'Default', '')));
  finally
    Ini.Free;
  end;
end;

procedure SaveDefaultKey(const AEngine: IKeyEngine; const AFingerprint: string);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath(AEngine));
  try
    if AFingerprint = '' then
      Ini.DeleteKey('Keys', 'Default')
    else
      Ini.WriteString('Keys', 'Default', UpperCase(AFingerprint));
  finally
    Ini.Free;
  end;
end;

function OwnKeyFingerprint(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray): string;
var
  Want: string;
  K: TKeyInfo;
begin
  Result := '';
  Want := LoadDefaultKey(AEngine);
  if Want <> '' then
    for K in AKeys do
      if K.HasSecret and SameText(K.Fingerprint, Want) and KeyUsable(K) then
        Exit(K.Fingerprint);
  for K in AKeys do
    if K.HasSecret and KeyUsable(K) then
      Exit(K.Fingerprint);
end;

function UsableMasterKeys(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray): TArray<string>;
var
  M: TMasterKeys;
  F: string;
  K: TKeyInfo;
begin
  SetLength(Result, 0);
  M := LoadMasterKeys(AEngine);
  if not M.Enabled then Exit;
  for F in M.Fingerprints do
    for K in AKeys do
      if SameText(K.Fingerprint, F) and KeyUsable(K) then
      begin
        Result := Result + [K.Fingerprint];
        Break;
      end;
end;

function WithMasterKeysIn(const AEngine: IKeyEngine; const AKeys: TKeyInfoArray;
  const ARecipients: TArray<string>): TArray<string>;
var
  F, R: string;
  Have: Boolean;
begin
  Result := Copy(ARecipients);
  for F in UsableMasterKeys(AEngine, AKeys) do
  begin
    Have := False;
    for R in Result do
      if SameText(R, F) then
      begin
        Have := True;
        Break;
      end;
    if not Have then
      Result := Result + [F];
  end;
end;

function WithMasterKeys(const AEngine: IKeyEngine; const ARecipients: TArray<string>): TArray<string>;
var
  M: TMasterKeys;
begin
  M := LoadMasterKeys(AEngine);
  if (not M.Enabled) or (Length(M.Fingerprints) = 0) then
    Exit(Copy(ARecipients));
  Result := WithMasterKeysIn(AEngine, AEngine.ListKeys, ARecipients);
end;

end.

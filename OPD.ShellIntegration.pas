unit OPD.ShellIntegration;

{ Windows Explorer integration, per user (HKEY_CURRENT_USER\Software\Classes), no administrator
  rights.  Nothing here runs unless the user clicks Install in the Explorer Integration window.

    - right-click any file or folder: "Encrypt with CryptLok..."
    - right-click .pgp / .gpg / .asc: "Decrypt/Verify with CryptLok"
    - a "CryptLok encrypted archive" file type (with the zip icon) offered under "Open with" for .pgp,
      and optionally made the default for .pgp

  Uninstall removes exactly what Install wrote.  The registry root is a parameter so the logic can be
  tested against a scratch key. }

interface

uses
  System.SysUtils, System.Classes, System.StrUtils;

type
  TShellEntry = record
    KeyPath: string;      { below the root, e.g. '*\shell\CryptLok.Encrypt\command' }
    ValueName: string;    { '' = the key's default value }
    Data: string;
  end;

  TShellState = (ssNotInstalled, ssInstalled, ssOtherCopy);

  TShellIntegration = class
  private
    FExe: string;
    FRoot: string;
    function Q(const S: string): string;
  public
    constructor Create(const AExe: string; const ARoot: string = 'Software\Classes');
    { Everything Install would write (the optional .pgp default is the last entry when requested). }
    function Entries(ADefaultForPgp: Boolean): TArray<TShellEntry>;
    function State: TShellState;
    function PgpDefaultIsOurs: Boolean;
    { Writes the entries; returns a note for the user ('' when there is nothing to add). }
    function Install(ADefaultForPgp: Boolean): string;
    procedure Uninstall;
    property Root: string read FRoot;
  end;

const
  PROGID = 'CryptLok.Archive';
  PROGID_SIG = 'CryptLok.Signature';

implementation

uses
  Winapi.Windows, Winapi.ShlObj, Winapi.ShlwApi, System.Win.Registry;

constructor TShellIntegration.Create(const AExe, ARoot: string);
begin
  inherited Create;
  FExe := AExe;
  FRoot := ARoot;
end;

function TShellIntegration.Q(const S: string): string;
begin
  Result := '"' + S + '"';
end;

function TShellIntegration.Entries(ADefaultForPgp: Boolean): TArray<TShellEntry>;
var
  L: TArray<TShellEntry>;

  procedure Add(const APath, AName, AData: string);
  begin
    SetLength(L, Length(L) + 1);
    L[High(L)].KeyPath := APath;
    L[High(L)].ValueName := AName;
    L[High(L)].Data := AData;
  end;

  procedure Verb(const ABase, AText, AArg: string);
  begin
    Add(ABase, '', AText);
    Add(ABase, 'Icon', Q(FExe) + ',0');
    Add(ABase + '\command', '', Q(FExe) + ' ' + AArg + ':"%1"');
  end;

var
  Ext: string;
begin
  SetLength(L, 0);
  Verb('*\shell\CryptLok.Encrypt', 'Encrypt with CryptLok...', '/zip');
  Verb('Directory\shell\CryptLok.Encrypt', 'Encrypt with CryptLok...', '/zip');
  Verb('*\shell\CryptLok.Shred', 'Shred with CryptLok...', '/shred');
  Verb('Directory\shell\CryptLok.Shred', 'Shred with CryptLok...', '/shred');
  Verb('*\shell\CryptLok.Sign', 'Sign with CryptLok...', '/signfile');
  for Ext in ['.pgp', '.gpg', '.asc'] do
    Verb('SystemFileAssociations\' + Ext + '\shell\CryptLok.Open', 'Decrypt/Verify with CryptLok', '/zipopen');
  Verb('SystemFileAssociations\.sig\shell\CryptLok.Open', 'Verify with CryptLok', '/zipopen');
  Add(PROGID, '', 'CryptLok encrypted archive');
  Add(PROGID + '\DefaultIcon', '', Q(FExe) + ',-101');
  Add(PROGID + '\shell\open', '', 'Open with CryptLok');
  Add(PROGID + '\shell\open\command', '', Q(FExe) + ' /zipopen:"%1"');
  Add('.pgp\OpenWithProgids', PROGID, '');
  { a detached signature (.sig): its own type with its own icon }
  Add(PROGID_SIG, '', 'CryptLok signature');
  Add(PROGID_SIG + '\DefaultIcon', '', Q(FExe) + ',-102');
  Add(PROGID_SIG + '\shell\open', '', 'Verify with CryptLok');
  Add(PROGID_SIG + '\shell\open\command', '', Q(FExe) + ' /zipopen:"%1"');
  Add('.sig\OpenWithProgids', PROGID_SIG, '');
  { .sig has no common owner: CryptLok becomes its default unless another program already is }
  Add('.sig', '', PROGID_SIG);
  if ADefaultForPgp then
    Add('.pgp', '', PROGID);
  Result := L;
end;

function ReadString(const ARoot, APath, AName: string; out AData: string): Boolean;
var
  R: TRegistry;
begin
  Result := False;
  AData := '';
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(ARoot + '\' + APath) then
    begin
      try
        if R.ValueExists(AName) then
        begin
          AData := R.ReadString(AName);
          Result := True;
        end;
      finally
        R.CloseKey;
      end;
    end;
  finally
    R.Free;
  end;
end;

function TShellIntegration.State: TShellState;
var
  Cmd: string;
begin
  if not ReadString(FRoot, '*\shell\CryptLok.Encrypt\command', '', Cmd) then
    Exit(ssNotInstalled);
  if SameText(Cmd, Q(FExe) + ' /zip:"%1"') then
    Result := ssInstalled
  else
    Result := ssOtherCopy;
end;

function TShellIntegration.PgpDefaultIsOurs: Boolean;
var
  D: string;
begin
  Result := ReadString(FRoot, '.pgp', '', D) and SameText(D, PROGID);
end;

{ Windows makes a type such as "sig_auto_file" when someone picks a program under "Open with". When that
  type just opens CryptLok it is ours in effect, and may be replaced by our proper type (with its icon). }
function OpensWithCryptLok(const ARoot, AProgId: string): Boolean;
var
  Cmd: string;
begin
  Result := ReadString(ARoot, AProgId + '\shell\open\command', '', Cmd) and ContainsText(Cmd, 'CryptLok.exe');
end;

procedure DeleteIfEmpty(R: TRegistry; const APath: string);
var
  Names: TStringList;
  Empty: Boolean;
begin
  if not R.OpenKeyReadOnly(APath) then Exit;
  Names := TStringList.Create;
  try
    R.GetValueNames(Names);
    Empty := (Names.Count = 0) and not R.HasSubKeys;
  finally
    Names.Free;
    R.CloseKey;
  end;
  if Empty then
    R.DeleteKey(APath);
end;

function TShellIntegration.Install(ADefaultForPgp: Boolean): string;
var
  E: TShellEntry;
  R: TRegistry;
  Existing: string;
  Skip: Boolean;
begin
  Result := '';
  R := TRegistry.Create(KEY_WRITE or KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    for E in Entries(ADefaultForPgp) do
    begin
      Skip := False;
      { never replace another program's default for .pgp }
      if ((E.KeyPath = '.pgp') or (E.KeyPath = '.sig')) and (E.ValueName = '') then
        if ReadString(FRoot, E.KeyPath, '', Existing) and (Existing <> '') and not SameText(Existing, PROGID) and
          not SameText(Existing, PROGID_SIG) and not OpensWithCryptLok(FRoot, Existing) then
        begin
          Skip := True;
          Result := Result + IfThen(Result = '', '', ' ') + 'Another program is already the default for ' + E.KeyPath +
            ' files (' + Existing + '). CryptLok was added to the "Open with" list instead; pick it there and choose "Always".';
        end;
      if Skip then Continue;
      if not R.OpenKey(FRoot + '\' + E.KeyPath, True) then
        raise Exception.Create('Could not write the registry key ' + E.KeyPath);
      try
        R.WriteString(E.ValueName, E.Data);
      finally
        R.CloseKey;
      end;
    end;
  finally
    R.Free;
  end;
  if SameText(FRoot, 'Software\Classes') then
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nil, nil);
end;

procedure TShellIntegration.Uninstall;
var
  R: TRegistry;
  Ext, D: string;
begin
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\*\shell\CryptLok.Encrypt'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\Directory\shell\CryptLok.Encrypt'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\*\shell\CryptLok.Shred'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\*\shell\CryptLok.Sign'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\SystemFileAssociations\.sig\shell\CryptLok.Open'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\' + PROGID_SIG));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\Directory\shell\CryptLok.Shred'));
  for Ext in ['.pgp', '.gpg', '.asc'] do
    SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\SystemFileAssociations\' + Ext + '\shell\CryptLok.Open'));
  SHDeleteKey(HKEY_CURRENT_USER, PChar(FRoot + '\' + PROGID));
  R := TRegistry.Create(KEY_WRITE or KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey(FRoot + '\.pgp\OpenWithProgids', False) then
    begin
      try
        if R.ValueExists(PROGID) then R.DeleteValue(PROGID);
      finally
        R.CloseKey;
      end;
    end;
    if ReadString(FRoot, '.pgp', '', D) and SameText(D, PROGID) then
      if R.OpenKey(FRoot + '\.pgp', False) then
      begin
        try
          R.DeleteValue('');
        finally
          R.CloseKey;
        end;
      end;
    { tidy up empty parents we created; a key that still holds a value or a subkey is left alone }
    if R.OpenKey(FRoot + '\.sig\OpenWithProgids', False) then
    begin
      try
        if R.ValueExists(PROGID_SIG) then R.DeleteValue(PROGID_SIG);
      finally
        R.CloseKey;
      end;
    end;
    if ReadString(FRoot, '.sig', '', D) and SameText(D, PROGID_SIG) then
      if R.OpenKey(FRoot + '\.sig', False) then
      begin
        try
          R.DeleteValue('');
        finally
          R.CloseKey;
        end;
      end;
    DeleteIfEmpty(R, FRoot + '\.sig\OpenWithProgids');
    DeleteIfEmpty(R, FRoot + '\.sig');
    DeleteIfEmpty(R, FRoot + '\SystemFileAssociations\.sig\shell');
    DeleteIfEmpty(R, FRoot + '\SystemFileAssociations\.sig');
    DeleteIfEmpty(R, FRoot + '\.pgp\OpenWithProgids');
    DeleteIfEmpty(R, FRoot + '\.pgp');
    for Ext in ['.pgp', '.gpg', '.asc'] do
    begin
      DeleteIfEmpty(R, FRoot + '\SystemFileAssociations\' + Ext + '\shell');
      DeleteIfEmpty(R, FRoot + '\SystemFileAssociations\' + Ext);
    end;
    DeleteIfEmpty(R, FRoot + '\SystemFileAssociations');
    DeleteIfEmpty(R, FRoot + '\*\shell');
    DeleteIfEmpty(R, FRoot + '\*');
    DeleteIfEmpty(R, FRoot + '\Directory\shell');
    DeleteIfEmpty(R, FRoot + '\Directory');
  finally
    R.Free;
  end;
  if SameText(FRoot, 'Software\Classes') then
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nil, nil);
end;

end.

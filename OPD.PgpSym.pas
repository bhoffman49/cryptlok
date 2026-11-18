unit OPD.PgpSym;

{ Decrypts a passphrase-encrypted OpenPGP message without GnuPG.
  This is what the self-decrypting archive (SDA) stub uses, so it must not depend on anything
  installed.  Supported: SKESK v4 with iterated/salted S2K (SHA-1/256/384/512), AES-128/192/256
  CFB with the MDC integrity packet (SEIPD v1), optional ZIP/ZLIB compression, literal data in
  old or new packet formats, partial body lengths.  Everything else is reported as unsupported.
  AES comes from Windows CNG (ECB, CFB is done here), hashing from System.Hash. }

interface

uses
  System.SysUtils, System.Classes;

type
  TSymStatus = (sdOk, sdWrongPassphrase, sdCorrupt, sdUnsupported);

  TSymProgress = reference to procedure(APercent: Integer);

{ AInFile[AOffset .. AOffset+ALength) holds the OpenPGP message (ALength = 0: to the end of file).
  On success APlainFile (a file created in ATempDir) holds the literal data and AInnerName the
  stored file name.  Temporary files are removed here; the caller removes APlainFile. }
function SymDecrypt(const AInFile: string; AOffset, ALength: Int64; const APass: TBytes;
  const ATempDir: string; out APlainFile, AInnerName, AError: string;
  const AProgress: TSymProgress = nil): TSymStatus;

implementation

uses
  Winapi.Windows, System.Hash, System.ZLib, System.Math;

{ ---- Windows CNG (AES) --------------------------------------------------------------- }

type
  BCRYPT_ALG_HANDLE = Pointer;
  BCRYPT_KEY_HANDLE = Pointer;

function BCryptOpenAlgorithmProvider(out phAlgorithm: BCRYPT_ALG_HANDLE; pszAlgId, pszImplementation: PWideChar;
  dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCloseAlgorithmProvider(hAlgorithm: BCRYPT_ALG_HANDLE; dwFlags: ULONG): LongInt; stdcall;
  external 'bcrypt.dll';
function BCryptSetProperty(hObject: Pointer; pszProperty: PWideChar; pbInput: PByte; cbInput: ULONG;
  dwFlags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptGenerateSymmetricKey(hAlgorithm: BCRYPT_ALG_HANDLE; out phKey: BCRYPT_KEY_HANDLE;
  pbKeyObject: PByte; cbKeyObject: ULONG; pbSecret: PByte; cbSecret: ULONG; dwFlags: ULONG): LongInt; stdcall;
  external 'bcrypt.dll';
function BCryptEncrypt(hKey: BCRYPT_KEY_HANDLE; pbInput: PByte; cbInput: ULONG; pPaddingInfo: Pointer;
  pbIV: PByte; cbIV: ULONG; pbOutput: PByte; cbOutput: ULONG; out pcbResult: ULONG; dwFlags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll';
function BCryptDestroyKey(hKey: BCRYPT_KEY_HANDLE): LongInt; stdcall; external 'bcrypt.dll';

type
  TAesEcb = class
  private
    FAlg: BCRYPT_ALG_HANDLE;
    FKey: BCRYPT_KEY_HANDLE;
  public
    constructor Create(const AKey: TBytes);
    destructor Destroy; override;
    { Encrypts AInput (multiple of 16 bytes) into AOutput. }
    procedure Encrypt(AInput, AOutput: PByte; ACount: Integer);
  end;

constructor TAesEcb.Create(const AKey: TBytes);
const
  Mode: WideString = 'ChainingModeECB';
begin
  inherited Create;
  if BCryptOpenAlgorithmProvider(FAlg, 'AES', nil, 0) <> 0 then
    raise Exception.Create('AES is not available');
  if BCryptSetProperty(FAlg, 'ChainingMode', PByte(PWideChar(Mode)), (Length(Mode) + 1) * 2, 0) <> 0 then
    raise Exception.Create('AES mode is not available');
  if BCryptGenerateSymmetricKey(FAlg, FKey, nil, 0, @AKey[0], Length(AKey), 0) <> 0 then
    raise Exception.Create('AES key could not be set');
end;

destructor TAesEcb.Destroy;
begin
  if FKey <> nil then BCryptDestroyKey(FKey);
  if FAlg <> nil then BCryptCloseAlgorithmProvider(FAlg, 0);
  inherited;
end;

procedure TAesEcb.Encrypt(AInput, AOutput: PByte; ACount: Integer);
var
  Got: ULONG;
begin
  if BCryptEncrypt(FKey, AInput, ACount, nil, nil, 0, AOutput, ACount, Got, 0) <> 0 then
    raise Exception.Create('AES failed');
end;

{ ---- hashing ---------------------------------------------------------------------------- }

type
  THasher = class
  private
    FKind: Integer;
    FSha1: THashSHA1;
    FSha2: THashSHA2;
  public
    constructor Create(AAlgo: Integer);
    procedure Update(const AData; ALength: Integer);
    function Final: TBytes;
  end;

constructor THasher.Create(AAlgo: Integer);
begin
  inherited Create;
  FKind := AAlgo;
  case AAlgo of
    2: FSha1 := THashSHA1.Create;
    8: FSha2 := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
    9: FSha2 := THashSHA2.Create(THashSHA2.TSHA2Version.SHA384);
    10: FSha2 := THashSHA2.Create(THashSHA2.TSHA2Version.SHA512);
  else
    raise Exception.Create('Unsupported hash');
  end;
end;

procedure THasher.Update(const AData; ALength: Integer);
begin
  if ALength <= 0 then Exit;
  if FKind = 2 then FSha1.Update(AData, ALength) else FSha2.Update(AData, ALength);
end;

function THasher.Final: TBytes;
begin
  if FKind = 2 then Result := FSha1.HashAsBytes else Result := FSha2.HashAsBytes;
end;

{ Partial body length: 2^(octet and 31).  Written as a loop because the 64-bit compiler mis-compiles
  Int64(1) shl (B and $1F) for a Byte operand (it shifted by B and $3F). }
function PartialLength(AOctet: Byte): Int64;
var
  I, C: Integer;
begin
  C := AOctet and $1F;
  Result := 1;
  for I := 1 to C do
    Result := Result * 2;
end;

{ ---- packet headers ---------------------------------------------------------------------- }

type
  TPacketHead = record
    Tag: Integer;
    Len: Int64;
    Partial: Boolean;
    Indeterminate: Boolean;
  end;

function ReadByteS(S: TStream; out B: Byte): Boolean;
begin
  Result := S.Read(B, 1) = 1;
end;

function ReadHead(S: TStream; AEnd: Int64; out H: TPacketHead): Boolean;
var
  B, B2, B3, B4, B5: Byte;
begin
  Result := False;
  FillChar(H, SizeOf(H), 0);
  if S.Position >= AEnd then Exit;
  if not ReadByteS(S, B) then Exit;
  if (B and $80) = 0 then Exit;
  if (B and $40) <> 0 then
  begin
    H.Tag := B and $3F;
    if not ReadByteS(S, B2) then Exit;
    if B2 < 192 then
      H.Len := B2
    else if B2 < 224 then
    begin
      if not ReadByteS(S, B3) then Exit;
      H.Len := ((B2 - 192) shl 8) + B3 + 192;
    end
    else if B2 = 255 then
    begin
      if not (ReadByteS(S, B2) and ReadByteS(S, B3) and ReadByteS(S, B4) and ReadByteS(S, B5)) then Exit;
      H.Len := (Int64(B2) shl 24) or (B3 shl 16) or (B4 shl 8) or B5;
    end
    else
    begin
      H.Len := PartialLength(B2);
      H.Partial := True;
    end;
  end
  else
  begin
    H.Tag := (B shr 2) and $F;
    case B and 3 of
      0: begin if not ReadByteS(S, B2) then Exit; H.Len := B2; end;
      1: begin if not (ReadByteS(S, B2) and ReadByteS(S, B3)) then Exit; H.Len := (B2 shl 8) or B3; end;
      2: begin
           if not (ReadByteS(S, B2) and ReadByteS(S, B3) and ReadByteS(S, B4) and ReadByteS(S, B5)) then Exit;
           H.Len := (Int64(B2) shl 24) or (B3 shl 16) or (B4 shl 8) or B5;
         end;
    else
      H.Indeterminate := True;
      H.Len := AEnd - S.Position;
    end;
  end;
  Result := True;
end;

{ Reads the body of one packet as a continuous byte stream (follows partial lengths). }
type
  TBodyReader = class
  private
    FS: TStream;
    FEnd: Int64;
    FRemain: Int64;
    FPartial: Boolean;
    FDone: Boolean;
  public
    constructor Create(AStream: TStream; AEnd: Int64; const AHead: TPacketHead);
    function Read(var ABuf; ACount: Integer): Integer;
  end;

constructor TBodyReader.Create(AStream: TStream; AEnd: Int64; const AHead: TPacketHead);
begin
  inherited Create;
  FS := AStream;
  FEnd := AEnd;
  FRemain := AHead.Len;
  FPartial := AHead.Partial;
end;

function TBodyReader.Read(var ABuf; ACount: Integer): Integer;
var
  P: PByte;
  N: Integer;
  B, B2, B3, B4, B5: Byte;
begin
  Result := 0;
  P := @ABuf;
  while (ACount > 0) and not FDone do
  begin
    if FRemain = 0 then
    begin
      if FPartial then
      begin
        { next length header of a partial-length body }
        if not ReadByteS(FS, B) then begin FDone := True; Break; end;
        if B < 192 then begin FRemain := B; FPartial := False; end
        else if B < 224 then
        begin
          if not ReadByteS(FS, B2) then begin FDone := True; Break; end;
          FRemain := ((B - 192) shl 8) + B2 + 192;
          FPartial := False;
        end
        else if B = 255 then
        begin
          if not (ReadByteS(FS, B2) and ReadByteS(FS, B3) and ReadByteS(FS, B4) and ReadByteS(FS, B5)) then
          begin FDone := True; Break; end;
          FRemain := (Int64(B2) shl 24) or (B3 shl 16) or (B4 shl 8) or B5;
          FPartial := False;
        end
        else
          FRemain := PartialLength(B);
        if FRemain = 0 then begin FDone := True; Break; end;
      end
      else
      begin
        FDone := True;
        Break;
      end;
    end;
    N := Integer(Min(Int64(ACount), FRemain));
    N := FS.Read(P^, N);
    if N <= 0 then begin FDone := True; Break; end;
    Inc(P, N);
    Dec(ACount, N);
    Dec(FRemain, N);
    Inc(Result, N);
  end;
end;

{ TStream facade so the zlib decompressor can read a packet body. }
type
  TBodyStream = class(TStream)
  private
    FBody: TBodyReader;
  public
    constructor Create(ABody: TBodyReader);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

constructor TBodyStream.Create(ABody: TBodyReader);
begin
  inherited Create;
  FBody := ABody;
end;

function TBodyStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FBody.Read(Buffer, Count);
end;

function TBodyStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TBodyStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

{ ---- string-to-key ----------------------------------------------------------------------- }

function DeriveKey(const APass: TBytes; AType, AHash: Integer; const ASalt: TBytes; ACountByte, AKeyLen: Integer): TBytes;
var
  Material: TBytes;
  H: THasher;
  Count, Done, N: Int64;
  Got: TBytes;
  Zero: Byte;
  I, Preload: Integer;
  Chunk: Int64;
begin
  SetLength(Result, 0);
  { salt + passphrase, repeated up to Count bytes }
  case AType of
    0: Material := Copy(APass);
    1, 3: Material := ASalt + APass;
  else
    raise Exception.Create('Unsupported string-to-key method');
  end;
  if Length(Material) = 0 then
    raise Exception.Create('Empty passphrase');
  if AType = 3 then
    Count := Int64(16 + (ACountByte and 15)) shl ((ACountByte shr 4) + 6)
  else
    Count := Length(Material);
  if Count < Length(Material) then
    Count := Length(Material);
  Preload := 0;
  while Length(Result) < AKeyLen do
  begin
    H := THasher.Create(AHash);
    try
      Zero := 0;
      for I := 1 to Preload do
        H.Update(Zero, 1);
      Done := 0;
      while Done < Count do
      begin
        Chunk := Min(Int64(Length(Material)), Count - Done);
        H.Update(Material[0], Integer(Chunk));
        Inc(Done, Chunk);
      end;
      Got := H.Final;
    finally
      H.Free;
    end;
    N := Min(Int64(Length(Got)), AKeyLen - Length(Result));
    Result := Result + Copy(Got, 0, Integer(N));
    Inc(Preload);
  end;
end;

{ ---- the decryptor ----------------------------------------------------------------------- }

const
  CHUNK = 1024 * 1024;

procedure Wipe(var A: TBytes);
begin
  if Length(A) > 0 then FillChar(A[0], Length(A), 0);
  A := nil;
end;

{ Walks decrypted packets; writes the literal data to AOutFile.  Handles compressed packets
  by decompressing into a temporary file and walking that. }
function ExtractLiteral(const AStream: TStream; AStart, AEnd: Int64; const ATempDir, AOutFile: string;
  var AName: string; ADepth: Integer; var AError: string): TSymStatus;
var
  H: TPacketHead;
  Body: TBodyReader;
  Pos0: Int64;
  Buf: TBytes;
  Algo: Byte;
  NameLen: Byte;
  Out_: TFileStream;
  N: Integer;
  TmpFile: string;
  Tmp: TFileStream;
  Dec: TZDecompressionStream;
  BS: TBodyStream;
  Skip: TBytes;
  Hdr: array[0..4] of Byte;
  Raw: TBytes;
begin
  Result := sdCorrupt;
  if ADepth > 3 then
  begin
    AError := 'Too many nested layers';
    Exit;
  end;
  AStream.Position := AStart;
  SetLength(Buf, 65536);
  while ReadHead(AStream, AEnd, H) do
  begin
    Pos0 := AStream.Position;
    case H.Tag of
      11: { literal data }
        begin
          Body := TBodyReader.Create(AStream, AEnd, H);
          try
            if Body.Read(Hdr[0], 2) < 2 then Exit;   { format, name length }
            NameLen := Hdr[1];
            SetLength(Raw, NameLen);
            if (NameLen > 0) and (Body.Read(Raw[0], NameLen) < NameLen) then Exit;
            AName := TEncoding.UTF8.GetString(Raw);
            if Body.Read(Hdr[0], 4) < 4 then Exit;    { date }
            Out_ := TFileStream.Create(AOutFile, fmCreate);
            try
              repeat
                N := Body.Read(Buf[0], Length(Buf));
                if N > 0 then Out_.WriteBuffer(Buf[0], N);
              until N <= 0;
            finally
              Out_.Free;
            end;
            Result := sdOk;
            Exit;
          finally
            Body.Free;
          end;
        end;
      8: { compressed data }
        begin
          Body := TBodyReader.Create(AStream, AEnd, H);
          try
            if Body.Read(Algo, 1) < 1 then Exit;
            if not (Algo in [1, 2]) then
            begin
              AError := 'This archive uses a compression method that is not supported (bzip2).';
              Result := sdUnsupported;
              Exit;
            end;
            TmpFile := IncludeTrailingPathDelimiter(ATempDir) + 'clk-dec-' + IntToStr(ADepth) + '.tmp';
            Tmp := TFileStream.Create(TmpFile, fmCreate);
            try
              BS := TBodyStream.Create(Body);
              try
                if Algo = 1 then
                  Dec := TZDecompressionStream.Create(BS, -15)
                else
                  Dec := TZDecompressionStream.Create(BS, 15);
                try
                  repeat
                    N := Dec.Read(Buf[0], Length(Buf));
                    if N > 0 then Tmp.WriteBuffer(Buf[0], N);
                  until N <= 0;
                finally
                  Dec.Free;
                end;
              finally
                BS.Free;
              end;
              Result := ExtractLiteral(Tmp, 0, Tmp.Size, ATempDir, AOutFile, AName, ADepth + 1, AError);
            finally
              Tmp.Free;
              DeleteFile(PChar(TmpFile));
            end;
            Exit;
          finally
            Body.Free;
          end;
        end;
    else
      { signatures, one-pass signatures and the like: skip the body }
      Body := TBodyReader.Create(AStream, AEnd, H);
      try
        repeat
          N := Body.Read(Buf[0], Length(Buf));
        until N <= 0;
      finally
        Body.Free;
      end;
    end;
    if H.Indeterminate then Break;
  end;
  if Result <> sdOk then
    AError := 'The archive does not contain any file data';
end;

function SymDecrypt(const AInFile: string; AOffset, ALength: Int64; const APass: TBytes;
  const ATempDir: string; out APlainFile, AInnerName, AError: string;
  const AProgress: TSymProgress): TSymStatus;
var
  F: TFileStream;
  EndPos: Int64;
  H: TPacketHead;
  B: Byte;
  Ver, CipherAlgo, S2kType, HashAlgo, CountByte, KeyLen: Integer;
  Salt: TBytes;
  Key: TBytes;
  HaveSkesk: Boolean;
  Body: TBodyReader;
  Aes: TAesEcb;
  PlainFile: string;
  PlainStream: TFileStream;
  CtBuf, KsIn, KsOut, Carry: TBytes;
  CarryLen, Got, Full, I: Integer;
  Prev: array[0..15] of Byte;
  First: Boolean;
  Total, Done: Int64;
  Mdc: THashSHA1;
  Tail: array[0..21] of Byte;
  Sum: TBytes;
  Rd: Integer;
  HashBuf: TBytes;
  Remaining: Int64;
begin
  APlainFile := '';
  AInnerName := '';
  AError := '';
  Result := sdCorrupt;
  Key := nil;
  HaveSkesk := False;
  Salt := nil;
  CipherAlgo := 0; S2kType := 0; HashAlgo := 0; CountByte := 0;
  F := TFileStream.Create(AInFile, fmOpenRead or fmShareDenyNone);
  try
    if ALength <= 0 then ALength := F.Size - AOffset;
    EndPos := AOffset + ALength;
    F.Position := AOffset;
    PlainFile := IncludeTrailingPathDelimiter(ATempDir) + 'clk-plain.tmp';
    try
      { --- find the symmetric key packet and the encrypted data packet --- }
      while ReadHead(F, EndPos, H) do
      begin
        if H.Tag = 3 then
        begin
          Body := TBodyReader.Create(F, EndPos, H);
          try
            if (Body.Read(B, 1) < 1) then Exit;
            Ver := B;
            if Ver <> 4 then
            begin
              AError := 'This archive uses a newer passphrase format that is not supported.';
              Exit(sdUnsupported);
            end;
            if Body.Read(B, 1) < 1 then Exit;  CipherAlgo := B;
            if Body.Read(B, 1) < 1 then Exit;  S2kType := B;
            if Body.Read(B, 1) < 1 then Exit;  HashAlgo := B;
            SetLength(Salt, 0);
            if S2kType in [1, 3] then
            begin
              SetLength(Salt, 8);
              if Body.Read(Salt[0], 8) < 8 then Exit;
            end;
            if S2kType = 3 then
            begin
              if Body.Read(B, 1) < 1 then Exit;
              CountByte := B;
            end;
            HaveSkesk := True;
          finally
            Body.Free;
          end;
          Continue;
        end;
        if H.Tag = 18 then
          Break;
        { anything else before the data (public-key packets, marker): skip }
        if H.Indeterminate then Exit;
        if H.Partial then Exit;
        F.Position := F.Position + H.Len;
      end;
      if H.Tag <> 18 then
      begin
        AError := 'This file does not contain encrypted data.';
        Exit;
      end;
      if not HaveSkesk then
      begin
        AError := 'This archive is not protected by a passphrase.';
        Exit(sdUnsupported);
      end;
      case CipherAlgo of
        7: KeyLen := 16;
        8: KeyLen := 24;
        9: KeyLen := 32;
      else
        AError := 'This archive uses a cipher that is not supported.';
        Exit(sdUnsupported);
      end;
      if not (HashAlgo in [2, 8, 9, 10]) then
      begin
        AError := 'This archive uses a hash method that is not supported.';
        Exit(sdUnsupported);
      end;

      Key := DeriveKey(APass, S2kType, HashAlgo, Salt, CountByte, KeyLen);
      Aes := TAesEcb.Create(Key);
      try
        Body := TBodyReader.Create(F, EndPos, H);
        try
          if (Body.Read(B, 1) < 1) or (B <> 1) then
          begin
            AError := 'This archive uses an encryption format that is not supported.';
            Exit(sdUnsupported);
          end;
          Total := ALength;
          Done := 0;
          PlainStream := TFileStream.Create(PlainFile, fmCreate);
          try
            SetLength(CtBuf, CHUNK + 16);
            SetLength(KsIn, CHUNK + 16);
            SetLength(KsOut, CHUNK + 16);
            SetLength(Carry, 16);
            CarryLen := 0;
            FillChar(Prev, SizeOf(Prev), 0);
            First := True;
            repeat
              { top up the buffer: carry bytes first }
              if CarryLen > 0 then
                Move(Carry[0], CtBuf[0], CarryLen);
              Got := Body.Read(CtBuf[CarryLen], CHUNK - CarryLen);
              Got := Got + CarryLen;
              CarryLen := 0;
              if Got <= 0 then Break;
              Full := (Got div 16) * 16;
              if (Full = 0) then
              begin
                { final partial block }
                Move(CtBuf[0], Carry[0], Got);
                CarryLen := Got;
                Break;
              end;
              { keystream = AES(previous ciphertext block || ciphertext blocks, without the last) }
              Move(Prev[0], KsIn[0], 16);
              if Full > 16 then
                Move(CtBuf[0], KsIn[16], Full - 16);
              Aes.Encrypt(@KsIn[0], @KsOut[0], Full);
              for I := 0 to Full - 1 do
                KsOut[I] := KsOut[I] xor CtBuf[I];          { plaintext }
              if First then
              begin
                First := False;
                { quick check: bytes 14,15 repeat as 16,17 }
                if (Full < 18) or (KsOut[14] <> KsOut[16]) or (KsOut[15] <> KsOut[17]) then
                begin
                  AError := 'That passphrase is not correct.';
                  Exit(sdWrongPassphrase);
                end;
              end;
              PlainStream.WriteBuffer(KsOut[0], Full);
              Move(CtBuf[Full - 16], Prev[0], 16);
              if Got > Full then
              begin
                Move(CtBuf[Full], Carry[0], Got - Full);
                CarryLen := Got - Full;
              end;
              Inc(Done, Full);
              if Assigned(AProgress) and (Total > 0) then
                AProgress(Integer(Min(Int64(99), Done * 100 div Total)));
            until False;
            if CarryLen > 0 then
            begin
              { last bytes that do not fill a block }
              Move(Prev[0], KsIn[0], 16);
              Aes.Encrypt(@KsIn[0], @KsOut[0], 16);
              for I := 0 to CarryLen - 1 do
                KsOut[I] := KsOut[I] xor Carry[I];
              PlainStream.WriteBuffer(KsOut[0], CarryLen);
              if First then
              begin
                AError := 'That passphrase is not correct.';
                Exit(sdWrongPassphrase);
              end;
            end;
            if First then
            begin
              AError := 'The archive is empty or damaged.';
              Exit;
            end;
            Remaining := PlainStream.Size;
          finally
            PlainStream.Free;
          end;
        finally
          Body.Free;
        end;
      finally
        Aes.Free;
      end;

      { --- integrity check: SHA-1 over everything except the final 20 bytes must match --- }
      PlainStream := TFileStream.Create(PlainFile, fmOpenRead or fmShareDenyNone);
      try
        if Remaining < 18 + 22 then
        begin
          AError := 'The archive is damaged.';
          Exit;
        end;
        PlainStream.Position := Remaining - 22;
        PlainStream.ReadBuffer(Tail, 22);
        if (Tail[0] <> $D3) or (Tail[1] <> $14) then
        begin
          AError := 'The archive has no integrity check and cannot be trusted.';
          Exit;
        end;
        Mdc := THashSHA1.Create;
        PlainStream.Position := 0;
        SetLength(HashBuf, CHUNK);
        Done := Remaining - 20;
        while Done > 0 do
        begin
          Rd := PlainStream.Read(HashBuf[0], Integer(Min(Int64(CHUNK), Done)));
          if Rd <= 0 then Break;
          Mdc.Update(HashBuf[0], Rd);
          Dec(Done, Rd);
        end;
        Sum := Mdc.HashAsBytes;
        for I := 0 to 19 do
          if Sum[I] <> Tail[2 + I] then
          begin
            AError := 'The archive was damaged or changed after it was made. Nothing was extracted.';
            Exit;
          end;
        { --- the inner packets sit between the 18-byte prefix and the 22-byte trailer --- }
        APlainFile := IncludeTrailingPathDelimiter(ATempDir) + 'clk-data.tmp';
        Result := ExtractLiteral(PlainStream, 18, Remaining - 22, ATempDir, APlainFile, AInnerName, 0, AError);
        if Result <> sdOk then
        begin
          DeleteFile(PChar(APlainFile));
          APlainFile := '';
        end;
      finally
        PlainStream.Free;
      end;
    finally
      if FileExists(PlainFile) then
      begin
        { the decrypted copy is overwritten before it is removed }
        try
          PlainStream := TFileStream.Create(PlainFile, fmOpenWrite or fmShareExclusive);
          try
            SetLength(HashBuf, 65536);
            FillChar(HashBuf[0], Length(HashBuf), 0);
            Remaining := PlainStream.Size;
            while Remaining > 0 do
            begin
              Rd := Integer(Min(Int64(Length(HashBuf)), Remaining));
              PlainStream.WriteBuffer(HashBuf[0], Rd);
              Dec(Remaining, Rd);
            end;
          finally
            PlainStream.Free;
          end;
        except
        end;
        DeleteFile(PChar(PlainFile));
      end;
      Wipe(Key);
    end;
  finally
    F.Free;
  end;
end;

end.

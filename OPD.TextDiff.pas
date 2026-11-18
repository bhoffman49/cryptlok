unit OPD.TextDiff;

{ Word-level comparison of two texts.  Used by the Viewer's "Compare with original": text that is only in the
  original is marked as removed, text that is only in the viewed message as added.  Common beginning and end
  are skipped first, so ordinary small edits are fast even in long texts. }

interface

uses
  System.SysUtils, System.Classes;

type
  TDiffOp = (doSame, doRemoved, doAdded);

  TDiffPiece = record
    Op: TDiffOp;
    Text: string;
  end;

  TDiffPieces = TArray<TDiffPiece>;

const
  { n x m limit of the differing middle part (4000 x 4000 words) }
  DIFF_MAX_CELLS = 16000000;

{ Compares AOriginal with ANew.  Line endings are treated as equal (CRLF = LF).  False when the two texts differ
  too much to compare here; AError says so. }
function DiffTexts(const AOriginal, ANew: string; out APieces: TDiffPieces; out AError: string): Boolean;

{ Counts of removed and added words, for a summary line. }
procedure DiffSummary(const APieces: TDiffPieces; out ARemoved, AAdded: Integer);

implementation

uses
  System.Generics.Collections, System.Math;

function Tokenize(const S: string): TArray<string>;
var
  L: TList<string>;
  I, Start: Integer;
  IsSpace: Boolean;
begin
  L := TList<string>.Create;
  try
    I := 1;
    while I <= Length(S) do
    begin
      Start := I;
      IsSpace := CharInSet(S[I], [' ', #9, #10, #13]);
      while (I <= Length(S)) and (CharInSet(S[I], [' ', #9, #10, #13]) = IsSpace) do
        Inc(I);
      L.Add(Copy(S, Start, I - Start));
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function Normalize(const S: string): string;
begin
  Result := S.Replace(#13#10, #10).Replace(#13, #10);
end;

procedure AddPiece(var APieces: TDiffPieces; AOp: TDiffOp; const AText: string);
var
  N: Integer;
begin
  if AText = '' then Exit;
  N := Length(APieces);
  if (N > 0) and (APieces[N - 1].Op = AOp) then
    APieces[N - 1].Text := APieces[N - 1].Text + AText
  else
  begin
    SetLength(APieces, N + 1);
    APieces[N].Op := AOp;
    APieces[N].Text := AText;
  end;
end;

function DiffTexts(const AOriginal, ANew: string; out APieces: TDiffPieces; out AError: string): Boolean;
var
  A, B: TArray<string>;
  Pre, Suf, N, M, I, J: Integer;
  Dp: TArray<Word>;
  W: Integer;
  Tmp: TArray<TDiffPiece>;
  Sb: string;

  function Cell(AI, AJ: Integer): Integer;
  begin
    Result := Dp[AI * W + AJ];
  end;

begin
  SetLength(APieces, 0);
  AError := '';
  A := Tokenize(Normalize(AOriginal));
  B := Tokenize(Normalize(ANew));
  Pre := 0;
  while (Pre < Length(A)) and (Pre < Length(B)) and (A[Pre] = B[Pre]) do
    Inc(Pre);
  Suf := 0;
  while (Suf < Length(A) - Pre) and (Suf < Length(B) - Pre) and
        (A[Length(A) - 1 - Suf] = B[Length(B) - 1 - Suf]) do
    Inc(Suf);
  N := Length(A) - Pre - Suf;     { differing middle of the original }
  M := Length(B) - Pre - Suf;     { ... and of the new text }
  if Int64(N) * Int64(M) > DIFF_MAX_CELLS then
  begin
    AError := 'The two texts differ too much to compare here.';
    Exit(False);
  end;

  Sb := '';
  for I := 0 to Pre - 1 do Sb := Sb + A[I];
  AddPiece(APieces, doSame, Sb);

  { longest common subsequence of the middle parts }
  W := M + 1;
  SetLength(Dp, (N + 1) * W);
  for I := N - 1 downto 0 do
    for J := M - 1 downto 0 do
      if A[Pre + I] = B[Pre + J] then
        Dp[I * W + J] := Dp[(I + 1) * W + J + 1] + 1
      else
        Dp[I * W + J] := Max(Dp[(I + 1) * W + J], Dp[I * W + J + 1]);

  I := 0;
  J := 0;
  while (I < N) or (J < M) do
  begin
    if (I < N) and (J < M) and (A[Pre + I] = B[Pre + J]) then
    begin
      AddPiece(APieces, doSame, A[Pre + I]);
      Inc(I); Inc(J);
    end
    else if (I < N) and ((J >= M) or (Cell(I + 1, J) >= Cell(I, J + 1))) then
    begin
      AddPiece(APieces, doRemoved, A[Pre + I]);
      Inc(I);
    end
    else
    begin
      AddPiece(APieces, doAdded, B[Pre + J]);
      Inc(J);
    end;
  end;

  Sb := '';
  for I := Length(A) - Suf to Length(A) - 1 do Sb := Sb + A[I];
  AddPiece(APieces, doSame, Sb);
  SetLength(Tmp, 0);
  Result := True;
end;

procedure DiffSummary(const APieces: TDiffPieces; out ARemoved, AAdded: Integer);
var
  P: TDiffPiece;
  T: string;
begin
  ARemoved := 0;
  AAdded := 0;
  for P in APieces do
    if P.Op <> doSame then
      for T in Tokenize(P.Text) do
        if Trim(T) <> '' then
          if P.Op = doRemoved then Inc(ARemoved) else Inc(AAdded);
end;

end.

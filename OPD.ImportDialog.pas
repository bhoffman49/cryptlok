unit OPD.ImportDialog;

{ Import flow:  work on temp COPIES of the chosen files -> preview -> import
  into the isolated keyring -> verify passphrases of imported private keys ->
  per-key report.  Secret key material is never displayed or logged and the
  temp copies are overwritten and deleted at the end. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ComCtrls, Vcl.Graphics, OPD.Theme, OPD.Engine;

{ Returns True when the keyring may have changed. }
function RunImportFlow(AOwner: TComponent; const AEngine: IKeyEngine;
  const AFiles: TArray<string>): Boolean;

implementation

uses
  System.IOUtils, System.Generics.Collections, System.StrUtils, OPD.PassphraseDialog,
  Winapi.Windows;

function Yes(AFlag: Boolean): string;
begin
  Result := IfThen(AFlag, 'Yes', 'No');
end;

function FmtDate(ADate: TDateTime): string;
begin
  if ADate = 0 then Result := 'Never' else Result := FormatDateTime('yyyy-mm-dd', ADate);
end;

{ ---- generic list dialog -------------------------------------------------- }

type
  TListDialog = class(TOPDForm)
  public
    Info: TLabel;
    List: TListView;
    constructor CreateList(AOwner: TComponent; const ACaption, AIntro: string;
      const AButtons: array of string; const AResults: array of TModalResult);
  end;

constructor TListDialog.CreateList(AOwner: TComponent; const ACaption, AIntro: string;
  const AButtons: array of string; const AResults: array of TModalResult);
var
  I, X: Integer;
  B: TButton;
begin
  inherited CreateNew(AOwner);
  Caption := ACaption;
  BorderStyle := bsSizeable;
  Position := poOwnerFormCenter;
  ClientWidth := 760;
  ClientHeight := 420;
  Constraints.MinWidth := 560;
  Constraints.MinHeight := 300;
  Font.Name := 'Segoe UI';
  Font.Size := 9;

  Info := TLabel.Create(Self);
  Info.Parent := Self;
  Info.SetBounds(12, 10, 736, 40);
  Info.AutoSize := False;
  Info.WordWrap := True;
  Info.Anchors := [akLeft, akTop, akRight];
  Info.Caption := AIntro;

  List := TListView.Create(Self);
  List.Parent := Self;
  List.SetBounds(12, 54, 736, 316);
  List.Anchors := [akLeft, akTop, akRight, akBottom];
  List.ViewStyle := vsReport;
  List.ReadOnly := True;
  List.RowSelect := True;
  List.GridLines := False;

  X := 748;
  for I := High(AButtons) downto 0 do
  begin
    B := TButton.Create(Self);
    B.Parent := Self;
    B.SetBounds(X - 96, 382, 96, 28);
    B.Anchors := [akRight, akBottom];
    B.Caption := AButtons[I];
    B.ModalResult := AResults[I];
    if I = 0 then B.Default := True;
    if AResults[I] = mrCancel then B.Cancel := True;
    Dec(X, 104);
  end;
end;

procedure AddCol(AList: TListView; const ACaption: string; AWidth: Integer);
var
  C: TListColumn;
begin
  C := AList.Columns.Add;
  C.Caption := ACaption;
  C.Width := AWidth;
end;

{ ---- flow ------------------------------------------------------------------ }

procedure SecureDelete(const AFile: string);
var
  Bytes: TBytes;
  Len: Int64;
begin
  try
    if not FileExists(AFile) then Exit;
    Len := TFile.GetSize(AFile);
    SetLength(Bytes, Len);  { zero-filled }
    TFile.WriteAllBytes(AFile, Bytes);
    System.SysUtils.DeleteFile(AFile);
  except
    { best effort }
  end;
end;

const
  OutcomeText: array[TImportOutcome] of string = ('New', 'Updated', 'Unchanged', 'Skipped', 'Failed');

function KeyLabel(const AItem: TImportItem): string;
begin
  Result := IfThen(AItem.UserId <> '', AItem.UserId, '0x' + Copy(AItem.KeyId, 9, 8));
end;

function RunImportFlow(AOwner: TComponent; const AEngine: IKeyEngine;
  const AFiles: TArray<string>): Boolean;
var
  Work: string;
  Copies: TArray<string>;
  Merged: TList<TKeyInfo>;
  Existing: TKeyInfoArray;
  I, J, K: Integer;
  Keys: TKeyInfoArray;
  Dlg: TListDialog;
  LI: TListItem;
  Items: TList<TImportItem>;
  Rep: TImportReport;
  Notes: TStringList;
  Passphrase: TBytes;
  Reason: string;
  Pending: TList<Integer>;
  Found: Boolean;
  Mr: TModalResult;
  It: TImportItem;
  Counts: array[TImportOutcome] of Integer;
  O: TImportOutcome;
  Key: TKeyInfo;
  Unsupported: Boolean;

  function IndexOfKey(const AKeyId: string): Integer;
  var
    N: Integer;
  begin
    Result := -1;
    for N := 0 to Merged.Count - 1 do
      if SameText(Merged[N].KeyId, AKeyId) then Exit(N);
  end;

  function ItemIndex(const AFpr: string): Integer;
  var
    N: Integer;
  begin
    Result := -1;
    for N := 0 to Items.Count - 1 do
      if SameText(Items[N].Fingerprint, AFpr) then Exit(N);
  end;

begin
  Result := False;
  Work := TPath.Combine(TPath.GetTempPath, 'OPD-' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(Work);
  SetLength(Copies, Length(AFiles));
  Merged := TList<TKeyInfo>.Create;
  Items := TList<TImportItem>.Create;
  Notes := TStringList.Create;
  Pending := TList<Integer>.Create;
  try
    try
      { 1. work only on copies }
      for I := 0 to High(AFiles) do
      begin
        Copies[I] := TPath.Combine(Work, Format('%d%s', [I, ExtractFileExt(AFiles[I])]));
        TFile.Copy(AFiles[I], Copies[I], True);
      end;

      { 2. preview }
      for I := 0 to High(Copies) do
      begin
        Keys := AEngine.PreviewFile(Copies[I]);
        for J := 0 to High(Keys) do
        begin
          K := IndexOfKey(Keys[J].KeyId);
          if K < 0 then
            Merged.Add(Keys[J])
          else if Keys[J].HasSecret then
          begin
            Key := Merged[K];
            Key.HasSecret := True;
            if Length(Key.UserIds) = 0 then Key.UserIds := Keys[J].UserIds;
            Merged[K] := Key;
          end;
        end;
      end;
      if Merged.Count = 0 then
      begin
        Unsupported := False;
        for I := 0 to High(Copies) do
          if AEngine.HasUnsupportedKey(Copies[I]) then Unsupported := True;
        if Unsupported then
          Application.MessageBox('This key cannot be imported. It was made with an algorithm that the GnuPG ' +
            'engine inside CryptLok does not support yet (for example a post-quantum key, or a version 6 key ' +
            'from a newer program).' + sLineBreak + sLineBreak +
            'The key itself is not damaged. Ask for a standard RSA or Curve25519 (ECC) key instead.',
            'Import Keys - unsupported key', MB_OK or MB_ICONWARNING)
        else
          Application.MessageBox('No OpenPGP keys were found in the selected file(s).',
            'Import Keys', MB_OK or MB_ICONINFORMATION);
        Exit;
      end;
      Existing := AEngine.ListKeys;

      Dlg := TListDialog.CreateList(AOwner, 'Import Keys',
        Format('%d key(s) found in the selected file(s). Nothing has been imported yet. ' +
          'Private keys keep their passphrase; you will be asked for it afterwards to ' +
          'confirm it works with the new keyring. Your original files are not touched ' +
          '(a temporary copy is used).', [Merged.Count]),
        ['Import', 'Cancel'], [mrOk, mrCancel]);
      try
        AddCol(Dlg.List, 'Name', 280);
        AddCol(Dlg.List, 'Key ID', 90);
        AddCol(Dlg.List, 'Type', 90);
        AddCol(Dlg.List, 'Size', 70);
        AddCol(Dlg.List, 'Created', 80);
        AddCol(Dlg.List, 'Contains', 100);
        AddCol(Dlg.List, 'Status', 100);
        for I := 0 to Merged.Count - 1 do
        begin
          LI := Dlg.List.Items.Add;
          LI.Caption := Merged[I].DisplayName + IfThen(Merged[I].DisplayEmail <> '', ' <' + Merged[I].DisplayEmail + '>', '');
          LI.SubItems.Add(Merged[I].ShortId);
          LI.SubItems.Add(Merged[I].AlgoName);
          LI.SubItems.Add(Merged[I].SizeText);
          LI.SubItems.Add(FmtDate(Merged[I].Created));
          LI.SubItems.Add(IfThen(Merged[I].HasSecret, 'Public + Private', 'Public'));
          Found := False;
          for K := 0 to High(Existing) do
            if SameText(Existing[K].KeyId, Merged[I].KeyId) then
            begin
              Found := True;
              Break;
            end;
          LI.SubItems.Add(IfThen(Found, 'In keyring', 'New'));
        end;
        if Dlg.ShowModal <> mrOk then
          Exit;
      finally
        Dlg.Free;
      end;

      { 2b. one passphrase for the private keys, used by gpg's loopback pinentry }
      Passphrase := nil;
      Mr := mrIgnore;
      for I := 0 to Merged.Count - 1 do
        if Merged[I].HasSecret then
        begin
          Mr := AskPassphrase(AOwner, 'Private keys from the selected keyring',
            'Enter the passphrase of your private key(s). It is handed to GnuPG only for ' +
            'this import and is wiped from memory afterwards. Skip to import without it.',
            True, Passphrase);
          Break;
        end;
      if Mr = mrCancel then
        Exit;

      { 3. import (public ring first so secret keys attach to their public part) }
      for I := 0 to High(Copies) do
      begin
        Rep := AEngine.ImportFile(Copies[I], Passphrase);
        Result := True;
        for J := 0 to High(Rep.Items) do
        begin
          K := ItemIndex(Rep.Items[J].Fingerprint);
          if K < 0 then
            Items.Add(Rep.Items[J])
          else
          begin
            It := Items[K];
            if Rep.Items[J].SecretImported then It.SecretImported := True;
            if (It.Outcome in [ioUnchanged]) and (Rep.Items[J].Outcome <> ioUnchanged) then
              It.Outcome := Rep.Items[J].Outcome;
            if It.UserId = '' then It.UserId := Rep.Items[J].UserId;
            if (Rep.Items[J].Detail <> '') and (Pos(Rep.Items[J].Detail, It.Detail) = 0) then
              It.Detail := IfThen(It.Detail = '', '', It.Detail + '; ') + Rep.Items[J].Detail;
            Items[K] := It;
          end;
        end;
        for J := 0 to High(Rep.Notes) do
          if Notes.IndexOf(Rep.Notes[J]) < 0 then Notes.Add(Rep.Notes[J]);
      end;

      { keys the preview listed that gpg did not report at all }
      for I := 0 to Merged.Count - 1 do
        if ItemIndex(Merged[I].Fingerprint) < 0 then
        begin
          FillChar(It, SizeOf(It), 0);
          It.Fingerprint := Merged[I].Fingerprint;
          It.KeyId := Merged[I].KeyId;
          It.UserId := Merged[I].DisplayName;
          It.Outcome := ioSkipped;
          It.Detail := 'gpg did not import this key (see notes below)';
          for J := 0 to High(Copies) do
            if AEngine.HasUnsupportedKey(Copies[J]) then
              It.Detail := 'uses an algorithm this GnuPG does not support yet (post-quantum or version 6 key)';
          Items.Add(It);
        end;

      { names for keys gpg did not report a user ID for (unchanged keys) }
      Existing := AEngine.ListKeys;
      for I := 0 to Items.Count - 1 do
        if Items[I].UserId = '' then
          for K := 0 to High(Existing) do
            if SameText(Existing[K].Fingerprint, Items[I].Fingerprint) then
            begin
              It := Items[I];
              It.UserId := Existing[K].DisplayName +
                IfThen(Existing[K].DisplayEmail <> '', ' <' + Existing[K].DisplayEmail + '>', '');
              Items[I] := It;
              Break;
            end;

      { 4. passphrase verification of imported private keys }
      for I := 0 to Items.Count - 1 do
        if Items[I].SecretImported then Pending.Add(I);
      if Pending.Count > 0 then
      begin
        { first: the passphrase already given is tried against every private key }
        if Length(Passphrase) > 0 then
        begin
          for I := Pending.Count - 1 downto 0 do
          begin
            It := Items[Pending[I]];
            if AEngine.CheckPassphrase(It.Fingerprint, Passphrase, Reason) then
            begin
              It.PassphraseChecked := True;
              It.Detail := It.Detail + '; passphrase verified';
              Items[Pending[I]] := It;
              Pending.Delete(I);
            end;
          end;
          WipeBytes(Passphrase);
        end;
        Mr := mrOk;
        { then each remaining key on its own }
        if Mr <> mrCancel then
          for I := 0 to Pending.Count - 1 do
          begin
            It := Items[Pending[I]];
            repeat
              Mr := AskPassphrase(AOwner, KeyLabel(It) + '  (' + '0x' + Copy(It.KeyId, 9, 8) + ')',
                'Enter the passphrase for this private key (the earlier one did not fit).',
                True, Passphrase);
              if Mr <> mrOk then Break;
              try
                if AEngine.CheckPassphrase(It.Fingerprint, Passphrase, Reason) then
                begin
                  It.PassphraseChecked := True;
                  It.Detail := It.Detail + '; passphrase verified';
                  Break;
                end;
                It.Detail := It.Detail + '; passphrase not accepted (' + Reason + ')';
                Application.MessageBox(PChar('That passphrase was not accepted: ' + Reason + '.'),
                  'Passphrase', MB_OK or MB_ICONWARNING);
              finally
                WipeBytes(Passphrase);
              end;
            until False;
            if not It.PassphraseChecked then
              It.Detail := It.Detail + IfThen(Pos('not accepted', It.Detail) > 0, '',
                '; passphrase NOT verified (skipped)') + ' - key stays locked until used';
            Items[Pending[I]] := It;
            if Mr = mrCancel then Break;
          end
        else
          for I := 0 to Pending.Count - 1 do
          begin
            It := Items[Pending[I]];
            It.Detail := It.Detail + '; passphrase NOT verified (cancelled)';
            Items[Pending[I]] := It;
          end;
      end;

      { 5. report }
      for O := Low(O) to High(O) do Counts[O] := 0;
      for I := 0 to Items.Count - 1 do Inc(Counts[Items[I].Outcome]);
      Dlg := TListDialog.CreateList(AOwner, 'Import Results',
        Format('%d new, %d updated, %d unchanged, %d skipped/failed.',
          [Counts[ioNew], Counts[ioUpdated], Counts[ioUnchanged],
           Counts[ioSkipped] + Counts[ioFailed]]) +
        IfThen(Notes.Count > 0, '  gpg notes: ' + Notes.CommaText, ''),
        ['Close'], [mrOk]);
      try
        Dlg.ClientWidth := 1100;
        AddCol(Dlg.List, 'Key', 250);
        AddCol(Dlg.List, 'Key ID', 90);
        AddCol(Dlg.List, 'Contains', 100);
        AddCol(Dlg.List, 'Result', 90);
        AddCol(Dlg.List, 'Details', 640);
        for I := 0 to Items.Count - 1 do
        begin
          It := Items[I];
          LI := Dlg.List.Items.Add;
          LI.Caption := KeyLabel(It);
          LI.SubItems.Add('0x' + Copy(It.KeyId, 9, 8));
          LI.SubItems.Add(IfThen(It.SecretImported, 'Public + Private', 'Public'));
          LI.SubItems.Add(OutcomeText[It.Outcome]);
          LI.SubItems.Add(It.Detail);
        end;
        Dlg.ShowModal;
      finally
        Dlg.Free;
      end;
    except
      on E: Exception do
        Application.MessageBox(PChar('Import failed: ' + E.Message), 'Import Keys',
          MB_OK or MB_ICONERROR);
    end;
  finally
    for I := 0 to High(Copies) do
      if Copies[I] <> '' then SecureDelete(Copies[I]);
    try
      TDirectory.Delete(Work, True);
    except
    end;
    Merged.Free;
    Items.Free;
    Notes.Free;
    Pending.Free;
    WipeBytes(Passphrase);
  end;
end;

end.

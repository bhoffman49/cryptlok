unit OPD.PhotoId;

{ Turns any picture (PNG, JPEG, BMP, GIF, TIFF) into a JPEG that suits a photo ID: at most 120 x 144 pixels
  (the size the classic PGP help recommends) and small enough that GnuPG does not ask "this JPEG is really
  large".  Pictures are never enlarged. }

interface

uses
  System.SysUtils, System.Classes;

const
  PHOTO_MAX_W = 120;
  PHOTO_MAX_H = 144;
  PHOTO_MAX_BYTES = 6000;       { gpg warns above 6144 bytes }

function PrepareJpeg(const AFile: string; out AJpeg: TBytes; out AError: string): Boolean;

implementation

uses
  Winapi.Windows, System.Math, Vcl.Graphics, Vcl.Imaging.jpeg;

function PrepareJpeg(const AFile: string; out AJpeg: TBytes; out AError: string): Boolean;
var
  Src: TWICImage;
  Bmp: TBitmap;
  J: TJPEGImage;
  MS: TMemoryStream;
  Scale: Double;
  W, H, Q: Integer;
begin
  Result := False;
  AError := '';
  SetLength(AJpeg, 0);
  Src := TWICImage.Create;
  try
    try
      Src.LoadFromFile(AFile);
    except
      on E: Exception do
      begin
        AError := 'That file could not be read as a picture (' + E.Message + ')';
        Exit;
      end;
    end;
    if (Src.Width < 1) or (Src.Height < 1) then
    begin
      AError := 'The picture is empty';
      Exit;
    end;
    Scale := Min(1.0, Min(PHOTO_MAX_W / Src.Width, PHOTO_MAX_H / Src.Height));
    W := Max(1, Round(Src.Width * Scale));
    H := Max(1, Round(Src.Height * Scale));
    Bmp := TBitmap.Create;
    try
      Bmp.PixelFormat := pf24bit;
      Bmp.SetSize(W, H);
      Bmp.Canvas.Brush.Color := clWhite;      { transparent areas become white }
      Bmp.Canvas.FillRect(Rect(0, 0, W, H));
      SetStretchBltMode(Bmp.Canvas.Handle, HALFTONE);
      Bmp.Canvas.StretchDraw(Rect(0, 0, W, H), Src);
      J := TJPEGImage.Create;
      MS := TMemoryStream.Create;
      try
        Q := 90;
        repeat
          MS.Clear;
          J.CompressionQuality := Q;
          J.Assign(Bmp);
          J.Compress;
          J.SaveToStream(MS);
          Dec(Q, 10);
        until (MS.Size <= PHOTO_MAX_BYTES) or (Q < 30);
        if MS.Size > PHOTO_MAX_BYTES then
        begin
          AError := 'The picture is too detailed to fit in a photo ID even when reduced';
          Exit;
        end;
        SetLength(AJpeg, MS.Size);
        MS.Position := 0;
        MS.ReadBuffer(AJpeg[0], MS.Size);
        Result := True;
      finally
        MS.Free;
        J.Free;
      end;
    finally
      Bmp.Free;
    end;
  finally
    Src.Free;
  end;
end;

end.

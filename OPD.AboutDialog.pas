unit OPD.AboutDialog;

{ About box: dark panel with the shield on the left, product text on the right. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  Vcl.Graphics, Vcl.Imaging.pngimage, Winapi.ShellAPI, OPD.Theme;

procedure ShowAbout(AOwner: TComponent; const AName, AVersion, ADetails: string);

implementation

uses
  System.Math;

type
  TShieldPanel = class(TGraphicControl)
  private
    FArt: TBitmap;
    procedure BuildArt;
  protected
    procedure Paint; override;
  public
    destructor Destroy; override;
  end;

destructor TShieldPanel.Destroy;
begin
  FArt.Free;
  inherited;
end;

{ Renders the gradient and the shield into a memory bitmap once, so painting is a plain copy. }
procedure TShieldPanel.BuildArt;
var
  Y, W, H, X0, Y0: Integer;
  F: Double;
  Png: TPngImage;
begin
  FArt := TBitmap.Create;
  FArt.PixelFormat := pf24bit;
  FArt.SetSize(Width, Height);
  { a designed banner (about-banner.png, 19:32) fills the whole panel when it is present }
  try
    Png := LoadPng('ABOUT_BANNER');
    try
      FArt.Canvas.Brush.Color := RGB(40, 42, 48);
      FArt.Canvas.FillRect(Rect(0, 0, Width, Height));
      SetStretchBltMode(FArt.Canvas.Handle, HALFTONE);
      FArt.Canvas.StretchDraw(Rect(0, 0, Width, Height), Png);
    finally
      Png.Free;
    end;
    Exit;
  except
    { none: draw the gradient and the shield }
  end;
  for Y := 0 to Height - 1 do
  begin
    F := Y / Max(Height, 1);
    FArt.Canvas.Pen.Color := RGB(Round(52 - 26 * F), Round(54 - 26 * F), Round(62 - 30 * F));
    FArt.Canvas.MoveTo(0, Y);
    FArt.Canvas.LineTo(Width, Y);
  end;
  try
    Png := LoadPng('ABOUT_SHIELD');
    try
      W := Min(Width - DpiScale(24), DpiScale(150));
      H := Round(W * Png.Height / Max(Png.Width, 1));
      X0 := (Width - W) div 2;
      Y0 := (Height - H) div 2;
      SetStretchBltMode(FArt.Canvas.Handle, HALFTONE);
      FArt.Canvas.StretchDraw(Rect(X0, Y0, X0 + W, Y0 + H), Png);
    finally
      Png.Free;
    end;
  except
    { no shield resource: the gradient alone }
  end;
end;

procedure TShieldPanel.Paint;
begin
  if (FArt = nil) or (FArt.Width <> Width) or (FArt.Height <> Height) then
  begin
    FreeAndNil(FArt);
    BuildArt;
  end;
  Canvas.Draw(0, 0, FArt);
end;

type
  TLinkHelper = class
    class procedure Open(Sender: TObject);
  end;

class procedure TLinkHelper.Open(Sender: TObject);
begin
  ShellExecute(0, 'open', 'https://www.level103.com', nil, nil, SW_SHOWNORMAL);
end;

procedure ShowAbout(AOwner: TComponent; const AName, AVersion, ADetails: string);
var
  F: TOPDForm;
  P: TShieldPanel;
  L: TLabel;
  M: TMemo;
  B: TButton;
begin
  F := TOPDForm.CreateNew(AOwner);
  try
    F.Caption := 'About ' + AName;
    F.BorderStyle := bsDialog;
    F.Position := poScreenCenter;
    F.ClientWidth := 560;
    F.ClientHeight := 320;
    F.Font.Name := UiFontName;
    F.Font.Size := 9;

    P := TShieldPanel.Create(F);
    P.Parent := F;
    P.SetBounds(0, 0, 190, 320);

    L := TLabel.Create(F); L.Parent := F; L.SetBounds(212, 20, 330, 32);
    L.Caption := AName; L.Font.Size := 20; L.Font.Style := [fsBold];
    L.Transparent := False; L.Color := clBtnFace;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(214, 56, 330, 18);
    L.Caption := 'OpenPGP Encryption Suite  -  version ' + AVersion;
    L.Font.Color := clGrayText; L.Transparent := False; L.Color := clBtnFace;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(214, 84, 330, 54);
    L.AutoSize := False; L.WordWrap := True;
    L.Transparent := False; L.Color := clBtnFace;
    L.Caption := 'Keys, zip archives, clipboard encryption and encrypted disks for Windows, ' +
      'powered by GnuPG and VeraCrypt.';
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(214, 140, 330, 18);
    L.Transparent := False; L.Color := clBtnFace; L.Font.Size := 10;
    L.Caption := 'Developer: Brian Hoffman';
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(214, 162, 60, 18);
    L.Transparent := False; L.Color := clBtnFace; L.Font.Size := 10;
    L.Caption := 'Website:';
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(274, 162, 260, 18);
    L.Transparent := False; L.Color := clBtnFace; L.Font.Size := 10;
    L.Font.Color := RGB(0, 102, 204); L.Font.Style := [fsUnderline];
    L.Cursor := crHandPoint; L.Caption := 'www.level103.com';
    L.OnClick := TLinkHelper.Open;
    L := TLabel.Create(F); L.Parent := F; L.SetBounds(214, 188, 330, 18);
    L.Transparent := False; L.Color := clBtnFace; L.Font.Color := clGrayText;
    L.Caption := 'Free for noncommercial use (PolyForm Noncommercial).';

    M := TMemo.Create(F); M.Parent := F; M.SetBounds(214, 214, 330, 56);
    M.ReadOnly := True; M.ScrollBars := ssVertical; M.WordWrap := True;
    M.Font.Size := 8; M.Text := ADetails;

    B := TButton.Create(F); B.Parent := F; B.SetBounds(458, 278, 84, 28);
    B.Caption := 'OK'; B.ModalResult := mrOk; B.Default := True; B.Cancel := True;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.

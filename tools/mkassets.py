# Generates ORIGINAL look-alike icons for CryptLok (no vendor artwork).
# Run:  python tools\mkassets.py   -> assets\*.png, assets\app.ico, CryptLok.Assets.rc
import os, math
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'assets')
os.makedirs(OUT, exist_ok=True)
SIZES = [16, 20, 24, 32]
S = 8  # supersample

BLUE = (52, 98, 190, 255)
BLUE_L = (110, 150, 225, 255)
SILVER = (196, 202, 210, 255)
SILVER_D = (120, 128, 140, 255)
GOLD = (222, 176, 60, 255)
GREEN = (60, 170, 70, 255)
RED = (200, 50, 45, 255)
GREY = (150, 150, 150, 255)
WHITE = (255, 255, 255, 255)
DARK = (40, 44, 52, 255)


def canvas(n):
    return Image.new('RGBA', (n * S, n * S), (0, 0, 0, 0))


def done(img, n):
    return img.resize((n, n), Image.LANCZOS)


def key_shape(n, head, body, scale=1.0):
    """Draw a diagonal key on a transparent layer (size n*S)."""
    N = n * S
    lay = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    # horizontal key centred, head left
    cy = N / 2
    hr = N * 0.20 * scale
    hx = N * 0.24
    L = N * 0.80
    sh = N * 0.07 * scale
    d.rounded_rectangle((hx, cy - sh, hx + L * 0.82, cy + sh), radius=sh, fill=body)
    # teeth
    for i, tl in enumerate((0.16, 0.10)):
        tx = hx + L * (0.50 + i * 0.17)
        d.rectangle((tx, cy, tx + N * 0.06, cy + N * tl * scale), fill=body)
    d.ellipse((hx - hr, cy - hr, hx + hr, cy + hr), fill=head, outline=DARK, width=max(1, S // 2))
    d.ellipse((hx - hr * 0.35, cy - hr * 0.35, hx + hr * 0.35, cy + hr * 0.35), fill=(0, 0, 0, 0))
    return lay


def rot(lay, ang):
    return lay.rotate(ang, resample=Image.BICUBIC)


def ic_keypair(n):
    img = canvas(n)
    a = rot(key_shape(n, BLUE, SILVER), -45)
    b = rot(key_shape(n, SILVER, SILVER_D, 0.9), -25)
    img.alpha_composite(b, (int(n * S * 0.10), int(n * S * 0.06)))
    img.alpha_composite(a, (-int(n * S * 0.04), int(n * S * 0.02)))
    return done(img, n)


def ic_pubkey(n):
    img = canvas(n)
    img.alpha_composite(rot(key_shape(n, SILVER, SILVER_D), -45))
    return done(img, n)


def ic_expired(n):
    img = canvas(n)
    img.alpha_composite(rot(key_shape(n, GREY, (170, 170, 170, 255)), -45))
    d = ImageDraw.Draw(img)
    N = n * S
    r = N * 0.26
    cx, cy = N * 0.72, N * 0.72
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=WHITE, outline=RED, width=S)
    d.line((cx, cy, cx, cy - r * 0.65), fill=RED, width=max(S // 2, 3))
    d.line((cx, cy, cx + r * 0.5, cy), fill=RED, width=max(S // 2, 3))
    return done(img, n)


def ic_revoked(n):
    img = canvas(n)
    img.alpha_composite(rot(key_shape(n, (230, 120, 110, 255), (170, 170, 170, 255)), -45))
    d = ImageDraw.Draw(img)
    N = n * S
    d.ellipse((N * 0.55, N * 0.55, N * 0.97, N * 0.97), fill=RED)
    d.line((N * 0.64, N * 0.64, N * 0.88, N * 0.88), fill=WHITE, width=S)
    d.line((N * 0.88, N * 0.64, N * 0.64, N * 0.88), fill=WHITE, width=S)
    return done(img, n)


def ic_envelope(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .08, N * .22, N * .92, N * .78), radius=N * .05, fill=(245, 245, 245, 255), outline=SILVER_D, width=S)
    d.line((N * .1, N * .26, N * .5, N * .55, N * .9, N * .26), fill=SILVER_D, width=S)
    return done(img, n)


def ic_photo(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .15, N * .1, N * .85, N * .9), radius=N * .06, fill=(235, 240, 250, 255), outline=SILVER_D, width=S)
    d.ellipse((N * .38, N * .22, N * .62, N * .46), fill=BLUE)
    d.pieslice((N * .26, N * .5, N * .74, N * 1.0), 180, 360, fill=BLUE)
    return done(img, n)


def ic_subkey(n):
    img = canvas(n)
    img.alpha_composite(rot(key_shape(n, GOLD, SILVER, 0.8), -45))
    return done(img, n)


def ic_check(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.ellipse((N * .06, N * .06, N * .94, N * .94), fill=GREEN)
    d.line((N * .27, N * .52, N * .44, N * .70, N * .75, N * .32), fill=WHITE, width=int(N * .13), joint='curve')
    return done(img, n)


def ic_dash(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.ellipse((N * .06, N * .06, N * .94, N * .94), fill=(225, 225, 225, 255), outline=GREY, width=S)
    d.line((N * .27, N * .5, N * .73, N * .5), fill=GREY, width=int(N * .12))
    return done(img, n)


# --- sidebar section icons -------------------------------------------------
def ic_sec_keys(n):
    return ic_keypair(n)


def ic_sec_msg(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .05, N * .2, N * .95, N * .8), radius=N * .06, fill=(240, 240, 240, 255), outline=SILVER_D, width=S)
    d.line((N * .07, N * .25, N * .5, N * .58, N * .93, N * .25), fill=SILVER_D, width=S)
    d.ellipse((N * .55, N * .5, N * .95, N * .92), fill=GOLD, outline=DARK, width=S // 2)
    return done(img, n)


def ic_sec_zip(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .2, N * .06, N * .8, N * .94), radius=N * .05, fill=(245, 245, 245, 255), outline=SILVER_D, width=S)
    for i in range(7):
        y = N * (.12 + i * .075)
        d.rectangle((N * .46 if i % 2 == 0 else N * .5, y, N * .5 if i % 2 == 0 else N * .54, y + N * .04), fill=BLUE)
    d.rounded_rectangle((N * .42, N * .66, N * .58, N * .86), radius=N * .03, fill=GOLD, outline=DARK, width=S // 2)
    return done(img, n)


def ic_sec_disk(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .05, N * .5, N * .95, N * .88), radius=N * .08, fill=SILVER, outline=SILVER_D, width=S)
    d.ellipse((N * .76, N * .62, N * .86, N * .72), fill=GREEN)
    d.rounded_rectangle((N * .2, N * .12, N * .62, N * .56), radius=N * .05, fill=BLUE, outline=DARK, width=S // 2)
    d.arc((N * .3, N * .0, N * .52, N * .3), 180, 360, fill=SILVER_D, width=int(N * .05))
    return done(img, n)


def ic_sec_viewer(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .12, N * .06, N * .74, N * .94), radius=N * .05, fill=(245, 245, 245, 255), outline=SILVER_D, width=S)
    for i in range(5):
        d.line((N * .22, N * (.2 + i * .13), N * .64, N * (.2 + i * .13)), fill=SILVER_D, width=S // 2)
    d.ellipse((N * .5, N * .5, N * .88, N * .88), fill=(220, 235, 255, 200), outline=BLUE, width=int(N * .06))
    d.line((N * .84, N * .84, N * .98, N * .98), fill=BLUE, width=int(N * .08))
    return done(img, n)


def ic_sec_share(n):
    img = canvas(n)
    d = ImageDraw.Draw(img)
    N = n * S
    d.rounded_rectangle((N * .05, N * .22, N * .95, N * .86), radius=N * .06, fill=(240, 200, 100, 255), outline=(170, 130, 40, 255), width=S)
    d.rounded_rectangle((N * .05, N * .14, N * .45, N * .32), radius=N * .04, fill=(240, 200, 100, 255), outline=(170, 130, 40, 255), width=S)
    d.rounded_rectangle((N * .38, N * .45, N * .62, N * .72), radius=N * .04, fill=BLUE, outline=DARK, width=S // 2)
    d.arc((N * .41, N * .3, N * .59, N * .55), 180, 360, fill=DARK, width=int(N * .05))
    return done(img, n)


ICONS = {
    'KEYPAIR': ic_keypair, 'PUBKEY': ic_pubkey, 'EXPIRED': ic_expired, 'REVOKED': ic_revoked,
    'ENVELOPE': ic_envelope, 'PHOTO': ic_photo, 'SUBKEY': ic_subkey, 'CHECK': ic_check, 'DASH': ic_dash,
    'SEC_KEYS': ic_sec_keys, 'SEC_MSG': ic_sec_msg, 'SEC_ZIP': ic_sec_zip, 'SEC_DISK': ic_sec_disk,
    'SEC_VIEWER': ic_sec_viewer, 'SEC_SHARE': ic_sec_share,
}

# designed icons (Axialis pack in 'program icons') replace the generated sidebar pictures
DESIGNED = {
    'SEC_KEYS': 'secukey.ico', 'SEC_MSG': 'securefile.ico', 'SEC_ZIP': 'zip.ico',
    'SEC_DISK': 'secvault.ico', 'SEC_VIEWER': 'armorfile2.ico', 'SEC_SHARE': 'clvault.ico',
}


def designed(name, n):
    f = DESIGNED.get(name)
    if not f:
        return None
    path = os.path.join(ROOT, 'program icons', f)
    if not os.path.exists(path):
        return None
    ico = Image.open(path)
    best = max(ico.ico.sizes(), key=lambda s: s[0])
    img = ico.ico.getimage(best).convert('RGBA')
    return img.resize((n, n), Image.LANCZOS)


rc = []
for name, fn in ICONS.items():
    for n in SIZES:
        fname = 'ic_%s_%d.png' % (name.lower(), n)
        (designed(name, n) or fn(n)).save(os.path.join(OUT, fname))
        rc.append('IC_%s_%d RCDATA "assets\\\\%s"' % (name, n, fname))

# header band key-ring picture (large)
big = Image.open(os.path.join(ROOT, 'program icons', 'keyring.png')).convert('RGBA').resize((48, 48), Image.LANCZOS)
big.save(os.path.join(OUT, 'ic_band_64.png'))
rc.append('IC_BAND_64 RCDATA "assets\\\\ic_band_64.png"')
Image.open(os.path.join(ROOT, 'program icons', 'keyring.png')).convert('RGBA').resize((112, 112), Image.LANCZOS).save(os.path.join(OUT, 'ic_band_112.png'))
rc.append('IC_BAND_112 RCDATA "assets\\\\ic_band_112.png"')


def app_icon(n):
    N = n * S
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    g = Image.new('RGBA', (N, N))
    px = g.load()
    for y in range(N):
        t = y / (N - 1)
        c = (int(96 + (40 - 96) * t), int(140 + (80 - 140) * t), int(225 + (170 - 225) * t), 255)
        for x in range(N):
            px[x, y] = c
    m = Image.new('L', (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, N - 1, N - 1), radius=int(N * .2), fill=255)
    img.paste(g, (0, 0), m)
    d = ImageDraw.Draw(img)
    # padlock
    d.arc((N * .3, N * .12, N * .7, N * .56), 180, 360, fill=WHITE, width=int(N * .09))
    d.line((N * .31, N * .34, N * .31, N * .46), fill=WHITE, width=int(N * .09))
    d.line((N * .69, N * .34, N * .69, N * .46), fill=WHITE, width=int(N * .09))
    d.rounded_rectangle((N * .2, N * .45, N * .8, N * .88), radius=N * .07, fill=WHITE)
    d.ellipse((N * .43, N * .55, N * .57, N * .69), fill=BLUE)
    d.rectangle((N * .47, N * .63, N * .53, N * .79), fill=BLUE)
    return img.resize((n, n), Image.LANCZOS)


# program and tray icon: the hand-made padlock when present (Brian's own art), else the drawn one
_padlock = os.path.join(ROOT, 'program icons', 'padlock.ico')
if os.path.exists(_padlock):
    import shutil as _sh
    _dst = os.path.join(OUT, 'app.ico')
    if not (os.path.exists(_dst) and open(_dst, 'rb').read() == open(_padlock, 'rb').read()):
        _sh.copyfile(_padlock, _dst)
    _big = max((Image.open(_padlock).ico.getimage(s) for s in Image.open(_padlock).ico.sizes()), key=lambda im: im.size[0])
    _big = _big.convert('RGBA')
    _big.resize((72, 72), Image.LANCZOS).save(os.path.join(OUT, 'about-72.png'))
    # tray: the padlock cropped to its edges, so it fills the tray slot like the other icons
    _tight = _big.crop(_big.getbbox())
    _side = max(_tight.size)
    _sq = Image.new('RGBA', (_side, _side), (0, 0, 0, 0))
    _sq.paste(_tight, ((_side - _tight.size[0]) // 2, (_side - _tight.size[1]) // 2))
    _sizes = [48, 40, 32, 24, 20, 16]
    _frames = [_sq.resize((n, n), Image.LANCZOS) for n in _sizes]
    _frames[0].save(os.path.join(OUT, 'tray.ico'), sizes=[(n, n) for n in _sizes], append_images=_frames[1:])
    rc.append('TRAYICON ICON "assets\\\\tray.ico"')
else:
    icons = [app_icon(n) for n in (256, 48, 32, 24, 16)]
    icons[0].save(os.path.join(OUT, 'app.ico'), sizes=[(256, 256), (48, 48), (32, 32), (24, 24), (16, 16)], append_images=icons[1:])
    app_icon(72).save(os.path.join(OUT, 'about-72.png'))
rc.append('ABOUT_ICON RCDATA "assets\\\\about-72.png"')

# wizard banner (designed by hand; copied in when present)
import shutil

def copy_if_changed(src, dst):
    """copy unless dst already holds the same bytes (a file Explorer has open cannot be rewritten)"""
    if os.path.exists(dst) and open(src, 'rb').read() == open(dst, 'rb').read():
        return
    shutil.copyfile(src, dst)

_banner = os.path.join(ROOT, 'program icons', 'banner.png')
if os.path.exists(_banner):
    copy_if_changed(_banner, os.path.join(OUT, 'banner.png'))
    rc.append('WIZ_BANNER RCDATA "assets\\\\banner.png"')

_abanner = os.path.join(ROOT, 'program icons', 'about-banner.png')
if os.path.exists(_abanner):
    copy_if_changed(_abanner, os.path.join(OUT, 'about-banner.png'))
    rc.append('ABOUT_BANNER RCDATA "assets\\\\about-banner.png"')

_shield = os.path.join(ROOT, 'program icons', 'shield-hollow-512.png')
if os.path.exists(_shield):
    Image.open(_shield).convert('RGBA').resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, 'about-shield.png'))
    rc.append('ABOUT_SHIELD RCDATA "assets\\\\about-shield.png"')

# self-decrypting archive: default icon and the stub program (built first by build.cmd)
_sdaico = os.path.join(ROOT, 'program icons', 'sda.ico')
if os.path.exists(_sdaico):
    copy_if_changed(_sdaico, os.path.join(OUT, 'sda.ico'))
    rc.append('SDA_ICON RCDATA "assets\\\\sda.ico"')
rc.append('SDA_STUB RCDATA "out\\\\CryptLokSda.exe"')

_zipico = os.path.join(ROOT, 'program icons', 'zip.ico')
if os.path.exists(_zipico):
    copy_if_changed(_zipico, os.path.join(OUT, 'zipfile.ico'))
    rc.append('101 ICON "assets\\\\zipfile.ico"')

# detached signature file (.sig): a page with a hand-written signature and a green "verified" badge
def sig_icon(n):
    S = 1024
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    navy = (47, 74, 114, 255)
    # page with a folded corner
    d.polygon([(170, 70), (640, 70), (860, 290), (860, 954), (170, 954)], fill=(244, 247, 252, 255), outline=navy)
    d.line([(170, 70), (640, 70), (860, 290), (860, 954), (170, 954), (170, 70)], fill=navy, width=26, joint='curve')
    d.polygon([(640, 70), (640, 290), (860, 290)], fill=(205, 216, 234, 255))
    d.line([(640, 70), (640, 290), (860, 290)], fill=navy, width=26, joint='curve')
    # text lines
    for y, x2 in ((380, 740), (470, 740), (560, 600)):
        d.line([(260, y), (x2, y)], fill=(150, 168, 198, 255), width=30)
    # signature scrawl and underline
    pts = [(250, 760), (300, 690), (340, 760), (380, 700), (430, 770), (480, 700), (520, 760), (580, 690), (640, 720)]
    d.line(pts, fill=(25, 40, 80, 255), width=26, joint='curve')
    d.line([(240, 840), (700, 840)], fill=(25, 40, 80, 255), width=14)
    # green check badge
    cx, cy, r = 760, 790, 190
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(46, 158, 79, 255), outline=(255, 255, 255, 255), width=22)
    d.line([(cx - 90, cy + 5), (cx - 25, cy + 75), (cx + 100, cy - 70)], fill=(255, 255, 255, 255), width=44, joint='curve')
    return im.resize((n, n), Image.LANCZOS)

# the designed icon (Axialis pack, 'program icons\sigfile.ico') wins; the generated one is the fallback
_sigico = os.path.join(ROOT, 'program icons', 'sigfile.ico')
if os.path.exists(_sigico):
    copy_if_changed(_sigico, os.path.join(OUT, 'sigfile.ico'))
else:
    _sigs = [sig_icon(n) for n in (256, 48, 32, 24, 16)]
    _sigs[0].save(os.path.join(OUT, 'sigfile.ico'), sizes=[(256, 256), (48, 48), (32, 32), (24, 24), (16, 16)], append_images=_sigs[1:])
rc.append('102 ICON "assets\\\\sigfile.ico"')

with open(os.path.join(ROOT, 'CryptLok.Assets.rc'), 'w') as f:
    f.write('MAINICON ICON "assets\\\\app.ico"\n')
    f.write('\n'.join(rc) + '\n')
    f.write('1 24 "CryptLok.manifest"\n')
    f.write('''1 VERSIONINFO
FILEVERSION 0,3,0,0
PRODUCTVERSION 0,3,0,0
FILEFLAGSMASK 0x3fL
FILEOS 0x4L
FILETYPE 0x1L
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Level103"
      VALUE "FileDescription", "CryptLok - OpenPGP Encryption Suite"
      VALUE "FileVersion", "0.3.0.0"
      VALUE "InternalName", "CryptLok"
      VALUE "LegalCopyright", "Copyright (C) 2026 Brian Hoffman"
      VALUE "OriginalFilename", "CryptLok.exe"
      VALUE "ProductName", "CryptLok"
      VALUE "ProductVersion", "0.3.0.0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 1200
  END
END
''')
print('ok', len(rc), 'resources')

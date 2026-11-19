# Changelog

## 0.2.0 — 2026-11-18

**Key Management** (new section in the sidebar)
- **Backup Keyring:** saves your public and private keys, trust settings and CryptLok settings to one `.zip` file
  (private keys stay protected by their passphrases). **Restore from a Backup** unpacks a backup into a folder you
  choose and switches CryptLok to it; your current keyring is left untouched.
- **Keyring Location:** keep the keyring in any folder you choose, for example on another drive or a USB stick.
  CryptLok copies it, checks the copy with GnuPG, restarts with it and offers to remove the old copy. A folder that
  already holds a CryptLok keyring is used as it is. If a keyring on a removable drive is not connected at start,
  CryptLok asks you to connect it instead of opening an empty keyring.

**Passphrase caching** (Tools > Options > Passphrase), as in the classic PGP tray
- Do not cache (default), cache while you are logged on, or cache for 2 minutes up to 8 hours.
- Only passphrases that worked are kept, encrypted in memory inside CryptLok and forgotten when it exits.
  Used for decrypting, signing, Zip, Viewer, signing files and keys, and mounting disks; changing a passphrase,
  photos and preferences always ask. **Clear Passphrase Cache** in the tray menu forgets them at once.

**Look**
- New padlock program and tray icon.

## 0.1.0 — 2026-11-17, first public release

CryptLok is my attempt to bring back the look and feel of the legacy PGP Desktop suite, built on the free GnuPG
engine (GnuPG 2.5 is included in the installer). Independent project, not affiliated with Broadcom/Symantec.

**Keys**
- Key list with validity, trust, size, key ID and dates; Key Properties with photo IDs and preferred algorithms.
- New key pairs, import (including classic `pubring.pkr` / `secring.skr`), export, delete, trust levels.
- Sign Key certifies someone else's key with one of yours (exportable or local only); Key Properties > Signatures
  lists who has signed a key and whether each signature checks out.
- Edit your own key's preferences (ciphers, hashes, compression, keyserver).
- Default key and Master Keys (keys added to everything you encrypt) in Tools > Options.
- Keys made with algorithms GnuPG cannot read yet (post-quantum / version 6 keys) get a clear message instead of a
  silent failure.

**Clipboard and tray**
- Encrypt, Sign, Encrypt & Sign, Decrypt & Verify from the tray. Decrypted text opens in a Text Viewer window and is
  never put back on the clipboard.
- The X button keeps CryptLok running in the tray (can be switched off in Tools > Options > General).
- Optional `Version:` and `Comment:` lines in the PGP blocks CryptLok makes.

**Files**
- Zip wizard: encrypt files and folders to a `.pgp` archive with keys or a passphrase, optionally signed; Sign Only.
- Self-decrypting archives (`.exe`) that open on any Windows PC with a passphrase.
- Viewer for encrypted/signed text, with signature check and Compare with original.
- Detached signatures: Tools > Sign a File (`.sig` or `.asc`), and double-click a `.sig` to verify it.
- Shredder and Wipe Free Space.

**Disks**
- Encrypted virtual disks on the installed VeraCrypt, unlocked with your GnuPG key (VeraCrypt is not included).
  Large disks (tested with 200 GB) are written in full; CryptLok shows the elapsed time and checks free space first.

**Windows integration**
- Installer option "Add CryptLok to Explorer": right-click Encrypt, Shred, Sign and Verify, plus a `.sig` file type with
  its own icon. Per user, no system-wide changes; the uninstaller removes it again. Can also be turned on or off later
  in Tools > Explorer Integration.

**Known limits**
- OpenPGP version 6 / RFC 9580 keys (for example post-quantum keys from newer programs) cannot be imported; GnuPG does
  not support them yet.
- No email-client plug-in; use the clipboard with any mail program.

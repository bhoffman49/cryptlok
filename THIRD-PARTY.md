# Third-party software

## GnuPG (bundled, in the `GnuPG` folder of the installed program)

CryptLok does its OpenPGP work by running the GnuPG programs (`gpg.exe`, `gpg-agent.exe` and the
files that go with them) as separate child processes, using its own private key folder
(`%USERPROFILE%\.cryptlok\gnupg`). It does not link GnuPG into its own code.

- Version: 2.5.24 (libgcrypt 1.12.4)
- Copyright (C) g10 Code GmbH and the GnuPG contributors
- Licence: GNU General Public License, version 3 or later (the text is in `GnuPG-COPYING.txt`;
  the libraries that ship with it are under the LGPL)
- Home page and complete corresponding source code: https://gnupg.org/ (source downloads:
  https://gnupg.org/download/). On request, Level103 will also point you to the exact source
  archive that matches the bundled version.

GnuPG is free software: you may redistribute it and change it under the terms of that licence.
It comes with no warranty. The bundled copy is unmodified.

## VeraCrypt (not bundled)

The Disk pages drive a separately installed copy of VeraCrypt (https://veracrypt.fr/). CryptLok
does not ship, copy or modify it, and installs no drivers of its own.

## Delphi runtime

CryptLok is written in Embarcadero Delphi and is built with its own runtime library (VCL/RTL),
which is linked into `CryptLok.exe` under the Delphi licence.

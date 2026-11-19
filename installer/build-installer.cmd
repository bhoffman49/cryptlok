@echo off
rem Builds out\CryptLok-Setup-<version>.exe.  Needs Inno Setup 6 (https://jrsoftware.org/isinfo.php).
rem Run build.cmd first so out\CryptLok.exe is current, and pgp-samples\bin must hold the GnuPG runtime.
setlocal
set ISCC=
for %%P in ("F:\Portable\innosetup\app\ISCC.exe" "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" "%ProgramFiles%\Inno Setup 6\ISCC.exe" "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe") do if exist %%P set ISCC=%%~P
if "%ISCC%"=="" (
  echo Inno Setup 6 was not found. Install it from https://jrsoftware.org/isdl.php and run this again.
  exit /b 1
)
"%ISCC%" "%~dp0CryptLok.iss" || exit /b 1
rem checksum file to publish next to the download (sha256sum format: hash, two spaces, file name); only the
rem installer just built, not older versions still in out\
powershell -NoProfile -Command "Get-ChildItem '%~dp0..\out\CryptLok-Setup-*.exe' | Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() + '  ' + $_.Name } | Set-Content -Encoding ascii '%~dp0..\out\SHA256SUMS.txt'"
type "%~dp0..\out\SHA256SUMS.txt"

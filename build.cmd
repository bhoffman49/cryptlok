@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
cd /d %~dp0
if not exist out mkdir out
if not exist out\sda-dcu mkdir out\sda-dcu
rem the self-decrypting archive stub first: the main program embeds it
pushd sda
cgrc SdaStub.rc || exit /b 1
dcc64 -B -Q -$O+ -$D- -DRELEASE -U.. -NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;Vcl -NU..\out\sda-dcu -E..\out CryptLokSda.dpr || exit /b 1
popd
cgrc CryptLok.Assets.rc || exit /b 1
dcc64 -B -Q -$O+ -$D- -DRELEASE -NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;Vcl -NUout -Eout CryptLok.dpr

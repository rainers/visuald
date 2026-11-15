@echo off
setlocal
set VS=C:\Program Files\Microsoft Visual Studio\18\Insiders
set MSVC=%VS%\VC\Tools\MSVC\14.52.37025
set SDK=C:\Program Files (x86)\Windows Kits\10
set DMD=C:\D\dmd-2.114.0-beta.1\windows\bin\dmd.exe

set PATH=%MSVC%\bin\HostX86\x86;%VS%\Common7\IDE;%SDK%\bin;C:\D\dmd-2.114.0-beta.1\windows\bin;%PATH%
set DMD_LIB=%MSVC%\lib\x64;%SDK%\Lib\10.0.26100.0\ucrt\x64;%SDK%\lib\10.0.26100.0\um\x64

cd /d C:\s\d\visuald\trunk\vdc\dmdserver
set RSP=..\..\bin\Debug COFF32\x64\dmdserver\dmdserver.build.rsp

"%DMD%" -d -m64 -g -gf -boundscheck=on ^
 -Idmd\compiler\src -I..\..\stdext -I..\..\stdext\.. -I..\..\build -I..\..\c2d -I..\..\c2d\.. -I..\..\sdk -I..\..\sdk\.. ^
 -Jdmd -Jdmd\compiler\src\dmd\res ^
 -version=MARS -version=NoBackend -version=GC -version=LanguageServer ^
 -c -of"..\..\bin\Debug COFF32\x64\dmdserver\dmdserver.obj" @"%RSP%" -L/STACK:8388608 -gf -check=assert
if errorlevel 1 exit /B 1

set LIB=C:\D\dmd-2.114.0-beta.1\windows\bin\..\lib64
link.exe @"..\..\bin\Debug COFF32\x64\dmdserver\dmdserver.link.rsp"
if errorlevel 1 exit /B 1
if not exist "..\..\bin\Debug COFF32\x64\dmdserver.exe" (echo not created && exit /B 1)
echo BUILD OK

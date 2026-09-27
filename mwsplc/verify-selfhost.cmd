@echo off
setlocal EnableExtensions
cd /d "%~dp0"
echo === MWSPLC v2.3.2 Windows selfhost verification ===
echo.

del /q stage2.exe stage3.exe from-smod.exe 2>nul

echo [1/7] Stage-1 version
mwsplc.exe version
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :fail1

echo.
echo [2/7] Stage-1 -^> Stage-2
mwsplc.exe compile src\mwsplc-selfhost-windows.se -o stage2.exe
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :fail2
if not exist stage2.exe goto :nostage2

echo.
echo [3/7] Stage-2 version
stage2.exe version
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :fail3

echo.
echo [4/7] Stage-2 -^> Stage-3
stage2.exe compile src\mwsplc-selfhost-windows.se -o stage3.exe
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :fail4
if not exist stage3.exe goto :nostage3

echo.
echo [5/7] Stage-3 version
stage3.exe version
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :fail5

echo.
echo [6/7] Stage-2 vs Stage-3
certutil -hashfile stage2.exe SHA256 | findstr /R /V "hash CertUtil" > stage2.sha
certutil -hashfile stage3.exe SHA256 | findstr /R /V "hash CertUtil" > stage3.sha
for /f "usebackq delims=" %%H in ("stage2.sha") do set H2=%%H
for /f "usebackq delims=" %%H in ("stage3.sha") do set H3=%%H
echo STAGE2=%H2%
echo STAGE3=%H3%
fc /b stage2.exe stage3.exe >nul
if errorlevel 1 goto :diff

echo.
echo [7/7] .smod -^> compiler
mwsplc.exe compile mwsplc.smod -o from-smod.exe
set E=%ERRORLEVEL%
echo EXIT=%E%
if not "%E%"=="0" goto :failsmod
fc /b stage2.exe from-smod.exe >nul
if errorlevel 1 goto :diffsm

echo.
echo SELFHOST PASS - Stage-2 == Stage-3 == from-smod byte-for-byte
pause
exit /b 0

:fail1
echo SELFHOST FAIL - Stage-1 version crashed/failed: %E%
goto :end
:fail2
echo SELFHOST FAIL - Stage-1 could not create Stage-2: %E%
goto :end
:fail3
echo SELFHOST FAIL - Stage-2 cannot run: %E%
goto :end
:fail4
echo SELFHOST FAIL - Stage-2 could not create Stage-3: %E%
goto :end
:fail5
echo SELFHOST FAIL - Stage-3 cannot run: %E%
goto :end
:nostage2
echo SELFHOST FAIL - stage2.exe was not created
goto :end
:nostage3
echo SELFHOST FAIL - stage3.exe was not created
goto :end
:diff
echo SELFHOST FAIL - Stage-2 and Stage-3 differ byte-for-byte
goto :end
:failsmod
echo SELFHOST FAIL - .smod compile failed: %E%
goto :end
:diffsm
echo SELFHOST FAIL - .smod result differs from Stage-2
goto :end
:end
pause
exit /b 1

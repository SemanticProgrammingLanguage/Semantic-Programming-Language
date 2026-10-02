@echo off
setlocal
cd /d "%~dp0"
echo === MWSPLC v2.3.2 smoke test ===
echo.
"%~dp0mwsplc.exe" version
echo VERSION_EXIT=%ERRORLEVEL%
echo.
"%~dp0mwsplc.exe" help
echo HELP_EXIT=%ERRORLEVEL%
echo.
del /q return42.exe 2>nul
"%~dp0mwsplc.exe" compile "%~dp0tests\return42.se" -o "%~dp0return42.exe"
echo COMPILE_EXIT=%ERRORLEVEL%
if exist "%~dp0return42.exe" (
  "%~dp0return42.exe"
  echo RETURN42_EXIT=%ERRORLEVEL%
) else (
  echo return42.exe WAS NOT CREATED
)
echo.
pause

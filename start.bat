@echo off
REM ==============================================================
REM  BMS 3D - start everything: the launcher page AND both 3D apps
REM  on one port (this folder and the two app folders inside it).
REM
REM  Double-click this file. It serves this folder on PORT and opens
REM  http://localhost:PORT/index.html in the browser.
REM    /index.html                     launcher (choose an app)
REM    /patient-journey-3d/live.html   outpatient realtime 3D
REM    /Lab-visit-3D/index.html        blood-draw room 3D
REM    /proxy?url=...                  HOSxP API proxy both apps use
REM
REM  Each app still has its own start.bat if you want to run only one.
REM
REM  Uses Python 3.7+ (serve.py) when it is installed, otherwise the
REM  Windows PowerShell that ships with Windows 10/11 (serve.ps1).
REM
REM  start.bat --no-browser   = start the server only
REM  ASCII only on purpose - Thai text breaks cmd.exe parsing.
REM ==============================================================
setlocal
cd /d "%~dp0"
set PORT=8805

set "PYOPEN=--open"
set "PSOPEN=-Open"
for %%a in (%*) do if /i "%%~a"=="--no-browser" (set "PYOPEN=" & set "PSOPEN=")

echo ==============================================================
echo   BMS 3D - launcher + both 3D apps on port %PORT%
echo ==============================================================
echo.
echo   This PC  : http://localhost:%PORT%/index.html
echo              http://localhost:%PORT%/patient-journey-3d/live.html
echo              http://localhost:%PORT%/Lab-visit-3D/index.html

echo   Other PCs on the network can open it too after you run
echo   Enable-LAN.bat once on this PC.
echo.
echo   Close this window (or press Ctrl+C) to stop the server.
echo.

if not exist "index.html" goto nofiles

set "PY="
py -3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)" >nul 2>nul && set "PY=python"
if defined PY if exist "serve.py" goto usepython
goto usepowershell

:usepython
echo   Server: Python
echo.
%PY% serve.py %PORT% %PYOPEN%
goto done

:usepowershell
if not exist "serve.ps1" goto nofiles
where powershell >nul 2>nul || goto nopowershell
echo   Server: Windows PowerShell (Python is not installed - that is OK)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "serve.ps1" -Port %PORT% %PSOPEN%
goto done

:done
echo.
echo Server stopped. If it did not start, read the message above:
echo   - port in use       : change "set PORT=" at the top of this file
echo   - execution policy  : PowerShell scripts are blocked on this PC -
echo                         ask IT to allow them, or install Python 3.
echo.
pause
exit /b 0

:nofiles
echo [ERROR] index.html is missing from this folder.
echo Keep index.html, assets\ and serve.py (or serve.ps1) together.
echo.
pause
exit /b 1

:nopowershell
echo [ERROR] Neither Python 3.7+ nor Windows PowerShell was found on this PC.
echo Install Python 3 from https://www.python.org and run this file again.
echo.
pause
exit /b 1

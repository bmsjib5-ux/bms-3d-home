@echo off
REM ---------------------------------------------------------------
REM  BMS Lab 3D - local web server + HOSxP API proxy
REM
REM  Uses Python 3.7+ (serve.py) when it is installed, otherwise the
REM  Windows PowerShell built into Windows 10/11 (serve.ps1).
REM  Nothing needs to be installed.
REM
REM  start.bat --no-browser   = start the server only
REM
REM  ASCII only on purpose - Thai text breaks cmd.exe parsing.
REM ---------------------------------------------------------------
setlocal
set PORT=8804

set "PYOPEN=--open"
set "PSOPEN=-Open"
if /i "%~1"=="--no-browser" set "PYOPEN="
if /i "%~1"=="--no-browser" set "PSOPEN="

REM pushd (not cd) also works when the folder is on a network share
pushd "%~dp0" 2>nul || goto nodir
if not exist "index.html" goto nofiles

echo ============================================================
echo   BMS Lab 3D - blood collection room, live from HOSxP
echo ------------------------------------------------------------
echo   Open in browser:  http://localhost:%PORT%/index.html
echo   Keep THIS window OPEN while using the tool.
echo   Close this window (or press Ctrl+C) to stop the server.
echo ------------------------------------------------------------
echo   Do NOT open index.html with a double click (file://).
echo   The HOSxP tunnel rejects file:// requests - use the URL above.
echo ============================================================
echo.

REM Is there a real Python 3.7+? The Microsoft Store "python" shortcut fails this test.
set "PY="
py -3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 7) else 1)" >nul 2>nul && set "PY=python"
if defined PY if exist "serve.py" goto usepython
goto usepowershell

:usepython
echo   Server: Python
echo.
%PY% serve.py %PORT% %PYOPEN%
goto stopped

:usepowershell
if not exist "serve.ps1" goto nofiles
where powershell >nul 2>nul || goto nopowershell
echo   Server: Windows PowerShell (Python is not installed - that is OK)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "serve.ps1" -Port %PORT% %PSOPEN%
goto stopped

:stopped
echo.
echo Server stopped. If it did not start, read the message above:
echo   - port in use       : this tool is already running in another window,
echo                         close that window or change PORT at the top of this file.
echo   - execution policy  : PowerShell scripts are blocked on this PC -
echo                         ask IT to allow them, or install Python 3.
goto end

:nofiles
echo [ERROR] Program files are missing in this folder:
echo   %CD%
echo.
echo Need index.html together with serve.ps1 (or serve.py).
echo If you opened start.bat from inside a ZIP file, right-click the ZIP,
echo choose "Extract All", then run start.bat from the extracted folder.
goto end

:nopowershell
echo [ERROR] Neither Python 3.7+ nor Windows PowerShell was found on this PC.
echo Install Python 3 from https://www.python.org and run this file again.
goto end

:nodir
echo [ERROR] Cannot open the folder of this file:
echo   %~dp0

:end
popd 2>nul
echo.
pause

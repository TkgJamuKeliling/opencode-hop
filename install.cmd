@echo off
setlocal
set "REPO=TkgJamuKeliling/opencode-hop"
set "PS1=%~dp0install.ps1"
set "DOWNLOADED=0"
set "PSARGS="

where powershell >nul 2>nul
if errorlevel 1 (
  echo error: PowerShell was not found. Windows 10 and 11 include it.
  exit /b 1
)

if exist "%PS1%" goto args

set "PS1=%TEMP%\opencode-hop-install.ps1"
echo Downloading installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/%REPO%/releases/latest/download/install.ps1' -OutFile '%PS1%'"
if errorlevel 1 (
  echo.
  echo error: could not download install.ps1.
  echo Download it manually from:
  echo   https://github.com/%REPO%/releases/latest
  echo and put it next to install.cmd.
  exit /b 1
)
set "DOWNLOADED=1"

:args
if "%~1"=="" goto run
set "A=%~1"
if /i "%A%"=="--tag" goto tag
if /i "%A%"=="-tag" goto tag
if /i "%A%"=="--check" goto check
if /i "%A%"=="-check" goto check
if /i "%A%"=="--dry-run" goto dryrun
if /i "%A%"=="-dryrun" goto dryrun
if /i "%A%"=="--help" goto help
if /i "%A%"=="-help" goto help
if /i "%A%"=="-h" goto help
if /i "%A:~0,6%"=="--tag=" goto tageq
echo error: unknown argument: %~1
echo Try --help.
exit /b 2

:tag
set "TAGVAL=%~2"
if "%TAGVAL%"=="" (
  echo error: --tag needs a value
  exit /b 2
)
if "%TAGVAL:~0,1%"=="-" (
  echo error: invalid tag: %TAGVAL%
  exit /b 2
)
set "PSARGS=%PSARGS% -Tag "%TAGVAL%""
shift
shift
goto args

:tageq
set "TAGVAL=%A:~6%"
if "%TAGVAL%"=="" (
  echo error: --tag needs a value
  exit /b 2
)
if "%TAGVAL:~0,1%"=="-" (
  echo error: invalid tag: %TAGVAL%
  exit /b 2
)
set "PSARGS=%PSARGS% -Tag "%TAGVAL%""
shift
goto args

:check
set "PSARGS=%PSARGS% -Check"
shift
goto args

:dryrun
set "PSARGS=%PSARGS% -DryRun"
shift
goto args

:help
set "PSARGS=%PSARGS% -Help"
shift
goto args

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PSARGS%
set "RC=%ERRORLEVEL%"
if "%DOWNLOADED%"=="1" del "%PS1%" >nul 2>nul
echo "%cmdcmdline%" | find /i "%~nx0" >nul
if not errorlevel 1 pause
exit /b %RC%

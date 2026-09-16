@echo off
REM ===================================================================
REM  Install drawer_helper.exe as an auto-start Windows service via NSSM.
REM  RUN AS ADMINISTRATOR, from the folder holding:
REM      drawer_helper.exe, config.ini, nssm.exe
REM  Get nssm.exe from https://nssm.cc (put it in this folder).
REM ===================================================================
setlocal
cd /d "%~dp0"

set SVC=CoccinelleDrawer
set DIR=%~dp0

if not exist "%DIR%nssm.exe" (
    echo nssm.exe not found in this folder. Download it from https://nssm.cc
    exit /b 1
)
if not exist "%DIR%drawer_helper.exe" (
    echo drawer_helper.exe not found. Run build.bat first ^(or copy it here^).
    exit /b 1
)

echo Edit config.ini for THIS till's printer before starting, then continue.
pause

"%DIR%nssm.exe" install %SVC% "%DIR%drawer_helper.exe"
"%DIR%nssm.exe" set %SVC% AppDirectory "%DIR%"
"%DIR%nssm.exe" set %SVC% Start SERVICE_AUTO_START
"%DIR%nssm.exe" set %SVC% DisplayName "Coccinelle Cash Drawer Helper"
"%DIR%nssm.exe" set %SVC% AppStdout "%DIR%service.out.log"
"%DIR%nssm.exe" set %SVC% AppStderr "%DIR%service.err.log"
"%DIR%nssm.exe" start %SVC%

echo.
echo Service "%SVC%" installed and started. Test with:
echo     curl http://localhost:9110/kick

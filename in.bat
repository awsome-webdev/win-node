@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: 0. ELEVATE TO ADMIN AUTOMATICALLY
:: ============================================================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [SETUP] Requesting administrative privileges...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title Win-Node Setup and Service Installer
echo ============================================================================
echo                 WIN-NODE AUTO-INSTALLER & SERVICE SETUP
echo ============================================================================

:: Target locations
set "SERVICE_NAME=WinNodeWorker"
set "USER_DOCS=%USERPROFILE%\Documents"
set "TARGET_DIR=%USER_DOCS%\win-node"
set "REPO_URL=https://github.com/awsome-webdev/win-node.git"

:: ============================================================================
:: 1. CHECK AND INSTALL GIT
:: ============================================================================
echo [1/6] Checking for Git...
where git >nul 2>&1
if %errorlevel% neq 0 (
    echo [SETUP] Git not found. Installing via winget...
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent
    set "PATH=%PATH%;C:\Program Files\Git\cmd"
    where git >nul 2>&1
    if !errorlevel! neq 0 (
        echo [ERROR] Git installation failed or PATH not updated.
        pause
        exit /b 1
    )
)
echo [OK] Git is available.

:: ============================================================================
:: 2. RESOLVE PYTHON
:: ============================================================================
echo [2/6] Checking for Python...
set "PY_EXE="

where python >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%i in ('where python') do (
        if not defined PY_EXE (
            echo %%i | findstr /i "WindowsApps" >nul
            if errorlevel 1 set "PY_EXE=%%i"
        )
    )
)

if not defined PY_EXE (
    where py >nul 2>&1
    if %errorlevel% equ 0 (
        for /f "tokens=*" %%i in ('py -c "import sys; print(sys.executable)" 2^>nul') do set "PY_EXE=%%i"
    )
)

if not defined PY_EXE (
    echo [SETUP] Python is not installed. Installing Python 3.12...
    winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements --silent
    set "PATH=%PATH%;C:\Program Files\Python312;C:\Program Files\Python312\Scripts;%LOCALAPPDATA%\Programs\Python\Python312;%LOCALAPPDATA%\Programs\Python\Python312\Scripts"
    for /f "tokens=*" %%i in ('where python 2^>nul') do (
        if not defined PY_EXE (
            echo %%i | findstr /i "WindowsApps" >nul
            if errorlevel 1 set "PY_EXE=%%i"
        )
    )
)

if not defined PY_EXE (
    echo [ERROR] Could not resolve a valid python.exe.
    pause
    exit /b 1
)
echo [OK] Using Python: %PY_EXE%

:: ============================================================================
:: 3. CLONE OR UPDATE REPOSITORY
:: ============================================================================
echo [3/6] Setting up repository in Documents...

if not exist "%USER_DOCS%" mkdir "%USER_DOCS%"

if not exist "%TARGET_DIR%" (
    echo [SETUP] Cloning %REPO_URL% into "%TARGET_DIR%"...
    git clone "%REPO_URL%" "%TARGET_DIR%"
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to clone git repository.
        pause
        exit /b 1
    )
) else (
    echo [NOTICE] Directory %TARGET_DIR% exists. Updating...
    pushd "%TARGET_DIR%"
    git pull --ff-only
    popd
)

cd /d "%TARGET_DIR%"

:: ============================================================================
:: 4. INSTALL REQUIREMENTS
:: ============================================================================
echo [4/6] Installing dependencies...

if exist "req.txt" (
    echo [SETUP] Installing packages from req.txt...
    "%PY_EXE%" -m pip install -r req.txt --no-warn-script-location
) else if exist "requirements.txt" (
    echo [SETUP] Installing packages from requirements.txt...
    "%PY_EXE%" -m pip install -r requirements.txt --no-warn-script-location
) else (
    echo [NOTICE] No req.txt or requirements.txt found. Skipping pip install.
)

:: ============================================================================
:: 5. DOWNLOAD NSSM (WITH ROBUST USER-AGENT / MIRROR FALLBACK)
:: ============================================================================
echo [5/6] Setting up Windows Service Manager (NSSM)...

set "NSSM_EXE=%TARGET_DIR%\nssm.exe"

if not exist "%NSSM_EXE%" (
    echo [SETUP] Downloading NSSM...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "$urls = @('https://nssm.cc/release/nssm-2.24.zip', 'https://github.com/kirillkovalenko/nssm/releases/download/2.24/nssm-2.24.zip'); " ^
      "$zip = Join-Path $env:TEMP 'nssm.zip'; " ^
      "$wc = New-Object System.Net.WebClient; " ^
      "$wc.Headers.Add('User-Agent', 'Mozilla/5.0'); " ^
      "$downloaded = $false; " ^
      "foreach ($u in $urls) { " ^
      "  try { $wc.DownloadFile($u, $zip); $downloaded = $true; break } catch {} " ^
      "} " ^
      "if ($downloaded -and (Test-Path $zip)) { " ^
      "  Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'nssm_out') -Force; " ^
      "  $found = Get-ChildItem -Path (Join-Path $env:TEMP 'nssm_out') -Filter 'nssm.exe' -Recurse | Where-Object { $_.FullName -like '*win64*' } | Select-Object -First 1; " ^
      "  if (-not $found) { $found = Get-ChildItem -Path (Join-Path $env:TEMP 'nssm_out') -Filter 'nssm.exe' -Recurse | Select-Object -First 1 }; " ^
      "  if ($found) { Copy-Item $found.FullName -Destination '%NSSM_EXE%' -Force }; " ^
      "  Remove-Item $zip -Force -ErrorAction SilentlyContinue; " ^
      "  Remove-Item (Join-Path $env:TEMP 'nssm_out') -Recurse -Force -ErrorAction SilentlyContinue; " ^
      "}"
)

if not exist "%NSSM_EXE%" (
    echo [ERROR] Failed to obtain nssm.exe.
    pause
    exit /b 1
)
echo [OK] NSSM binary ready.

:: ============================================================================
:: 6. CONFIGURE AND START SERVICE
:: ============================================================================
echo [6/6] Configuring service "%SERVICE_NAME%"...

if not exist "%TARGET_DIR%\m.py" (
    echo [ERROR] %TARGET_DIR%\m.py does not exist!
    pause
    exit /b 1
)

:: Stop & remove existing service instance cleanly
"%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>&1
"%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>&1

:: Configure service parameters
"%NSSM_EXE%" install "%SERVICE_NAME%" "%PY_EXE%"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppParameters "-u \"%TARGET_DIR%\m.py\""
"%NSSM_EXE%" set "%SERVICE_NAME%" AppDirectory "%TARGET_DIR%"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppEnvironmentExtra PYTHONUNBUFFERED=1
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStdout "%TARGET_DIR%\service_out.log"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStderr "%TARGET_DIR%\service_err.log"
"%NSSM_EXE%" set "%SERVICE_NAME%" Start SERVICE_AUTO_START
"%NSSM_EXE%" set "%SERVICE_NAME%" AppThrottle 2000

echo [SETUP] Starting service...
"%NSSM_EXE%" start "%SERVICE_NAME%"

echo ============================================================================
echo [SUCCESS] Service "%SERVICE_NAME%" started!
echo Target Script : %TARGET_DIR%\m.py
echo Output Log    : %TARGET_DIR%\service_out.log
echo Error Log     : %TARGET_DIR%\service_err.log
echo ============================================================================
pause

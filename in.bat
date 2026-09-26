@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: 0. ELEVATE TO ADMIN AUTOMATICALLY
:: ============================================================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [SETUP] Requesting administrative privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
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
        echo [ERROR] Git installation failed or PATH not updated. Please install Git manually.
        pause
        exit /b 1
    )
)
echo [OK] Git is available.

:: ============================================================================
:: 2. CHECK AND INSTALL PYTHON 3.12
:: ============================================================================
echo [2/6] Checking for Python...
set "PY_EXE="

:: Check if standard 'python' or 'py' command works
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
    echo [SETUP] Python is not installed. Installing Python 3.12 via winget...
    winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements --silent
    
    :: Refresh common paths where Python installs
    set "PATH=%PATH%;C:\Program Files\Python312;C:\Program Files\Python312\Scripts;%LOCALAPPDATA%\Programs\Python\Python312;%LOCALAPPDATA%\Programs\Python\Python312\Scripts"
    
    for /f "tokens=*" %%i in ('where python 2^>nul') do (
        if not defined PY_EXE (
            echo %%i | findstr /i "WindowsApps" >nul
            if errorlevel 1 set "PY_EXE=%%i"
        )
    )
)

if not defined PY_EXE (
    echo [ERROR] Could not resolve a valid python.exe. Please install Python manually and check "Add to PATH".
    pause
    exit /b 1
)

echo [OK] Using Python at: %PY_EXE%

:: ============================================================================
:: 3. CLONE OR UPDATE REPOSITORY IN DOCUMENTS
:: ============================================================================
echo [3/6] Setting up repository in Documents...

if not exist "%TARGET_DIR%" (
    echo [SETUP] Cloning %REPO_URL% into "%TARGET_DIR%"...
    git clone "%REPO_URL%" "%TARGET_DIR%"
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to clone git repository.
        pause
        exit /b 1
    )
) else (
    echo [NOTICE] Directory %TARGET_DIR% already exists. Pulling latest changes...
    cd /d "%TARGET_DIR%"
    git pull --ff-only
)

cd /d "%TARGET_DIR%"

:: ============================================================================
:: 4. INSTALL REQUIREMENTS
:: ============================================================================
echo [4/6] Installing dependencies...

:: Upgrade pip first
"%PY_EXE%" -m pip install --upgrade pip --quiet

if exist "req.txt" (
    echo [SETUP] Installing packages from req.txt...
    "%PY_EXE%" -m pip install -r req.txt
) else if exist "requirements.txt" (
    echo [SETUP] Installing packages from requirements.txt...
    "%PY_EXE%" -m pip install -r requirements.txt
) else (
    echo [WARNING] Neither req.txt nor requirements.txt found. Skipping pip install.
)

:: ============================================================================
:: 5. DOWNLOAD NSSM FOR RELIABLE SERVICE EXECUTION
:: ============================================================================
echo [5/6] Setting up Windows Service Manager (NSSM)...

set "NSSM_EXE=%TARGET_DIR%\nssm.exe"
if not exist "%NSSM_EXE%" (
    echo [SETUP] Downloading NSSM binary...
    powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $zip = Join-Path $env:TEMP 'nssm.zip'; Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip; Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'nssm_extracted') -Force; Copy-Item (Join-Path $env:TEMP 'nssm_extracted\nssm-2.24\win64\nssm.exe') -Destination '%NSSM_EXE%'; Remove-Item $zip -Force; Remove-Item (Join-Path $env:TEMP 'nssm_extracted') -Recurse -Force"
)

if not exist "%NSSM_EXE%" (
    echo [ERROR] Failed to download nssm.exe.
    pause
    exit /b 1
)

:: ============================================================================
:: 6. CONFIGURE AND START SERVICE
:: ============================================================================
echo [6/6] Configuring Windows Service "%SERVICE_NAME%"...

:: Stop and remove existing service if present
"%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>&1
"%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>&1

:: Install service running m.py
"%NSSM_EXE%" install "%SERVICE_NAME%" "%PY_EXE%" "-u \"%TARGET_DIR%\m.py\""
"%NSSM_EXE%" set "%SERVICE_NAME%" AppDirectory "%TARGET_DIR%"

:: Ensure unbuffered output and log redirection
"%NSSM_EXE%" set "%SERVICE_NAME%" AppEnvironmentExtra PYTHONUNBUFFERED=1
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStdout "%TARGET_DIR%\service_out.log"
"%NSSM_EXE%" set "%SERVICE_NAME%" AppStderr "%TARGET_DIR%\service_err.log"

:: Set service to automatically restart if m.py exits/crashes
"%NSSM_EXE%" set "%SERVICE_NAME%" Start SERVICE_AUTO_START
"%NSSM_EXE%" set "%SERVICE_NAME%" AppThrottle 2000

echo [SETUP] Starting service "%SERVICE_NAME%"...
"%NSSM_EXE%" start "%SERVICE_NAME%"

echo ============================================================================
echo [SUCCESS] Service "%SERVICE_NAME%" has been created and started!
echo Location : %TARGET_DIR%
echo Logs     : %TARGET_DIR%\service_out.log
echo ============================================================================
pause

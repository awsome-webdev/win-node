@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: 0. ELEVATE TO ADMIN AUTOMATICALLY
:: ============================================================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [UNINSTALL] Requesting administrative privileges...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title Win-Node Uninstaller
echo ============================================================================
echo                 WIN-NODE CLEAN UNINSTALLER
echo ============================================================================

set "SERVICE_NAME=WinNodeWorker"
set "USER_DOCS=%USERPROFILE%\Documents"
set "TARGET_DIR=%USER_DOCS%\win-node"
set "NSSM_EXE=%TARGET_DIR%\nssm.exe"
set "SHORTCUT_PATH=%USERPROFILE%\Desktop\Win-Node Dashboard.lnk"

:: ============================================================================
:: 1. STOP AND REMOVE WINDOWS SERVICE
:: ============================================================================
echo [1/4] Stopping and removing service "%SERVICE_NAME%"...

:: Check if NSSM exists inside the repo folder
if exist "%NSSM_EXE%" (
    "%NSSM_EXE%" stop "%SERVICE_NAME%" >nul 2>&1
    "%NSSM_EXE%" remove "%SERVICE_NAME%" confirm >nul 2>&1
)

:: Fallback using built-in sc.exe to ensure service is eradicated
sc query "%SERVICE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [INFO] Stopping service via Windows Service Controller...
    sc stop "%SERVICE_NAME%" >nul 2>&1
    timeout /t 2 >nul
    sc delete "%SERVICE_NAME%" >nul 2>&1
)

echo [OK] Service "%SERVICE_NAME%" removed.

:: ============================================================================
:: 2. TERMINATE ANY LINGERING PROCESSES
:: ============================================================================
echo [2/4] Checking for lingering node processes...

:: Kill any orphaned python processes running m.py
wmic process where "CommandLine like '%%m.py%%'" call terminate >nul 2>&1

:: Kill any stray nssm instance
taskkill /F /IM nssm.exe >nul 2>&1

echo [OK] Processes cleared.

:: ============================================================================
:: 3. REMOVE DESKTOP SHORTCUT
:: ============================================================================
echo [3/4] Removing desktop shortcut...

if exist "%SHORTCUT_PATH%" (
    del /f /q "%SHORTCUT_PATH%" >nul 2>&1
    echo [OK] Shortcut deleted from %USERPROFILE%\Desktop.
) else (
    echo [NOTICE] Desktop shortcut not found.
)

:: Also check if shortcut was created under Administrator's desktop
if exist "C:\Users\Administrator\Desktop\Win-Node Dashboard.lnk" (
    del /f /q "C:\Users\Administrator\Desktop\Win-Node Dashboard.lnk" >nul 2>&1
)

:: ============================================================================
:: 4. REMOVE REPOSITORY DIRECTORY
:: ============================================================================
echo [4/4] Removing repository files from Documents...

if exist "%TARGET_DIR%" (
    :: Step out of directory in case CMD has an active lock on it
    cd /d "%USERPROFILE%"
    
    :: Remove read-only locks on git packfiles and remove tree
    attrib -r -s -h "%TARGET_DIR%\*.*" /s /d >nul 2>&1
    rmdir /s /q "%TARGET_DIR%"
    
    if exist "%TARGET_DIR%" (
        echo [WARNING] Could not delete immediately due to a file lock. Retrying...
        timeout /t 2 >nul
        rmdir /s /q "%TARGET_DIR%"
    )
    
    if not exist "%TARGET_DIR%" (
        echo [OK] Successfully removed %TARGET_DIR%.
    ) else (
        echo [ERROR] Failed to completely remove %TARGET_DIR%. Some files may be locked.
    )
) else (
    echo [NOTICE] Directory %TARGET_DIR% does not exist.
)

echo ============================================================================
echo [SUCCESS] Win-Node service, repository, and shortcut have been removed!
echo Note: Python runtime and pip packages were kept intact.
echo ============================================================================
pause

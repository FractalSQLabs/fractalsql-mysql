@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql.dll (pre-built by build.bat) plus the install
REM SQL and LICENSE files into a Windows MSI using the WiX Toolset.
REM
REM One MSI per (MySQL major, arch) pair. The resulting MSI installs
REM into the target server's on-disk layout:
REM
REM     C:\Program Files\MySQL\MySQL Server ^<MYSQL_MAJOR^>\lib\plugin\fractalsql.dll
REM     C:\Program Files\MySQL\MySQL Server ^<MYSQL_MAJOR^>\share\doc\fractalsql-mysql\LICENSE
REM     C:\Program Files\MySQL\MySQL Server ^<MYSQL_MAJOR^>\share\doc\fractalsql-mysql\LICENSE-THIRD-PARTY
REM     C:\Program Files\MySQL\MySQL Server ^<MYSQL_MAJOR^>\share\doc\fractalsql-mysql\install_udf.sql
REM
REM That matches MySQL's default Windows install layout, so end-users
REM who took the MySQL MSI server installer can run:
REM     mysql -u root -p ^< "C:\Program Files\MySQL\MySQL Server ^<VER^>\share\doc\fractalsql-mysql\install_udf.sql"
REM with no further path munging.
REM
REM Prerequisites
REM   * WiX Toolset v3.x installed (candle.exe / light.exe on PATH).
REM   * dist\windows\my^<MYSQL_MAJOR^>\fractalsql.dll already produced
REM     by scripts\windows\build.bat.
REM
REM Environment
REM   MYSQL_MAJOR   8.4 ^| 9.7 ^| 26.7: selects UpgradeCode and install-folder name
REM   MSI_ARCH      x64 ^| arm64: passed to candle -arch
REM   MSI_VERSION   overrides Product Version (default 2.0.2, read from src\fractalsql.c's FSQL_VERSION if not set)

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set REPO_ROOT=%~dp0..\..
pushd %REPO_ROOT%

if "%MYSQL_MAJOR%"==""    (
    echo ==^> ERROR: MYSQL_MAJOR must be set ^(8.4 ^| 9.7 ^| 26.7^)
    popd
    exit /b 1
)
if "%MSI_ARCH%"==""    set MSI_ARCH=x64
if "%MSI_VERSION%"=="" (
    REM findstr splits a plain /r pattern on spaces into multiple search
    REM strings, which would also match every other line mentioning
    REM FSQL_VERSION (e.g. "static const char kVersion[] = FSQL_VERSION;")
    REM and let the last match's token 3 win. /c: keeps it one pattern.
    for /f "tokens=3" %%V in ('findstr /r /c:"^#define FSQL_VERSION" src\fractalsql.c') do set MSI_VERSION=%%~V
)
if "%MSI_VERSION%"=="" (
    echo ==^> ERROR: could not read FSQL_VERSION from src\fractalsql.c; set MSI_VERSION explicitly
    popd
    exit /b 1
)

set DLL=dist\windows\my%MYSQL_MAJOR%\fractalsql.dll
if not exist "%DLL%" (
    echo ==^> ERROR: %DLL% missing: run build.bat with MYSQL_MAJOR=%MYSQL_MAJOR% first
    popd
    exit /b 1
)

REM Per-(major, arch) staging dir so candle can reference a stable
REM "dist\windows\staging-...\fractalsql.dll" path from the wxs. Avoids
REM threading MYSQL_MAJOR through every File/@Source attribute.
set STAGE=dist\windows\staging-my%MYSQL_MAJOR%-%MSI_ARCH%
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"

copy /Y "%DLL%"                "%STAGE%\fractalsql.dll"     > nul
copy /Y sql\install_udf.sql    "%STAGE%\install_udf.sql"    > nul
copy /Y LICENSE                "%STAGE%\LICENSE"            > nul
copy /Y THIRD-PARTY-NOTICES.md "%STAGE%\LICENSE-THIRD-PARTY" > nul

REM Per-cell README ships in the MSI so users who only grab the .msi
REM still see the "which MySQL major, which arch" pairing without
REM hopping to GitHub.
(
  echo FractalSQL for MySQL %MYSQL_MAJOR%, Community Edition %MSI_VERSION%
  echo Architecture: %MSI_ARCH%
  echo.
  echo This MSI installs the fractalsql UDF DLL into the canonical
  echo MySQL Windows install root:
  echo     C:\Program Files\MySQL\MySQL Server %MYSQL_MAJOR%\lib\plugin\fractalsql.dll
  echo.
  echo After install, activate the UDFs once per server:
  echo     mysql -u root -p ^< "C:\Program Files\MySQL\MySQL Server %MYSQL_MAJOR%\share\doc\fractalsql-mysql\install_udf.sql"
  echo     mysql -u root -p -e "SELECT fractal_edition^(^), fractal_version^(^);"
) > "%STAGE%\README.txt"

if not exist obj mkdir obj
REM candle preprocessor can't take a dotted major without escaping;
REM expose two sanitized variants:
REM   MAJOR_TAG   underscore-safe, used in WiX Ids and filenames
REM   MAJOR_HEX   4-digit hex-safe, padded, used inside GUID strings
REM                 which MUST be pure hex [0-9A-F].
set MAJOR_TAG=%MYSQL_MAJOR:.=_%
REM MAJOR_HEX values stay 4 hex digits: the GUID templates below embed
REM them, and GUID strings must be pure [0-9A-F]. 9.7 -> 0907, 26.7 ->
REM 2607 (the 2 in the hundreds place still reads as hex 2).
if "%MYSQL_MAJOR%"=="8.4"    set MAJOR_HEX=0804
if "%MYSQL_MAJOR%"=="9.7"    set MAJOR_HEX=0907
if "%MYSQL_MAJOR%"=="26.7"   set MAJOR_HEX=2607
if "%MAJOR_HEX%"==""    (
    echo ==^> ERROR: no MAJOR_HEX mapping for MYSQL_MAJOR=%MYSQL_MAJOR%
    popd
    exit /b 1
)
set OBJ=obj\fractalsql-my%MAJOR_TAG%-%MSI_ARCH%.wixobj

set MSI=dist\windows\FractalSQL-MySQL-%MYSQL_MAJOR%-%MSI_VERSION%-%MSI_ARCH%.msi
if not exist "dist\windows" mkdir "dist\windows"

set WXS=scripts\windows\fractalsql.wxs

echo ==^> MYSQL_MAJOR   = %MYSQL_MAJOR%
echo ==^> MSI_ARCH      = %MSI_ARCH%
echo ==^> MSI_VERSION   = %MSI_VERSION%
echo ==^> STAGE         = %STAGE%
echo ==^> MSI           = %MSI%

REM -arch propagates into $(sys.BUILDARCH) inside the WXS, used there
REM to set <Package Platform="..."/> and keep ICE80 happy about the
REM component/directory bitness pairing.
REM
REM -dMYSQL_MAJOR / -dSTAGE_DIR / -dMSI_VERSION are consumed by the
REM preprocessor inside fractalsql.wxs (see <?define?> section).
candle -nologo -arch %MSI_ARCH% ^
    -dMYSQL_MAJOR=%MYSQL_MAJOR% ^
    -dMYSQL_MAJOR_TAG=%MAJOR_TAG% ^
    -dMYSQL_MAJOR_HEX=%MAJOR_HEX% ^
    -dSTAGE_DIR=%STAGE% ^
    -dMSI_VERSION=%MSI_VERSION% ^
    -out %OBJ% %WXS%
if errorlevel 1 (
    echo ==^> candle failed
    popd
    exit /b 1
)

light -nologo ^
      -ext WixUIExtension ^
      -ext WixUtilExtension ^
      -out "%MSI%" ^
      %OBJ%
if errorlevel 1 (
    echo ==^> light failed
    popd
    exit /b 1
)

echo ==^> Built %MSI%
dir "%MSI%"

popd
endlocal
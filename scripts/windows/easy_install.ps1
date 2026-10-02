<#
.SYNOPSIS
    easy_install.ps1: the "easy button" for FractalSQL on Windows. One
    command gets you from a bare Windows box (with MySQL already
    installed) to a running install with reasoning configured.
    PowerShell counterpart to scripts/easy_install.sh (Linux/macOS);
    same design, Windows-native underneath.

.DESCRIPTION
    Detects an installed MySQL via its Windows Service, resolved from
    the server binary's location rather than a hardcoded service name --
    machines with several installs register several services (MySQL,
    MySQL84, MySQL90, ...), so the literal name "MySQL" is just one
    candidate, and it can belong to a different major than the one you
    meant. -MysqlDir overrides detection entirely; -ServiceName overrides
    the service resolution. Offers to install the
    matching .msi if the FractalSQL plugin itself is missing. Runs the
    same reasoning-provider wizard as easy_install.sh: registers the
    UDFs and agent procedures, configures reasoning via the service's
    environment (there is no GUC/sysvar surface at all, see
    docs/reasoning-setup.md), and runs a smoke test.

    Design differences, all forced by MySQL's own architecture (see
    scripts/easy_install.sh's header comment for the full rationale,
    identical here):
      - No -PgMajor-style multi-install selector: one binary covers
        every supported major (8.4 LTS, 9.7 LTS, and 26.7), and
        there's normally
        exactly one MySQL Windows Service to target.
      - Every FRACTALSQL_* reasoning setting is a service environment
        variable, never a live-reloadable GUC, so applying any of them
        always means a service restart.
      - mysql.exe, not psql.exe. Registration is two plain
        SQL files (sql/install_udf.sql + sql/install_agents.sql), not
        CREATE EXTENSION -- no catalog-version/staleness concept, since
        both scripts are unconditionally idempotent.
      - Verification functions are fractal_edition()/fractal_version()
        (the fractalsql_ prefix, see sql/install_udf.sql).

    No telemetry. This script never reports usage, provider choice, or
    success or failure anywhere.

.PARAMETER MysqlDir
    Top-level MySQL install directory, e.g.
    "C:\Program Files\MySQL\MySQL Server 8.4". Optional. When given,
    skips service auto-detection and uses this directly.

.PARAMETER Port
    Override the auto-detected port if it guessed wrong.

.PARAMETER RootPassword
    Password for the MySQL root account. Asked for once (masked) and
    cached in $env:MYSQL_PWD for the rest of the run if not supplied
    here -- the Windows MSI asks you to set a root password during
    install; a ZIP archive or a manual --initialize-insecure install
    leaves root with an empty password instead.

.PARAMETER ServiceName
    Windows Service name to target, e.g. "MySQL84". Optional: resolved
    automatically from the install being targeted, since machines with
    several MySQL installs have several services (MySQL, MySQL84,
    MySQL90, ...) and the literal name "MySQL" belongs to whichever
    install registered it. Only needed when the service can't be matched
    to the install directory another way (custom service names pointing
    outside the install root).

.PARAMETER Database
    Target database for the agent stored procedures -- must already
    exist. UDFs themselves are server-global (mysql.func) and need no
    database; agent procedures are ordinary stored procedures and do
    (running install_agents.sql with none selected fails with
    "No database selected").

.PARAMETER Provider
    ollama | openai-compatible | skip

.PARAMETER TimeoutSecs
    Reasoning request timeout in seconds, applied as the reasoning
    plugin's FSQL_REASONING_HTTP_TIMEOUT_MS (minus 30s for its
    low-speed abort). Default 330, the same cold-start headroom the
    docker-compose demo sets: a local model that isn't loaded yet can
    take minutes before its first token, and the plugin's shorter
    built-in default turns that into a clean NULL. Only set for the
    ollama provider.

.PARAMETER Yes
    Pre-confirm every prompt (needed for CI/non-interactive use).

.PARAMETER NoInstall
    Don't offer to install a missing .msi.

.PARAMETER DryRun
    Print what would happen, change nothing.

.PARAMETER ForceReinstall
    Skip the "already registered" pause before re-running the SQL
    registration scripts.

.PARAMETER Uninstall
    Reverse everything this script can set up.

.PARAMETER Version
    Package version to install. Defaults to this script's own embedded
    version.

.EXAMPLE
    .\easy_install.ps1
    .\easy_install.ps1 -MysqlDir "C:\Program Files\MySQL\MySQL Server 8.4" -Provider ollama -Yes
#>

param(
    [string]$MysqlDir,
    [int]$Port,
    [string]$RootPassword,
    [string]$ServiceName,
    [string]$Database,
    [ValidateSet('ollama', 'openai-compatible', 'skip')][string]$Provider,
    [string]$Url,
    [string]$Model,
    [string]$Token,
    [string]$EmbedUrl,
    [string]$EmbedModel,
    [int]$TimeoutSecs = 330,
    [string]$Think,
    [string]$ThinkProvider,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$DryRun,
    [switch]$ForceReinstall,
    [switch]$Uninstall,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# --- version -----------------------------------------------------------
$FsqlVersion = '@@FSQL_VERSION@@'
if ($FsqlVersion -eq '@@FSQL_VERSION@@') {
    $srcFile = Join-Path $PSScriptRoot '..\..\src\fractalsql.c'
    if (Test-Path $srcFile) {
        $m = Select-String -Path $srcFile -Pattern '^#define FSQL_VERSION "(.*)"$' | Select-Object -First 1
        if ($m) { $FsqlVersion = $m.Matches[0].Groups[1].Value }
    }
}
if (-not $Version) { $Version = $FsqlVersion }
if (-not $Version) { throw "could not determine a version to install. Pass -Version X.Y.Z" }

$Repo = 'FractalSQLabs/fractalsql-mysql'
# Resolved from the targeted install by Get-MySqlTarget (see its
# comments); -ServiceName overrides the resolution. Not hardcoded here:
# machines with several installs have several candidate services.

# --- output helpers ------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor White }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Die   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red; exit 1 }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- prompting -----------------------------------------------------------
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { Write-Ok "$Question -> yes (-Yes)"; return $true }
    try {
        $reply = Read-Host "$Question [Y/n]"
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Yes, or the specific parameter for what you're trying to set."
    }
    return ($reply -eq '' -or $reply -match '^[Yy]')
}

function Prompt-Value {
    param([string]$Question, [string]$Default = '')
    try {
        if ($Default) {
            $reply = Read-Host "$Question [$Default]"
            if (-not $reply) { return $Default }
            return $reply
        } else {
            return Read-Host $Question
        }
    } catch {
        if ($Default) { return $Default }
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass the corresponding parameter."
    }
}

function Prompt-Secret {
    param([string]$Question)
    try {
        $secure = Read-Host $Question -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -RootPassword, or set MYSQL_PWD."
    }
}

function Resolve-RootPassword {
    if ($env:MYSQL_PWD) { return }
    if ($RootPassword) { $env:MYSQL_PWD = $RootPassword; return }
    if (Confirm-Step "Does root@localhost need a password? (the MSI asks you to set one during install; say no if this is a fresh --initialize-insecure/ZIP install with no password set)") {
        $env:MYSQL_PWD = Prompt-Secret "Password for MySQL root"
    }
}

# --- detect ----------------------------------------------------------------
# Single-target detection (no -PgMajor-style multi-install selector, see
# this file's own .DESCRIPTION): exactly one MySQL install to target,
# but NOT necessarily one service name. Reasoning config lives in the
# service's registry Environment value and is applied by restarting that
# service, so the service has to be resolved from the install being
# targeted -- machines with several installs register several services
# (MySQL, MySQL84, MySQL90, ...) and the literal name "MySQL"
# belongs to whichever install registered it. -ServiceName overrides the
# resolution when the service can't be matched another way.
function Find-ServiceForDir {
    param([string]$BaseDir)
    $binDir = (Join-Path $BaseDir 'bin').TrimEnd('\').ToLower()
    $found = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -and $_.PathName.ToLower().Contains($binDir)
    })
    return ($found | Select-Object -First 1)
}

function Get-MySqlTarget {
    if ($MysqlDir) {
        $exe = Join-Path $MysqlDir 'bin\mysqld.exe'
        if (-not (Test-Path $exe)) { Write-Die "-MysqlDir '$MysqlDir' doesn't look like a MySQL install (no bin\mysqld.exe)" }
        $svc = Find-ServiceForDir $MysqlDir
        if (-not $svc) {
            Write-Die "no Windows Service runs a server out of '$MysqlDir\bin'. If the service exists under a name that can't be matched to this directory, pass -ServiceName."
        }
        $script:ServiceName = $svc.Name
        return @{ Dir = $MysqlDir; Port = (Get-PortFor $MysqlDir) }
    }
    # No -MysqlDir: auto-detect by the server binary, not by the literal
    # service name "MySQL" -- that name is just one candidate, and on a
    # multi-install machine it can belong to a different major than the
    # one you meant.
    $svcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '[\\/]mysqld\.exe'
    })
    if (-not $svcs) {
        Write-Die "no MySQL Windows Service found (nothing runs mysqld.exe). If MySQL was unpacked from a ZIP archive without registering a service, pass -MysqlDir."
    }
    if ($svcs.Count -gt 1) {
        Write-Host "Several MySQL Windows Services found:"
        foreach ($s in $svcs) { Write-Host "  $($s.Name) -> $($s.PathName)" }
        Write-Die "pass -MysqlDir <install dir> (or -ServiceName <name>) to pick one."
    }
    $svc = $svcs[0]
    # PathName looks like: "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqld.exe" --defaults-file=...
    # -- quoted when the exe path contains a space, but mysqld --install
    # registers it unquoted (and with the service name appended as a
    # trailing arg) when it doesn't, e.g. D:\a\...\bin\mysqld.exe
    # --defaults-file=... FractalSQLCI. The closing quote is therefore
    # optional, matched by a following whitespace instead.
    $exePath = ($svc.PathName -replace '^"?([^"]+[\\/]mysqld\.exe)"?\s.*$', '$1')
    if (-not (Test-Path $exePath)) { Write-Die "Service '$($svc.Name)' PathName didn't resolve to a real server exe ($exePath). Pass -MysqlDir." }
    $dir = Split-Path (Split-Path $exePath -Parent) -Parent
    $script:ServiceName = $svc.Name
    return @{ Dir = $dir; Port = (Get-PortFor $dir) }
}

function Get-PortFor {
    param([string]$BaseDir)
    foreach ($ini in @((Join-Path $BaseDir 'data\my.ini'), (Join-Path $BaseDir 'my.ini'))) {
        if (Test-Path $ini) {
            $m = Select-String -Path $ini -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
            if ($m) { return [int]$m.Matches[0].Groups[1].Value }
        }
    }
    return 3306
}

# --- mysql.exe plumbing ----------------------------------------------------
# ArgumentList (not a raw string) needs no manual argv-escaping.
function Invoke-MySql {
    param([string]$Bin, [int]$MyPort, [string[]]$Sql, [string]$File, [string]$Db)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'mysql.exe'
    $argList = @('-h', '127.0.0.1', '-P', "$MyPort", '-u', 'root', '-N', '-B')
    if ($Db) { $argList += @('-D', $Db) }
    if ($File) { $argList += @('-e', "source $File") }
    foreach ($s in $Sql) { $argList += @('-e', $s) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "mysql.exe failed: $errOut" }
    return $out.Trim()
}

function Invoke-MySqlFile {
    param([string]$Bin, [int]$MyPort, [string]$Path, [string]$Db)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'mysql.exe'
    $argList = @('-h', '127.0.0.1', '-P', "$MyPort", '-u', 'root')
    if ($Db) { $argList += @('-D', $Db) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $sqlText = [IO.File]::ReadAllText($Path)
        # install_udf.sql hardcodes SONAME 'fractalsql.so' on every CREATE
        # FUNCTION (the Linux load name). The UDF loader treats a SONAME
        # with an explicit extension as a literal filename, so on Windows
        # that has to be fractalsql.dll -- rewrite at pipe time rather than
        # diverge the file per platform. install_agents.sql is pure SQL/PSM
        # with no SONAME references, so this is a no-op for it.
        $sqlText = $sqlText -replace "SONAME 'fractalsql\.so'", "SONAME 'fractalsql.dll'"
        $proc.StandardInput.Write($sqlText)
        $proc.StandardInput.Close()
    } catch {
        # mysql.exe exits on the first statement error, which breaks the
        # write pipe above. Fall through: the server's own error text on
        # stderr is the useful diagnostic, not this pipe exception.
    }
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "mysql.exe (< $Path) failed: $errOut" }
    return $out.Trim()
}

# Restart-Service returns when the service reports Running, but mysqld
# only starts accepting connections some seconds later. Everything this
# script does after a restart talks to the live server, so poll for
# readiness instead of racing it (a connection refused here used to
# surface as a confusing "pipe is being closed" from the client).
function Wait-ServerReady {
    param([string]$Bin, [int]$MyPort, [int]$TimeoutSecs = 60)
    for ($i = 0; $i -lt $TimeoutSecs; $i++) {
        try {
            Invoke-MySql $Bin $MyPort @('SELECT 1;') | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

# plugin_dir comes from a live `SELECT @@plugin_dir` query, not a
# hardcoded 'lib\plugin' guess under the install root. A build-time or
# static guess for a MySQL plugin directory can differ from the
# server's own live value (see scripts/easy_install.sh's header
# comment for the Linux/macOS case), so this queries live instead.
$script:PluginDir = $null
function Resolve-PluginDir {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $myPort = if ($Port) { $Port } else { $Target.Port }
    $dir = Invoke-MySql $bin $myPort @('SELECT @@plugin_dir;')
    if (-not $dir) { Write-Die "SELECT @@plugin_dir returned nothing" }
    # @@plugin_dir reports backslash-escaped paths on Windows
    # ("C:\\Program Files\\..."). The reasoning plugin's loader doesn't
    # resolve that escape, so a FRACTALSQL_REASONING_PLUGIN path built
    # from the raw value never loads -- every reasoning call returns a
    # clean NULL with no error and no HTTP attempt. Normalize to single
    # separators before anything consumes it.
    $dir = $dir -replace '\\\\', '\'
    $script:PluginDir = $dir.TrimEnd('\')
}

function Test-Installed {
    return Test-Path (Join-Path $script:PluginDir 'fractalsql.dll')
}

# --- Phase B: install the package (default-on) ------------------------
function Install-Package {
    param($Target)
    if (Test-Installed) { return }
    if ($NoInstall) {
        Write-Die "FractalSQL isn't installed under $($Target.Dir). Grab the matching .msi from https://github.com/$Repo/releases and install it, then re-run this script (or drop -NoInstall)."
    }
    if (-not (Confirm-Step "FractalSQL isn't installed yet. Install it now?")) {
        Write-Die "Nothing to do without installing the package first. Re-run without -NoInstall, or install it yourself from https://github.com/$Repo/releases."
    }

    # FractalSQL-MySQL-<major>-<version>-x64.msi: the .wxs installs into
    # "MySQL Server <major>" (this repo's own directory-name convention,
    # matching the real MySQL install it's layered onto), so the major
    # has to come from the detected install directory's own name.
    $major = [regex]::Match($Target.Dir, 'MySQL Server\s+([\d.]+)').Groups[1].Value
    if (-not $major) { Write-Die "couldn't determine the MySQL major version from install directory '$($Target.Dir)'. Pass -MysqlDir pointing at a 'MySQL Server <major>' directory." }
    $asset = "FractalSQL-MySQL-$major-$Version-x64.msi"
    $assetUrl = "https://github.com/$Repo/releases/download/v$Version/$asset"
    $tmp = Join-Path $env:TEMP "fsql-easy-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msiPath = Join-Path $tmp $asset
        Write-Step "Downloading $asset..."
        Invoke-WebRequest -Uri $assetUrl -OutFile $msiPath -UseBasicParsing
        Write-Step "msiexec /i `"$msiPath`" /quiet /norestart"
        if (-not $DryRun) {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiPath`"", '/quiet', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "msiexec exited with code $($p.ExitCode)" }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Write-Ok "Package installed."
    # The installer drops install_udf.sql (but not install_agents.sql --
    # see scripts\windows\fractalsql.wxs) into share\doc\fractalsql-mysql\
    # and does not run either (see docs/getting-started.md) --
    # Invoke-Wizard's registration step below looks there when a repo
    # checkout isn't available.
}

# --- Phase C: the wizard -----------------------------------------------
# Every FRACTALSQL_* reasoning setting is a service environment variable,
# read once at mysqld.exe startup -- there is no GUC/sysvar surface at
# all here (see this file's own .DESCRIPTION).
# A Windows Service's environment lives in the registry
# (HKLM:\SYSTEM\CurrentControlSet\Services\<service>, in a REG_MULTI_SZ
# *value* named Environment -- NOT in a subkey of that name; the service
# manager only reads the value), written here via Set-ItemProperty, then
# Restart-Service.
#
# The write MERGES: entries already on the service that this wizard does
# not manage (e.g. FRACTALSQL_ENTERPRISE_LIB set up by a separate
# enterprise install) are preserved; wizard-managed keys overwrite their
# own old values. A wholesale replace here is what silently disables a
# previously-working enterprise tier on the next restart.
function Set-ReasoningEnvAndRestart {
    param([hashtable]$EnvValues, [string]$Bin, [int]$MyPort)

    Write-Step "About to set (service environment for '$ServiceName'):"
    foreach ($k in $EnvValues.Keys) {
        if ($k -like '*HTTP_TOKEN*') { Write-Host "  $k=***" } else { Write-Host "  $k=$($EnvValues[$k])" }
    }
    if (-not (Confirm-Step "Apply this configuration? This needs a MySQL service restart, which drops active connections -- there is no live reload for these.")) {
        Write-Warn2 "Aborted. Nothing was changed."
        return $false
    }
    if ($DryRun) {
        Write-Step "(-DryRun: not actually writing or restarting)"
        return $false
    }

    $doRestart = Confirm-Step "Restart the MySQL service now to apply it?"

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $managedKeys = @($EnvValues.Keys)
    $existing = @()
    try {
        $existing = @(Get-ItemProperty $regPath -ErrorAction Stop).Environment
    } catch { }
    $kept = @($existing | Where-Object {
        $_ -and ($_.Split('=', 2)[0] -notin $managedKeys)
    })
    if ($kept.Count -gt 0) {
        Write-Step ("Preserving existing service-environment entries this wizard does not manage: " +
            (($kept | ForEach-Object { $_.Split('=', 2)[0] }) -join ', '))
    }
    $regValues = $kept + @($EnvValues.Keys | ForEach-Object { "$_=$($EnvValues[$_])" })
    $quotedValues = ($regValues | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
    $elevatedCmd = "Set-ItemProperty -Path '$regPath' -Name Environment -Value @($quotedValues) -Type MultiString"
    if ($doRestart) { $elevatedCmd += "; Restart-Service -Name '$ServiceName' -Force" }

    if (Test-IsAdmin) {
        try {
            Invoke-Expression $elevatedCmd
        } catch {
            Write-Warn2 "Could not write the service environment ($($_.Exception.Message)). Set those values by hand under $regPath and restart $ServiceName yourself."
            return $false
        }
    } elseif ([Environment]::UserInteractive) {
        Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
        try {
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd)
            if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
        } catch {
            Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Set the values by hand under $regPath and restart $ServiceName, or re-run this whole script from an Administrator PowerShell."
            return $false
        }
    } else {
        Write-Warn2 "Skipping: this needs administrator access and there's no interactive session to grant it in. Set the values by hand under $regPath and restart $ServiceName, or re-run this whole script from an Administrator PowerShell."
        return $false
    }

    if ($doRestart) {
        Write-Step "Waiting for $script:ServiceName to accept connections..."
        if (-not (Wait-ServerReady $Bin $MyPort)) {
            Write-Warn2 "$script:ServiceName didn't accept connections within 60s of the restart. Check the error log under the install's data\ directory before continuing."
            return $false
        }
        Write-Ok "$script:ServiceName restarted with the new reasoning config."
        return $true
    } else {
        Write-Ok "Environment written."
        Write-Warn2 "Not restarted. The config won't take effect until you run: Restart-Service $ServiceName (as Administrator)"
        return $false
    }
}

function Invoke-Wizard {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $myPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-RootPassword

    if (-not $Database) { $Database = Prompt-Value "Target database for the agent stored procedures (must already exist; UDFs themselves don't need one)" }
    if (-not $Database) { Write-Die "a target database is required to register the agent procedures. Pass -Database <name>." }
    $dbExists = Invoke-MySql $bin $myPort @("SHOW DATABASES LIKE '$($Database -replace "'", "''")';")
    if ($dbExists -ne $Database) { Write-Die "database '$Database' doesn't exist. Create it first (CREATE DATABASE $Database;), then re-run with -Database $Database." }

    if (-not $Provider) {
        Write-Step "Reasoning provider:"
        Write-Host "  1) Local Ollama"
        Write-Host "  2) Cloud / OpenAI-compatible endpoint"
        Write-Host "  3) Skip: search-only install, configure reasoning later"
        $choice = Prompt-Value "Choice" "1"
        $Provider = switch ($choice) { '1' { 'ollama' } '2' { 'openai-compatible' } default { 'skip' } }
    }

    # Live plugin_dir (resolved once in main via Resolve-PluginDir), not a
    # hardcoded 'lib\plugin' guess under the install root -- see this
    # file's own Resolve-PluginDir comment for why.
    $pluginDll = Join-Path $script:PluginDir 'fractalsql-reasoning-http.dll'

    $envValues = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Ollama chat URL" "http://localhost:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = Prompt-Value "Ollama embeddings URL" "http://localhost:11434/v1/embeddings" }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $envValues['FRACTALSQL_REASONING_PLUGIN'] = $pluginDll
            $envValues['FRACTALSQL_HTTP_URL'] = $Url
            $envValues['FRACTALSQL_HTTP_ALLOW_PLAINTEXT'] = '1'
            $envValues['FRACTALSQL_HTTP_MODEL'] = $Model
            $envValues['FRACTALSQL_HTTP_EMBED_URL'] = $EmbedUrl
            $envValues['FRACTALSQL_HTTP_EMBED_MODEL'] = $EmbedModel
            $envValues['FRACTALSQL_HTTP_THINK'] = $Think
            $envValues['FRACTALSQL_HTTP_THINK_PROVIDER'] = $ThinkProvider
            # Cold-start headroom for a local Ollama: a model that isn't
            # loaded yet can take minutes before its first token, and the
            # plugin's shorter built-in default turns that into a clean
            # NULL. Same values docker-compose.yml sets for the same
            # reason (330000ms / 300s).
            $envValues['FSQL_REASONING_HTTP_TIMEOUT_MS'] = "$($TimeoutSecs * 1000)"
            $envValues['FSQL_REASONING_HTTP_LOW_SPEED_SECS'] = "$([Math]::Max(1, $TimeoutSecs - 30))"
        }
        'openai-compatible' {
            if (-not $Url) { $Url = Prompt-Value "Chat completions URL" }
            if (-not $Url) { Write-Die "a URL is required for a cloud/OpenAI-compatible endpoint" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked, never logged)" }
            $envValues['FRACTALSQL_REASONING_PLUGIN'] = $pluginDll
            $envValues['FRACTALSQL_HTTP_URL'] = $Url
            $envValues['FRACTALSQL_HTTP_TOKEN'] = $Token
            $envValues['FRACTALSQL_HTTP_MODEL'] = $Model
            if ($Url -notlike 'https://*') {
                Write-Warn2 "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            }
        }
        'skip' {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
        }
    }

    $applied = $false
    if ($Provider -ne 'skip') {
        if ($DryRun) {
            Write-Step "About to set (service environment for '$ServiceName'):"
            foreach ($k in $envValues.Keys) {
                if ($k -like '*HTTP_TOKEN*') { Write-Host "  $k=***" } else { Write-Host "  $k=$($envValues[$k])" }
            }
            Write-Step "(-DryRun: not actually applying)"
        } else {
            $applied = Set-ReasoningEnvAndRestart $envValues $bin $myPort
        }
    }

    Write-Step "Registering UDFs + agent procedures..."
    $already = ''
    try { $already = Invoke-MySql $bin $myPort @("SELECT 1 FROM mysql.func WHERE name='fractal_edition';") } catch {}
    if ($already -and -not $ForceReinstall) {
        if (-not (Confirm-Step "fractal_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?")) {
            Write-Die "Nothing to do. Re-run with -ForceReinstall to skip this pause."
        }
    }
    if ($DryRun) {
        Write-Step "(-DryRun: not actually running sql\install_udf.sql or sql\install_agents.sql)"
    } else {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $udfSql = Join-Path $repoRoot 'sql\install_udf.sql'
        $agentsSql = Join-Path $repoRoot 'sql\install_agents.sql'
        if (-not (Test-Path $udfSql)) {
            # Release .msi layout: share\doc\fractalsql-mysql\ under the
            # MySQL install root (see scripts\windows\fractalsql.wxs).
            $udfSql = Join-Path $Target.Dir 'share\doc\fractalsql-mysql\install_udf.sql'
            $agentsSql = Join-Path $Target.Dir 'share\doc\fractalsql-mysql\install_agents.sql'
        }
        if (-not (Test-Path $udfSql)) { Write-Die "install_udf.sql not found in a repo checkout or under $($Target.Dir)\share\doc\fractalsql-mysql\. Run this from an extracted release or a repo checkout." }
        Invoke-MySqlFile $bin $myPort $udfSql -Db $Database | Out-Null
        if (Test-Path $agentsSql) {
            Invoke-MySqlFile $bin $myPort $agentsSql -Db $Database | Out-Null
            Write-Ok "UDFs + agent procedures registered."
        } else {
            # The release .msi ships only install_udf.sql (see
            # scripts\windows\fractalsql.wxs), so a wizard run straight
            # after an MSI install has no agents SQL to source -- warn
            # rather than die, since the UDFs themselves are already in.
            Write-Warn2 "install_agents.sql not found under $($Target.Dir)\share\doc\fractalsql-mysql\ (the .msi ships only install_udf.sql). Agent procedures not registered; run sql\install_agents.sql from a repo checkout to add them."
            Write-Ok "UDFs registered."
        }
    }

    if (-not $DryRun) {
        $ed = Invoke-MySql $bin $myPort @('SELECT fractal_edition();') -Db $Database
        $ver = Invoke-MySql $bin $myPort @('SELECT fractal_version();') -Db $Database
        Write-Ok "fractal_edition() = $ed, fractal_version() = $ver"
        if ($ver -ne $Version) {
            Write-Warn2 "That's not $Version, the version this script expected. The installed fractalsql.dll itself is out of date. Reinstall the current .msi from https://github.com/$Repo/releases over this install to actually update it, then re-run this script."
        }
        if ($Provider -ne 'skip' -and $applied -and (Confirm-Step "Run a live reasoning smoke test (SELECT fractal_reason(CONNECTION_ID(), 'say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time.")) {
            try {
                $reply = Invoke-MySql $bin $myPort @("SELECT fractal_reason(CONNECTION_ID(), 'say ok');") -Db $Database
                Write-Host "  $reply"
            } catch {
                Write-Warn2 "That failed. If it looks like a timeout on a slow/cold local model, see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            }
        } elseif ($Provider -ne 'skip' -and -not $applied) {
            Write-Warn2 "Reasoning config wasn't applied (restart declined or failed), so skipping the smoke test. fractal_reason() will use whatever config the service already has."
        }
    }

    Write-Host ""
    Write-Host "You're set up. Where next:" -ForegroundColor Green
    Write-Host "  - docs/starter-kits.md: industry-specific runnable examples"
    Write-Host "  - docs/api-agency.md: the 16 built-in agents, full reference"
    Write-Host "  - docs/composition-guide.md: build your own agent"
    Write-Host "  - Re-run this script anytime to switch providers or models. It's"
    Write-Host "    safe, but every change needs a service restart to take effect."
}

# --- -Uninstall ---------------------------------------------------------
function Invoke-Uninstall {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $myPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-RootPassword
    Write-Step "This will reset FRACTALSQL_* reasoning env vars and restart the MySQL service."

    if (Confirm-Step "Reset reasoning config now?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually resetting)"
        } else {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
            $elevatedCmd = "Remove-ItemProperty -Path '$regPath' -Name Environment -ErrorAction SilentlyContinue; Restart-Service -Name '$ServiceName' -Force"
            if (Test-IsAdmin) {
                Invoke-Expression $elevatedCmd
            } elseif ([Environment]::UserInteractive) {
                Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd) | Out-Null
            } else {
                Write-Warn2 "Skipping: needs administrator access. Remove the Environment value under $regPath and restart $ServiceName by hand."
            }
            Write-Ok "Reasoning env vars reset."
            Write-Step "Waiting for $script:ServiceName to accept connections..."
            if (-not (Wait-ServerReady $bin $myPort)) {
                Write-Warn2 "$script:ServiceName didn't accept connections within 60s of the restart. Check the error log under the install's data\ directory."
            }
        }
    }

    if (Confirm-Step "Also drop the fractalsql UDFs (deletes any dependent objects too)?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually dropping)"
        } else {
            $dropSql = Invoke-MySql $bin $myPort @("SELECT CONCAT('DROP FUNCTION IF EXISTS ', name, ';') FROM mysql.func WHERE dl='fractalsql.dll';")
            if ($dropSql) { Invoke-MySql $bin $myPort @($dropSql) | Out-Null }
            Write-Ok "UDFs dropped. Agent procedures (fractal_agent_*) aren't UDFs and aren't tracked in mysql.func -- drop them via sql\install_agents.sql's own DROP PROCEDURE list, or by hand."
        }
    }

    Write-Host "  To remove the package: uninstall 'FractalSQL for MySQL' from Windows Settings > Apps, or msiexec /x <product code>"
}

# --- main ------------------------------------------------------------------
$target = Get-MySqlTarget
Write-Step "Targeting MySQL at $($target.Dir) (port $(if ($Port) { $Port } else { $target.Port }))"

if ($Uninstall) {
    Invoke-Uninstall $target
    exit 0
}

# Resolve-PluginDir needs a live connection (SELECT @@plugin_dir), so the
# root password has to be in hand first -- both ahead of Install-Package,
# which itself depends on $script:PluginDir via Test-Installed.
Resolve-RootPassword
Resolve-PluginDir $target
Write-Step "Plugin directory (live @@plugin_dir): $script:PluginDir"

Install-Package $target
Invoke-Wizard $target

<#
.SYNOPSIS
    Installs or updates the OpenCode CLI on Windows and deploys its configuration.

.DESCRIPTION
    - Binary + PATH: per-user, no admin rights needed
      (%LOCALAPPDATA%\Programs\opencode\bin, User PATH).
    - User config: %USERPROFILE%\.config\opencode\opencode.jsonc
      Created if missing. With -UpdateConfig it is overwritten (a timestamped
      .bak copy is kept).
    - System policy: %ProgramData%\opencode\opencode.jsonc
      The only step that needs admin rights. A UAC prompt appears ONLY when
      the file is missing or differs from the repository version. The folder
      is locked down so ordinary users (and agents running as them) can read
      the policy but not change it.
    - API key: ROUTERAI_API_KEY is requested only if it is not set yet
      (checked in Process, User and Machine scopes).

    Works on Windows PowerShell 5.1 and PowerShell 7+.
    Config files are taken from the folder next to this script if it is run
    from a file; otherwise they are downloaded from $BaseUrl.

.PARAMETER BaseUrl
    Raw URL prefix of the repository folder that holds install.ps1,
    system-opencode.jsonc and user-opencode.jsonc. Pin it to a tag or commit.

.PARAMETER UpdateConfig
    Overwrite the existing user config (with a backup).

.PARAMETER SkipSystemPolicy
    Do not touch %ProgramData%\opencode (no UAC prompt).

.EXAMPLE
    irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main/install.ps1))) -UpdateConfig
#>
param(
    [string]$BaseUrl = 'https://raw.githubusercontent.com/ErrOzz/opencode_setup/refs/heads/main',
    [switch]$UpdateConfig,
    [switch]$SkipSystemPolicy
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # big speed-up for downloads in PS 5.1
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- helpers
function Write-Step([string]$Message) { Write-Host "[>] $Message"  -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "[i] $Message"  -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "[!] $Message"  -ForegroundColor Yellow }

function Get-LocalRepoFile([string]$Name) {
    if ($PSScriptRoot) {
        $path = Join-Path $PSScriptRoot $Name
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

# Copies the file from the script folder if present, otherwise downloads it.
function Get-RepoFile([string]$Name, [string]$Destination) {
    $local = Get-LocalRepoFile $Name
    if ($local) {
        Copy-Item -LiteralPath $local -Destination $Destination -Force
        return
    }
    if ($BaseUrl -match '[<>]') {
        throw "BaseUrl still contains placeholders. Edit the default value in install.ps1 or pass -BaseUrl."
    }
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Name" -OutFile $Destination
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- main
try {
    Write-Host '=== OpenCode CLI install / update ===' -ForegroundColor Cyan

    # 1. Stop a running OpenCode so the binary can be replaced
    $running = Get-Process -Name 'opencode' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Warn 'OpenCode is running. Stopping it for the update (unsaved sessions will be closed)...'
        $running | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    # 2. Download and unpack the standalone binary (per-user)
    $binDir = Join-Path $env:LOCALAPPDATA 'Programs\opencode\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $zipPath = Join-Path $env:TEMP "opencode-latest-$PID.zip"
    try {
        Write-Step 'Downloading the latest OpenCode CLI...'
        Invoke-WebRequest -UseBasicParsing -OutFile $zipPath `
            -Uri 'https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-x64.zip'
        Write-Step "Extracting to $binDir ..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $binDir -Force
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    # 3. User PATH (read raw so %VARS% in existing entries are preserved)
    $envKey   = 'HKCU:\Environment'
    $rawPath  = (Get-Item -Path $envKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $entries  = @($rawPath -split ';' | Where-Object { $_ })
    $present  = $entries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
    if (-not $present) {
        Write-Step 'Adding the install folder to the user PATH...'
        $newPath = ($entries + $binDir) -join ';'
        Set-ItemProperty -Path $envKey -Name 'Path' -Value $newPath -Type ExpandString
    }
    if (($env:Path -split ';') -notcontains $binDir) { $env:Path += ";$binDir" }

    # 4. User config (provider + models)
    $userConfigDir  = Join-Path $env:USERPROFILE '.config\opencode'
    $userConfigPath = Join-Path $userConfigDir 'opencode.jsonc'
    New-Item -ItemType Directory -Force -Path $userConfigDir | Out-Null

    if (-not (Test-Path -LiteralPath $userConfigPath)) {
        Write-Step 'User config not found. Creating it from the template...'
        Get-RepoFile 'user-opencode.jsonc' $userConfigPath
    }
    elseif ($UpdateConfig) {
        $backup = "$userConfigPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Write-Step "Updating user config (backup: $backup)..."
        Copy-Item -LiteralPath $userConfigPath -Destination $backup -Force
        Get-RepoFile 'user-opencode.jsonc' $userConfigPath
    }
    else {
        Write-Info 'User config already exists - left untouched (use -UpdateConfig to replace it).'
    }

    # 5. System policy in %ProgramData% (needs admin, only when it changed)
    if ($SkipSystemPolicy) {
        Write-Info 'System policy step skipped (-SkipSystemPolicy).'
    }
    else {
        $policyName = 'system-opencode.jsonc'
        $policyDir  = Join-Path $env:ProgramData 'opencode'
        $policyDest = Join-Path $policyDir 'opencode.jsonc'

        # Compare the repository version with the installed one (no admin needed)
        $tmpPolicy = Join-Path $env:TEMP "opencode-policy-$PID.jsonc"
        try {
            Get-RepoFile $policyName $tmpPolicy
            $upToDate = (Test-Path -LiteralPath $policyDest) -and
                        ((Get-FileHash -LiteralPath $tmpPolicy).Hash -eq
                         (Get-FileHash -LiteralPath $policyDest).Hash)
        }
        finally {
            Remove-Item -LiteralPath $tmpPolicy -Force -ErrorAction SilentlyContinue
        }

        if ($upToDate) {
            Write-Info 'System policy is already up to date.'
        }
        else {
            # The admin part fetches the file itself, so nothing user-writable
            # sits between the download and the protected location.
            $local = Get-LocalRepoFile $policyName
            if ($local) {
                $fetch = "Copy-Item -LiteralPath '$local' -Destination '$policyDest' -Force"
            }
            else {
                $fetch = "Invoke-WebRequest -UseBasicParsing -Uri '$BaseUrl/$policyName' -OutFile '$policyDest'"
            }

            $adminCmd = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
`$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path '$policyDir' | Out-Null
icacls '$policyDir' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if (`$LASTEXITCODE -ne 0) { throw 'icacls failed' }
$fetch
"@

            Write-Step 'Installing the system policy (admin rights required)...'
            if (Test-IsAdmin) {
                & ([scriptblock]::Create($adminCmd))
            }
            else {
                Write-Info 'A UAC prompt will appear - confirm it to continue.'
                $childCmd = "try { $adminCmd } catch { Write-Host `$_.Exception.Message -ForegroundColor Red; Start-Sleep 3; exit 1 }"
                $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCmd))
                $hostExe  = (Get-Process -Id $PID).Path   # same host: pwsh or powershell
                try {
                    $proc = Start-Process -FilePath $hostExe -Verb RunAs -Wait -PassThru `
                        -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded)
                    if ($proc.ExitCode -ne 0) { throw "Elevated step failed (exit code $($proc.ExitCode))." }
                }
                catch [System.ComponentModel.Win32Exception] {
                    throw 'UAC prompt was cancelled - the system policy was NOT installed.'
                }
            }
            Write-Info "System policy installed: $policyDest"
        }
    }

    # 6. API key: ask only if it is not set anywhere
    $keyName  = 'ROUTERAI_API_KEY'
    $keyScope = $null
    foreach ($scope in 'Process', 'User', 'Machine') {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($keyName, $scope))) {
            $keyScope = $scope
            break
        }
    }

    if ($keyScope) {
        Write-Info "$keyName found in $keyScope scope - not asking again."
    }
    else {
        Write-Warn "$keyName is not set."
        $secure = Read-Host 'Enter your RouterAI API key (or press Enter to set it later)' -AsSecureString
        if ($secure.Length -gt 0) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            [Environment]::SetEnvironmentVariable($keyName, $plain, 'User')
            Set-Item -Path "Env:$keyName" -Value $plain
            Write-Step 'API key saved to your user environment variables.'
        }
    }

    # 7. Verify
    Write-Host ''
    try {
        $version = & (Join-Path $binDir 'opencode.exe') --version
        Write-Host "[OK] OpenCode installed: $version" -ForegroundColor Green
    }
    catch {
        Write-Warn 'Installed, but could not run opencode.exe --version.'
    }
    Write-Host 'Open a NEW terminal and run: opencode --version' -ForegroundColor Cyan
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    return
}

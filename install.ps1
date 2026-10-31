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
      this file is missing/differs from the repository version, OR the local
      additions file below does not exist yet. The folder is locked down so
      ordinary users (and agents running as them) can read the policy but
      not change it.
    - Local policy additions: %ProgramData%\opencode\opencode.json
      Created once as an empty template; this script NEVER overwrites it
      again. OpenCode merges it with opencode.jsonc automatically (same
      folder), so you can hand-edit it (admin rights required) to add
      machine-specific allowed paths etc. without them being wiped on the
      next update. Prefer adding new keys there over overriding ones already
      set in opencode.jsonc, since precedence on an actual conflict between
      the two files is not documented upstream - verify with
      `opencode debug config`.
    - API key: ROUTERAI_API_KEY is requested only if it is not set yet
      (checked in Process, User and Machine scopes).

    Works on Windows PowerShell 5.1 and PowerShell 7+.
    Config files are taken from the folder next to this script if it is run
    from a file; otherwise they are downloaded from $BaseUrl.

.PARAMETER BaseUrl
    Raw URL prefix of the repository folder that holds install.ps1,
    opencode-system.jsonc and opencode-user.jsonc. Pin it to a tag or commit.

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

# Synchronous, single-threaded streaming download with a live status line, so
# a big file (the CLI zip) doesn't look like the script has frozen. Falls
# back to a silent Invoke-WebRequest if HttpClient is unavailable for any
# reason - the download still happens, it's just quiet again.
function Get-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Downloading'
    )
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $client = [System.Net.Http.HttpClient]::new()
    }
    catch {
        Write-Warn 'Falling back to a plain (quiet) download.'
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
        return
    }

    try {
        $client.Timeout = [TimeSpan]::FromMinutes(10)
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $total = $response.Content.Headers.ContentLength   # $null if the server doesn't send it

        $inStream  = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [IO.File]::Open($OutFile, [IO.FileMode]::Create)
        try {
            $buffer    = New-Object byte[] 81920
            $readTotal = 0L
            $sw        = [Diagnostics.Stopwatch]::StartNew()
            while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $read)
                $readTotal += $read
                if ($sw.ElapsedMilliseconds -ge 200) {
                    $mb = [math]::Round($readTotal / 1MB, 1)
                    if ($total) {
                        $pct     = [int](($readTotal * 100) / $total)
                        $totalMb = [math]::Round($total / 1MB, 1)
                        Write-Host -NoNewline ("`r    {0}: {1,3}% ({2} / {3} MB)   " -f $Label, $pct, $mb, $totalMb)
                    }
                    else {
                        Write-Host -NoNewline ("`r    {0}: {1} MB   " -f $Label, $mb)
                    }
                    $sw.Restart()
                }
            }
            Write-Host ''
        }
        finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
    }
    finally {
        $client.Dispose()
    }
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
        Get-FileWithProgress -Label 'CLI' -OutFile $zipPath `
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
        Get-RepoFile 'opencode-user.jsonc' $userConfigPath
    }
    elseif ($UpdateConfig) {
        $backup = "$userConfigPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Write-Step "Updating user config (backup: $backup)..."
        Copy-Item -LiteralPath $userConfigPath -Destination $backup -Force
        Get-RepoFile 'opencode-user.jsonc' $userConfigPath
    }
    else {
        Write-Info 'User config already exists - left untouched (use -UpdateConfig to replace it).'
    }

    # 5. System policy in %ProgramData% (needs admin, only when it changed)
    if ($SkipSystemPolicy) {
        Write-Info 'System policy step skipped (-SkipSystemPolicy).'
    }
    else {
        $policyName = 'opencode-system.jsonc'
        $policyDir   = Join-Path $env:ProgramData 'opencode'
        $policyDest  = Join-Path $policyDir 'opencode.jsonc'   # repo-managed base, always synced
        $localPolicy = Join-Path $policyDir 'opencode.json'    # hand-maintained additions, never synced

        # OpenCode merges opencode.json + opencode.jsonc when both are present in the
        # same config directory (non-conflicting keys from each are combined - see
        # https://github.com/anomalyco/opencode/issues/32447). We rely on exactly that:
        # opencode.jsonc stays fully repo-controlled and is overwritten every run;
        # opencode.json is created once as an empty template and is then yours to edit
        # by hand (e.g. extra allowed paths) - this script will never touch it again.
        # Keep the two files' keys non-overlapping where possible, since precedence
        # between them on a CONFLICT is not documented; check the merged result anytime
        # with `opencode debug config`.

        # Compare the repository version with what's installed, and check whether the
        # local-additions file still needs to be created (no admin rights needed for this).
        $tmpPolicy = Join-Path $env:TEMP "opencode-policy-$PID.jsonc"
        try {
            Get-RepoFile $policyName $tmpPolicy
            $baseUpToDate = (Test-Path -LiteralPath $policyDest) -and
                            ((Get-FileHash -LiteralPath $tmpPolicy).Hash -eq
                             (Get-FileHash -LiteralPath $policyDest).Hash)
        }
        finally {
            Remove-Item -LiteralPath $tmpPolicy -Force -ErrorAction SilentlyContinue
        }
        $localMissing = -not (Test-Path -LiteralPath $localPolicy)

        if ($baseUpToDate -and -not $localMissing) {
            Write-Info 'System policy is already up to date.'
        }
        else {
            # The admin part fetches/writes the files itself, so nothing user-writable
            # sits between the download and the protected location.
            $local = Get-LocalRepoFile $policyName
            if ($local) {
                $fetch = "Copy-Item -LiteralPath '$local' -Destination '$policyDest' -Force"
            }
            else {
                $fetch = "Invoke-WebRequest -UseBasicParsing -Uri '$BaseUrl/$policyName' -OutFile '$policyDest'"
            }

            # Only written if opencode.json does not already exist - never overwritten afterwards.
            $localTemplate = @'
{
  // Local additions to the managed OpenCode policy (this machine only).
  //
  // This file is NEVER touched by install.ps1 after it is first created - edit
  // it by hand (admin rights required, same as this whole folder) to add
  // extra allowed paths etc. OpenCode merges it with opencode.jsonc in this
  // same folder automatically.
  //
  // Prefer ADDING keys here rather than overriding ones already set in
  // opencode.jsonc - precedence on a genuine conflict between opencode.json
  // and opencode.jsonc is not documented upstream. Check the merged result
  // with: opencode debug config
  //
  // Example:
  // "permission": {
  //   "read": { "D:/SharedCAD/**": "allow" }
  // }
}
'@
            $encodedTemplate = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($localTemplate))

            $adminCmd = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
`$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path '$policyDir' | Out-Null
icacls '$policyDir' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if (`$LASTEXITCODE -ne 0) { throw 'icacls failed' }
$fetch
if (-not (Test-Path -LiteralPath '$localPolicy')) {
    [IO.File]::WriteAllText('$localPolicy', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedTemplate')))
}
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
            if ($localMissing) {
                Write-Info "Created $localPolicy - edit it by hand (as admin) to add local path overrides."
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
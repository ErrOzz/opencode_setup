#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Установка и обновление OpenCode CLI + развёртывание конфигурации.
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Развёртывание OpenCode CLI ===" -ForegroundColor Cyan

# 1. Завершаем работающий процесс OpenCode, если это обновление
$runningProcess = Get-Process -Name "opencode" -ErrorAction SilentlyContinue
if ($runningProcess) {
    Write-Host "[!] Обнаружен запущенный процесс OpenCode. Завершаем для обновления..." -ForegroundColor Yellow
    Stop-Process -Name "opencode" -Force
    Start-Sleep -Seconds 1
}

# 2. Скачивание и установка бинарника
$binDir = "$env:ProgramFiles\opencode\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$zipPath = "$env:TEMP\opencode-latest.zip"
Write-Host "[>] Скачивание актуальной версии OpenCode..." -ForegroundColor Green
Invoke-WebRequest -Uri "https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-x64.zip" -OutFile $zipPath

Write-Host "[>] Распаковка в $binDir..." -ForegroundColor Green
Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
Remove-Item $zipPath -Force

# 3. Настройка системного PATH
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (($machinePath -split ';') -notcontains $binDir) {
    Write-Host "[>] Добавление $binDir в системный PATH..." -ForegroundColor Green
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$binDir", "Machine")
    $env:Path += ";$binDir"
}

# 4. Системный конфиг безопасности (%ProgramData%)
$programDataDir = "$env:ProgramData\opencode"
New-Item -ItemType Directory -Force -Path $programDataDir | Out-Null
$systemConfigPath = "$programDataDir\opencode.jsonc"

Write-Host "[>] Обновление системного конфига безопасности..." -ForegroundColor Green
# Если файл лежит рядом со скриптом (например, opencode-system.jsonc), копируем его:
if (Test-Path "$PSScriptRoot\opencode-system.jsonc") {
    Copy-Item "$PSScriptRoot\opencode-system.jsonc" -Destination $systemConfigPath -Force
}

# 5. Пользовательский конфиг (%USERPROFILE%)
$userConfigDir = "$env:USERPROFILE\.config\opencode"
New-Item -ItemType Directory -Force -Path $userConfigDir | Out-Null
$userConfigPath = "$userConfigDir\opencode.jsonc"

if (-not (Test-Path $userConfigPath)) {
    Write-Host "[>] Пользовательский конфиг не найден. Создаём начальный шаблон..." -ForegroundColor Green
    if (Test-Path "$PSScriptRoot\opencode-user.jsonc") {
        Copy-Item "$PSScriptRoot\opencode-user.jsonc" -Destination $userConfigPath
    }
} else {
    Write-Host "[i] Пользовательский конфиг уже существует, пропускаем (не затираем)." -ForegroundColor Gray
}

# 6. Проверка переменной окружения
$currentKey = [Environment]::GetEnvironmentVariable("ROUTERAI_API_KEY", "User")
if ([string]::IsNullOrWhiteSpace($currentKey)) {
    Write-Host "[!] Переменная ROUTERAI_API_KEY не найдена в профиле пользователя." -ForegroundColor Yellow
    $keyInput = Read-Host "Введите ваш API-ключ RouterAI (или нажмите Enter, чтобы настроить позже)"
    if (-not [string]::IsNullOrWhiteSpace($keyInput)) {
        [Environment]::SetEnvironmentVariable("ROUTERAI_API_KEY", $keyInput.Trim(), "User")
        Write-Host "[+] Ключ сохранён в пользовательских переменных среды." -ForegroundColor Green
    }
}

Write-Host "`n[OK] OpenCode успешно установлен/обновлен!" -ForegroundColor Green
Write-Host "Перезапустите терминал и выполните команду: opencode --version" -ForegroundColor Cyan
<#
.SYNOPSIS
    Yangi kompyuterga standart dasturlar to'plamini winget orqali o'rnatish.

.DESCRIPTION
    Dasturlar ro'yxati apps.json faylida. Standart holatda faqat REJA ko'rsatiladi (nima o'rnatilgan,
    nima o'rnatilishi kerak). Haqiqatan o'rnatish uchun -Apply kaliti beriladi.
    10 ta yangi kompyuterni qo'lda sozlash o'rniga bitta buyruq: hamma joyda bir xil versiyalar.

.EXAMPLE
    .\Install-Workstation.ps1                       # reja (hech narsa o'rnatilmaydi)
    .\Install-Workstation.ps1 -Category multimedia   # faqat "multimedia" profilidagi dasturlar
    .\Install-Workstation.ps1 -Apply                # o'rnatish
#>
[CmdletBinding()]
param(
    [string]$AppList = (Join-Path $PSScriptRoot 'apps.json'),
    [string]$Category = 'base',
    [switch]$Apply
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'winget topilmadi. Microsoft Store''dan "App Installer" ni o''rnating.' -ForegroundColor Red
    exit 2
}

$config = Get-Content $AppList -Raw -Encoding UTF8 | ConvertFrom-Json
$apps = @($config.profiles.$Category)
if (-not $apps.Count) { Write-Host "Profil topilmadi: $Category" -ForegroundColor Red; exit 2 }

Write-Host "Profil: $Category ($($apps.Count) ta dastur)  Rejim: $(if ($Apply) { 'O''RNATISH' } else { 'REJA (o''zgarish yo''q)' })`n" -ForegroundColor Cyan

$summary = @{ Installed = 0; ToInstall = 0; Done = 0; Failed = 0 }
foreach ($app in $apps) {
    # winget list --id: dastur o'rnatilgan bo'lsa exit code 0
    winget list --id $app.id --exact --accept-source-agreements --disable-interactivity *> $null
    $isInstalled = ($LASTEXITCODE -eq 0)

    if ($isInstalled) {
        $summary.Installed++
        Write-Host ("  [bor]       {0,-28} {1}" -f $app.name, $app.id) -ForegroundColor DarkGray
        continue
    }
    if (-not $Apply) {
        $summary.ToInstall++
        Write-Host ("  [o'rnatish] {0,-28} {1}" -f $app.name, $app.id) -ForegroundColor Yellow
        continue
    }
    Write-Host ("  [...]       {0,-28} o'rnatilmoqda" -f $app.name) -ForegroundColor Cyan
    winget install --id $app.id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) { $summary.Done++; Write-Host "              tayyor" -ForegroundColor Green }
    else { $summary.Failed++; Write-Host "              XATO (kod $LASTEXITCODE)" -ForegroundColor Red }
}

Write-Host ("`nO'rnatilgan edi: {0}   O'rnatish kerak: {1}   O'rnatildi: {2}   Xato: {3}" -f
    $summary.Installed, $summary.ToInstall, $summary.Done, $summary.Failed)
if (-not $Apply -and $summary.ToInstall) { Write-Host "O'rnatish uchun:  .\Install-Workstation.ps1 -Category $Category -Apply" -ForegroundColor Cyan }
if ($summary.Failed) { exit 1 } else { exit 0 }

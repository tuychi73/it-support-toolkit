<#
.SYNOPSIS
    Kompyuterning to'liq texnik pasporti (inventarizatsiya): HTML hisobot + JSON.

.DESCRIPTION
    Protsessor, xotira modullari, disklar va ularning holati (Health Status), videokarta, tarmoq adapterlari,
    BIOS, batareya, xatoli qurilmalar (drayveri yo'q yoki ishlamayotgan) va o'rnatilgan dasturlar.
    JSON fayllar keyinchalik barcha kompyuterlar bo'yicha umumiy inventar jadvaliga birlashtiriladi.
    Administrator huquqi talab qilinmaydi.

.EXAMPLE
    .\Get-SystemReport.ps1
    .\Get-SystemReport.ps1 -OutDir \\server\inventory -Anonymize
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'reports'),
    # Seriya raqami, MAC, IP va foydalanuvchi nomini yashiradi (hisobotni internetga qo'yish uchun)
    [switch]$Anonymize
)

$ErrorActionPreference = 'Stop'

function Mask([string]$Value) {
    if (-not $Anonymize -or [string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -le 4) { return '****' }
    return $Value.Substring(0, 2) + ('*' * ($Value.Length - 4)) + $Value.Substring($Value.Length - 2)
}

function Get-Safe([scriptblock]$Block) {
    # Bitta bo'lim xato bersa (masalan, batareya yo'q), butun hisobot to'xtamasligi kerak
    try { & $Block } catch { Write-Verbose "O'tkazib yuborildi: $($_.Exception.Message)"; $null }
}

Write-Host 'Ma''lumotlar yig''ilmoqda...' -ForegroundColor Cyan

$cs   = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1

$report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Computer    = [ordered]@{
        Name         = Mask $env:COMPUTERNAME
        User         = Mask $env:USERNAME
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        SerialNumber = Mask $bios.SerialNumber
        BIOS         = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('yyyy-MM-dd')))"
    }
    OS = [ordered]@{
        Name        = $os.Caption
        Version     = "$($os.Version) (build $($os.BuildNumber))"
        Arch        = $os.OSArchitecture
        InstallDate = $os.InstallDate.ToString('yyyy-MM-dd')
        LastBoot    = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        UptimeDays  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    }
    CPU = [ordered]@{
        Name    = $cpu.Name.Trim()
        Cores   = $cpu.NumberOfCores
        Threads = $cpu.NumberOfLogicalProcessors
        MaxMHz  = $cpu.MaxClockSpeed
        LoadPct = $cpu.LoadPercentage
    }
    Memory = [ordered]@{
        TotalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        FreeGB  = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        Modules = @(Get-Safe { Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
            [ordered]@{ Slot = $_.DeviceLocator; SizeGB = [math]::Round($_.Capacity / 1GB, 1)
                        SpeedMHz = $_.Speed; Manufacturer = "$($_.Manufacturer)".Trim() } } })
    }
    PhysicalDisks = @(Get-Safe { Get-PhysicalDisk | ForEach-Object {
        [ordered]@{ Name = $_.FriendlyName; Type = "$($_.MediaType)"; Bus = "$($_.BusType)"
                    SizeGB = [math]::Round($_.Size / 1GB); Health = "$($_.HealthStatus)" } } })
    Volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [ordered]@{ Drive = $_.DeviceID; FileSystem = $_.FileSystem
                    SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1)
                    FreePct = if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size) } else { 0 } } })
    GPU = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{ Name = $_.Name; Driver = $_.DriverVersion
                    Resolution = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } })
    Network = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {
        [ordered]@{ Adapter = $_.Description; MAC = Mask $_.MACAddress
                    IPv4 = Mask (($_.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', ')
                    Gateway = Mask ($_.DefaultIPGateway -join ', '); DNS = Mask ($_.DNSServerSearchOrder -join ', ')
                    DHCP = $_.DHCPEnabled } })
    Battery = @(Get-Safe { Get-CimInstance Win32_Battery | ForEach-Object {
        [ordered]@{ Name = $_.Name; ChargePct = $_.EstimatedChargeRemaining; Status = $_.Status } } })
    # ConfigManagerErrorCode <> 0: Qurilmalar dispetcheridagi "sariq belgi" (drayver yo'q, o'chirilgan, xato)
    ProblemDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object {
        [ordered]@{ Name = $_.Name; Class = $_.PNPClass; ErrorCode = $_.ConfigManagerErrorCode } })
    Software = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Sort-Object DisplayName -Unique |
        ForEach-Object { [ordered]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher } })
}

# ---------------- HTML ----------------
function Enc([object]$v) { [System.Net.WebUtility]::HtmlEncode("$v") }

function Table([string]$Title, [object[]]$Rows) {
    if (-not $Rows -or $Rows.Count -eq 0) { return "<h2>$Title</h2><p class='muted'>Ma'lumot yo'q</p>" }
    $cols = @($Rows[0].Keys)
    $head = ($cols | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
    $body = ($Rows | ForEach-Object { $r = $_; '<tr>' + (($cols | ForEach-Object { "<td>$(Enc $r[$_])</td>" }) -join '') + '</tr>' }) -join "`n"
    return "<h2>$Title</h2><div class='wrap'><table><thead><tr>$head</tr></thead><tbody>$body</tbody></table></div>"
}

function KeyValue([string]$Title, $Dict) {
    $rows = ($Dict.Keys | Where-Object { $Dict[$_] -isnot [array] } | ForEach-Object { "<tr><th>$(Enc $_)</th><td>$(Enc $Dict[$_])</td></tr>" }) -join ''
    return "<div class='box'><h2>$Title</h2><table class='kv'>$rows</table></div>"
}

$problems = $report.ProblemDevices.Count
$lowDisk  = @($report.Volumes | Where-Object { $_.FreePct -lt 15 }).Count
$badDisk  = @($report.PhysicalDisks | Where-Object { $_.Health -and $_.Health -ne 'Healthy' }).Count
$summary  = if ($problems + $lowDisk + $badDisk -eq 0) { "<p class='ok'>Jiddiy muammo topilmadi</p>" } else {
    "<p class='bad'>E'tibor talab qiladi: xatoli qurilmalar $problems ta, kam joy qolgan disklar $lowDisk ta, nosoz disklar $badDisk ta</p>" }

$html = @"
<!doctype html><html lang="uz"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Texnik pasport: $(Enc $report.Computer.Name)</title>
<style>
 body{font-family:'Segoe UI',Arial,sans-serif;margin:0;padding:24px;background:#f5f6f8;color:#1d2330;font-size:14px}
 h1{margin:0 0 4px;font-size:22px} h2{font-size:15px;margin:22px 0 8px;color:#1e3a8a}
 .muted{color:#6b7280} .ok{color:#15803d;font-weight:600} .bad{color:#b91c1c;font-weight:600}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px}
 .box{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:4px 14px 12px}
 .wrap{overflow-x:auto;background:#fff;border:1px solid #e5e7eb;border-radius:10px}
 table{border-collapse:collapse;width:100%} th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #eef0f3;vertical-align:top}
 thead th{background:#f9fafb;color:#6b7280;font-weight:600} .kv th{width:38%;color:#6b7280;font-weight:600}
</style></head><body>
<h1>Kompyuter texnik pasporti: $(Enc $report.Computer.Name)</h1>
<div class="muted">Yaratildi: $(Enc $report.GeneratedAt)</div>
$summary
<div class="grid">
$(KeyValue 'Kompyuter' $report.Computer)
$(KeyValue 'Operatsion tizim' $report.OS)
$(KeyValue 'Protsessor' $report.CPU)
$(KeyValue 'Operativ xotira' $report.Memory)
</div>
$(Table 'Xotira modullari' $report.Memory.Modules)
$(Table 'Fizik disklar' $report.PhysicalDisks)
$(Table "Bo'limlar (volumes)" $report.Volumes)
$(Table 'Videokarta' $report.GPU)
$(Table 'Tarmoq' $report.Network)
$(Table 'Batareya' $report.Battery)
$(Table 'Xatoli qurilmalar (Device Manager)' $report.ProblemDevices)
$(Table "O'rnatilgan dasturlar ($($report.Software.Count) ta)" $report.Software)
</body></html>
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$base = Join-Path $OutDir ("{0}_{1}" -f $report.Computer.Name.Replace('*', 'x'), (Get-Date -Format 'yyyyMMdd_HHmm'))
[System.IO.File]::WriteAllText("$base.html", $html, (New-Object System.Text.UTF8Encoding $true))
[System.IO.File]::WriteAllText("$base.json", ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))

Write-Host "Tayyor:" -ForegroundColor Green
Write-Host "  $base.html"
Write-Host "  $base.json"
Write-Host ("  Xatoli qurilmalar: {0}, kam joyli disklar: {1}, nosoz disklar: {2}, dasturlar: {3}" -f $problems, $lowDisk, $badDisk, $report.Software.Count)

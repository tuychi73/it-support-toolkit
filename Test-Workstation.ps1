<#
.SYNOPSIS
    Kompyuterni tezkor diagnostika qilish: muammolarni topadi va nima qilish kerakligini aytadi.

.DESCRIPTION
    Foydalanuvchi "kompyuter sekin ishlayapti / internet yo'q / printer chiqarmayapti" deganda
    texnik xodim birinchi bo'lib ishga tushiradigan tekshiruvlar to'plami.
    Har bir tekshiruv natijasi: OK / WARN / FAIL + tavsiya.
    Chiqish kodi: 0 = hammasi joyida, 1 = ogohlantirish bor, 2 = jiddiy muammo bor (monitoring tizimlari uchun).

.EXAMPLE
    .\Test-Workstation.ps1
    .\Test-Workstation.ps1 -Json | Out-File result.json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$InternetHost = '8.8.8.8',
    [string]$DnsName = 'google.com'
)

$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Area, [string]$Check, [ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
                    [string]$Detail, [string]$Advice = '') {
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Advice = $Advice })
}

function Invoke-Check([string]$Area, [string]$Check, [scriptblock]$Block) {
    try { & $Block }
    catch { Add-Result $Area $Check 'WARN' "Tekshirib bo'lmadi: $($_.Exception.Message)" 'Administrator sifatida qayta ishga tushirib ko''ring' }
}

# ---------- Disk ----------
Invoke-Check 'Disk' "Bo'sh joy" {
    foreach ($v in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $pct = [math]::Round(100 * $v.FreeSpace / $v.Size)
        $free = [math]::Round($v.FreeSpace / 1GB, 1)
        if ($pct -lt 5) { Add-Result 'Disk' "Bo'sh joy $($v.DeviceID)" 'FAIL' "$free GB ($pct%)" 'Temp fayllar, Yuklamalar va Savatni tozalang; "Disk Cleanup" ishga tushiring' }
        elseif ($pct -lt 15) { Add-Result 'Disk' "Bo'sh joy $($v.DeviceID)" 'WARN' "$free GB ($pct%)" 'Tez orada joy tugaydi: keraksiz fayllarni tozalang' }
        else { Add-Result 'Disk' "Bo'sh joy $($v.DeviceID)" 'OK' "$free GB ($pct%)" }
    }
}
Invoke-Check 'Disk' 'Disk holati' {
    foreach ($d in Get-PhysicalDisk) {
        if ($d.HealthStatus -eq 'Healthy') { Add-Result 'Disk' "Holati: $($d.FriendlyName)" 'OK' "$($d.MediaType), $($d.HealthStatus)" }
        else { Add-Result 'Disk' "Holati: $($d.FriendlyName)" 'FAIL' "$($d.HealthStatus)" 'Ma''lumotlarning zaxira nusxasini DARHOL oling va diskni almashtiring' }
    }
}

# ---------- Tizim ----------
Invoke-Check 'Tizim' 'Operativ xotira' {
    $os = Get-CimInstance Win32_OperatingSystem
    $used = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
    $top = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 |
            ForEach-Object { "$($_.ProcessName) $([math]::Round($_.WorkingSet64 / 1MB)) MB" }) -join ', '
    if ($used -ge 90) { Add-Result 'Tizim' 'Operativ xotira' 'WARN' "$used% band. Eng ko'p: $top" 'Keraksiz dasturlarni yoping; doimiy bo''lsa RAM qo''shish kerak' }
    else { Add-Result 'Tizim' 'Operativ xotira' 'OK' "$used% band" }
}
Invoke-Check 'Tizim' 'Uzluksiz ishlash vaqti' {
    $days = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalDays, 1)
    if ($days -gt 14) { Add-Result 'Tizim' 'Uzluksiz ishlash vaqti' 'WARN' "$days kun qayta yuklanmagan" 'Kompyuterni qayta ishga tushiring (yangilanishlar o''rnatiladi, xotira tozalanadi)' }
    else { Add-Result 'Tizim' 'Uzluksiz ishlash vaqti' 'OK' "$days kun" }
}
Invoke-Check 'Tizim' 'Kutilayotgan qayta yuklash' {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if ($keys | Where-Object { Test-Path $_ }) { Add-Result 'Tizim' 'Kutilayotgan qayta yuklash' 'WARN' 'Yangilanishlar qayta yuklashni kutmoqda' 'Ish tugagach kompyuterni qayta yuklang' }
    else { Add-Result 'Tizim' 'Kutilayotgan qayta yuklash' 'OK' "Yo'q" }
}
Invoke-Check 'Tizim' 'Xatoli qurilmalar' {
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($bad.Count) { Add-Result 'Tizim' 'Xatoli qurilmalar' 'WARN' (($bad | Select-Object -First 5 | ForEach-Object { "$($_.Name) (kod $($_.ConfigManagerErrorCode))" }) -join '; ') 'Device Manager: drayverni yangilang yoki qayta o''rnating; kod 22 - qurilma o''chirilgan' }
    else { Add-Result 'Tizim' 'Xatoli qurilmalar' 'OK' "Yo'q" }
}
Invoke-Check 'Tizim' "So'nggi 24 soatdagi jiddiy xatolar" {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 200 -ErrorAction SilentlyContinue)
    if ($ev.Count -ge 10) {
        $top = ($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        Add-Result 'Tizim' "Jurnal xatolari (24 soat)" 'WARN' "$($ev.Count) ta. Ko'p uchraydigan: $top" 'Event Viewer > Windows Logs > System: manbasini tekshiring'
    } else { Add-Result 'Tizim' "Jurnal xatolari (24 soat)" 'OK' "$($ev.Count) ta" }
}

# ---------- Tarmoq ----------
Invoke-Check 'Tarmoq' 'Tarmoq adapteri' {
    $up = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up')
    if ($up.Count) { Add-Result 'Tarmoq' 'Tarmoq adapteri' 'OK' (($up | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ') }
    else { Add-Result 'Tarmoq' 'Tarmoq adapteri' 'FAIL' 'Ulangan adapter yo''q' 'Kabelni / Wi-Fi ni tekshiring, adapter Device Manager''da yoqilganmi' }
}
$gw = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { $_.DefaultIPGateway } | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1
Invoke-Check 'Tarmoq' 'Router (gateway)' {
    if (-not $gw) { Add-Result 'Tarmoq' 'Router (gateway)' 'FAIL' 'Gateway yo''q' 'IP manzil olinmagan: ipconfig /release va /renew, routerni tekshiring' ; return }
    if (Test-Connection $gw -Count 2 -Quiet) { Add-Result 'Tarmoq' 'Router (gateway)' 'OK' "$gw javob beradi" }
    else { Add-Result 'Tarmoq' 'Router (gateway)' 'FAIL' "$gw javob bermadi" 'Router yoqilganmi, kabel ulanganmi; routerni qayta yuklang' }
}
Invoke-Check 'Tarmoq' 'Internet' {
    if (Test-Connection $InternetHost -Count 2 -Quiet) { Add-Result 'Tarmoq' 'Internet' 'OK' "$InternetHost javob beradi" }
    else { Add-Result 'Tarmoq' 'Internet' 'FAIL' "$InternetHost javob bermadi" 'Router ishlasa-yu internet bo''lmasa: provayder bilan bog''laning' }
}
Invoke-Check 'Tarmoq' 'DNS' {
    $ip = (Resolve-DnsName $DnsName -Type A -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1).IPAddress
    Add-Result 'Tarmoq' 'DNS' 'OK' "$DnsName -> $ip"
}

# ---------- Xavfsizlik ----------
Invoke-Check 'Xavfsizlik' 'Antivirus (Defender)' {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $age = [math]::Round(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays)
    if (-not $mp.RealTimeProtectionEnabled) { Add-Result 'Xavfsizlik' 'Antivirus (Defender)' 'FAIL' 'Real vaqtda himoya o''chirilgan' 'Windows Security > Virus & threat protection: yoqing' }
    elseif ($age -gt 7) { Add-Result 'Xavfsizlik' 'Antivirus (Defender)' 'WARN' "Bazalar $age kun eski" 'Windows Update orqali yangilang' }
    else { Add-Result 'Xavfsizlik' 'Antivirus (Defender)' 'OK' "Yoqilgan, bazalar $age kunlik" }
}
Invoke-Check 'Xavfsizlik' 'Firewall' {
    $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
    if ($off.Count) { Add-Result 'Xavfsizlik' 'Firewall' 'WARN' ("O'chirilgan profillar: " + ($off.Name -join ', ')) 'Firewall''ni yoqing (ayniqsa Public profil)' }
    else { Add-Result 'Xavfsizlik' 'Firewall' 'OK' 'Barcha profillar yoqilgan' }
}

# ---------- Printerlar ----------
Invoke-Check 'Printer' 'Printerlar' {
    $printers = @(Get-CimInstance Win32_Printer | Where-Object { $_.Name -notmatch 'PDF|XPS|OneNote|Fax' })
    if (-not $printers.Count) { Add-Result 'Printer' 'Printerlar' 'OK' "Fizik printer o'rnatilmagan"; return }
    foreach ($p in $printers) {
        $jobs = @(Get-CimInstance Win32_PrintJob | Where-Object { $_.Name -like "$($p.Name),*" }).Count
        if ($p.WorkOffline) { Add-Result 'Printer' $p.Name 'FAIL' 'Offline' 'Printer yoqilganmi, kabel/Wi-Fi; Print Spooler xizmatini qayta ishga tushiring' }
        elseif ($jobs -gt 5) { Add-Result 'Printer' $p.Name 'WARN' "Navbatda $jobs ta hujjat" 'Navbat "tiqilib" qolgan bo''lishi mumkin: navbatni tozalang' }
        else { Add-Result 'Printer' $p.Name 'OK' "Navbatda $jobs ta hujjat" }
    }
}

# ---------- Natija ----------
if ($Json) { $results | ConvertTo-Json -Depth 3; }
else {
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    Write-Host "`nDiagnostika: $env:COMPUTERNAME  $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n" -ForegroundColor Cyan
    foreach ($r in $results) {
        Write-Host ("[{0,-4}] " -f $r.Status) -ForegroundColor $color[$r.Status] -NoNewline
        Write-Host ("{0,-10} {1,-34} {2}" -f $r.Area, $r.Check, $r.Detail)
        if ($r.Advice -and $r.Status -ne 'OK') { Write-Host ("       -> {0}" -f $r.Advice) -ForegroundColor DarkGray }
    }
    $s = $results | Group-Object Status -NoElement | ForEach-Object { "$($_.Name): $($_.Count)" }
    Write-Host ("`nJami: " + ($s -join ', '))
}

if ($results.Status -contains 'FAIL') { exit 2 } elseif ($results.Status -contains 'WARN') { exit 1 } else { exit 0 }

<#
.SYNOPSIS
    Lokal tarmoqdagi faol qurilmalarni topish: IP, nomi, MAC manzil.

.DESCRIPTION
    Robo-gid, proyektor yoki printerning IP manzili noma'lum bo'lsa yoki tarmoqqa
    ulangan-ulanmaganini tekshirish kerak bo'lganda ishlatiladi.
    Ping so'rovlari parallel (asinxron) yuboriladi: 254 ta manzil ~2 soniyada tekshiriladi.
    FAQAT o'zingizga tegishli yoki ruxsat berilgan tarmoqda ishlating.

.EXAMPLE
    .\Find-NetworkDevices.ps1                          # joriy tarmoq (gateway asosida avtomatik)
    .\Find-NetworkDevices.ps1 -Subnet 192.168.10 -From 1 -To 100
    .\Find-NetworkDevices.ps1 | Export-Csv devices.csv -NoTypeInformation -Encoding UTF8
#>
[CmdletBinding()]
param(
    [string]$Subnet,
    [ValidateRange(1, 254)][int]$From = 1,
    [ValidateRange(1, 254)][int]$To = 254,
    [int]$TimeoutMs = 800
)

if (-not $Subnet) {
    $gw = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
          ForEach-Object { $_.DefaultIPGateway } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if (-not $gw) { Write-Error 'Gateway topilmadi, -Subnet ni qo''lda kiriting (masalan 192.168.1)'; exit 2 }
    $Subnet = ($gw -split '\.')[0..2] -join '.'
}

Write-Host "Skanerlanmoqda: $Subnet.$From - $Subnet.$To" -ForegroundColor Cyan

# Har bir manzil uchun asinxron ping: Task'lar parallel bajariladi
$tasks = foreach ($i in $From..$To) {
    $ip = "$Subnet.$i"
    [pscustomobject]@{ IP = $ip; Task = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip, $TimeoutMs) }
}
[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks.Task) 2>$null

$alive = $tasks | Where-Object { $_.Task.Status -eq 'RanToCompletion' -and $_.Task.Result.Status -eq 'Success' }

# MAC manzillar ARP jadvalidan (ping'dan keyin to'ladi)
$arp = @{}
Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
    ForEach-Object { $arp[$_.IPAddress] = $_.LinkLayerAddress }

$result = foreach ($a in $alive) {
    $name = try { [System.Net.Dns]::GetHostEntry($a.IP).HostName } catch { '' }
    [pscustomobject]@{
        IP        = $a.IP
        Name      = $name
        MAC       = $arp[$a.IP]
        LatencyMs = $a.Task.Result.RoundtripTime
    }
}
$result = $result | Sort-Object { [version]$_.IP }
Write-Host "Topildi: $(@($result).Count) ta qurilma`n" -ForegroundColor Green
$result

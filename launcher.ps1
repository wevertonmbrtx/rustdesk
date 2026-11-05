$ErrorActionPreference = 'Stop'

# [Net.SecurityProtocolType]::Tls12 não existe no .NET 3.5 (PowerShell 2.0 do Windows 7).
# Usa o valor numérico (3072) e segue em frente se o .NET não suportar: o Save-Url tem fallback.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$desktop   = [Environment]::GetFolderPath('Desktop')
$iconDir   = Join-Path $env:LOCALAPPDATA 'RustDeskLauncher'
$iconPath  = Join-Path $iconDir 'rustdesk.ico'
$lnkPath   = Join-Path $desktop 'RustDesk.lnk'
$batchPath = Join-Path $env:TEMP 'initrd.bat'
$progPath  = Join-Path $env:TEMP 'progress.ps1'
$batchUrl  = 'https://wevertonmbrtx.github.io/rustdesk/initrd.bat'
# Ícone externo, baixado a cada execução (o rustdesk.exe portátil é apagado depois do uso):
# primeiro o do repositório oficial do RustDesk; a cópia deste repositório só entra se o
# arquivo oficial mudar de lugar. O dl.flathub.org, usado antes, tem o mesmo logo, mas não
# aceita nenhuma cifra TLS do Windows 7.
$iconUrls  = @(
    'https://raw.githubusercontent.com/rustdesk/rustdesk/master/res/icon.ico',
    'https://wevertonmbrtx.github.io/rustdesk/rustdesk.ico'
)

function Get-UrlBytes([string]$Url) {
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        return ,$wc.DownloadData($Url)
    } catch {}
    # Fallback WinINet (mesma pilha do Internet Explorer): faz TLS 1.2 no Windows 7 mesmo sem
    # a atualização de TLS do .NET 3.5 que o WebClient do PowerShell 2.0 precisaria.
    # Não segue redirecionamento para outro domínio, então use URLs finais.
    $x = New-Object -ComObject MSXML2.XMLHTTP
    $x.open('GET', $Url, $false)
    $x.send()
    if ($x.status -ne 200) { throw "HTTP $($x.status): $Url" }
    return ,[byte[]]$x.responseBody
}

function Save-Url([string]$Url, [string]$Path) {
    [IO.File]::WriteAllBytes($Path, (Get-UrlBytes $Url))
}

try {
    if (-not (Test-Path $iconDir)) {
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    }
} catch {}
$iconOk = $false
foreach ($u in $iconUrls) {
    try {
        $b = Get-UrlBytes $u
        # Só aceita um .ico de verdade (cabeçalho 00 00 01 00), nunca uma página de erro
        if ($b.Length -gt 6 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0) {
            [IO.File]::WriteAllBytes($iconPath, $b)
            $iconOk = $true
            break
        }
    } catch {}
}
if (-not $iconOk) { Write-Warning "Can't download icon" }

$url = $batchUrl
$q   = [char]34
$a   = [char]38

$cmd = '%SystemRoot%\System32\cmd.exe'
$tmp = '%TEMP%\initrd.bat'

if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    $lnkArgs = '/c ' + $q + 'curl -fsSL -o ' + $q + $tmp + $q + ' ' + $q + $url + $q + ' ' + $a + ' call ' + $q + $tmp + $q + $q
} else {
    # Windows 7/8.1 não têm curl.exe, e o certutil não faz TLS 1.2 no Windows 7. O atalho baixa pelo
    # PowerShell: o initrd.bat garante .NET 4.5 + PowerShell 5 antes de recriar este atalho.
    $dl = '[Net.ServicePointManager]::SecurityProtocol=3072;(New-Object Net.WebClient).DownloadFile(' + "'" + $url + "'" + ',$env:TEMP+' + "'\initrd.bat')"
    $lnkArgs = '/c ' + $q + 'powershell -NoProfile -ExecutionPolicy Bypass -Command ' + $q + $dl + $q + ' ' + $a + ' call ' + $q + $tmp + $q + $q
}

try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($ws.SpecialFolders.Item('Desktop') + '\RustDesk.lnk')
    $lnk.TargetPath  = $cmd
    $lnk.Arguments   = $lnkArgs
    $lnk.WindowStyle = 1
    $lnk.Description = 'RustDesk Reset'
    # Sempre o .ico baixado: o rustdesk.exe portátil é apagado depois do uso, e o instalado pode não existir
    if (Test-Path -LiteralPath $iconPath) { $lnk.IconLocation = "$iconPath,0" }
    $lnk.Save()
} catch {
    Write-Warning "Can't create shortcut: $_"
}

try {
    Save-Url $batchUrl $batchPath
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

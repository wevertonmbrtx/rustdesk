$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '   ' -NoNewline
Write-Host 'Disclaimer:' -ForegroundColor Cyan -NoNewline
Write-Host ' This script is not affiliated with or endorsed by RustDesk.' -ForegroundColor White

# Texto secundário em cinza para dar contraste e legibilidade
Write-Host '   It does not modify or redistribute the software; it only downloads the official version' -ForegroundColor Gray
Write-Host '   from GitHub and runs it in portable mode if not installed.' -ForegroundColor Gray

# Marca em destaque
Write-Host '   ' -NoNewline
Write-Host 'RustDesk' -ForegroundColor Cyan -NoNewline
Write-Host "$([char]0x2122) is a trademark of its respective owner." -ForegroundColor Gray

Write-Host '   ' -NoNewline
Write-Host 'Script Repository:' -ForegroundColor White -NoNewline
Write-Host ' https://github.com/wevertonmbrtx/rustdesk' -ForegroundColor Blue

Write-Host '   ' -NoNewline
Write-Host 'Report Issues:' -ForegroundColor White -NoNewline
Write-Host ' https://github.com/wevertonmbrtx/rustdesk/issues' -ForegroundColor Blue
Write-Host ''

# [Net.SecurityProtocolType]::Tls12 não existe no .NET 3.5 (PowerShell 2.0 do Windows 7).
# Usa o valor numérico (3072) e segue em frente se o .NET não suportar: o Save-Url tem fallback.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$desktop   = [Environment]::GetFolderPath('Desktop')
$iconDir   = Join-Path $env:LOCALAPPDATA 'RustDeskLauncher'
$iconPath  = Join-Path $iconDir 'rustdesk.ico'
$lnkPath   = Join-Path $desktop 'RustDesk.lnk'
$batchPath = Join-Path $env:TEMP 'initrd.bat'
$progPath  = Join-Path $env:TEMP 'progress.ps1'
$doneFlag  = Join-Path $env:TEMP 'rustdesk_done.txt'
$portableDir = Join-Path $env:LOCALAPPDATA 'RustDesk'
$batchUrl  = 'https://wevertonmbrtx.github.io/rustdesk/initrd.bat'
$launcherUrl = 'https://wevertonmbrtx.github.io/rustdesk/launcher.ps1'
# Ícone baixado a cada execução do repositório oficial do RustDesk (o rustdesk.exe portátil é
# apagado depois do uso). O logo é marca do RustDesk, por isso este repositório não guarda uma
# cópia: se o arquivo oficial mudar de lugar, o atalho fica sem ícone até a URL ser atualizada.
# O dl.flathub.org, usado antes, tem o mesmo logo, mas não aceita nenhuma cifra TLS do Windows 7.
$iconUrls  = @(
    'https://raw.githubusercontent.com/rustdesk/rustdesk/master/res/icon.ico'
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

# O atalho só chama este launcher, o único orquestrador. Baixa pelo WinINet (MSXML2), que faz TLS 1.2
# em qualquer Windows, inclusive com o PowerShell 2.0 do Windows 7.
$cmd     = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
$dl      = '$x=New-Object -Com MSXML2.XMLHTTP;$x.open(''GET'',''' + $launcherUrl + ''',$false);$x.send();iex $x.responseText'
$lnkArgs = '-NoProfile -ExecutionPolicy Bypass -Command "' + $dl + '"'

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

Remove-Item $doneFlag -Force -ErrorAction SilentlyContinue
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$batchPath`""
Write-Host 'Ao fechar o RustDesk, esta janela faz a limpeza dos arquivos baixados.'

# Espera o initrd.bat avisar que terminou: instalar dependências pode demorar, e um reinício encerra
# esta janela. Sem o aviso (UAC recusado, erro), sai sem apagar nada: a próxima execução grava por cima.
$deadline = (Get-Date).AddHours(1)
while (-not (Test-Path $doneFlag)) {
    if ((Get-Date) -gt $deadline) { return }
    Start-Sleep -Seconds 2
}

# O usuário parou de usar quando não há mais processo do RustDesk. Com o serviço registrado, o
# RustDesk instalado fica sempre rodando, então não há o que esperar.
$absentStreak = 0
while ($absentStreak -lt 3) {
    if ((Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) -or
        -not (Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue)) {
        $absentStreak++
    } else {
        $absentStreak = 0
    }
    Start-Sleep -Seconds 2
}

Remove-Item $doneFlag -Force -ErrorAction SilentlyContinue

# Cópia portátil: apaga primeiro o .exe. Se ele estiver rodando ou não existir, o Remove-Item falha e
# a pasta fica intacta. As configurações, em %APPDATA%\RustDesk, não são tocadas.
try {
    Remove-Item (Join-Path $portableDir 'rustdesk.exe') -Force -ErrorAction Stop
    Remove-Item $portableDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

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

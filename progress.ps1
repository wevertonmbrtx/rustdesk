param(
    # Arquivo escrito pelo initrd.bat a cada etapa: "inicio;fim;texto;tipo" (tipo = vazio, open ou fail)
    [string]$StatusFile = (Join-Path $env:TEMP 'rustdesk_progress.txt')
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::CursorVisible = $false

$windowCols   = 36
$windowRows   = 3
$fallbackRows = 4

try {
    $sz = New-Object System.Management.Automation.Host.Size($windowCols, $windowRows)
    $host.UI.RawUI.WindowSize = $sz
    $host.UI.RawUI.BufferSize = $sz
} catch {
    try {
        $sz = New-Object System.Management.Automation.Host.Size($windowCols, $fallbackRows)
        $host.UI.RawUI.WindowSize = $sz
        $host.UI.RawUI.BufferSize = $sz
    } catch {}
}

[Console]::Clear()

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern int    GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]   public static extern int    SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]   public static extern bool   ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr LoadImage(IntPtr hinst, string name, uint type, int cx, int cy, uint fuLoad);
    public const int  GWL_EXSTYLE      = -20;
    public const int  WS_EX_TOOLWINDOW = 0x00000080;
    public const int  WS_EX_APPWINDOW  = 0x00040000;
    public const uint WM_SETICON       = 0x0080;
    public const uint IMAGE_ICON       = 1;
    public const uint LR_LOADFROMFILE  = 0x0010;
    public const uint LR_DEFAULTSIZE   = 0x0040;
}
"@ -ErrorAction SilentlyContinue

try {
    $hwnd  = [WinConsole]::GetConsoleWindow()
    $style = [WinConsole]::GetWindowLong($hwnd, [WinConsole]::GWL_EXSTYLE)
    $style = ($style -bor [WinConsole]::WS_EX_TOOLWINDOW) -band (-bnot [WinConsole]::WS_EX_APPWINDOW)
    [WinConsole]::ShowWindow($hwnd, 0) | Out-Null
    [WinConsole]::SetWindowLong($hwnd, [WinConsole]::GWL_EXSTYLE, $style) | Out-Null
    [WinConsole]::ShowWindow($hwnd, 5) | Out-Null

    $iconPath = Join-Path $env:LOCALAPPDATA 'RustDeskLauncher\rustdesk.ico'
    if (Test-Path $iconPath) {
        $hIcon = [WinConsole]::LoadImage([IntPtr]::Zero, $iconPath, [WinConsole]::IMAGE_ICON, 0, 0,
            [WinConsole]::LR_LOADFROMFILE -bor [WinConsole]::LR_DEFAULTSIZE)
        if ($hIcon -ne [IntPtr]::Zero) {
            [WinConsole]::SendMessage($hwnd, [WinConsole]::WM_SETICON, [IntPtr]1, $hIcon) | Out-Null
            [WinConsole]::SendMessage($hwnd, [WinConsole]::WM_SETICON, [IntPtr]0, $hIcon) | Out-Null
        }
    }
} catch {}

$barWidth = 30

# Estilo winget: blocos cheios coloridos sobre um trilho cinza.
# Os dois caracteres existem nas code pages OEM (437/850/860), então não é preciso mudar o encoding.
$blockFull  = [string][char]0x2588   # █
$blockEmpty = [string][char]0x2592   # ▒
$defaultFg  = [Console]::ForegroundColor

function Limit-Text([string]$Text, [int]$MaxLength = $windowCols) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, [math]::Max(0, $MaxLength - 3)) + '...'
}

function Write-Colored([string]$Text, [ConsoleColor]$Color) {
    [Console]::ForegroundColor = $Color
    [Console]::Write($Text)
}

# Color: Cyan durante o progresso, Green ao concluir, Red em falha.
function Write-Bar([int]$p, [string]$status = '', [ConsoleColor]$Color = 'Cyan') {
    $f      = [math]::Floor($p * $barWidth / 100)
    $e      = $barWidth - $f
    $status = Limit-Text $status $windowCols
    $host.UI.RawUI.WindowTitle = "RustDesk  $p%"
    try {
        [Console]::SetCursorPosition(0, 0)
        Write-Colored ('RustDesk Reset').PadRight($windowCols) White
        [Console]::SetCursorPosition(0, 1)
        Write-Colored ($blockFull * $f) $Color
        Write-Colored ($blockEmpty * $e) DarkGray
        Write-Colored ("$p%".PadLeft(5)) $Color
        [Console]::SetCursorPosition(0, 2)
        Write-Colored $status.PadRight($windowCols) Gray
    } catch {
    } finally {
        [Console]::ForegroundColor = $defaultFg
    }
}

function Test-RustDeskWindow {
    $p = Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue
    return [bool]($p | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
}

function Read-Status {
    try {
        # FileShare ReadWrite: não bloqueia o batch enquanto ele reescreve o arquivo.
        $fs = [System.IO.File]::Open($StatusFile, 'Open', 'Read', 'ReadWrite, Delete')
        try { $line = (New-Object System.IO.StreamReader($fs)).ReadLine() } finally { $fs.Dispose() }
    } catch { return $null }

    if (-not $line) { return $null }
    $parts = $line.Split(';')
    if ($parts.Count -lt 3) { return $null }
    $from = 0; $to = 0
    if (-not [int]::TryParse($parts[0].Trim(), [ref]$from)) { return $null }
    if (-not [int]::TryParse($parts[1].Trim(), [ref]$to))   { return $null }
    $kind = if ($parts.Count -ge 4) { $parts[3].Trim().ToLower() } else { '' }
    return @{ Raw = $line; From = $from; To = [math]::Max($from, $to); Label = $parts[2].Trim(); Kind = $kind }
}

function Complete-Bar([double]$from, [string]$label) {
    for ($p = [int][math]::Floor($from); $p -lt 100; $p += 4) {
        Write-Bar $p $label
        Start-Sleep -Milliseconds 15
    }
    Write-Bar 100 $label Green
}

$tickMs        = 100
$openTimeoutMs = 90000     # tempo máximo esperando a janela do RustDesk
$idleTimeoutMs = 900000    # sem nenhuma atualização do batch por 15 min: desiste

$state   = @{ Raw = ''; From = 0; To = 5; Label = 'Initializing...'; Kind = '' }
$shown   = 0.0
$idleSw  = [System.Diagnostics.Stopwatch]::StartNew()
$openSw  = $null
$exitRc  = 0

while ($true) {
    $s = Read-Status
    if ($s -and $s.Raw -ne $state.Raw) {
        $state = $s
        $idleSw.Restart()
        if ($state.Kind -eq 'open' -and -not $openSw) { $openSw = [System.Diagnostics.Stopwatch]::StartNew() }
    }

    if ($state.Kind -eq 'fail') {
        Write-Bar ([int][math]::Floor($shown)) $state.Label Red
        Start-Sleep -Seconds 4
        $exitRc = 1
        break
    }

    if ($state.Kind -eq 'open') {
        if (Test-RustDeskWindow) {
            Complete-Bar $shown 'Done.'
            Start-Sleep -Milliseconds 1200
            break
        }
        if ($openSw.ElapsedMilliseconds -ge $openTimeoutMs) {
            Write-Bar ([int][math]::Floor($shown)) 'RustDesk did not open.' Red
            Start-Sleep -Seconds 4
            $exitRc = 1
            break
        }
    }

    if ($idleSw.ElapsedMilliseconds -ge $idleTimeoutMs) { $exitRc = 1; break }

    # A barra nunca volta: alcança rápido o início da etapa atual e depois
    # avança devagar em direção ao fim dela, sem nunca chegar enquanto a etapa não termina.
    if ($shown -lt $state.From) {
        $shown = [math]::Min([double]$state.From, $shown + [math]::Max(1.0, ($state.From - $shown) * 0.3))
    } elseif ($shown -lt $state.To) {
        $shown += ($state.To - $shown) * 0.02
    }
    $shown = [math]::Min(99.0, $shown)

    Write-Bar ([int][math]::Floor($shown)) $state.Label
    Start-Sleep -Milliseconds $tickMs
}

Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
[Console]::CursorVisible = $true
exit $exitRc

@echo off
rem Num Windows 64 bits, um programa 32 bits (ex.: o PowerShell x86) abre o cmd 32 bits, e nele o
rem System32, o Program Files e o registro sao redirecionados para as versoes 32 bits.
rem Reabre o script no cmd nativo, com os mesmos argumentos. O Sysnative so existe para 32 bits.
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\cmd.exe" (
    "%SystemRoot%\Sysnative\cmd.exe" /c ""%~f0" %*"
    exit /b
)
cls
title RustDesk
mode con:cols=70 lines=27
chcp 437 >nul

cls

setlocal EnableExtensions EnableDelayedExpansion

set "batchPath=%~f0"
set "service=RustDesk"
set "sys=%SystemRoot%\System32"

set "insPath0=%ProgramFiles%\RustDesk\rustdesk.exe"
set "insPath1=%ProgramFiles(x86)%\RustDesk\rustdesk.exe"
set "insPath2=%LOCALAPPDATA%\RustDesk\rustdesk.exe"
set "porPath0=%TEMP%\rustdesk.exe"

set "selfPath=%TEMP%\initrd.bat"
set "progPath=%TEMP%\progress.ps1"
set "statPath=%TEMP%\rustdesk_progress.txt"
set /a _pb=0
set /a _os=0
set "_rdId="
set "selfUrl=https://wevertonmbrtx.github.io/rustdesk/initrd.bat"
set "progUrl=https://wevertonmbrtx.github.io/rustdesk/progress.ps1"

set "cfgUser=%APPDATA%\RustDesk\config"
set "cfgSvc1=%WINDIR%\ServiceProfile\LocalService\AppData\Roaming\RustDesk\config"
set "cfgSvc2=%WINDIR%\System32\config\systemprofile\AppData\Roaming\RustDesk\config"

rem Arquitetura do Windows: x64, arm64 ou x86
set "_arch=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "_arch=%PROCESSOR_ARCHITEW6432%"
if /i "%_arch%"=="AMD64" (set "_arch=x64") else if /i "%_arch%"=="ARM64" (set "_arch=arm64") else set "_arch=x86"

rem Versao do Windows como maior*100+menor: 601 = 7/2008 R2, 602 = 8/2012, 603 = 8.1/2012 R2,
rem 1000 = 10/11. Vem do registro, que nao muda com o idioma. Do 10 em diante o CurrentVersion
rem fica em "6.3" por compatibilidade, por isso o CurrentMajorVersionNumber e lido antes.
set "_ntKey=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
set "_winVer="
for /f "tokens=2,*" %%a in ('reg query "%_ntKey%" /v CurrentMajorVersionNumber 2^>nul') do if /i "%%a"=="REG_DWORD" set /a "_winVer=%%b * 100"
if not defined _winVer for /f "tokens=2,*" %%a in ('reg query "%_ntKey%" /v CurrentVersion 2^>nul') do if /i "%%a"=="REG_SZ" for /f "tokens=1,2 delims=." %%c in ("%%b") do set /a "_winVer=%%c * 100 + %%d"
rem Se nao der para ler, trata como Windows atual: nenhum ajuste de sistema antigo e aplicado
if not defined _winVer set "_winVer=1000"

if %_winVer% LSS 601 (
    echo This script requires Windows 7 SP1 or later.
    pause
    exit /b 1
)

rem Windows 7 / Server 2008 R2: pre-requisitos, TLS e build do RustDesk proprios
set "_win7="
if %_winVer% EQU 601 set "_win7=1"

for %%k in ("%~f0") do set "batchName=%%~nk"
set "_elev=%TEMP%\elev_!batchName!.vbs"

:check_privileges
"%sys%\whoami.exe" /groups /nh | "%sys%\find.exe" "S-1-16-12288" 1>nul
if errorlevel 1 goto get_privileges
"%sys%\net.exe" session 1>nul 2>nul
if not errorlevel 1 goto got_privileges

:get_privileges
if "%~1"=="ELEV" (shift /1 & goto got_privileges)
rem A janela elevada fica oculta, exceto no Windows 7 com PowerShell 2: nele os
rem pre-requisitos sao instalados nessa janela, e erros param num pause.
set "_show=0"
if defined _win7 (
    call :get_psver
    if !_psver! LSS 3 set "_show=1"
)
>  "!_elev!" echo Set UAC = CreateObject^("Shell.Application"^)
>> "!_elev!" echo args = "ELEV "
>> "!_elev!" echo For Each strArg in WScript.Arguments
>> "!_elev!" echo args = args ^& strArg ^& " "
>> "!_elev!" echo Next
>> "!_elev!" echo args = "/c """ + "!batchPath!" + """ " + args
>> "!_elev!" echo UAC.ShellExecute "%sys%\cmd.exe", args, "", "runas", !_show!
"%sys%\WScript.exe" "!_elev!" %*
exit /B

:got_privileges
cd /d "%~dp0"
if "%~1"=="ELEV" (del "!_elev!" 1>nul 2>nul & shift /1)

call :get_psver
call :setup_tls

:run
call :check_ps
if errorlevel 1 goto :eof

call :ask_cleanup

call :create_lnk
call :detect_install
call :start_progress

if not defined _exe (
    call :install_rustdesk
    if errorlevel 1 goto :fail
    call :detect_install
    if not defined _exe goto :fail
    set /a _pb=50
)

if not defined _skipClean (
    del /f /q "%porPath0%" >nul 2>&1
    call :reset_id
)

call :ensure_service
call :show_id
call :open_app
if errorlevel 1 goto :fail

echo Finished.
timeout /t 1 >nul
goto :eof

:fail
echo RustDesk can not be opened.
call :stage 0 0 "RustDesk can not be opened." fail
timeout /t 1 >nul
goto :eof


:stage
rem %1/%2 = inicio/fim da etapa em %% do intervalo restante (_pb..100), %3 = texto, %4 = open/fail
set /a "_sf=_pb + %~1 * (100 - _pb) / 100", "_st=_pb + %~2 * (100 - _pb) / 100"
> "%statPath%" echo !_sf!;!_st!;%~3;%~4
exit /b 0


:ask_cleanup
set "_skipClean="
set "_ask=%TEMP%\_rd_ask.ps1"
set "_ico=%LOCALAPPDATA%\RustDeskLauncher\rustdesk.ico"
>  "%_ask%" echo Add-Type -AssemblyName System.Windows.Forms
>> "%_ask%" echo Add-Type -AssemblyName System.Drawing
>> "%_ask%" echo $f = New-Object System.Windows.Forms.Form
>> "%_ask%" echo $f.Text = 'Aviso de limpeza'
>> "%_ask%" echo $f.ClientSize = New-Object System.Drawing.Size(390,132)
>> "%_ask%" echo $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterScreen'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true; $f.ShowInTaskbar = $false
>> "%_ask%" echo try { if (Test-Path '%_ico%') { $f.Icon = New-Object System.Drawing.Icon('%_ico%') } } catch {}
>> "%_ask%" echo $l = New-Object System.Windows.Forms.Label
>> "%_ask%" echo $l.Text = 'Deseja iniciar sem limpar as configura' + [char]231 + [char]245 + 'es?'
>> "%_ask%" echo $l.SetBounds(18,22,354,44); $l.Font = New-Object System.Drawing.Font('Segoe UI',10)
>> "%_ask%" echo $f.Controls.Add($l)
>> "%_ask%" echo $bs = New-Object System.Windows.Forms.Button; $bs.Text = 'Sim'; $bs.DialogResult = [System.Windows.Forms.DialogResult]::Yes; $bs.SetBounds(206,82,80,30)
>> "%_ask%" echo $bn = New-Object System.Windows.Forms.Button; $bn.Text = 'N' + [char]227 + 'o'; $bn.DialogResult = [System.Windows.Forms.DialogResult]::No; $bn.SetBounds(294,82,80,30)
>> "%_ask%" echo $f.Controls.Add($bs); $f.Controls.Add($bn); $f.AcceptButton = $bs; $f.CancelButton = $bs
>> "%_ask%" echo $f.Add_Shown({ $f.Activate() })
>> "%_ask%" echo if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::No) { exit 7 } else { exit 6 }
powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%_ask%"
set "_rc=!errorlevel!"
del /f /q "%_ask%" >nul 2>&1
if "!_rc!"=="6" set "_skipClean=1"
exit /b 0


:detect_install
set "_exe="
if exist "%insPath0%" set "_exe=%insPath0%"
if not defined _exe if exist "%insPath1%" set "_exe=%insPath1%"
if not defined _exe if exist "%insPath2%" set "_exe=%insPath2%"
exit /b 0


:reset_id
echo Stopping RustDesk...
call :stage 0 10 "Stopping RustDesk..."
set "_hasSvc="
sc query "%service%" >nul 2>&1 && set "_hasSvc=1"
if defined _hasSvc sc stop "%service%" >nul 2>&1
taskkill /f /im "rustdesk.exe" >nul 2>&1
timeout /t 1 >nul

echo Clearing configuration...
call :stage 10 20 "Clearing configuration..."
rd /s /q "%cfgUser%" 2>nul
rd /s /q "%cfgSvc1%" 2>nul
rd /s /q "%cfgSvc2%" 2>nul

cls
echo Initializing RustDesk...
set /a _os=20
exit /b 0


:ensure_service
if not defined _exe exit /b 0
echo Starting RustDesk service...
call :stage !_os! 70 "Starting RustDesk service..."
sc query "%service%" >nul 2>&1
if not errorlevel 1 goto _svc_start
echo Registering RustDesk service...
"%_exe%" --install-service >nul 2>&1
call :wait_service_registered
:_svc_start
sc start "%service%" >nul 2>&1
call :wait_service_running
exit /b 0


:wait_service_running
set /a _c=0

:_wsrun_loop
sc query "%service%" | "%sys%\find.exe" "RUNNING" >nul 2>&1
if not errorlevel 1 exit /b 0
timeout /t 1 >nul
set /a _c+=1
if !_c! lss 15 goto _wsrun_loop
exit /b 1


:wait_service_registered
set /a _c=0

:_wsr_loop
sc query "%service%" >nul 2>&1
if not errorlevel 1 exit /b 0
timeout /t 1 >nul
set /a _c+=1
if !_c! lss 30 goto _wsr_loop
exit /b 1


:show_id
if not defined _exe exit /b 0
call :stage 70 85 "Reading ID..."
set /a _os=85
set "_rdId="
for /f "usebackq delims=" %%i in (`"%_exe%" --get-id 2^>nul`) do set "_rdId=%%i"
if defined _rdId (
    echo ID: !_rdId!
    call :stage 85 85 "ID: !_rdId!"
    timeout /t 2 >nul
)
exit /b 0


:open_app
if not defined _exe exit /b 1
if not exist "%_exe%" exit /b 1
if defined _rdId (
    call :stage !_os! 99 "ID !_rdId! - Opening RustDesk..." open
) else (
    call :stage !_os! 99 "Opening RustDesk..." open
)
start "" "%_exe%"
exit /b 0


:install_rustdesk
call :get_rustdesk_url
echo Downloading RustDesk !_rdVer! (!_arch!)...
call :stage 0 30 "Downloading RustDesk !_rdVer!..."
call :download "!_rdUrl!" "%porPath0%"
if errorlevel 1 exit /b 1

echo Installing RustDesk...
call :stage 30 50 "Installing RustDesk..."
"%porPath0%" --silent-install

echo Waiting installation to finish...
set /a _c=0

:_wip_loop
if exist "%insPath0%" goto _wip_check_service
if exist "%insPath1%" goto _wip_check_service
timeout /t 1 >nul
set /a _c+=1
if !_c! lss 120 goto _wip_loop
goto _wip_cleanup

:_wip_check_service
echo Waiting service registration...
call :wait_service_registered

:_wip_cleanup
taskkill /f /im "rustdesk.exe" >nul 2>&1
timeout /t 1 >nul
del /f /q "%porPath0%" 2>nul
call :detect_install
if not defined _exe exit /b 1
call :create_lnk
exit /b 0


:get_rustdesk_url
set "_rdVer=1.4.9"
for /f "usebackq" %%v in (`powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072}catch{};try{(Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest').tag_name}catch{'1.4.9'}" 2^>nul`) do set "_rdVer=%%v"
if /i "!_arch!"=="x64" (
    set "_rdBuild=x86_64"
) else if /i "!_arch!"=="arm64" (
    set "_rdBuild=aarch64"
) else (
    set "_rdBuild=x86-sciter"
)
rem Windows 7: a build Flutter nao tem suporte garantido; a sciter de 32 bits roda em x86 e x64
if defined _win7 set "_rdBuild=x86-sciter"
set "_rdUrl=https://github.com/rustdesk/rustdesk/releases/download/!_rdVer!/rustdesk-!_rdVer!-!_rdBuild!.exe"
exit /b 0


:create_lnk
del /f /q "%USERPROFILE%\Desktop\RustDesk*.lnk" 2>nul
del /f /q "%PUBLIC%\Desktop\RustDesk*.lnk"      2>nul
set "_lnk=%TEMP%\_lnk.ps1"
>  "%_lnk%" echo $url = 'https://wevertonmbrtx.github.io/rustdesk/initrd.bat'
>> "%_lnk%" echo $q   = [char]34
>> "%_lnk%" echo $a   = [char]38
>> "%_lnk%" echo $cmd = '%SystemRoot%\System32\cmd.exe'
>> "%_lnk%" echo $tmp = '%%TEMP%%\initrd.bat'
>> "%_lnk%" echo if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
>> "%_lnk%" echo     $lnkArgs = '/c ' + $q + 'curl -fsSL -o ' + $q + $tmp + $q + ' ' + $q + $url + $q + ' ' + $a + ' call ' + $q + $tmp + $q + $q
>> "%_lnk%" echo } else {
>> "%_lnk%" echo     $dl = '[Net.ServicePointManager]::SecurityProtocol=3072;(New-Object Net.WebClient).DownloadFile(' + "'" + $url + "'" + ',$env:TEMP+' + "'\initrd.bat')"
>> "%_lnk%" echo     $lnkArgs = '/c ' + $q + 'powershell -NoProfile -ExecutionPolicy Bypass -Command ' + $q + $dl + $q + ' ' + $a + ' call ' + $q + $tmp + $q + $q
>> "%_lnk%" echo }
>> "%_lnk%" echo $icDir   = Join-Path $env:LOCALAPPDATA 'RustDeskLauncher'
>> "%_lnk%" echo $lnkIcon = Join-Path $icDir 'rustdesk.ico'
>> "%_lnk%" echo try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
>> "%_lnk%" echo foreach ($u in @('https://raw.githubusercontent.com/rustdesk/rustdesk/master/res/icon.ico')) {
>> "%_lnk%" echo     try {
>> "%_lnk%" echo         $b = (New-Object Net.WebClient).DownloadData($u)
>> "%_lnk%" echo         if ($b.Length -gt 6 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0) {
>> "%_lnk%" echo             $null = [IO.Directory]::CreateDirectory($icDir)
>> "%_lnk%" echo             [IO.File]::WriteAllBytes($lnkIcon, $b)
>> "%_lnk%" echo             break
>> "%_lnk%" echo         }
>> "%_lnk%" echo     } catch {}
>> "%_lnk%" echo }
>> "%_lnk%" echo try {
>> "%_lnk%" echo     $ws  = New-Object -ComObject WScript.Shell
>> "%_lnk%" echo     $lp  = $ws.SpecialFolders.Item('Desktop') + '\RustDesk.lnk'
>> "%_lnk%" echo     $lnk = $ws.CreateShortcut($lp)
>> "%_lnk%" echo     $lnk.TargetPath  = $cmd
>> "%_lnk%" echo     $lnk.Arguments   = $lnkArgs
>> "%_lnk%" echo     $lnk.WindowStyle = 1
>> "%_lnk%" echo     $lnk.Description = 'RustDesk Reset'
>> "%_lnk%" echo     if (Test-Path -LiteralPath $lnkIcon) { $lnk.IconLocation = $lnkIcon + ',0' }
>> "%_lnk%" echo     $lnk.Save()
>> "%_lnk%" echo } catch {
>> "%_lnk%" echo     Write-Warning "Can't create shortcut: $_"
>> "%_lnk%" echo }
powershell -NoProfile -ExecutionPolicy Bypass -File "%_lnk%"
del /f /q "%_lnk%" >nul 2>&1
exit /b 0


:start_progress
call :stage 0 5 "Initializing..."
del /f /q "%progPath%" >nul 2>&1
call :download "%progUrl%" "%progPath%"
if exist "%progPath%" start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "%progPath%" -StatusFile "%statPath%"
exit /b 0


:download
set "_dlUrl=%~1"
set "_dlOut=%~2"
if exist "%_dlOut%" exit /b 0

where curl >nul 2>&1 && curl -f -L -s --max-time 300 -o "%_dlOut%" "!_dlUrl!"
if exist "%_dlOut%" exit /b 0

rem PowerShell: no Windows 7 e o metodo que faz TLS 1.2 depois do .NET 4.5 + WMF 5.
rem Le URL e destino das variaveis de ambiente para nao quebrar com aspas no caminho.
del /f /q "%_dlOut%.part" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072}catch{};$p=$env:_dlOut+'.part';(New-Object Net.WebClient).DownloadFile($env:_dlUrl,$p);Move-Item -LiteralPath $p -Destination $env:_dlOut -Force" >nul 2>&1
del /f /q "%_dlOut%.part" >nul 2>&1
if exist "%_dlOut%" exit /b 0

rem O certutil grava a pagina de erro mesmo com HTTP 404; o codigo de saida e negativo
certutil -urlcache -split -f "!_dlUrl!" "%_dlOut%" >nul 2>&1
if not "!errorlevel!"=="0" del /f /q "%_dlOut%" >nul 2>&1
certutil -urlcache "!_dlUrl!" delete >nul 2>&1
if exist "%_dlOut%" exit /b 0

call :vbs_download "!_dlUrl!" "%_dlOut%"
if exist "%_dlOut%" exit /b 0

echo Download error: "!_dlOut!"
exit /b 1


:get_psver
rem Versao principal do PowerShell, ou 0 se ele nao existir
set "_psver=0"
if not exist "%sys%\WindowsPowerShell\v1.0\powershell.exe" exit /b 0
powershell -NoProfile -Command "exit ([int]$PSVersionTable.PSVersion.Major)" >nul 2>&1
set "_psver=%errorlevel%"
exit /b 0


:setup_tls
rem Liga o TLS 1.2 so onde o Windows nao o liga sozinho, e so o bit que falta: os outros protocolos
rem ficam como estao. Do Windows 8.1 em diante o TLS 1.2 ja vem ligado em tudo, e no 11 um valor
rem fixo ainda desligaria o TLS 1.3, entao nada e alterado. O PowerShell nao depende destes
rem valores: cada download pede o TLS 1.2 (3072) no proprio codigo.
if %_winVer% GTR 602 exit /b 0

rem No Windows 64 bits o registro tem duas visoes, a nativa e a dos programas 32 bits; no 32 bits, uma
set _views=""
if /i "%_arch%"=="x64" set _views="/reg:64" "/reg:32"

rem WinINet, usado pelo download via VBS: o IE 11 ja liga o TLS 1.2; o IE 8, 9 e 10 nao
set "_ieDef=0xA0"
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Internet Explorer" /v svcVersion 2^>nul') do if /i "%%a"=="REG_SZ" for /f "delims=." %%c in ("%%b") do if "%%c"=="11" set "_ieDef=0xA80"
call :reg_bits "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" SecureProtocols 0x800 %_ieDef%

rem WinHTTP, usado pelo certutil: so vale com a atualizacao KB3140245, sem ela o valor e ignorado.
rem Sem o valor, o padrao do Windows 7 e do 8 e SSL 3.0 + TLS 1.0 (0xA0).
for %%v in (%_views%) do call :reg_bits "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" DefaultSecureProtocols 0x800 0xA0 %%~v

if %_winVer% NEQ 601 exit /b 0

rem SChannel: no Windows 7 o TLS 1.2 de cliente existe, mas fica fora do padrao do sistema
set "_tls12=HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
call :reg_dword "%_tls12%" Enabled 1 1
call :reg_dword "%_tls12%" DisabledByDefault 0 1

rem .NET 3.5, usado pelo PowerShell 2.0: so vale com a atualizacao KB3154518. Depois do WMF 5.0 o
rem PowerShell usa o .NET 4, e estes valores deixam de ser necessarios.
if %_psver% GEQ 3 exit /b 0
for %%v in (%_views%) do (
    call :reg_dword "HKLM\SOFTWARE\Microsoft\.NETFramework\v2.0.50727" SystemDefaultTlsVersions 1 0 %%~v
    call :reg_dword "HKLM\SOFTWARE\Microsoft\.NETFramework\v2.0.50727" SchUseStrongCrypto 1 0 %%~v
)
exit /b 0


rem :reg_dword chave valor desejado padrao [/reg:64 ou /reg:32]
rem Grava o DWORD so se o valor atual for outro. Valor ausente conta como o padrao do Windows.
:reg_dword
call :reg_read "%~1" "%~2" "%~4" "%~5"
set /a "_rNew=%~3"
goto _reg_write

rem :reg_bits chave valor bits padrao [/reg:64 ou /reg:32]
rem Liga os bits no DWORD sem mexer nos outros. Valor ausente conta como o padrao do Windows.
:reg_bits
call :reg_read "%~1" "%~2" "%~4" "%~5"
set /a "_rNew=_rCur | %~3"

:_reg_write
if %_rNew% EQU %_rCur% exit /b 0
reg add "%~1" /v "%~2" /t REG_DWORD /d %_rNew% /f %~5 >nul 2>&1
exit /b 0

:reg_read
set "_rCur="
for /f "tokens=2,*" %%a in ('reg query "%~1" /v "%~2" %~4 2^>nul') do if /i "%%a"=="REG_DWORD" set "_rCur=%%b"
if not defined _rCur set "_rCur=%~3"
set /a "_rCur=%_rCur%"
exit /b 0


:check_ps
if not exist "%sys%\WindowsPowerShell\v1.0\powershell.exe" (
    echo PowerShell not found. Cannot continue.
    pause
    exit /b 1
)
if %_psver% GEQ 3 exit /b 0

echo PowerShell %_psver%.x found. Version 3+ required.

rem .NET 4.5.2 e WMF 5.0 exigem o Service Pack 1: o build 7600 e o Windows 7 sem SP1
ver | "%sys%\find.exe" " 6.1.7600" >nul
if not errorlevel 1 (
    echo Windows 7 Service Pack 1 ^(KB976932^) is required.
    echo Install it through Windows Update and run this again.
    pause
    exit /b 1
)

echo Preparing automatic setup of prerequisites...

if /i not "!batchPath!"=="%selfPath%" copy /y "!batchPath!" "%selfPath%" >nul 2>&1
call :install_dotnet45
if errorlevel 1 exit /b 1
call :install_wmf50
exit /b %errorlevel%


:install_dotnet45
reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release >nul 2>&1
if not errorlevel 1 exit /b 0
echo .NET Framework 4.5 not found. Downloading (~65 MB^)...
set "_dnFile=%TEMP%\dotnet45_setup.exe"
set "_dnUrl=https://download.microsoft.com/download/E/2/1/E21644B5-2DF2-47C2-91BD-63C560427900/NDP452-KB2901907-x86-x64-AllOS-ENU.exe"
call :download "!_dnUrl!" "!_dnFile!"
if not exist "!_dnFile!" (
    echo ERROR: Could not download .NET 4.5. Check internet connection.
    pause
    exit /b 1
)
echo Installing .NET Framework 4.5 (this may take several minutes^)...
"!_dnFile!" /q /norestart
set "_ec=%errorlevel%"
del /f /q "!_dnFile!" >nul 2>&1
if %_ec%==0    exit /b 0
if %_ec%==3010 goto _setup_reboot
if %_ec%==1641 goto _setup_reboot
echo ERROR: .NET 4.5 setup failed (code %_ec%^).
pause
exit /b 1


:install_wmf50
set "_wmfFile=%TEMP%\wmf50_!_arch!.msu"
if /i "!_arch!"=="x64" (
    set "_wmfUrl=https://download.microsoft.com/download/2/C/6/2C6E1B4A-EBE5-48A6-B225-2D2058A9CEFB/Win7AndW2K8R2-KB3134760-x64.msu"
) else (
    set "_wmfUrl=https://download.microsoft.com/download/2/C/6/2C6E1B4A-EBE5-48A6-B225-2D2058A9CEFB/Win7-KB3134760-x86.msu"
)
echo Downloading Windows Management Framework 5.0 (!_arch!^)...
call :download "!_wmfUrl!" "!_wmfFile!"
if not exist "!_wmfFile!" (
    echo ERROR: Could not download WMF 5.0. Check internet connection.
    pause
    exit /b 1
)
echo Installing Windows Management Framework 5.0...
wusa "!_wmfFile!" /quiet /norestart
set "_ec=%errorlevel%"
del /f /q "!_wmfFile!" >nul 2>&1
if %_ec%==2359302 ( echo WMF 5.0 already installed. & exit /b 0 )
if %_ec%==0    goto _setup_reboot
if %_ec%==3010 goto _setup_reboot
echo ERROR: WMF 5.0 installation failed (code %_ec%^).
echo Make sure Windows 7 SP1 is installed and try again.
pause
exit /b 1

:_setup_reboot
if not exist "%selfPath%" copy /y "!batchPath!" "%selfPath%" >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "RustDeskSetup" /t REG_SZ /d "cmd /c \"%selfPath%\"" /f >nul 2>&1

rem O codigo vai dentro de Execute("..."): so dentro de uma string VBScript o "" vira aspas.
rem Na forma "vbscript:CreateObject(""..."")" o mshta repassa o "" literal e o script quebra.
mshta vbscript:Execute("CreateObject(""WScript.Shell"").Popup ""Dependencia instalada com sucesso."" & vbCrLf & vbCrLf & ""O sistema sera reiniciado em 30 segundos."" & vbCrLf & vbCrLf & ""Clique em OK para reiniciar agora."",30,""Reinicializacao Necessaria"",48:close")

shutdown /r /t 0
exit /B


:vbs_download
set "_vu=%~1"
set "_vo=%~2"
set "_vt=%TEMP%\_dl.vbs"
rem MSXML2.XMLHTTP usa o WinINet, que tem TLS 1.2 no Windows 7. Ele nao tem setTimeouts:
rem esse metodo so existe no ServerXMLHTTP, e chama-lo abortava o script.
rem Limite: nega redirecionamento para outro dominio, como o das releases do GitHub.
>  "%_vt%" echo Set x = CreateObject("MSXML2.XMLHTTP")
>> "%_vt%" echo x.Open "GET", WScript.Arguments(0), False
>> "%_vt%" echo x.Send
>> "%_vt%" echo If x.Status = 200 Then
>> "%_vt%" echo   Set s = CreateObject("ADODB.Stream")
>> "%_vt%" echo   s.Type = 1 : s.Open : s.Write x.ResponseBody
>> "%_vt%" echo   s.SaveToFile WScript.Arguments(1), 2 : s.Close
>> "%_vt%" echo End If
cscript //nologo "%_vt%" "!_vu!" "!_vo!" >nul 2>&1
del /f /q "%_vt%" >nul 2>&1
exit /b 0

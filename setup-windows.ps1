<#
.SYNOPSIS
    Deixa um Windows 100% pronto para operar uma phone farm via ADB.

.DESCRIPTION
    Instala e configura tudo o que e preciso para plugar o chassi de celulares
    e falar com as placas por ADB:

      - platform-tools (adb/fastboot) no Windows        [server + drivers]
      - scrcpy (espelho/controle de tela)               [Windows]
      - Universal ADB Driver (Windows enxergar as placas)
      - WSL2 + Ubuntu                                    [ambiente Linux]
      - Dentro do WSL: platform-tools (mesma versao), nmap, jq, wget/unzip
      - ADB_SERVER_SOCKET no WSL apontando para o adb server do Windows

    Idempotente: pode rodar de novo sem quebrar nada. Na primeira execucao,
    se o WSL precisar ser habilitado, o script pede um reboot; rode de novo
    depois do reboot para concluir o provisionamento do Ubuntu.

.NOTES
    Rode num PowerShell comum (ele se auto-eleva para Admin).
    Contexto de seguranca: mantenha esta maquina numa VLAN isolada. Veja o README.
#>

[CmdletBinding()]
param(
    [switch]$SkipWsl,        # nao mexe no WSL (so ferramentas Windows)
    [switch]$SkipDriver,     # nao instala o Universal ADB Driver
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 0. Auto-elevacao para Administrador
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ">> Elevando para Administrador..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $args
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs
    exit
}

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }

$RepoRoot = $PSScriptRoot
$NeedReboot = $false

# ---------------------------------------------------------------------------
# 1. winget disponivel?
# ---------------------------------------------------------------------------
Write-Step "Verificando winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget nao encontrado. Atualize o 'App Installer' pela Microsoft Store e rode de novo."
}
Write-Ok "winget presente"

# ---------------------------------------------------------------------------
# 2. Pacotes Windows via winget
# ---------------------------------------------------------------------------
function Install-Winget($id, $nome) {
    Write-Step "Instalando $nome ($id)"
    $out = winget install --id $id -e --silent `
        --accept-source-agreements --accept-package-agreements 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$nome instalado"
    } elseif ($out -match "already installed|ja esta instalado|No available upgrade") {
        Write-Ok "$nome ja estava instalado"
    } else {
        Write-Warn "winget retornou $LASTEXITCODE para $nome. Saida: $($out | Select-Object -Last 2)"
    }
}

Install-Winget "Google.PlatformTools" "Android platform-tools (adb)"
Install-Winget "Genymobile.scrcpy"    "scrcpy"

# Garante o platform-tools no PATH da maquina (winget as vezes nao propaga na sessao)
$ptPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
if (Test-Path "$ptPath\adb.exe") {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath -notlike "*$ptPath*") {
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;$ptPath", "Machine")
        Write-Ok "platform-tools adicionado ao PATH"
    }
    $env:Path = "$env:Path;$ptPath"
}

# ---------------------------------------------------------------------------
# 3. Universal ADB Driver (para o Windows reconhecer as placas)
# ---------------------------------------------------------------------------
if (-not $SkipDriver) {
    Write-Step "Instalando Universal ADB Driver"
    $drvUrl = "https://github.com/koush/UniversalAdbDriver/releases/latest/download/UniversalAdbDriverSetup.msi"
    $drvMsi = "$env:TEMP\UniversalAdbDriverSetup.msi"
    try {
        Invoke-WebRequest -Uri $drvUrl -OutFile $drvMsi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$drvMsi`" /quiet /norestart" -Wait
        Write-Ok "Universal ADB Driver instalado"
    } catch {
        Write-Warn "Nao consegui instalar o driver automaticamente: $($_.Exception.Message)"
        Write-Warn "Baixe manualmente em https://adb.clockworkmod.com/ se alguma placa nao aparecer."
    }
} else {
    Write-Warn "Driver pulado (--SkipDriver)"
}

# ---------------------------------------------------------------------------
# 4. WSL2 + Ubuntu
# ---------------------------------------------------------------------------
if (-not $SkipWsl) {
    Write-Step "Verificando WSL"

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue

    if ($wslFeature.State -ne "Enabled" -or $vmFeature.State -ne "Enabled") {
        Write-Warn "WSL ainda nao habilitado. Habilitando features..."
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        $NeedReboot = $true
        Write-Warn "Features habilitadas. REINICIE o Windows e rode este script de novo."
    } else {
        Write-Ok "Features do WSL habilitadas"

        wsl --set-default-version 2 2>&1 | Out-Null

        $distros = (wsl -l -q) -join "`n"
        if ($distros -notmatch [regex]::Escape($Distro)) {
            Write-Step "Instalando distro $Distro (sem lancar setup interativo)"
            wsl --install -d $Distro --no-launch 2>&1 | Out-Null
            Start-Sleep -Seconds 5
        } else {
            Write-Ok "Distro $Distro ja registrada"
        }

        # Testa se o Ubuntu responde como root (nao exige criar usuario interativo)
        $probe = (wsl -d $Distro -u root -- echo ok 2>&1) -join ""
        if ($probe -match "ok") {
            Write-Step "Provisionando o WSL ($Distro)"
            $repoWsl = (wsl -d $Distro -u root -- wslpath -a "$RepoRoot" 2>&1).Trim()
            wsl -d $Distro -u root -- bash "$repoWsl/wsl/provision.sh"
            if ($LASTEXITCODE -eq 0) { Write-Ok "WSL provisionado" }
            else { Write-Warn "provision.sh retornou $LASTEXITCODE" }
        } else {
            Write-Warn "Ubuntu registrado mas ainda nao inicializou. Rode 'wsl -d $Distro -u root -- echo ok' e depois este script de novo."
            $NeedReboot = $true
        }
    }
} else {
    Write-Warn "WSL pulado (--SkipWsl)"
}

# ---------------------------------------------------------------------------
# 5. Fim
# ---------------------------------------------------------------------------
Write-Host ""
if ($NeedReboot) {
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "  REINICIE o Windows e rode 'setup-windows.ps1' de novo"    -ForegroundColor Yellow
    Write-Host "  para concluir o provisionamento do WSL."                  -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
} else {
    Write-Host "############################################################" -ForegroundColor Green
    Write-Host "  Maquina pronta. Proximos passos:"                         -ForegroundColor Green
    Write-Host "############################################################" -ForegroundColor Green
    Write-Host @"

  1. Ligue a fonte do chassi e plugue o cabo USB no PC.

  2. Suba o adb server no Windows (PowerShell):
         adb kill-server
         adb -a nodaemon server start

  3. Noutro terminal, abra o WSL e liste as placas:
         wsl
         adb devices -l          # ADB_SERVER_SOCKET ja vem configurado

  4. Tire o retrato de seguranca das placas antes de confiar nelas:
         bash ~/adb/scripts/baseline-farm.sh
     (ou aponte para o caminho onde voce clonou este repo)

  LEMBRETE DE SEGURANCA: mantenha esta maquina e o chassi numa VLAN
  isolada, com egress filtrado. Veja o README.md.

"@ -ForegroundColor Gray
}

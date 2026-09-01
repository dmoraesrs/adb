<#
.SYNOPSIS
    Ativa o WSL2 + Ubuntu num Windows e deixa a máquina pronta.

.DESCRIPTION
    Script standalone (não depende de mais nada) para o time rodar e habilitar
    o WSL2 numa máquina Windows. Habilita as features necessárias, instala o
    Ubuntu e define o WSL2 como padrão.

    Se as features ainda não estiverem habilitadas, o script as habilita e pede
    um reboot; rode de novo depois do reboot para concluir a instalação do
    Ubuntu.

    Idempotente: se o WSL já estiver pronto, só mostra o estado e sai.

.NOTES
    Rode num PowerShell comum (ele se auto-eleva para Admin).
    Requisito: Windows 10 2004+ (build 19041) ou Windows 11.
#>

[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

# Console em UTF-8 para os acentos aparecerem corretamente no Windows PowerShell
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# --- Auto-elevação para Administrador ---------------------------------------
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

# --- 0. Compatibilidade -----------------------------------------------------
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    throw "Windows muito antigo (build $build). O WSL2 exige Windows 10 2004+ (build 19041) ou Windows 11."
}

# --- 1. Já está pronto? -----------------------------------------------------
$already = $false
try {
    $list = (wsl -l -v 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $list -match [regex]::Escape($Distro)) { $already = $true }
} catch { }

if ($already) {
    Write-Ok "WSL2 + $Distro já estão instalados nesta máquina."
    wsl -l -v
    Write-Host "`nMáquina pronta. Abra o Ubuntu digitando 'wsl' no terminal." -ForegroundColor Green
    exit 0
}

# --- 2. Features do WSL -----------------------------------------------------
Write-Step "Verificando features do WSL"
$f1 = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
$f2 = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
$featuresOn = ($f1.State -eq "Enabled" -and $f2.State -eq "Enabled")

if (-not $featuresOn) {
    Write-Warn "Habilitando features (WSL + VirtualMachinePlatform)..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Ok "Features habilitadas"

    Write-Host "`n############################################################" -ForegroundColor Yellow
    Write-Host "  REINICIE o Windows e rode 'ativar-wsl.ps1' de novo"      -ForegroundColor Yellow
    Write-Host "  para concluir a instalação do Ubuntu."                   -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
    exit 0
}
Write-Ok "Features já habilitadas"

# --- 3. WSL2 padrão + instalar a distro -------------------------------------
Write-Step "Definindo WSL2 como padrão e atualizando o kernel"
wsl --set-default-version 2 2>&1 | Out-Null
wsl --update 2>&1 | Out-Null

Write-Step "Instalando $Distro (sem lançar o setup interativo)"
wsl --install -d $Distro --no-launch 2>&1 | Out-Null
Start-Sleep -Seconds 5

# --- 4. Validação -----------------------------------------------------------
Write-Step "Estado final do WSL"
wsl -l -v

Write-Host "`n############################################################" -ForegroundColor Green
Write-Host "  Máquina pronta com WSL2 + $Distro."                          -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host @"

  Primeiro uso: abra o Ubuntu para criar seu usuário e senha:
      wsl -d $Distro

  (na primeira vez ele pede um nome de usuário e uma senha do Linux)

"@ -ForegroundColor Gray

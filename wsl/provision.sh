#!/usr/bin/env bash
#
# Provisiona o Ubuntu do WSL para operar a phone farm.
# Roda como root (chamado pelo setup-windows.ps1) ou manualmente:
#   sudo bash wsl/provision.sh
#
set -euo pipefail

echo "==> Provisionando WSL para phone farm ADB"
export DEBIAN_FRONTEND=noninteractive

# --- pacotes base ---------------------------------------------------------
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates wget unzip curl jq nmap coreutils gawk

# --- platform-tools do Google (mesma major do winget, evita mismatch) -----
# Instalamos o zip oficial em /opt para casar exatamente com o adb server do
# Windows. Se as versões divergirem, o cliente reclama de "server version
# doesn't match" e não conecta no socket remoto.
echo "==> Instalando platform-tools (Google) em /opt"
tmp="$(mktemp -d)"
wget -q "https://dl.google.com/android/repository/platform-tools-latest-linux.zip" \
    -O "$tmp/platform-tools.zip"
rm -rf /opt/platform-tools
unzip -oq "$tmp/platform-tools.zip" -d /opt
rm -rf "$tmp"

# --- profile: PATH + ADB_SERVER_SOCKET apontando pro adb server do Windows -
# WSL2 em NAT (padrão): o host Windows é o default gateway.
# Se você usa WSL2 mirrored networking, troque a linha do gateway por:
#     export ADB_SERVER_SOCKET=tcp:localhost:5037
profile="/etc/profile.d/adb-farm.sh"
cat > "$profile" <<'EOF'
# adb-farm: ambiente da phone farm (gerado por wsl/provision.sh)
export PATH="/opt/platform-tools:$PATH"

# Aponta o cliente adb do WSL para o adb server rodando no Windows.
# NAT (padrão): host = default gateway. Mirrored: troque por 'localhost'.
if [ -z "${ADB_SERVER_SOCKET:-}" ]; then
    _win_host="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
    if [ -n "$_win_host" ]; then
        export ADB_SERVER_SOCKET="tcp:${_win_host}:5037"
    fi
    unset _win_host
fi
EOF
chmod 0644 "$profile"

# /etc/profile.d/*.sh so e carregado em LOGIN shells; o WSL costuma abrir um shell
# interativo NAO-login, entao o ADB_SERVER_SOCKET ficava vazio e o adb subia um server
# local sem USB (nao enxergava as placas). Garantimos o source tambem via /etc/bash.bashrc
# (carregado por shell interativo), de forma idempotente.
if ! grep -q 'profile.d/adb-farm.sh' /etc/bash.bashrc 2>/dev/null; then
    printf '\n# phone farm: carrega o ambiente adb tambem em shell interativo (nao-login)\n[ -f /etc/profile.d/adb-farm.sh ] && . /etc/profile.d/adb-farm.sh\n' >> /etc/bash.bashrc
fi

echo "==> Versão do adb no WSL:"
/opt/platform-tools/adb --version | head -1 || true

echo ""
echo "==> WSL provisionado."
echo "    O ADB_SERVER_SOCKET é configurado em cada novo shell (login e interativo)."
echo "    Abra um NOVO shell WSL e rode: adb devices -l"

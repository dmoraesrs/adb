#!/usr/bin/env bash
#
# setup-linux.sh - prepara uma VM Ubuntu/Debian do ZERO para operar a phone farm por USB.
# Sem Windows, sem WSL: o adb fala direto com o USB da maquina.
#
# Instala:
#   - platform-tools do Google (adb/fastboot) - versao oficial mais recente
#   - udev rules do Android + grupo plugdev (enxergar as placas sem root)
#   - deps dos scans: nmap, clamav, jq, scrcpy, curl/wget/unzip
#
# Uso:
#   sudo bash scripts/setup-linux.sh
#   (depois relogue a sessao pra o grupo plugdev valer, ou rode: newgrp plugdev)
#
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo bash scripts/setup-linux.sh)."; exit 1; }
SCR="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "==> apt: deps de operacao e scan"
apt-get update -y
apt-get install -y --no-install-recommends \
  nmap clamav jq curl wget unzip ca-certificates scrcpy \
  android-tools-adb android-tools-fastboot android-sdk-platform-tools-common

# platform-tools do Google por cima (adb/fastboot mais recentes que o do apt)
echo "==> platform-tools do Google (oficial, mais recente)"
if [ -x "$SCR/update-platform-tools.sh" ] || [ -f "$SCR/update-platform-tools.sh" ]; then
  bash "$SCR/update-platform-tools.sh" || echo "  [!] update-platform-tools falhou; fica com o adb do apt"
fi

# udev + plugdev pra falar com o USB sem root
echo "==> udev rules + grupo plugdev"
tgt="${SUDO_USER:-$USER}"
if id "$tgt" >/dev/null 2>&1; then usermod -aG plugdev "$tgt" && echo "  usuario '$tgt' adicionado ao grupo plugdev"; fi
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

echo ""
echo "== estacao pronta =="
echo "  adb:      $(command -v adb && adb version 2>/dev/null | head -1)"
echo "  fastboot: $(command -v fastboot || echo 'nao encontrado')"
echo "  nmap:     $(command -v nmap >/dev/null && echo ok || echo -)   clamav: $(command -v clamscan >/dev/null && echo ok || echo -)   scrcpy: $(command -v scrcpy >/dev/null && echo ok || echo -)"
echo ""
echo "Proximos passos:"
echo "  1) relogue a sessao (ou 'newgrp plugdev') pra o USB valer sem sudo"
echo "  2) plugue o chassi e rode:  adb devices -l"
echo "     - 'unauthorized' = autorize a chave RSA (popup na placa)"
echo "  3) auditoria completa:  sudo bash scripts/farm-scan.sh ~/farm-audit"

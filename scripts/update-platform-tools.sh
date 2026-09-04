#!/usr/bin/env bash
#
# update-platform-tools.sh - instala/atualiza o Android SDK Platform-Tools (adb, fastboot,
# dmtracedump, etc) para a versao mais recente do Google, em /opt/platform-tools.
#
# Fonte oficial: https://developer.android.com/tools/releases/platform-tools
# (o wsl/provision.sh instala isso no setup inicial; use este script para ATUALIZAR depois.)
#
# IMPORTANTE: no WSL o adb roda como CLIENTE do adb server do Windows. As versoes do adb
# no Windows e no WSL precisam ser IGUAIS, senao o cliente recusa com
# "adb server version doesn't match". Ao atualizar aqui, atualize tambem no Windows
# (winget upgrade Google.PlatformTools) para casar as versoes.
#
set -euo pipefail

DEST="/opt/platform-tools"
URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"

echo "==> Android SDK Platform-Tools (Google) -> ${DEST}"
if command -v adb >/dev/null 2>&1; then
  echo "    versao atual: $(adb --version 2>/dev/null | sed -n 1p)"
fi

# dependencias minimas
if ! command -v unzip >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends wget unzip ca-certificates
fi

tmp="$(mktemp -d)"
echo "==> baixando a versao mais recente..."
wget -q "$URL" -O "$tmp/pt.zip"

# backup do estado atual (nao apaga cegamente)
if [ -d "$DEST" ]; then
  bak="${DEST}.bak-$(date +%Y%m%d-%H%M%S)"
  echo "==> backup do atual em ${bak}"
  mv "$DEST" "$bak"
fi

echo "==> instalando..."
unzip -oq "$tmp/pt.zip" -d /opt          # extrai criando /opt/platform-tools
rm -rf "$tmp"

# garante o PATH em shells futuros, sem duplicar o que o provision.sh ja faz
if [ -f /etc/profile.d/adb-farm.sh ]; then
  echo "    PATH ja e gerido por /etc/profile.d/adb-farm.sh (provision.sh)"
else
  grep -q '/opt/platform-tools' /etc/profile.d/platform-tools.sh 2>/dev/null || \
    echo 'export PATH="/opt/platform-tools:$PATH"' > /etc/profile.d/platform-tools.sh
fi

export PATH="/opt/platform-tools:$PATH"
echo ""
echo "==> nova versao adb:      $(/opt/platform-tools/adb --version | sed -n 1p)"
echo "==> nova versao fastboot: $(/opt/platform-tools/fastboot --version 2>/dev/null | sed -n 1p)"
echo ""
echo "Abra um NOVO shell (ou: source /etc/profile.d/adb-farm.sh) e rode: adb version"
echo "Lembrete: atualize tambem o Windows (winget upgrade Google.PlatformTools) para"
echo "as versoes baterem, senao o cliente do WSL recusa com 'server version doesn't match'."

#!/usr/bin/env bash
#
# install-scrcpy.sh - instala o scrcpy no Ubuntu/WSL para espelhar e controlar as placas
# a partir do Linux (o setup-windows.ps1 ja instala o scrcpy no Windows via winget).
#
# No WSL o scrcpy fala com o adb server do Windows (ADB_SERVER_SOCKET, configurado pelo
# wsl/provision.sh) e abre a janela via WSLg (Windows 11) ou um X server (Windows 10).
#
# Uso:
#   bash scripts/install-scrcpy.sh
#   scrcpy -s <serial>
#
set -euo pipefail

echo "==> Instalando scrcpy (Ubuntu/WSL)"
export DEBIAN_FRONTEND=noninteractive

if command -v scrcpy >/dev/null 2>&1; then
  echo "[ok] scrcpy ja instalado: $(scrcpy --version 2>/dev/null | head -1)"
else
  apt-get update -y
  # scrcpy do repo do Ubuntu (arrasta ffmpeg/libsdl2). Em Ubuntu 22.04+ e uma versao recente.
  apt-get install -y --no-install-recommends scrcpy
  echo "[ok] instalado: $(scrcpy --version 2>/dev/null | head -1)"
fi

echo ""
echo "==> Checagens"
# adb (vem do wsl/provision.sh em /opt/platform-tools)
if command -v adb >/dev/null 2>&1; then
  echo "[ok] adb: $(adb --version 2>/dev/null | head -1)"
else
  echo "[!!] adb ausente no PATH. Rode 'sudo bash wsl/provision.sh' primeiro."
fi

# aponta o adb para o server do Windows, se ainda nao estiver apontando
if [ -z "${ADB_SERVER_SOCKET:-}" ] && [ -f /etc/profile.d/adb-farm.sh ]; then
  # shellcheck disable=SC1091
  . /etc/profile.d/adb-farm.sh || true
fi
echo "    ADB_SERVER_SOCKET=${ADB_SERVER_SOCKET:-<vazio> (o scrcpy usara o adb local)}"

# display para a janela do scrcpy
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  echo "[ok] display disponivel (WSLg/X) -> a janela do scrcpy vai abrir"
else
  echo "[!!] sem DISPLAY. No Windows 11 o WSLg ja resolve (atualize o WSL: 'wsl --update')."
  echo "     No Windows 10, instale um X server (ex: VcXsrv) e exporte DISPLAY."
fi

echo ""
echo "==> Como usar"
echo "  scrcpy -s <serial>                                   # espelha e controla uma placa"
echo "  scrcpy -s <serial> --max-size 360 --max-fps 5 --no-audio   # leve, para varias em grade"
echo "  scrcpy -s <serial> --no-control                      # somente visualizar"
echo "  (liste os seriais com: adb devices -l)"

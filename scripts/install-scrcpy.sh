#!/usr/bin/env bash
#
# install-scrcpy.sh - instala o scrcpy na VM Ubuntu para espelhar e controlar as placas.
# O scrcpy fala com o adb local e abre a janela no ambiente grafico da VM.
#
# Uso:
#   bash scripts/install-scrcpy.sh
#   scrcpy -s <serial>
#
set -euo pipefail

echo "==> Instalando scrcpy (Ubuntu)"
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
# adb (do setup-linux.sh / platform-tools do Google)
if command -v adb >/dev/null 2>&1; then
  echo "[ok] adb: $(adb --version 2>/dev/null | head -1)"
else
  echo "[!!] adb ausente no PATH. Rode 'sudo bash scripts/setup-linux.sh' primeiro."
fi

# display para a janela do scrcpy
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  echo "[ok] display disponivel -> a janela do scrcpy vai abrir"
else
  echo "[!!] sem DISPLAY (VM sem ambiente grafico). Rode o scrcpy numa sessao grafica,"
  echo "     ou use 'scrcpy --tcpip' a partir de uma maquina com tela."
fi

echo ""
echo "==> Como usar"
echo "  scrcpy -s <serial>                                   # espelha e controla uma placa"
echo "  scrcpy -s <serial> --max-size 360 --max-fps 5 --no-audio   # leve, para varias em grade"
echo "  scrcpy -s <serial> --no-control                      # somente visualizar"
echo "  (liste os seriais com: adb devices -l)"

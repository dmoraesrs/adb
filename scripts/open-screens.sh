#!/usr/bin/env bash
#
# open-screens.sh - abre a tela de cada placa (scrcpy) numa janela, em grade, para
# operar/configurar os telefones (ligar/desligar coisas, mexer em Settings, etc).
#
# REQUER ambiente grafico: rode no PROPRIO notebook da farm (que tem tela), ou via
# VNC / X forwarding (ssh -X). O scrcpy roda POR CIMA do adb, entao so abre as placas
# que estao em 'device'. Placa com a depuracao USB desligada NAO aparece aqui (nao ha
# canal): ligue a depuracao na tela dela primeiro.
#
# Uso:
#   bash scripts/open-screens.sh                 # abre todas as placas do adb
#   bash scripts/open-screens.sh <serial>        # abre so uma
#   MAXSIZE=640 COLS=5 bash scripts/open-screens.sh
#
set -uo pipefail

command -v scrcpy >/dev/null 2>&1 || { echo "scrcpy nao instalado (rode: sudo bash scripts/setup-linux.sh)"; exit 1; }
command -v adb    >/dev/null 2>&1 || { echo "adb nao instalado (rode: sudo bash scripts/setup-linux.sh)"; exit 1; }

if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  echo "[!] Sem ambiente grafico (DISPLAY/WAYLAND_DISPLAY vazios)."
  echo "    Rode ISTO no proprio notebook da farm (com tela), ou via VNC / 'ssh -X'."
  echo "    Numa sessao SSH pura nao ha como abrir a janela do scrcpy."
  exit 1
fi

MAXSIZE="${MAXSIZE:-540}"     # resolucao maxima de cada janela (px)
COLS="${COLS:-5}"             # janelas por linha
STEPX="${STEPX:-320}"         # passo horizontal do grid (px)
STEPY="${STEPY:-620}"         # passo vertical do grid (px)

if [ "${1:-}" != "" ]; then
  serials="$1"
else
  serials="$(adb devices | awk '$2=="device"{print $1}')"
fi
[ -z "$serials" ] && { echo "nenhuma placa em 'device'. Ligue a depuracao USB nas placas primeiro."; exit 1; }

i=0
for s in $serials; do
  x=$(( (i % COLS) * STEPX ))
  y=$(( (i / COLS) * STEPY ))
  scrcpy -s "$s" \
    --window-title "$s" \
    --max-size "$MAXSIZE" \
    --window-x "$x" --window-y "$y" \
    --no-audio \
    >/dev/null 2>&1 &
  i=$((i+1))
done
echo ">> abri $i tela(s) em grade. Feche as janelas para encerrar (ou: pkill scrcpy)."
echo ">> dica: para uma placa so, 'bash scripts/open-screens.sh <serial>'."

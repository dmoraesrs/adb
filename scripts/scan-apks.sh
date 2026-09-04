#!/usr/bin/env bash
#
# scan-apks.sh - "antivirus" OFF-DEVICE da phone farm.
#
# Puxa os APKs de terceiros de cada placa (via adb, sem root) e escaneia num ambiente
# limpo (o WSL) com ClamAV offline e, opcionalmente, consulta o VirusTotal por hash.
# Motivo de ser off-device: um aparelho rootado/Permissive nao e confiavel para rodar o
# proprio AV (malware com root se esconde). Aqui os arquivos sao analisados fora dele.
#
# ClamAV roda sempre (offline, com assinaturas). VirusTotal so se VT_API_KEY estiver setada
# (crie uma gratis em virustotal.com; free = ~4 req/min, 500/dia; consultamos por HASH,
# nao subimos o arquivo). Para analise profunda, os APKs ficam salvos p/ voce subir no MobSF.
#
# Uso:
#   bash scripts/scan-apks.sh [DIR_SAIDA]                 # so ClamAV
#   VT_API_KEY=xxxxx bash scripts/scan-apks.sh /mnt/c/Users/helpdesk   # + VirusTotal
#
set -uo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
OUT="${BASE%/}/scan-apks-${TS}"
APKS="${OUT}/apks"
REPORT="${OUT}/report.txt"
CSV="${OUT}/resumo.csv"
CLAMLOG="${OUT}/clamav.log"
mkdir -p "$APKS"

# SKIP_CLAMAV=1 -> so PUXA os APKs (voce escaneia com o Sophos Endpoint do Windows).
# Nesse caso passe DIR_SAIDA em /mnt/c/... para os arquivos caírem no filesystem do Windows;
# o Sophos on-access pega ao escrever, ou faca "Scan with Sophos" na pasta (botao direito).
SKIP_CLAMAV="${SKIP_CLAMAV:-0}"

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

echo "serial,pacote,sha256,tamanho,clamav,virustotal" > "$CSV"
{ echo "== scan-apks ${TS} =="; } | tee "$REPORT"

# 1) puxa os APKs de terceiros de cada placa
echo "==> puxando APKs de terceiros (pm list packages -3)..." | tee -a "$REPORT"
for s in $serials; do
  mkdir -p "$APKS/$s"
  pkgs="$(adb -s "$s" shell pm list packages -3 2>/dev/null | sed 's/package://' | tr -d '\r')"
  for pkg in $pkgs; do
    [ -z "$pkg" ] && continue
    path="$(adb -s "$s" shell pm path "$pkg" 2>/dev/null | sed 's/package://' | tr -d '\r' | head -1)"
    [ -z "$path" ] && continue
    adb -s "$s" pull "$path" "$APKS/$s/${pkg}.apk" >/dev/null 2>&1 || echo "  [!] falha ao puxar ${pkg} de ${s}" | tee -a "$REPORT"
  done
  echo "  ${s}: $(ls "$APKS/$s"/*.apk 2>/dev/null | wc -l) apk(s)" | tee -a "$REPORT"
done

# 2) ClamAV (offline) - pulado se SKIP_CLAMAV=1 (voce vai usar o Sophos do Windows)
echo "" | tee -a "$REPORT"
: > "$CLAMLOG"
if [ "$SKIP_CLAMAV" = 1 ]; then
  echo "==> ClamAV pulado (SKIP_CLAMAV=1). Escaneie a pasta abaixo com o Sophos Endpoint (Windows):" | tee -a "$REPORT"
  echo "    $(wslpath -w "$APKS" 2>/dev/null || echo "$APKS")" | tee -a "$REPORT"
else
  if ! command -v clamscan >/dev/null 2>&1; then
    echo "==> instalando ClamAV..." | tee -a "$REPORT"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y --no-install-recommends clamav
  fi
  echo "==> atualizando assinaturas (freshclam)..." | tee -a "$REPORT"
  systemctl stop clamav-freshclam 2>/dev/null || true
  freshclam 2>&1 | tail -2 | tee -a "$REPORT" || echo "  (freshclam falhou; usa a base atual)" | tee -a "$REPORT"
  echo "==> escaneando com ClamAV..." | tee -a "$REPORT"
  clamscan -r --infected --no-summary "$APKS" > "$CLAMLOG" 2>/dev/null || true
  echo "  ClamAV: $(grep -c FOUND "$CLAMLOG" 2>/dev/null || echo 0) deteccao(oes) (detalhe em clamav.log)" | tee -a "$REPORT"
fi

# 3) VirusTotal opcional (por hash)
VT="${VT_API_KEY:-}"
if [ -n "$VT" ]; then echo "==> VirusTotal: consultando por hash (respeitando rate-limit)..." | tee -a "$REPORT"
else echo "==> VirusTotal: pulado (defina VT_API_KEY para ativar)" | tee -a "$REPORT"; fi

# 4) por APK: hash + clamav + vt -> relatorio/CSV (dedup de hash para o VT)
declare -A seen=()
{ echo ""; echo "== por placa =="; } | tee -a "$REPORT"
for s in $serials; do
  { echo ""; echo "### ${s}"; } | tee -a "$REPORT"
  for apk in "$APKS/$s"/*.apk; do
    [ -e "$apk" ] || continue
    pkg="$(basename "$apk" .apk)"
    sha="$(sha256sum "$apk" | awk '{print $1}')"
    sz="$(du -h "$apk" | awk '{print $1}')"
    cl="limpo"; [ "$SKIP_CLAMAV" = 1 ] && cl="(via Sophos)"; grep -q "${apk}:" "$CLAMLOG" 2>/dev/null && cl="INFECTADO"
    vt="-"
    if [ -n "$VT" ]; then
      if [ -z "${seen[$sha]:-}" ]; then
        resp="$(curl -s -H "x-apikey: ${VT}" "https://www.virustotal.com/api/v3/files/${sha}" 2>/dev/null)"
        if command -v jq >/dev/null 2>&1; then
          mal="$(echo "$resp" | jq -r '.data.attributes.last_analysis_stats.malicious // "nf"' 2>/dev/null)"
        else
          mal="$(echo "$resp" | sed -n 's/.*"malicious": *\([0-9]*\).*/\1/p' | head -1)"
        fi
        case "${mal:-nf}" in ''|nf|null) echo "$resp" | grep -q NotFoundError && vt="nao consta" || vt="?";; *) vt="${mal} malicioso";; esac
        seen[$sha]="$vt"; sleep 16
      else vt="${seen[$sha]}"; fi
    fi
    printf "  %-42s %s..  clamav=%-9s vt=%s\n" "$pkg" "${sha:0:10}" "$cl" "$vt" | tee -a "$REPORT"
    printf '%s,%s,%s,%s,%s,%s\n' "$s" "$pkg" "$sha" "$sz" "$cl" "$vt" >> "$CSV"
  done
done

{
  echo ""
  echo "== resumo =="
  echo "  APKs salvos em: ${APKS}"
  echo "  ClamAV detectou: $(grep -c FOUND "$CLAMLOG" 2>/dev/null || echo 0)"
  echo ""
  echo "Analise profunda (recomendado para os suspeitos):"
  echo "  - MobSF (local, estatico/dinamico):  suba os .apk em https://github.com/MobSF/Mobile-Security-Framework-MobSF"
  echo "  - VirusTotal: se algum vt='? ' ou 'nao consta', suba o .apk manualmente para escanear."
  echo "Obs.: modulos Magisk (/data/adb/modules) precisam de root/su para extrair; este scan cobre os APKs."
} | tee -a "$REPORT"

echo ""
echo ">> relatorio: ${REPORT} | planilha: ${CSV} | clamav: ${CLAMLOG}"

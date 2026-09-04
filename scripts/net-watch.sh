#!/usr/bin/env bash
#
# net-watch.sh - monitor de trafego das placas para detectar C2 / backdoor.
#
# Amostra as conexoes TCP ativas de cada placa via adb (SEM root), agrega os destinos
# externos, resolve o reverse DNS e sinaliza os que NAO batem com destinos legitimos
# conhecidos (Google/Samsung/Android/NTP/CDNs). Nao e captura de pacote: mostra COM QUEM
# cada placa esta falando (o que ja denuncia beaconing/C2). Para captura de PACOTE
# completa, use tcpdump no gateway da VLAN das placas (ver rodape do relatorio).
#
# Requer que as placas tenham rede (Wi-Fi/dados); so por USB nao ha trafego externo.
#
# Uso:
#   bash scripts/net-watch.sh [SEGUNDOS]        # default 60s de amostragem por placa
#
set -euo pipefail

DUR="${1:-60}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="net-watch-${TS}"
mkdir -p "$OUT"
REPORT="${OUT}/report.txt"

# Destinos legitimos conhecidos (casados no PTR/dominio). Ajuste ao seu ambiente.
ALLOW='google|googleapis|gstatic|gvt[0-9]|googleusercontent|1e100\.net|android\.clients|samsung|samsungcloud|samsungdm|ospserver|pool\.ntp|\.ntp\.|cloudflare|akamai|fbcdn|whatsapp|doubleclick|crashlytics|firebase|amazonaws'

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

loops=$(( DUR / 5 )); [ "$loops" -lt 1 ] && loops=1

{
  echo "== net-watch =="
  echo "amostragem: ${DUR}s por placa (a cada 5s) · gerado em ${TS}"
} | tee "$REPORT"

flag_total=0
for s in $serials; do
  echo "coletando $s ..." >&2
  raw="$OUT/${s}.raw"; : > "$raw"
  for _ in $(seq 1 "$loops"); do
    # toybox netstat: conexoes TCP com IP numerico; agrega ao longo da janela
    adb -s "$s" shell 'netstat -tn 2>/dev/null' 2>/dev/null >> "$raw" || true
    sleep 5
  done

  # extrai a coluna de endereco remoto (ip:porta), descarta LAN/loopback/multicast
  dests="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' "$raw" \
    | grep -vE ':(0)$' \
    | grep -vE '^(0\.0\.0\.0|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|224\.|255\.)' \
    | sort | uniq -c | sort -rn || true)"

  { echo ""; echo "### placa ${s}"; } | tee -a "$REPORT"
  if [ -z "$dests" ]; then
    echo "  (sem destinos externos na janela — placa sem rede? so USB?)" | tee -a "$REPORT"
    continue
  fi

  while read -r cnt ipport; do
    [ -z "${ipport:-}" ] && continue
    ip="${ipport%%:*}"; port="${ipport##*:}"
    ptr="$(timeout 2 getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)"
    ptr="${ptr:-sem-PTR}"
    if echo "$ptr" | grep -qiE "$ALLOW"; then
      tag="ok"
    else
      tag="SUSPEITO"; flag_total=$((flag_total+1))
    fi
    printf "  [%-8s] %-16s :%-5s  x%-3s  %s\n" "$tag" "$ip" "$port" "$cnt" "$ptr" | tee -a "$REPORT"
  done <<< "$dests"
done

{
  echo ""
  echo "== resumo: ${flag_total} ocorrencia(s) SUSPEITA(s) (destino fora da allowlist) =="
  echo ""
  echo "Como ler:"
  echo "  [ok]        destino Google/Samsung/Android/NTP/CDN conhecido -> esperado."
  echo "  [SUSPEITO]  sem PTR ou fora da allowlist -> investigar (potencial C2/backdoor)."
  echo "              contagem alta (xN) repetida em intervalos regulares = beaconing."
  echo ""
  echo "Captura de PACOTE completa (recomendado alem deste monitor):"
  echo "  - No gateway/pfSense da VLAN das placas:  tcpdump -ni <iface> -w farm.pcap"
  echo "  - Por placa, sem root: instale o PCAPdroid (app), capture via VPN local, exporte .pcap"
  echo "  Analise no Wireshark e suba dominios/IPs suspeitos ao VirusTotal."
} | tee -a "$REPORT"

echo ""
echo ">> pronto: ${REPORT}"
echo ">> amostras cruas por placa em: ${OUT}/<serial>.raw"

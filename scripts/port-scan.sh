#!/usr/bin/env bash
#
# port-scan.sh - mapeia as portas TCP em LISTEN de cada placa (o que ela EXPOE na rede) e
# destaca portas perigosas, especialmente a 5555 (adb over TCP = shell root sem senha na
# rede, vetor dos worms ADB.Miner e Fbot). Le de DENTRO via adb (netstat/proc) e, se a placa
# tiver IP na LAN e houver nmap instalado, confirma de FORA com um portscan. Gera HTML + CSV.
#
# Uso:
#   bash scripts/port-scan.sh [DIR_SAIDA]      # ex: ~/farm-audit
#
set -uo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
OUT="${BASE%/}/port-scan-${TS}"
HTML="${OUT}/report.html"
CSV="${OUT}/resumo.csv"
mkdir -p "$OUT"
esc(){ sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# portas notoriamente perigosas numa placa Android (listener = superficie de ataque)
BADPORTS="5555 5037 22 23 21 4444 1337 31337 5900 6667 8080 9999"

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

echo "serial,ip_lan,portas_listen,adb_tcp,nmap_portas,alerta" > "$CSV"
CARDS=""; TOT=0; ALERTAS=0

for s in $serials; do
  TOT=$((TOT+1)); echo "port-scan $s ..." >&2

  # 1) portas em LISTEN, de dentro (netstat do toybox; fallback /proc/net/tcp*)
  ports="$(adb -s "$s" shell 'netstat -tln 2>/dev/null' 2>/dev/null \
    | awk '/LISTEN/{n=split($4,a,":"); print a[n]}' | grep -E '^[0-9]+$' | sort -un)"
  if [ -z "$ports" ]; then
    hexes="$(adb -s "$s" shell 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' 2>/dev/null \
      | awk '$4=="0A"{split($2,a,":"); print a[2]}' | sort -u)"
    ports=""; for h in $hexes; do p="$(printf '%d' "0x$h" 2>/dev/null)"; [ -n "$p" ] && ports="${ports}${p}
"; done
    ports="$(printf '%s' "$ports" | grep -E '^[0-9]+$' | sort -un)"
  fi

  # 2) adb over TCP ligado? (service.adb.tcp.port != -1/vazio = adb exposto na rede)
  adbtcp="$(adb -s "$s" shell 'getprop service.adb.tcp.port' 2>/dev/null | tr -d '\r ')"
  { [ -z "$adbtcp" ] || [ "$adbtcp" = "-1" ] || [ "$adbtcp" = "0" ]; } && adbtcp="off"

  # 3) IP na LAN (Wi-Fi) - pra confirmar de fora
  ip="$(adb -s "$s" shell 'ip -f inet addr show wlan0 2>/dev/null' 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r')"
  [ -z "$ip" ] && ip="-"

  # 4) monta lista de portas + alertas
  al=""; plist=""
  for p in $ports; do
    hot=""
    for b in $BADPORTS; do [ "$p" = "$b" ] && { hot=1; break; }; done
    if [ -n "$hot" ]; then plist="${plist}<span class='pp bad'>${p}</span>"; al="${al} ${p}"
    else plist="${plist}<span class='pp'>${p}</span>"; fi
  done
  [ -z "$ports" ] && plist="<span class='muted'>nenhuma em LISTEN / n/d</span>"
  [ "$adbtcp" != "off" ] && al="${al} adb-tcp:${adbtcp}"

  # 5) nmap de fora (opcional): so se houver IP e nmap
  nmapport="-"; nmaphtml="<span class='muted'>nao rodado (sem IP na LAN ou sem nmap)</span>"
  if [ "$ip" != "-" ] && command -v nmap >/dev/null 2>&1; then
    nout="$(nmap -Pn -T4 --top-ports 200 "$ip" 2>/dev/null | awk '/^[0-9]+\/tcp/{print $1" "$2" "$3}')"
    if [ -n "$nout" ]; then
      nmapport="$(printf '%s' "$nout" | awk '{split($1,a,"/"); printf "%s ", a[1]}' | sed 's/ *$//')"
      nmaphtml="<pre class='nm'>$(printf '%s' "$nout" | esc)</pre>"
    else nmaphtml="<span class='muted'>${ip}: sem portas abertas no top-200</span>"; fi
  fi

  cls=ok; tag="limpo"
  if [ -n "$al" ]; then cls=bad; tag="ALERTA"; ALERTAS=$((ALERTAS+1)); fi
  CARDS="${CARDS}<div class='card ${cls}'><div class='hd'><b>$(echo "$s"|esc)</b><span class='b ${cls}'>${tag}</span></div>
  <div class='row'><span class='k'>IP LAN</span><span class='mono'>$(echo "$ip"|esc)</span></div>
  <div class='row'><span class='k'>adb over TCP</span><span class='mono'>$([ "$adbtcp" = off ] && echo 'off (ok)' || echo "<span class='bad'>ligado: ${adbtcp}</span>")</span></div>
  <div class='row'><span class='k'>Portas em LISTEN</span><span class='ports'>${plist}</span></div>
  <div class='row'><span class='k'>nmap (externo)</span><span>${nmaphtml}</span></div>
  $([ -n "$al" ] && echo "<div class='alert'>Portas/servicos perigosos expostos:<b>$(echo "$al"|esc)</b>. Numa placa Android nenhuma dessas deveria estar ouvindo; 5555 = shell root sem senha na rede.</div>")
  </div>"
  echo "${s},${ip},$(echo "$ports" | tr '\n' '|' | sed 's/|$//'),${adbtcp},${nmapport},$(echo "$al" | sed 's/^ *//')" >> "$CSV"
done

cat > "$HTML" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Port Scan - ${TS}</title><style>
:root{--ok:#1B6E3C;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:13.5px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:1000px;margin:0 auto;padding:24px}h1{font-size:22px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 18px}
.card{border:1.5px solid var(--bd);border-left-width:5px;border-radius:12px;background:#fff;padding:14px 16px;margin-bottom:14px}
.card.ok{border-left-color:var(--ok)}.card.bad{border-left-color:var(--bad)}
.hd{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}.hd b{font-family:ui-monospace,Menlo,monospace;font-size:14px;color:var(--navy)}
.row{display:flex;gap:12px;padding:5px 0;border-top:1px solid #eef2f6}.row:first-of-type{border-top:0}.k{color:var(--muted);min-width:130px;font-size:12px}
.mono{font-family:ui-monospace,monospace;font-size:12.5px}.muted{color:var(--muted)}.bad{color:var(--bad);font-weight:700}
.ports{display:flex;flex-wrap:wrap;gap:5px}.pp{font-family:ui-monospace,monospace;font-size:12px;background:#eef2f6;padding:1px 7px;border-radius:6px}.pp.bad{background:#FDECEC;color:var(--bad);font-weight:700}
.nm{font-family:ui-monospace,monospace;font-size:11.5px;background:#0f1b28;color:#d6e4f0;padding:8px 10px;border-radius:8px;margin:2px 0;white-space:pre-wrap}
.b{font-weight:800;font-size:10.5px;padding:2px 9px;border-radius:6px}.b.ok{background:#E7F6EC;color:var(--ok)}.b.bad{background:#FDECEC;color:var(--bad)}
.alert{margin-top:8px;background:#fdf2f2;border:1px solid #f3caca;color:#7a1e1e;padding:8px 10px;border-radius:8px;font-size:12.5px}
.foot{color:var(--muted);font-size:11.5px;margin-top:6px}.foot a{color:#1C6FB5}
</style></head><body><div class="wrap">
<h1>Port Scan - Phone Farm</h1><p class="sub">${TS} · ${TOT} placa(s) · ${ALERTAS} com portas perigosas · portas em LISTEN lidas via adb${nmapport:+ e confirmadas com nmap}</p>
${CARDS}
<p class="foot">Numa placa de farm nenhum servico TCP deveria estar em LISTEN acessivel pela rede. A porta <b>5555</b> (adb over TCP) e a mais critica: da shell root sem autenticacao a qualquer host na mesma rede. Mantenha o chassi em <b>VLAN isolada</b> com egress default-deny. Ref: <a href="https://source.android.com/docs/security">AOSP Security</a>. Planilha em resumo.csv. Retrato pontual.</p>
</div></body></html>
HH

echo ""
echo ">> relatorio: $HTML"
echo ">> planilha:  $CSV"
echo ">> ${TOT} placa(s), ${ALERTAS} com portas perigosas em LISTEN"

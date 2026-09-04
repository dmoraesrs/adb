#!/usr/bin/env bash
#
# check-all.sh - AUDITORIA COMPLETA da phone farm num comando so.
#
# Roda, em sequencia, todos os checks e junta os relatorios numa pasta unica, com um
# index.html consolidado (dashboard + links):
#   1) health-report.sh    saude/integridade
#   2) validate-farm.sh    integridade + Magisk/apps/admins  -> veredito por placa
#   3) hardening-check.sh  config de seguranca vs CIS/AOSP    -> score por placa
#   4) scan-apks.sh        antivirus dos APKs (ClamAV; ou Sophos com SKIP_CLAMAV=1)
#   5) net-watch.sh        (opcional) conexoes/C2  -> defina NET_SECS>0 para ativar
#
# Uso:
#   bash scripts/check-all.sh [DIR_SAIDA]                         # tudo com ClamAV
#   VT_API_KEY=xxx bash scripts/check-all.sh /mnt/c/Users/helpdesk
#   SKIP_CLAMAV=1 bash scripts/check-all.sh /mnt/c/Users/helpdesk  # APKs p/ o Sophos do Windows
#   NET_SECS=60 bash scripts/check-all.sh /mnt/c/Users/helpdesk    # inclui o monitor de rede
#
set -uo pipefail

# garante que o adb aponta pro server do Windows (o profile pode nao ter carregado neste shell)
if [ -z "${ADB_SERVER_SOCKET:-}" ] && [ -f /etc/profile.d/adb-farm.sh ]; then . /etc/profile.d/adb-farm.sh; fi
if [ -z "${ADB_SERVER_SOCKET:-}" ]; then
  _w="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  [ -n "$_w" ] && export ADB_SERVER_SOCKET="tcp:${_w}:5037"; unset _w
fi

SCR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
AUDIT="${BASE%/}/farm-audit-${TS}"
NET_SECS="${NET_SECS:-0}"
mkdir -p "$AUDIT"

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
NDEV="$(printf '%s\n' "$serials" | grep -c '[^[:space:]]')"
if [ "${NDEV:-0}" -eq 0 ] 2>/dev/null; then
  echo "Nenhuma placa em 'device'. adb server inacessivel? ADB_SERVER_SOCKET='${ADB_SERVER_SOCKET:-vazio}'."
  echo "No Windows: 'adb -a nodaemon server start' + firewall 5037. No WSL: 'adb devices -l' deve listar."
  exit 1
fi
echo "== check-all: ${NDEV} placa(s) -> ${AUDIT} =="

step(){ echo ""; echo ">>> $1"; shift; "$@" >/dev/null 2>&1 && echo "    ok" || echo "    [!] etapa retornou erro (segue)"; }

step "1/5 saude"      bash "$SCR/health-report.sh"   "$AUDIT/health"
step "2/5 validacao"  bash "$SCR/validate-farm.sh"   "$AUDIT/validate"
step "3/5 hardening"  bash "$SCR/hardening-check.sh" "$AUDIT/hardening"
step "4/5 antivirus"  bash "$SCR/scan-apks.sh"       "$AUDIT/scan"
if [ "$NET_SECS" -gt 0 ] 2>/dev/null; then
  mkdir -p "$AUDIT/net"; ( cd "$AUDIT/net" && step "5/5 rede" bash "$SCR/net-watch.sh" "$NET_SECS" )
else echo ""; echo ">>> 5/5 rede: pulado (defina NET_SECS>0 para incluir)"; fi

# ---- localiza os artefatos gerados ----
find1(){ ls "$1" 2>/dev/null | head -1; }
H_HTML="$(find1 "$AUDIT/health/"*/report.html)"
V_HTML="$(find1 "$AUDIT/validate/"*/report.html)"; V_CSV="$(find1 "$AUDIT/validate/"*/resumo.csv)"
K_HTML="$(find1 "$AUDIT/hardening/"*/report.html)"; K_CSV="$(find1 "$AUDIT/hardening/"*/resumo.csv)"
S_TXT="$(find1 "$AUDIT/scan/"*/report.txt)"; S_CSV="$(find1 "$AUDIT/scan/"*/resumo.csv)"; S_CLAM="$(find1 "$AUDIT/scan/"*/clamav.log)"
N_TXT="$(find1 "$AUDIT/net/"*/report.txt)"

# ---- metricas ----
crit=0; aten=0; okv=0
[ -n "$V_CSV" ] && { crit=$(grep -c ',CRITICO,' "$V_CSV"); aten=$(grep -c ',ATENCAO,' "$V_CSV"); okv=$(grep -c ',OK,' "$V_CSV"); }
hscore="n/d"
[ -n "$K_CSV" ] && hscore=$(awk -F, 'NR>1{s+=$2;n++}END{if(n)printf "%d", s/n; else print "n/d"}' "$K_CSV")
avhit=0
[ -n "$S_CLAM" ] && avhit=$(grep -c 'FOUND' "$S_CLAM" 2>/dev/null || echo 0)
[ -n "$S_CSV" ] && avhit=$(( avhit + $(grep -c ',INFECTADO,' "$S_CSV" 2>/dev/null || echo 0) ))
netsusp="n/d"; [ -n "$N_TXT" ] && netsusp=$(grep -oE '[0-9]+ ocorrencia' "$N_TXT" | head -1 | grep -oE '[0-9]+' || echo 0)

rel(){ [ -n "$1" ] && echo "${1#$AUDIT/}" || echo ""; }
link(){ local p; p="$(rel "$1")"; [ -n "$p" ] && echo "<a href='$p'>abrir</a>" || echo "<span class='na'>nao gerado</span>"; }

INDEX="$AUDIT/index.html"
cat > "$INDEX" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Auditoria da Phone Farm - ${TS}</title><style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:980px;margin:0 auto;padding:26px}h1{font-size:23px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 20px}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.kpi{border:1.5px solid var(--bd);border-radius:12px;padding:14px 16px;background:#fff}.kpi b{font-size:26px;display:block;color:var(--navy);line-height:1.1}.kpi span{color:var(--muted);font-size:12px}
.kpi.bad b{color:var(--bad)}.kpi.warn b{color:var(--warn)}.kpi.ok b{color:var(--ok)}
table{width:100%;border-collapse:collapse;background:#fff;border:1.5px solid var(--bd);border-radius:12px;overflow:hidden}
th,td{text-align:left;padding:12px 14px;border-bottom:1px solid #eef2f6}th{background:#f7fafd;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.4px}
td a{color:#1C6FB5;font-weight:700}.na{color:var(--muted)}
.foot{color:var(--muted);font-size:11.5px;margin-top:16px}
</style></head><body><div class="wrap">
<h1>Auditoria de Seguranca da Phone Farm</h1><p class="sub">${TS} · ${NDEV} placa(s) · relatorio consolidado</p>
<div class="kpis">
  <div class="kpi"><b>${NDEV}</b><span>placas</span></div>
  <div class="kpi bad"><b>${crit}</b><span>criticas (validacao)</span></div>
  <div class="kpi warn"><b>${aten}</b><span>atencao</span></div>
  <div class="kpi ok"><b>${okv}</b><span>ok</span></div>
  <div class="kpi"><b>${hscore}</b><span>hardening medio /100</span></div>
  <div class="kpi bad"><b>${avhit}</b><span>deteccoes antivirus</span></div>
</div>
<table><thead><tr><th>Relatorio</th><th>O que valida</th><th></th></tr></thead><tbody>
<tr><td>Saude / integridade</td><td>identidade, Verified Boot, SELinux, patch, bateria/storage</td><td>$(link "$H_HTML")</td></tr>
<tr><td>Validacao de seguranca</td><td>root/Magisk, apps de terceiros, device admins, /data/local/tmp -> veredito</td><td>$(link "$V_HTML")</td></tr>
<tr><td>Hardening (CIS/AOSP)</td><td>config de seguranca do Android vs baseline -> score por placa</td><td>$(link "$K_HTML")</td></tr>
<tr><td>Antivirus (APKs)</td><td>APKs puxados e escaneados (ClamAV/VirusTotal/Sophos)</td><td>$([ -n "$S_TXT" ] && echo "<a href='$(rel "$S_TXT")'>abrir</a>" || echo "<span class='na'>nao gerado</span>")</td></tr>
<tr><td>Rede / C2</td><td>conexoes das placas x destinos suspeitos${netsusp:+ (susp: ${netsusp})}</td><td>$([ -n "$N_TXT" ] && echo "<a href='$(rel "$N_TXT")'>abrir</a>" || echo "<span class='na'>pulado</span>")</td></tr>
</tbody></table>
<p class="foot">Planilhas (.csv) e detalhes por placa dentro de cada subpasta. Referencias oficiais em cada relatorio. Retrato pontual, sem root; nao substitui analise forense de firmware.</p>
</div></body></html>
HH

echo ""
echo "======================================================================"
echo " AUDITORIA CONCLUIDA"
echo " indice:   $INDEX"
echo " resumo:   ${NDEV} placas | criticas=${crit} atencao=${aten} ok=${okv} | hardening~${hscore}/100 | antivirus=${avhit} deteccoes"
echo "======================================================================"
command -v wslpath >/dev/null 2>&1 && echo " abrir no Windows: explorer.exe \"$(wslpath -w "$INDEX")\""

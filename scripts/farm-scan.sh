#!/usr/bin/env bash
#
# farm-scan.sh - TUDO NUM COMANDO (Ubuntu/Linux puro):
#   0) instala as ferramentas do Google (platform-tools: adb/fastboot) + deps (nmap, clamav, jq)
#      e as udev rules pra enxergar as placas por USB sem root
#   1) valida os telefones (integridade + root/Magisk + apps + device admins)  -> veredito por placa
#   2) passa antivirus nos apps (puxa os APKs e escaneia com ClamAV; +VirusTotal se VT_API_KEY)
#   3) escaneia as portas de cada placa (LISTEN + 5555/adb-tcp; +nmap se a placa tiver IP)
# e junta tudo num index.html consolidado.
#
# Uso:
#   sudo bash scripts/farm-scan.sh [DIR_SAIDA]         # instala o que faltar e roda tudo
#   VT_API_KEY=xxxxx sudo bash scripts/farm-scan.sh ~/farm-audit
#   SKIP_INSTALL=1 bash scripts/farm-scan.sh ~/farm-audit   # nao instala nada, so roda
#
set -uo pipefail

SCR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
AUDIT="${BASE%/}/farm-scan-${TS}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
mkdir -p "$AUDIT"

# ---------- 0) ferramentas ----------
ensure_tools(){
  [ "$SKIP_INSTALL" = 1 ] && { echo "== install pulado (SKIP_INSTALL=1) =="; return 0; }
  [ "$(id -u)" -eq 0 ] || { echo "[!] rode com sudo pra instalar as ferramentas (ou use SKIP_INSTALL=1)."; exit 1; }
  echo "== 0/3 instalando ferramentas do Google + deps =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  # deps de scan
  apt-get install -y --no-install-recommends nmap clamav jq curl unzip wget ca-certificates >/dev/null 2>&1 || true
  # platform-tools do Google (adb/fastboot). Se ja tem adb, mantem; senao instala o oficial.
  if ! command -v adb >/dev/null 2>&1; then
    bash "$SCR/update-platform-tools.sh" 2>/dev/null || apt-get install -y --no-install-recommends android-tools-adb android-tools-fastboot >/dev/null 2>&1 || true
  fi
  # udev rules pra falar com o USB das placas sem root
  apt-get install -y --no-install-recommends android-sdk-platform-tools-common >/dev/null 2>&1 || true
  tgt="${SUDO_USER:-$USER}"; id "$tgt" >/dev/null 2>&1 && usermod -aG plugdev "$tgt" 2>/dev/null || true
  udevadm control --reload-rules 2>/dev/null || true; udevadm trigger 2>/dev/null || true
  echo "    adb: $(command -v adb || echo 'NAO instalado') | nmap: $(command -v nmap >/dev/null && echo ok || echo -) | clamav: $(command -v clamscan >/dev/null && echo ok || echo -)"
}
ensure_tools

# ---------- placas ----------
serials="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')"
NDEV="$(printf '%s\n' "$serials" | grep -c '[^[:space:]]')"
if [ "${NDEV:-0}" -eq 0 ] 2>/dev/null; then
  echo ""
  echo "[!] Nenhuma placa em 'device'. Verifique:"
  echo "    - 'adb devices -l' lista as placas? (se 'unauthorized', autorize a chave RSA)"
  echo "    - as placas estao energizadas e o hub USB aguenta a carga?"
  echo "    - relogar pode ser preciso apos entrar no grupo plugdev."
  exit 1
fi
echo "== ${NDEV} placa(s) -> ${AUDIT} =="

step(){ echo ""; echo ">>> $1"; shift; "$@" >/dev/null 2>&1 && echo "    ok" || echo "    [!] etapa retornou erro (segue)"; }
step "1/3 validacao"  bash "$SCR/validate-farm.sh" "$AUDIT/validate"
step "2/3 antivirus"  env VT_API_KEY="${VT_API_KEY:-}" bash "$SCR/scan-apks.sh" "$AUDIT/scan"
step "3/3 portas"     bash "$SCR/port-scan.sh" "$AUDIT/ports"

# ---------- localiza artefatos ----------
find1(){ ls "$1" 2>/dev/null | head -1; }
V_HTML="$(find1 "$AUDIT/validate/"*/report.html)"; V_CSV="$(find1 "$AUDIT/validate/"*/resumo.csv)"
S_TXT="$(find1 "$AUDIT/scan/"*/report.txt)"; S_CLAM="$(find1 "$AUDIT/scan/"*/clamav.log)"; S_CSV="$(find1 "$AUDIT/scan/"*/resumo.csv)"
P_HTML="$(find1 "$AUDIT/ports/"*/report.html)"; P_CSV="$(find1 "$AUDIT/ports/"*/resumo.csv)"

crit=0; aten=0; okv=0
[ -n "$V_CSV" ] && { crit=$(grep -c ',CRITICO,' "$V_CSV" 2>/dev/null); aten=$(grep -c ',ATENCAO,' "$V_CSV" 2>/dev/null); okv=$(grep -c ',OK,' "$V_CSV" 2>/dev/null); }
avhit=0
[ -n "$S_CLAM" ] && avhit=$(grep -c 'FOUND' "$S_CLAM" 2>/dev/null || echo 0)
[ -n "$S_CSV" ] && avhit=$(( avhit + $(grep -c ',INFECTADO,' "$S_CSV" 2>/dev/null || echo 0) ))
portalert=0
[ -n "$P_CSV" ] && portalert=$(awk -F, 'NR>1 && $6!=""{n++}END{print n+0}' "$P_CSV" 2>/dev/null)

rel(){ [ -n "$1" ] && echo "${1#$AUDIT/}" || echo ""; }
link(){ local p; p="$(rel "$1")"; [ -n "$p" ] && echo "<a href='$p'>abrir</a>" || echo "<span class='na'>nao gerado</span>"; }

INDEX="$AUDIT/index.html"
cat > "$INDEX" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Farm Scan - ${TS}</title><style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:940px;margin:0 auto;padding:26px}h1{font-size:23px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 20px}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.kpi{border:1.5px solid var(--bd);border-radius:12px;padding:14px 16px;background:#fff}.kpi b{font-size:26px;display:block;color:var(--navy);line-height:1.1}.kpi span{color:var(--muted);font-size:12px}
.kpi.bad b{color:var(--bad)}.kpi.warn b{color:var(--warn)}.kpi.ok b{color:var(--ok)}
table{width:100%;border-collapse:collapse;background:#fff;border:1.5px solid var(--bd);border-radius:12px;overflow:hidden}
th,td{text-align:left;padding:12px 14px;border-bottom:1px solid #eef2f6}th{background:#f7fafd;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.4px}
td a{color:#1C6FB5;font-weight:700}.na{color:var(--muted)}.foot{color:var(--muted);font-size:11.5px;margin-top:16px}
</style></head><body><div class="wrap">
<h1>Farm Scan - Auditoria da Phone Farm</h1><p class="sub">${TS} · ${NDEV} placa(s) · instala + valida + antivirus + portas</p>
<div class="kpis">
  <div class="kpi"><b>${NDEV}</b><span>placas</span></div>
  <div class="kpi bad"><b>${crit}</b><span>criticas (validacao)</span></div>
  <div class="kpi warn"><b>${aten}</b><span>atencao</span></div>
  <div class="kpi ok"><b>${okv}</b><span>ok</span></div>
  <div class="kpi bad"><b>${avhit}</b><span>deteccoes antivirus</span></div>
  <div class="kpi bad"><b>${portalert}</b><span>placas c/ portas perigosas</span></div>
</div>
<table><thead><tr><th>Relatorio</th><th>O que valida</th><th></th></tr></thead><tbody>
<tr><td>Validacao de seguranca</td><td>root/Magisk, apps de terceiros, device admins, /data/local/tmp -> veredito</td><td>$(link "$V_HTML")</td></tr>
<tr><td>Antivirus (APKs)</td><td>APKs puxados e escaneados (ClamAV/VirusTotal)</td><td>$([ -n "$S_TXT" ] && echo "<a href='$(rel "$S_TXT")'>abrir</a>" || echo "<span class='na'>nao gerado</span>")</td></tr>
<tr><td>Port scan</td><td>portas em LISTEN, 5555/adb-tcp e nmap externo -> superficie de rede</td><td>$(link "$P_HTML")</td></tr>
</tbody></table>
<p class="foot">Planilhas (.csv) e detalhes por placa em cada subpasta. Retrato pontual sem root; nao substitui analise forense de firmware. Placa com veredito CRITICO ou porta 5555 exposta deve ser isolada em VLAN e reflashada com ROM stock oficial.</p>
</div></body></html>
HH

echo ""
echo "======================================================================"
echo " FARM SCAN CONCLUIDO"
echo " indice:  $INDEX"
echo " resumo:  ${NDEV} placas | criticas=${crit} atencao=${aten} ok=${okv} | antivirus=${avhit} | portas perigosas em ${portalert} placa(s)"
echo "======================================================================"

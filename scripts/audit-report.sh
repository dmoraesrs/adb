#!/usr/bin/env bash
#
# audit-report.sh - auditoria de seguranca COMPLETA das placas + UM report.html consolidado.
#
# Roda em sequencia: validate + hardening + port-scan + antivirus (ClamAV) + inventario de apps,
# e junta tudo num unico relatorio executivo autocontido (audit-<ts>/report.html). Pensado pra
# rodar desanexado (nohup) e voce so pegar o resultado no fim. Escreve /tmp/audit-report-done ao
# terminar, com o caminho do report em /tmp/audit-report-path.
#
# Uso:
#   nohup bash scripts/audit-report.sh ~/farm-audit >/tmp/audit.log 2>&1 &
#   (ClamAV precisa da base: rode antes 'sudo freshclam', ou o antivirus fica sem assinaturas)
#
set -uo pipefail
SCR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
OUT="${BASE%/}/audit-${TS}"
mkdir -p "$OUT"
LOG="$OUT/run.log"
esc(){ sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

echo "[1/5] validacao"  | tee -a "$LOG"; bash "$SCR/validate-farm.sh"   "$OUT/validate"  >>"$LOG" 2>&1
echo "[2/5] hardening"  | tee -a "$LOG"; bash "$SCR/hardening-check.sh" "$OUT/hardening" >>"$LOG" 2>&1
echo "[3/5] portas"     | tee -a "$LOG"; bash "$SCR/port-scan.sh"       "$OUT/ports"     >>"$LOG" 2>&1
echo "[4/5] antivirus"  | tee -a "$LOG"; bash "$SCR/scan-apks.sh"       "$OUT/scan"      >>"$LOG" 2>&1
echo "[5/5] inventario" | tee -a "$LOG"
INV="$OUT/apps.txt"; : > "$INV"
for s in $(adb devices | awk '$2=="device"{print $1}'); do
  adb -s "$s" shell pm list packages -3 2>/dev/null | sed 's/package://' | tr -d '\r'
done | sort | uniq -c | sort -rn > "$INV"

VCSV="$(ls "$OUT"/validate/*/resumo.csv 2>/dev/null | head -1)"
KCSV="$(ls "$OUT"/hardening/*/resumo.csv 2>/dev/null | head -1)"
PCSV="$(ls "$OUT"/ports/*/resumo.csv 2>/dev/null | head -1)"
CLAM="$(ls "$OUT"/scan/*/clamav.log 2>/dev/null | head -1)"
SCSV="$(ls "$OUT"/scan/*/resumo.csv 2>/dev/null | head -1)"

# ---- metricas ----
NDEV=$(adb devices | awk '$2=="device"{n++}END{print n+0}')
CRIT=0; ATEN=0; OKV=0
[ -n "$VCSV" ] && { CRIT=$(grep -c ',CRITICO,' "$VCSV"); ATEN=$(grep -c ',ATENCAO,' "$VCSV"); OKV=$(grep -c ',OK,' "$VCSV"); }
HSCORE="n/d"; [ -n "$KCSV" ] && HSCORE=$(awk -F, 'NR>1{s+=$2;n++}END{if(n)printf "%d",s/n; else print "n/d"}' "$KCSV")
AVHIT=0; [ -n "$CLAM" ] && AVHIT=$(grep -c FOUND "$CLAM" 2>/dev/null || echo 0)
PALERT=0; [ -n "$PCSV" ] && PALERT=$(awk -F, 'NR>1 && $6!=""{n++}END{print n+0}' "$PCSV")
NAPKS=0; [ -n "$SCSV" ] && NAPKS=$(( $(wc -l < "$SCSV") - 1 ))

# ---- linhas das tabelas ----
vrows=""
if [ -n "$VCSV" ]; then
  vrows=$(awk -F',' 'NR>1{
    v=$15; cls=(v=="CRITICO")?"bad":(v=="ATENCAO")?"warn":"ok";
    printf "<tr class=%s><td class=mono>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><b class=%s>%s</b></td></tr>",cls,$1,$6,$7,$8,$9,$10,cls,v
  }' "$VCSV")
fi
approws=""
if [ -f "$INV" ]; then
  approws=$(awk '{c=$1; $1=""; sub(/^ /,""); pkg=$0;
    sus=(pkg ~ /genfarmer|xwkeyboard|musically|shopee|niuniu|\.id$|ceijs|jinhua|magisk/)?"warn":"";
    printf "<tr class=%s><td>%s</td><td class=mono>%s</td></tr>",sus,c,pkg
  }' "$INV")
fi
krows=""
if [ -n "$KCSV" ]; then
  krows=$(awk -F',' 'NR>1{cls=($2>=80)?"ok":($2>=50)?"warn":"bad";
    printf "<tr class=%s><td class=mono>%s</td><td><b class=%s>%s/100</b></td><td>%s</td><td>%s</td><td>%s</td></tr>",cls,$1,cls,$2,$3,$4,$5
  }' "$KCSV")
fi
avblock="<p class=muted>Sem deteccoes do ClamAV nos APKs escaneados.</p>"
[ "$AVHIT" -gt 0 ] 2>/dev/null && avblock="<pre class=nm>$(grep FOUND "$CLAM" 2>/dev/null | esc)</pre>"

cat > "$OUT/report.html" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Auditoria da Phone Farm - ${TS}</title><style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:13.5px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:1080px;margin:0 auto;padding:26px}h1{font-size:23px;margin:0 0 2px;color:var(--navy)}h2{font-size:16px;color:var(--navy);margin:26px 0 8px}
.sub{color:var(--muted);margin:0 0 18px}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:12px;margin-bottom:8px}
.kpi{border:1.5px solid var(--bd);border-radius:12px;padding:12px 14px;background:#fff}.kpi b{font-size:24px;display:block;color:var(--navy);line-height:1.1}.kpi span{color:var(--muted);font-size:11.5px}
.kpi.bad b{color:var(--bad)}.kpi.warn b{color:var(--warn)}.kpi.ok b{color:var(--ok)}
table{width:100%;border-collapse:collapse;background:#fff;border:1.5px solid var(--bd);border-radius:12px;overflow:hidden;font-size:12.5px}
th,td{text-align:left;padding:8px 11px;border-bottom:1px solid #eef2f6}th{background:#f7fafd;color:var(--muted);font-size:10.5px;text-transform:uppercase;letter-spacing:.3px}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:11.5px}.muted{color:var(--muted)}
tr.bad td{background:#fdf2f2}tr.warn td{background:#fdf8ee}
b.ok{color:var(--ok)}b.warn{color:var(--warn)}b.bad{color:var(--bad)}
.nm{font-family:ui-monospace,monospace;font-size:11.5px;background:#0f1b28;color:#d6e4f0;padding:9px 11px;border-radius:8px;white-space:pre-wrap;overflow-x:auto}
.foot{color:var(--muted);font-size:11.5px;margin-top:20px}
</style></head><body><div class="wrap">
<h1>Auditoria de Seguranca da Phone Farm</h1>
<p class="sub">${TS} · ${NDEV} placa(s) acessiveis via adb · relatorio consolidado</p>
<div class="kpis">
  <div class="kpi"><b>${NDEV}</b><span>placas auditadas</span></div>
  <div class="kpi bad"><b>${CRIT}</b><span>criticas</span></div>
  <div class="kpi warn"><b>${ATEN}</b><span>atencao</span></div>
  <div class="kpi ok"><b>${OKV}</b><span>ok</span></div>
  <div class="kpi"><b>${HSCORE}</b><span>hardening medio /100</span></div>
  <div class="kpi bad"><b>${AVHIT}</b><span>deteccoes antivirus</span></div>
  <div class="kpi bad"><b>${PALERT}</b><span>placas c/ porta perigosa</span></div>
  <div class="kpi"><b>${NAPKS}</b><span>APKs escaneados</span></div>
</div>

<h2>1. Veredito por placa</h2>
<table><thead><tr><th>Serial</th><th>SELinux</th><th>Root</th><th>Bootloader</th><th>V.Boot</th><th>adb TCP</th><th>Veredito</th></tr></thead><tbody>${vrows}</tbody></table>

<h2>2. Apps de terceiros (destaque = farm/suspeito)</h2>
<table><thead><tr><th>Placas</th><th>Pacote</th></tr></thead><tbody>${approws}</tbody></table>

<h2>3. Hardening (CIS/AOSP)</h2>
<table><thead><tr><th>Serial</th><th>Score</th><th>Pass</th><th>Warn</th><th>Fail</th></tr></thead><tbody>${krows}</tbody></table>

<h2>4. Antivirus (ClamAV nos APKs)</h2>
${avblock}

<p class="foot">Retrato pontual sem alterar as placas. Detalhes por placa e planilhas (.csv) nas subpastas de <code>${OUT}</code>. Placa CRITICA ou com porta 5555 exposta deve ser isolada em VLAN e reflashada com ROM stock oficial.</p>
</div></body></html>
HH

echo "$OUT/report.html" > /tmp/audit-report-path
touch /tmp/audit-report-done
echo "DONE -> $OUT/report.html" | tee -a "$LOG"

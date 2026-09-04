#!/usr/bin/env bash
#
# validate-farm.sh - PROCESSO COMPLETO de validacao de seguranca das placas.
#
# Junta num relatorio unico: integridade da ROM (build variant, Verified Boot, bootloader,
# SELinux, criptografia, patch), superficie de ADB, ROOT (su/Magisk) e um APROFUNDAMENTO
# forense leve (modulos Magisk, apps de terceiros, device admins, servicos de acessibilidade,
# /data/local/tmp) - os lugares onde control-software/backdoor costuma morar. Da um veredito
# por placa (OK / ATENCAO / CRITICO) com os motivos, e gera:
#   validate-<ts>/report.html          relatorio consolidado (1 card por placa)
#   validate-<ts>/resumo.csv           uma linha por placa
#   validate-<ts>/detalhe/<serial>.txt dump completo p/ revisao manual
#
# NAO precisa de root. So getprop/dumpsys/pm/settings/ls via adb shell.
#
# Uso:
#   bash scripts/validate-farm.sh [DIR_SAIDA]      # ex: /mnt/c/Users/helpdesk
#
set -uo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
OUT="${BASE%/}/validate-${TS}"
DET="${OUT}/detalhe"
HTML="${OUT}/report.html"
CSV="${OUT}/resumo.csv"
mkdir -p "$DET"

esc(){ sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
gp(){ echo "$1" | tr -d '\r' | sed -e 's/^ *//; s/ *$//'; }

# nomes/substrings de familias de firmware malicioso pre-instalado (heuristica)
SUSPECT='adups|com\.fw\.upgrade|com\.rock|triada|badbox|hummingbad|com\.ehz|xhide|com\.gmobi|com\.adups|riskware|com\.wps\.|com\.sprd\.'

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

echo "serial,modelo,android,patch,build_type,selinux,root,bootloader,verifiedboot,adb_tcp,magisk_modules,apps3,accessibility,tmp_files,veredito,motivos" > "$CSV"
TOT=0; N_OK=0; N_WARN=0; N_BAD=0; CARDS=""

badge(){ case "$1" in ok) echo "<span class='b ok'>$2</span>";; warn) echo "<span class='b warn'>$2</span>";; bad) echo "<span class='b bad'>$2</span>";; *) echo "<span class='b na'>$2</span>";; esac; }

for s in $serials; do
  TOT=$((TOT+1)); echo "validando $s ..." >&2
  raw="$(adb -s "$s" shell '
    echo "MODEL|$(getprop ro.product.model)"
    echo "REL|$(getprop ro.build.version.release)"
    echo "PATCH|$(getprop ro.build.version.security_patch)"
    echo "FP|$(getprop ro.build.fingerprint)"
    echo "BTYPE|$(getprop ro.build.type)"
    echo "DEBUG|$(getprop ro.debuggable)"
    echo "SECURE|$(getprop ro.secure)"
    echo "ADBSEC|$(getprop ro.adb.secure)"
    echo "TCP|$(getprop service.adb.tcp.port)$(getprop persist.adb.tcp.port)"
    echo "VBOOT|$(getprop ro.boot.verifiedbootstate)"
    echo "LOCK|$(getprop ro.boot.flash.locked)"
    echo "SELINUX|$(getenforce 2>/dev/null)"
    echo "CRYPTO|$(getprop ro.crypto.state)"
    echo "SU|$(ls -l /system/xbin/su /system/bin/su /sbin/su /su/bin/su 2>/dev/null | head -1)"
    echo "MODS|$(ls /data/adb/modules 2>/dev/null | tr "\n" "," )"
    echo "PK3|$(pm list packages -3 2>/dev/null | sed "s/package://" | tr "\n" "," )"
    echo "ADMIN|$(dumpsys device_policy 2>/dev/null | grep -iE "admin=|Active admin" | tr "\n" ";" )"
    echo "ACC|$(settings get secure enabled_accessibility_services 2>/dev/null)"
    echo "TMP|$(ls -A /data/local/tmp 2>/dev/null | tr "\n" "," )"
  ' 2>/dev/null)"

  declare -A f=()
  while IFS='|' read -r k v; do [ -n "$k" ] && f[$k]="$(gp "$v")"; done <<< "$raw"

  # dump por placa (revisao manual)
  { echo "== $s  ($(date)) =="; echo "$raw"; } > "$DET/${s}.txt"

  # ---- avaliacao ----
  items=""; worst="ok"; motivos=""
  bump(){ case "$1" in bad) worst="bad";; warn) [ "$worst" = ok ] && worst="warn";; esac; return 0; }
  add(){ items="${items}<div class='it'><span class='k'>$1</span>$(badge "$2" "$3")</div>"; bump "$2"; }
  motivo(){ motivos="${motivos}${motivos:+; }$1"; }

  bt="${f[BTYPE]:-?}";    [ "$bt" = user ] && add "Build variant" ok "user" || { add "Build variant" bad "$bt"; motivo "ROM $bt (adulterada)"; }
  sel="${f[SELINUX]:-}";  case "$sel" in Enforcing) add "SELinux" ok "Enforcing";; Permissive) add "SELinux" bad "Permissive"; motivo "SELinux Permissive";; *) add "SELinux" na "${sel:-n/d}";; esac
  suv="${f[SU]:-}";       if [ -n "$suv" ]; then rt="presente"; echo "$suv" | grep -qi magisk && rt="Magisk"; add "Root" bad "$rt"; motivo "root ($rt)"; else add "Root" ok "ausente"; fi
  lk="${f[LOCK]:-}";      case "$lk" in 1) add "Bootloader" ok "locked";; 0) add "Bootloader" warn "unlocked"; motivo "bootloader unlocked";; *) add "Bootloader" na "${lk:-n/d}";; esac
  vb="${f[VBOOT]:-}";     case "$vb" in green) add "Verified Boot" ok "green";; yellow|orange) add "Verified Boot" warn "$vb"; motivo "verified boot $vb";; red) add "Verified Boot" bad "red"; motivo "verified boot red";; *) add "Verified Boot" na "${vb:-n/d}";; esac
  dbg="${f[DEBUG]:-}";    [ "$dbg" = 1 ] && { add "debuggable" bad "1"; motivo "debuggable"; } || add "debuggable" ok "${dbg:-0}"
  asec="${f[ADBSEC]:-}";  [ "$asec" = 1 ] && add "ro.adb.secure" ok "1" || { add "ro.adb.secure" bad "${asec:-0}"; motivo "adb sem chave"; }
  tcp="${f[TCP]:-}";      { [ -z "$tcp" ] || [ "$tcp" = "-1" ]; } && add "ADB TCP" ok "off" || { add "ADB TCP" warn "$tcp"; motivo "adb tcp $tcp"; }
  pt="${f[PATCH]:-}"; py="${pt%%-*}"; cy="$(date +%Y)"
  if [ -z "$pt" ]; then add "Patch" na "n/d"; elif [ "${py:-0}" -ge "$((cy-1))" ] 2>/dev/null; then add "Patch" ok "$pt"; elif [ "${py:-0}" -ge "$((cy-3))" ] 2>/dev/null; then add "Patch" warn "$pt"; motivo "patch $pt atrasado"; else add "Patch" bad "$pt"; motivo "patch $pt (anos sem update)"; fi

  # deep scan
  mods="${f[MODS]:-}"; mods="${mods%,}"
  [ -n "$mods" ] && { add "Modulos Magisk" warn "${mods}"; motivo "modulos magisk: ${mods}"; } || add "Modulos Magisk" ok "nenhum"
  pk3="${f[PK3]:-}"; pk3="${pk3%,}"; n3=0; [ -n "$pk3" ] && n3=$(echo "$pk3" | tr ',' '\n' | grep -c .)
  susp="$(echo "$pk3" | tr ',' '\n' | grep -iE "$SUSPECT" || true)"
  if [ -n "$susp" ]; then add "Apps 3os" bad "${n3} (SUSPEITO)"; motivo "app suspeito: $(echo "$susp" | tr '\n' ' ')"; else add "Apps 3os" ok "${n3}"; fi
  acc="${f[ACC]:-}"; { [ -z "$acc" ] || [ "$acc" = "null" ]; } && add "Acessibilidade" ok "nenhum" || { add "Acessibilidade" warn "ativo"; motivo "accessibility service ativo"; }
  adm="${f[ADMIN]:-}"; [ -n "$adm" ] && { add "Device admin" warn "presente"; motivo "device admin ativo"; } || add "Device admin" ok "nenhum"
  tmp="${f[TMP]:-}"; tmp="${tmp%,}"; [ -n "$tmp" ] && { add "/data/local/tmp" warn "${tmp}"; motivo "tmp: ${tmp}"; } || add "/data/local/tmp" ok "vazio"

  case "$worst" in ok) N_OK=$((N_OK+1)); vc="ok"; vt="OK";; warn) N_WARN=$((N_WARN+1)); vc="warn"; vt="ATENCAO";; bad) N_BAD=$((N_BAD+1)); vc="bad"; vt="CRITICO";; esac
  [ -z "$motivos" ] && motivos="sem apontamentos"

  sub="$(echo "${f[MODEL]:-?} · Android ${f[REL]:-?} · ${n3} apps 3os" | esc)"
  mot_html="$(echo "$motivos" | esc)"
  CARDS="${CARDS}<div class='card ${vc}'><div class='hd'><div><b>$(echo "$s"|esc)</b><small>${sub}</small></div><span class='v ${vc}'>${vt}</span></div><div class='fp'>$(echo "${f[FP]:-}"|esc)</div><div class='its'>${items}</div><div class='mot'><b>Motivos:</b> ${mot_html}</div></div>"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,"%s",%s,"%s"\n' \
    "$s" "${f[MODEL]:-}" "${f[REL]:-}" "${pt}" "${bt}" "${sel}" "${suv:+sim}" "${lk}" "${vb}" "${tcp}" "${mods}" "${n3}" "${acc:+sim}" "${tmp}" "${vt}" "${motivos}" >> "$CSV"
  unset f
done

pct(){ [ "$TOT" -gt 0 ] && echo $(( $1*100/TOT )) || echo 0; }
cat > "$HTML" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Validacao da Phone Farm - ${TS}</title><style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:1180px;margin:0 auto;padding:24px}h1{font-size:22px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 18px}
.kpis{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}.kpi{border:1.5px solid var(--bd);border-radius:12px;padding:12px 16px;background:#fff;min-width:120px}
.kpi b{font-size:24px;display:block;color:var(--navy)}.kpi span{color:var(--muted);font-size:12px}.kpi.ok b{color:var(--ok)}.kpi.warn b{color:var(--warn)}.kpi.bad b{color:var(--bad)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:14px}
.card{border:1.5px solid var(--bd);border-left-width:5px;border-radius:12px;background:#fff;padding:14px 16px}
.card.ok{border-left-color:var(--ok)}.card.warn{border-left-color:var(--warn)}.card.bad{border-left-color:var(--bad)}
.hd{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}.hd b{font-family:ui-monospace,Menlo,monospace;font-size:13px;color:var(--navy)}
.hd small{display:block;color:var(--muted);font-size:11.5px;margin-top:3px}.fp{font-family:ui-monospace,monospace;font-size:10px;color:#9db0c2;margin:8px 0;word-break:break-all}
.v{font-size:11px;font-weight:800;padding:3px 9px;border-radius:20px;white-space:nowrap}.v.ok{background:#E7F6EC;color:var(--ok)}.v.warn{background:#FBEEDD;color:var(--warn)}.v.bad{background:#FDECEC;color:var(--bad)}
.its{display:grid;grid-template-columns:1fr 1fr;gap:5px 14px;margin-top:6px}.it{display:flex;justify-content:space-between;gap:6px;font-size:12px;border-bottom:1px dotted #eef2f6;padding:3px 0}.it .k{color:var(--muted)}
.b{font-weight:700;font-size:11px;padding:1px 7px;border-radius:6px}.b.ok{background:#E7F6EC;color:var(--ok)}.b.warn{background:#FBEEDD;color:var(--warn)}.b.bad{background:#FDECEC;color:var(--bad)}.b.na{background:#eef2f6;color:var(--muted)}
.mot{margin-top:10px;font-size:12px;color:#7a3a10;background:#FFF6E9;border-radius:8px;padding:8px 10px}
.foot{color:var(--muted);font-size:11.5px;margin-top:18px}.foot a{color:#1C6FB5}
</style></head><body><div class="wrap">
<h1>Validacao de Seguranca da Phone Farm</h1><p class="sub">${TS} · ${TOT} placa(s) · integridade + aprofundamento (Magisk/apps/admins) + rede</p>
<div class="kpis"><div class="kpi"><b>${TOT}</b><span>placas</span></div><div class="kpi ok"><b>${N_OK}</b><span>OK ($(pct $N_OK)%)</span></div><div class="kpi warn"><b>${N_WARN}</b><span>Atencao ($(pct $N_WARN)%)</span></div><div class="kpi bad"><b>${N_BAD}</b><span>Critico ($(pct $N_BAD)%)</span></div></div>
<div class="grid">${CARDS}</div>
<p class="foot">Detalhe por placa (apps, modulos, admins) em <code>detalhe/&lt;serial&gt;.txt</code> · planilha em <code>resumo.csv</code>. Referencias: <a href="https://source.android.com/docs/security/features/verifiedboot">Verified Boot</a> · <a href="https://source.android.com/docs/security/features/selinux">SELinux</a> · <a href="https://source.android.com/docs/security/bulletin">Security Bulletins</a> · <a href="https://security.googleblog.com/2019/06/pha-family-highlights-triada.html">Triada/BadBox</a>. Retrato pontual, sem root; nao substitui analise forense de firmware.</p>
</div></body></html>
HH

echo ""
echo ">> relatorio:  $HTML"
echo ">> planilha:   $CSV"
echo ">> detalhes:   $DET/<serial>.txt"
echo ">> resumo: ${TOT} placas | OK=${N_OK} | Atencao=${N_WARN} | Critico=${N_BAD}"

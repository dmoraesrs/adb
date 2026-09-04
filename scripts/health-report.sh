#!/usr/bin/env bash
#
# health-report.sh - Retrato de SAUDE e SEGURANCA das placas da phone farm em HTML.
#
# Para cada placa reconhecida pelo adb, coleta identidade, integridade da ROM
# (Verified Boot, bootloader, build variant, SELinux, criptografia), superficie de
# ADB e saude de hardware (bateria, memoria, storage). Avalia cada item como
# OK / ATENCAO / CRITICO e gera um relatorio HTML unico com legenda e REFERENCIAS
# OFICIAIS (Android Open Source Project, Google, Samsung) para cada criterio.
#
# NAO precisa de root. Usa apenas getprop/dumpsys/pm via adb shell.
#
# Uso:
#   bash scripts/health-report.sh
#   ADB_SERVER_SOCKET=tcp:192.168.0.10:5037 bash scripts/health-report.sh   # via server remoto
#
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
OUT="health-report-${TS}"
HTML="${OUT}/report.html"
mkdir -p "$OUT"

esc() { sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
gp()  { echo "$1" | tr -d '\r' | sed -e 's/^ *//; s/ *$//'; }

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

# contadores globais
TOT=0; N_OK=0; N_WARN=0; N_BAD=0
CARDS=""

# badge(status,texto) -> span colorido; status: ok|warn|bad|na
badge() {
  case "$1" in
    ok)   echo "<span class='b ok'>$2</span>";;
    warn) echo "<span class='b warn'>$2</span>";;
    bad)  echo "<span class='b bad'>$2</span>";;
    *)    echo "<span class='b na'>$2</span>";;
  esac
}

for s in $serials; do
  TOT=$((TOT+1))
  echo "coletando $s ..." >&2
  raw="$(adb -s "$s" shell '
    echo "MODEL|$(getprop ro.product.model)"
    echo "MFR|$(getprop ro.product.manufacturer)"
    echo "REL|$(getprop ro.build.version.release)"
    echo "PATCH|$(getprop ro.build.version.security_patch)"
    echo "BTYPE|$(getprop ro.build.type)"
    echo "DEBUG|$(getprop ro.debuggable)"
    echo "SECURE|$(getprop ro.secure)"
    echo "ADBSEC|$(getprop ro.adb.secure)"
    echo "TCP|$(getprop service.adb.tcp.port)$(getprop persist.adb.tcp.port)"
    echo "VBOOT|$(getprop ro.boot.verifiedbootstate)"
    echo "VERITY|$(getprop ro.boot.veritymode)"
    echo "LOCK|$(getprop ro.boot.flash.locked)$(getprop ro.boot.vbmeta.device_state)"
    echo "CRYPTO|$(getprop ro.crypto.state)"
    echo "FP|$(getprop ro.build.fingerprint)"
    echo "SELINUX|$(getenforce 2>/dev/null)"
    echo "SU|$(ls /system/xbin/su /system/bin/su /sbin/su /su/bin/su 2>/dev/null | head -1)"
    echo "MAGISK|$(ls /sbin/.magisk /data/adb/magisk 2>/dev/null | head -1)"
    echo "BATTL|$(dumpsys battery 2>/dev/null | sed -n "s/.*level: *//p" | head -1)"
    echo "BATTH|$(dumpsys battery 2>/dev/null | sed -n "s/.*health: *//p" | head -1)"
    echo "BATTT|$(dumpsys battery 2>/dev/null | sed -n "s/.*temperature: *//p" | head -1)"
    echo "MEMT|$(sed -n "s/MemTotal: *//p" /proc/meminfo | tr -d " kB")"
    echo "MEMA|$(sed -n "s/MemAvailable: *//p" /proc/meminfo | tr -d " kB")"
    echo "DATA|$(df /data 2>/dev/null | tail -1 | awk "{print \$5\" usado, \"\$4\" livre\"}")"
    echo "UP|$(cut -d. -f1 /proc/uptime)"
    echo "PK3|$(pm list packages -3 2>/dev/null | wc -l)"
  ' 2>/dev/null)"

  declare -A f=()
  while IFS='|' read -r k v; do [ -n "$k" ] && f[$k]="$(gp "$v")"; done <<< "$raw"

  # ---- avaliacoes ----
  items=""; worst="ok"
  bump(){ case "$1" in bad) worst="bad";; warn) [ "$worst" = ok ] && worst="warn";; esac; }
  add(){ items="${items}<div class='it'><span class='k'>$1</span>$(badge "$2" "$3")</div>"; bump "$2"; }

  bt="${f[BTYPE]:-?}";       [ "$bt" = user ] && add "Build variant" ok "user (oficial)" || add "Build variant" bad "$bt (adulterada)"
  dbg="${f[DEBUG]:-?}";      [ "$dbg" = 0 ] && add "ro.debuggable" ok "0" || add "ro.debuggable" bad "$dbg"
  sec="${f[SECURE]:-?}";     [ "$sec" = 1 ] && add "ro.secure" ok "1" || add "ro.secure" bad "$sec"
  asec="${f[ADBSEC]:-?}";    [ "$asec" = 1 ] && add "ro.adb.secure" ok "1 (exige chave)" || add "ro.adb.secure" bad "$asec (ADB aberto)"
  tcp="${f[TCP]:-}";         { [ -z "$tcp" ] || [ "$tcp" = "-1" ]; } && add "ADB TCP (5555)" ok "desligado" || add "ADB TCP (5555)" warn "porta $tcp ligada"
  su="${f[SU]:-}"; mg="${f[MAGISK]:-}"; { [ -z "$su" ] && [ -z "$mg" ]; } && add "Root (su/Magisk)" ok "ausente" || add "Root (su/Magisk)" bad "presente"
  vb="${f[VBOOT]:-}";        case "$vb" in green) add "Verified Boot" ok "green";; yellow|orange) add "Verified Boot" warn "$vb";; red) add "Verified Boot" bad "red";; *) add "Verified Boot" na "${vb:-n/d}";; esac
  lk="${f[LOCK]:-}";         case "$lk" in 1|*locked*) add "Bootloader" ok "locked";; 0|*unlocked*) add "Bootloader" warn "unlocked";; *) add "Bootloader" na "${lk:-n/d}";; esac
  se="${f[SELINUX]:-}";      case "$se" in Enforcing) add "SELinux" ok "Enforcing";; Permissive) add "SELinux" bad "Permissive";; *) add "SELinux" na "${se:-n/d}";; esac
  cr="${f[CRYPTO]:-}";       case "$cr" in encrypted) add "Criptografia" ok "encrypted";; unencrypted) add "Criptografia" warn "unencrypted";; *) add "Criptografia" na "${cr:-n/d}";; esac
  pt="${f[PATCH]:-}"
  if [ -n "$pt" ]; then
    py="${pt%%-*}"; cy="$(date +%Y)"
    if [ -n "$py" ] && [ "$py" -ge "$((cy-1))" ] 2>/dev/null; then add "Security patch" ok "$pt"
    elif [ -n "$py" ] && [ "$py" -ge "$((cy-3))" ] 2>/dev/null; then add "Security patch" warn "$pt (atrasado)"
    else add "Security patch" bad "$pt (sem update ha anos)"; fi
  else add "Security patch" na "n/d"; fi
  bh="${f[BATTH]:-}"; case "$bh" in 2|Good|good) add "Bateria" ok "boa";; ""|0) add "Bateria" na "n/d";; *) add "Bateria" warn "health=$bh";; esac

  case "$worst" in ok) N_OK=$((N_OK+1)); vc="ok";; warn) N_WARN=$((N_WARN+1)); vc="warn";; bad) N_BAD=$((N_BAD+1)); vc="bad";; esac

  memt="${f[MEMT]:-0}"; upd="$(( ${f[UP]:-0} / 86400 ))"
  sub="$(echo "${f[MODEL]:-?} · Android ${f[REL]:-?} · ${f[PK3]:-?} apps de terceiros · storage ${f[DATA]:-n/d} · uptime ${upd}d" | esc)"
  CARDS="${CARDS}<div class='card ${vc}'><div class='hd'><div><b>$(echo "$s" | esc)</b><small>${sub}</small></div><span class='v ${vc}'>$(echo "$vc" | tr a-z A-Z)</span></div><div class='fp' title='fingerprint'>$(echo "${f[FP]:-}" | esc)</div><div class='its'>${items}</div></div>"
  unset f
done

pct(){ [ "$TOT" -gt 0 ] && echo $(( $1*100/TOT )) || echo 0; }

cat > "$HTML" <<HTMLHEAD
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Saude e Seguranca da Phone Farm - ${TS}</title>
<style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:1180px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 18px}
.kpis{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}
.kpi{border:1.5px solid var(--bd);border-radius:12px;padding:12px 16px;background:#fff;min-width:130px}
.kpi b{font-size:24px;display:block;color:var(--navy)}.kpi span{color:var(--muted);font-size:12px}
.kpi.ok b{color:var(--ok)}.kpi.warn b{color:var(--warn)}.kpi.bad b{color:var(--bad)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:14px}
.card{border:1.5px solid var(--bd);border-left-width:5px;border-radius:12px;background:#fff;padding:14px 16px}
.card.ok{border-left-color:var(--ok)}.card.warn{border-left-color:var(--warn)}.card.bad{border-left-color:var(--bad)}
.hd{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.hd b{font-family:ui-monospace,Menlo,monospace;font-size:13px;color:var(--navy)}
.hd small{display:block;color:var(--muted);font-size:11.5px;margin-top:3px;line-height:1.4}
.fp{font-family:ui-monospace,monospace;font-size:10px;color:#9db0c2;margin:8px 0;word-break:break-all}
.v{font-size:11px;font-weight:800;padding:3px 9px;border-radius:20px;white-space:nowrap}
.v.ok{background:#E7F6EC;color:var(--ok)}.v.warn{background:#FBEEDD;color:var(--warn)}.v.bad{background:#FDECEC;color:var(--bad)}
.its{display:grid;grid-template-columns:1fr 1fr;gap:5px 14px;margin-top:6px}
.it{display:flex;justify-content:space-between;align-items:center;gap:6px;font-size:12px;border-bottom:1px dotted #eef2f6;padding:3px 0}
.it .k{color:var(--muted)}
.b{font-weight:700;font-size:11px;padding:1px 7px;border-radius:6px;white-space:nowrap}
.b.ok{background:#E7F6EC;color:var(--ok)}.b.warn{background:#FBEEDD;color:var(--warn)}.b.bad{background:#FDECEC;color:var(--bad)}.b.na{background:#eef2f6;color:var(--muted)}
.refs{margin-top:26px;border:1.5px solid var(--bd);border-radius:12px;background:#fff;padding:18px 20px}
.refs h2{font-size:16px;color:var(--navy);margin:0 0 10px}
.refs table{width:100%;border-collapse:collapse;font-size:12.5px}
.refs td{padding:7px 8px;border-bottom:1px solid #eef2f6;vertical-align:top}
.refs td:first-child{font-weight:700;color:var(--navy);white-space:nowrap}
.refs a{color:#1C6FB5;text-decoration:none}.refs a:hover{text-decoration:underline}
.foot{color:var(--muted);font-size:11.5px;margin-top:18px}
</style></head><body><div class="wrap">
<h1>Relatorio de Saude e Seguranca da Phone Farm</h1>
<p class="sub">Gerado em ${TS} · ${TOT} placa(s) · retrato via ADB (sem root)</p>
<div class="kpis">
  <div class="kpi"><b>${TOT}</b><span>placas</span></div>
  <div class="kpi ok"><b>${N_OK}</b><span>OK ($(pct $N_OK)%)</span></div>
  <div class="kpi warn"><b>${N_WARN}</b><span>Atencao ($(pct $N_WARN)%)</span></div>
  <div class="kpi bad"><b>${N_BAD}</b><span>Critico ($(pct $N_BAD)%)</span></div>
</div>
<div class="grid">${CARDS}</div>
<div class="refs"><h2>Legenda e referencias oficiais</h2>
<table>
<tr><td>Build variant (user/userdebug/eng)</td><td>ROM oficial usa <code>user</code>. <code>userdebug/eng</code> = build de desenvolvimento/adulterada. <a href="https://source.android.com/docs/setup/build/building#choose-a-target">source.android.com/docs/setup/build/building</a></td></tr>
<tr><td>ro.adb.secure / ADB</td><td>Com <code>1</code>, o ADB exige autorizacao de chave RSA (nao e shell aberto). <a href="https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/README.md">ADB README (AOSP)</a></td></tr>
<tr><td>ADB over TCP (5555)</td><td>Superficie de rede. Foi o vetor dos worms ADB.Miner/Fbot. Deixe desligada fora de VLAN isolada. <a href="https://source.android.com/docs/setup/test/adb">source.android.com/docs/setup/test/adb</a></td></tr>
<tr><td>Verified Boot / dm-verity</td><td><code>green</code> = boot integro e verificado; <code>yellow/orange</code> = chave propria; <code>red</code> = corrompido. <a href="https://source.android.com/docs/security/features/verifiedboot">source.android.com/docs/security/features/verifiedboot</a></td></tr>
<tr><td>Bootloader (locked)</td><td>Bootloader destravado permite flash de imagens nao assinadas. <a href="https://source.android.com/docs/security/features/verifiedboot/device-state">Verified Boot device state</a></td></tr>
<tr><td>SELinux</td><td>Deve estar <code>Enforcing</code>. <code>Permissive</code> derruba o confinamento de processos. <a href="https://source.android.com/docs/security/features/selinux">source.android.com/docs/security/features/selinux</a></td></tr>
<tr><td>Criptografia</td><td>File-Based Encryption protege os dados em repouso. <a href="https://source.android.com/docs/security/features/encryption">source.android.com/docs/security/features/encryption</a></td></tr>
<tr><td>Security patch level</td><td>Data do ultimo boletim de seguranca aplicado. <a href="https://source.android.com/docs/security/bulletin">Android Security Bulletins</a> · <a href="https://security.samsungmobile.com/workScope.smsb">Samsung Mobile Security</a></td></tr>
<tr><td>Integridade em runtime</td><td>Para atestar o dispositivo em apps, use a Play Integrity API. <a href="https://developer.android.com/google/play/integrity">developer.android.com/google/play/integrity</a></td></tr>
<tr><td>Firmware malicioso pre-instalado</td><td>Familias como Triada/BadBox sobrevivem a factory reset. <a href="https://security.googleblog.com/2019/06/pha-family-highlights-triada.html">Google Security Blog: Triada</a></td></tr>
</table></div>
<p class="foot">Relatorio gerado por scripts/health-report.sh (toolkit dmoraesrs/adb). Retrato pontual, sem root; nao substitui analise forense de firmware.</p>
</div></body></html>
HTMLHEAD

echo ""
echo ">> pronto: $HTML"
echo ">> resumo: ${TOT} placas | OK=${N_OK} | Atencao=${N_WARN} | Critico=${N_BAD}"
echo ">> abra o HTML no navegador (no WSL: 'explorer.exe $HTML' ou 'wslview $HTML')"

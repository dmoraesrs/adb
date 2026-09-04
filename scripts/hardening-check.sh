#!/usr/bin/env bash
#
# hardening-check.sh - avalia o ENDURECIMENTO (hardening) do Android de cada placa contra um
# baseline de boas praticas (CIS Android Benchmark / AOSP Security), lendo as configuracoes
# do proprio SO via adb (settings/getprop/dumpsys) - sem root. Da um SCORE por placa e um
# relatorio HTML com cada item PASS/FAIL/WARN, o valor lido, o esperado e a referencia.
#
# Uso:
#   bash scripts/hardening-check.sh [DIR_SAIDA]      # ex: /mnt/c/Users/helpdesk
#
set -uo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BASE="${1:-.}"
OUT="${BASE%/}/hardening-${TS}"
HTML="${OUT}/report.html"
CSV="${OUT}/resumo.csv"
mkdir -p "$OUT"

gp(){ echo "$1" | tr -d '\r' | sed -e 's/^ *//; s/ *$//'; }
esc(){ sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

serials="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
[ -z "$serials" ] && { echo "Nenhuma placa em 'device'. Confira o adb server / ADB_SERVER_SOCKET."; exit 1; }

echo "serial,score,pass,warn,fail" > "$CSV"
TOT=0; CARDS=""

for s in $serials; do
  TOT=$((TOT+1)); echo "hardening $s ..." >&2
  raw="$(adb -s "$s" shell '
    echo "build_type|$(getprop ro.build.type)"
    echo "debuggable|$(getprop ro.debuggable)"
    echo "ro_secure|$(getprop ro.secure)"
    echo "adb_secure|$(getprop ro.adb.secure)"
    echo "selinux|$(getenforce 2>/dev/null)"
    echo "vbstate|$(getprop ro.boot.verifiedbootstate)"
    echo "bootloader|$(getprop ro.boot.flash.locked)"
    echo "crypto|$(getprop ro.crypto.state)"
    echo "patch|$(getprop ro.build.version.security_patch)"
    echo "oem_unlock|$(getprop sys.oem_unlock_allowed)"
    echo "su|$(ls /sbin/su /system/xbin/su /system/bin/su 2>/dev/null | head -1)"
    echo "adb_enabled|$(settings get global adb_enabled 2>/dev/null)"
    echo "dev_settings|$(settings get global development_settings_enabled 2>/dev/null)"
    echo "unknown_src|$(settings get secure install_non_market_apps 2>/dev/null)$(settings get global install_non_market_apps 2>/dev/null)"
    echo "verify_apps|$(settings get global package_verifier_enable 2>/dev/null)"
    echo "show_pwd|$(settings get system show_password 2>/dev/null)"
    echo "adb_wifi|$(settings get global adb_wifi_enabled 2>/dev/null)"
    echo "auto_time|$(settings get global auto_time 2>/dev/null)"
    echo "accessibility|$(settings get secure enabled_accessibility_services 2>/dev/null)"
    echo "admins|$(dumpsys device_policy 2>/dev/null | grep -c "admin=")"
  ' 2>/dev/null)"

  declare -A v=()
  while IFS='|' read -r k val; do [ -n "$k" ] && v[$k]="$(gp "$val")"; done <<< "$raw"

  ROWS=""; P=0; W=0; F=0
  # chk LABEL VALOR REGRA SEVERIDADE(high|med) REF
  chk(){
    local label="$1" val="$2" rule="$3" sev="$4" ref="$5" st exp="$3"
    val="${val:-n/d}"; { [ "$val" = "null" ] || [ -z "$val" ]; } && val="n/d"
    case "$rule" in
      "="*)   [ "$val" = "${rule#=}" ] && st=pass || st=fail; exp="= ${rule#=}";;
      "!"*)   [ "$val" != "${rule#!}" ] && st=pass || st=fail; exp="nao ${rule#!}";;
      empty)  { [ "$val" = "n/d" ] || [ "$val" = "0" ]; } && st=pass || st=fail; exp="vazio";;
      patch)  local py="${val%%-*}" cy; cy="$(date +%Y)"; if [ "${py:-0}" -ge "$((cy-1))" ] 2>/dev/null; then st=pass; elif [ "${py:-0}" -ge "$((cy-3))" ] 2>/dev/null; then st=warn; else st=fail; fi; exp="< 1 ano";;
      *) st=na; exp="$rule";;
    esac
    # severidade med rebaixa fail -> warn (esperado nao seguir no contexto farm)
    [ "$st" = fail ] && [ "$sev" = med ] && st=warn
    case "$st" in pass) P=$((P+1)); cls=ok; tg=PASS;; warn) W=$((W+1)); cls=warn; tg=WARN;; fail) F=$((F+1)); cls=bad; tg=FAIL;; *) cls=na; tg="N/D";; esac
    ROWS="${ROWS}<tr class='${cls}'><td>$(echo "$label"|esc)</td><td class='mono'>$(echo "$val"|esc)</td><td class='mono'>$(echo "$exp"|esc)</td><td><span class='b ${cls}'>${tg}</span></td><td class='ref'>$(echo "$ref"|esc)</td></tr>"
  }

  chk "Build variant = user"            "${v[build_type]:-}"   "=user"      high "AOSP build variants (release-keys/user)"
  chk "ro.debuggable = 0"               "${v[debuggable]:-}"   "=0"         high "AOSP: builds nao-debuggable em producao"
  chk "ro.secure = 1"                   "${v[ro_secure]:-}"    "=1"         high "AOSP hardening"
  chk "ro.adb.secure = 1 (exige chave)" "${v[adb_secure]:-}"   "=1"         high "ADB authorization (chave RSA)"
  chk "SELinux Enforcing"               "${v[selinux]:-}"      "=Enforcing" high "source.android.com/.../selinux"
  chk "Verified Boot = green"           "${v[vbstate]:-}"      "=green"     high "source.android.com/.../verifiedboot"
  chk "Bootloader locked"               "${v[bootloader]:-}"   "=1"         high "Verified Boot device state (locked)"
  chk "Storage criptografado"           "${v[crypto]:-}"       "=encrypted" high "source.android.com/.../encryption"
  chk "OEM unlock desabilitado"         "${v[oem_unlock]:-}"   "=0"         high "impede flash de imagens nao assinadas"
  chk "Security patch recente"          "${v[patch]:-}"        patch        high "Android Security Bulletins"
  chk "Sem root (su/Magisk)"            "${v[su]:-}"           empty        high "root = superficie total"
  chk "Instalar de fontes desconhecidas OFF" "${v[unknown_src]:-}" "=0"     high "CIS: Unknown sources disabled"
  chk "Play Protect / verify apps ON"   "${v[verify_apps]:-}"  "=1"         high "CIS: Verify apps enabled"
  chk "Mostrar senhas OFF"              "${v[show_pwd]:-}"     "=0"         med  "CIS: Show passwords disabled"
  chk "ADB over Wi-Fi OFF"              "${v[adb_wifi]:-}"     "=0"         high "adb pela rede = superficie"
  chk "Sem servico de acessibilidade"  "${v[accessibility]:-}" empty       high "accessibility = vetor de automacao/backdoor"
  chk "Sem device admin extra"          "${v[admins]:-0}"      "=0"         med  "app com admin controla o device"
  chk "USB debugging OFF"               "${v[adb_enabled]:-}"  "=0"         med  "CIS: USB debugging disabled (farm usa, por isso WARN)"
  chk "Developer options OFF"           "${v[dev_settings]:-}" "=0"         med  "CIS: Developer options disabled"
  chk "NTP (auto time) ON"              "${v[auto_time]:-}"    "=1"         med  "hora confiavel p/ logs/certificados"

  TC=$((P+W+F)); SC=0; [ "$TC" -gt 0 ] && SC=$(( P*100/TC ))
  scls=bad; [ "$SC" -ge 80 ] && scls=ok || { [ "$SC" -ge 50 ] && scls=warn; }
  CARDS="${CARDS}<div class='card ${scls}'><div class='hd'><b>$(echo "$s"|esc)</b><span class='score ${scls}'>${SC}<small>/100</small></span></div><div class='sum'>${P} PASS · ${W} WARN · ${F} FAIL</div><table class='ck'><thead><tr><th>Item</th><th>Lido</th><th>Esperado</th><th>Status</th><th>Referencia</th></tr></thead><tbody>${ROWS}</tbody></table></div>"
  echo "${s},${SC},${P},${W},${F}" >> "$CSV"
  unset v
done

cat > "$HTML" <<HH
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hardening Check - ${TS}</title><style>
:root{--ok:#1B6E3C;--warn:#8A5A08;--bad:#B02020;--navy:#12263a;--bd:#e3e9f0;--muted:#5b6b7c}
*{box-sizing:border-box}body{margin:0;font:13.5px/1.5 -apple-system,Segoe UI,system-ui,sans-serif;color:#1c2b3a;background:#f5f8fb}
.wrap{max-width:1120px;margin:0 auto;padding:24px}h1{font-size:22px;margin:0 0 4px;color:var(--navy)}.sub{color:var(--muted);margin:0 0 18px}
.card{border:1.5px solid var(--bd);border-left-width:5px;border-radius:12px;background:#fff;padding:14px 16px;margin-bottom:14px}
.card.ok{border-left-color:var(--ok)}.card.warn{border-left-color:var(--warn)}.card.bad{border-left-color:var(--bad)}
.hd{display:flex;justify-content:space-between;align-items:center}.hd b{font-family:ui-monospace,Menlo,monospace;font-size:14px;color:var(--navy)}
.score{font-size:26px;font-weight:800}.score small{font-size:12px;color:var(--muted);font-weight:600}.score.ok{color:var(--ok)}.score.warn{color:var(--warn)}.score.bad{color:var(--bad)}
.sum{color:var(--muted);font-size:12px;margin:2px 0 10px}
.ck{width:100%;border-collapse:collapse;font-size:12px}.ck th{text-align:left;color:var(--muted);font-weight:700;font-size:10.5px;text-transform:uppercase;letter-spacing:.3px;padding:4px 8px;border-bottom:1.5px solid var(--bd)}
.ck td{padding:5px 8px;border-bottom:1px solid #eef2f6;vertical-align:top}.ck .mono{font-family:ui-monospace,monospace;font-size:11.5px}.ck .ref{color:var(--muted);font-size:11px}
tr.bad td{background:#fdf2f2}tr.warn td{background:#fdf8ee}
.b{font-weight:800;font-size:10.5px;padding:1px 7px;border-radius:6px}.b.ok{background:#E7F6EC;color:var(--ok)}.b.warn{background:#FBEEDD;color:var(--warn)}.b.bad{background:#FDECEC;color:var(--bad)}.b.na{background:#eef2f6;color:var(--muted)}
.foot{color:var(--muted);font-size:11.5px;margin-top:6px}.foot a{color:#1C6FB5}
</style></head><body><div class="wrap">
<h1>Hardening Check - Phone Farm</h1><p class="sub">${TS} · ${TOT} placa(s) · baseline CIS Android / AOSP Security · leitura do SO via adb</p>
${CARDS}
<p class="foot">Baseline: <a href="https://www.cisecurity.org/benchmark/google_android">CIS Google Android Benchmark</a> · <a href="https://source.android.com/docs/security">AOSP Security</a> · <a href="https://source.android.com/docs/security/bulletin">Security Bulletins</a>. Itens WARN = boas praticas que a operacao de farm normalmente afrouxa (ex: USB debugging). Planilha em resumo.csv. Retrato pontual, sem root.</p>
</div></body></html>
HH

echo ""
echo ">> relatorio: $HTML"
echo ">> planilha:  $CSV"
echo ">> ${TOT} placa(s) avaliada(s)"

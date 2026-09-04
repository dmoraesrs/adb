#!/usr/bin/env bash
#
# baseline-farm.sh
# Tira o retrato de segurança de todas as placas Android da phone farm ANTES
# de confiar em qualquer uma. Para cada placa coleta: serial, modelo, ROM,
# se o ADB over TCP (5555) já vem ligado, se tem root, e se algum pacote bate
# com nome de firmware malicioso conhecido (BadBox/Triada/Adups etc).
#
# Uso:
#   bash scripts/baseline-farm.sh
#
# Saída: farm-baseline-<timestamp>/baseline.csv  (+ detalhe por placa)
#
set -uo pipefail

OUT="farm-baseline-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/detalhe"
CSV="$OUT/baseline.csv"
echo "serial,modelo,marca,android,patch,build_type,debuggable,ro_secure,ro_adb_secure,adb_tcp_port,root,gms,pkgs_terceiros,suspeitos" > "$CSV"

# Indicadores conhecidos de firmware malicioso / apps de farm suspeitos.
# Ajuste conforme for descobrindo pacotes novos.
BAD='adups|fota\.|com\.rock|triada|hummingbird|systemcore|com\.system\.service|blwmb|com\.gm\.'

mapfile -t SERIALS < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
echo ">> ${#SERIALS[@]} placas online"
if [ "${#SERIALS[@]}" -eq 0 ]; then
    echo "!! Nenhuma placa 'device'. Confira: 'adb devices -l', autorizacao da chave RSA," \
         "grupo plugdev/udev (setup-linux.sh), fonte do chassi ligada e cabo USB."
    exit 1
fi

for s in "${SERIALS[@]}"; do
    g(){ adb -s "$s" shell getprop "$1" 2>/dev/null | tr -d '\r'; }

    modelo=$(g ro.product.model);          marca=$(g ro.product.manufacturer)
    android=$(g ro.build.version.release); patch=$(g ro.build.version.security_patch)
    btype=$(g ro.build.type);              dbg=$(g ro.debuggable)
    rosec=$(g ro.secure);                  adbsec=$(g ro.adb.secure)
    tcp=$(g service.adb.tcp.port); [ -z "$tcp" ] && tcp=$(g persist.adb.tcp.port)

    # root: su respondendo uid=0, ou binário su presente
    if adb -s "$s" shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
        root=SIM
    elif adb -s "$s" shell 'ls /system/xbin/su /system/bin/su 2>/dev/null' | grep -q su; then
        root=BIN
    else
        root=nao
    fi

    gms=$(adb -s "$s" shell pm list packages 2>/dev/null | grep -c 'com.google.android.gms')
    adb -s "$s" shell pm list packages 2>/dev/null | tr -d '\r' | sed 's/package://' | sort \
        > "$OUT/detalhe/$s.pkgs.txt"
    pkgs3=$(adb -s "$s" shell pm list packages -3 2>/dev/null | grep -c .)
    suspeitos=$(grep -Ei "$BAD" "$OUT/detalhe/$s.pkgs.txt" | paste -sd'|' -)

    # conexões de rede da placa (best-effort; netstat do toybox é limitado)
    adb -s "$s" shell 'netstat -tunp 2>/dev/null || cat /proc/net/tcp' \
        > "$OUT/detalhe/$s.net.txt" 2>/dev/null

    echo "$s,$modelo,$marca,$android,$patch,$btype,$dbg,$rosec,$adbsec,${tcp:-},$root,$gms,$pkgs3,\"${suspeitos:-}\"" >> "$CSV"
    printf '  [%s] %s and%s tcp=%s root=%s suspeitos=%s\n' \
        "$s" "${modelo:-?}" "${android:-?}" "${tcp:-none}" "$root" "${suspeitos:-nenhum}"
done

echo ""
echo ">> pronto: $CSV"
echo ">> detalhe por placa (pacotes + rede): $OUT/detalhe/"
echo ""
echo "Bandeiras vermelhas para revisar no CSV:"
echo "  adb_tcp_port=5555     -> a 5555 já vem ligada de fábrica"
echo "  ro_adb_secure=0       -> ADB aberto sem autorização de chave"
echo "  build_type=userdebug  -> ROM de desenvolvimento/adulterada"
echo "  root=SIM/BIN          -> root pré-integrado"
echo "  suspeitos preenchido  -> puxe o APK e mande pro MobSF/VirusTotal"

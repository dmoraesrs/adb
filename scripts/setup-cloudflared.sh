#!/usr/bin/env bash
#
# setup-cloudflared.sh - instala, configura e INICIA o Cloudflare Tunnel na VM Ubuntu para
# acesso SSH remoto a phone farm (atravessa CGNAT, sem VM/IP publico e sem abrir porta no roteador).
#
# O que ele faz, de ponta a ponta:
#   1) instala o cloudflared e o openssh-server
#   2) autentica na Cloudflare (login no navegador) - so na primeira vez
#   3) cria o tunel e o config.yml (hostname -> ssh://localhost:22)
#   4) cria o registro DNS (CNAME) automaticamente via 'cloudflared tunnel route dns'
#   5) sobe como servico systemd (reconecta sozinho no boot)  <- ja deixa a ferramenta rodando
#
# Uso:
#   sudo bash scripts/setup-cloudflared.sh <hostname> [nome-do-tunel]
#   ex: sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br
#
#   NO_DNS=1 sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br   # nao cria o DNS (faco a parte)
#
set -uo pipefail

HOST="${1:-}"; NAME="${2:-farm-ssh}"
[ -z "$HOST" ] && { echo "uso: sudo bash scripts/setup-cloudflared.sh <hostname> [nome-do-tunel]"; echo "  ex: sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)."; exit 1; }
CFDIR="/root/.cloudflared"
NO_DNS="${NO_DNS:-0}"

echo "==> instalando cloudflared + openssh-server"
if ! command -v cloudflared >/dev/null 2>&1; then
  arch="$(uname -m)"; case "$arch" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; armv7l) A=arm;; *) A=amd64;; esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A}" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
echo "    $(cloudflared --version 2>/dev/null | head -1)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends openssh-server ca-certificates >/dev/null 2>&1 || true
ssh-keygen -A 2>/dev/null || true
systemctl enable --now ssh 2>/dev/null || service ssh start 2>/dev/null || true

# 1) login (interativo) se ainda nao autenticou nesta VM
if [ ! -f "${CFDIR}/cert.pem" ]; then
  echo ""
  echo ">> AUTENTICACAO: vai aparecer uma URL. Abra no navegador, faca login na Cloudflare"
  echo "   e ESCOLHA a zona do dominio de '${HOST}'. Depois volte aqui."
  cloudflared tunnel login
fi

# 2) cria o tunel se ainda nao existe
if ! cloudflared tunnel list 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$NAME"; then
  cloudflared tunnel create "$NAME"
fi
TID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$NAME" 'NR>1 && $2==n{print $1; exit}')"
[ -z "$TID" ] && { echo "[!] nao obtive o TUNNEL_ID de '${NAME}'. Rode: cloudflared tunnel list"; exit 1; }
CREDS="${CFDIR}/${TID}.json"
[ -f "$CREDS" ] || CREDS="$(ls ${CFDIR}/*.json 2>/dev/null | head -1)"

# 3) config apontando o hostname -> ssh local da VM
echo "==> gravando /etc/cloudflared/config.yml"
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TID}
credentials-file: ${CREDS}
ingress:
  - hostname: ${HOST}
    service: ssh://localhost:22
  - service: http_status:404
EOF

# 4) DNS (CNAME ${HOST} -> ${TID}.cfargotunnel.com) pelo proprio cloudflared
if [ "$NO_DNS" = 1 ]; then
  echo "==> DNS pulado (NO_DNS=1). Registro a criar: CNAME ${HOST} -> ${TID}.cfargotunnel.com"
else
  echo "==> criando o registro DNS (${HOST})"
  cloudflared tunnel route dns "$NAME" "$HOST" 2>&1 | sed 's/^/    /' \
    || echo "    [!] nao criei o DNS (a zona pode estar noutra conta). Crie o CNAME manualmente: ${HOST} -> ${TID}.cfargotunnel.com"
fi

# 5) servico (reconecta no boot) - ja inicia a ferramenta
echo "==> instalando e iniciando o servico do cloudflared"
cloudflared service install 2>/dev/null || true
systemctl enable --now cloudflared 2>/dev/null || echo "[!] sem systemd; rode manual em background: cloudflared tunnel run ${NAME}"

cat <<FIM

======================================================================
 cloudflared OK e RODANDO. Tunel: ${NAME}
   TUNNEL_ID:    ${TID}
   hostname SSH: ${HOST}
   CNAME target: ${TID}.cfargotunnel.com
======================================================================

FALTA (1 passo manual, uma vez): proteger no Zero Trust com o SEU e-mail
  one.dash.cloudflare.com -> Access -> Applications -> Add (Self-hosted)
  Application domain: ${HOST}   |   Policy: Emails = seu@email  (Action: Allow)
  (sem isso o hostname fica publico; com Access, so voce autentica)

Testar (da sua maquina, com cloudflared instalado):
  ssh -o ProxyCommand="cloudflared access ssh --hostname %h" USUARIO@${HOST}

Operacao do servico:
  systemctl status cloudflared      # ver estado
  systemctl restart cloudflared     # reiniciar
  journalctl -u cloudflared -f      # logs ao vivo
FIM

#!/usr/bin/env bash
#
# setup-cloudflared.sh - instala e configura o Cloudflare Tunnel no WSL para acesso SSH
# remoto a phone farm (atravessa CGNAT, sem VM/IP publico e sem abrir porta).
#
# O que ele faz: instala o cloudflared, sobe o sshd do WSL, autentica (login), cria o tunel,
# gera o config.yml apontando o hostname -> ssh://localhost:22 e sobe como servico.
# A criacao do REGISTRO DNS e feita a parte (o script imprime o CNAME target).
#
# Uso:
#   sudo bash scripts/setup-cloudflared.sh <hostname> [nome-do-tunel]
#   ex: sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br
#
set -uo pipefail

HOST="${1:-}"; NAME="${2:-farm-ssh}"
[ -z "$HOST" ] && { echo "uso: sudo bash scripts/setup-cloudflared.sh <hostname> [nome-do-tunel]"; echo "  ex: sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)."; exit 1; }
CFDIR="/root/.cloudflared"

echo "==> instalando cloudflared + openssh-server"
if ! command -v cloudflared >/dev/null 2>&1; then
  arch="$(uname -m)"; case "$arch" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) A=amd64;; esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A}" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
echo "    $(cloudflared --version 2>/dev/null | head -1)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y --no-install-recommends openssh-server ca-certificates
ssh-keygen -A 2>/dev/null || true
service ssh start 2>/dev/null || systemctl start ssh 2>/dev/null || true

# 1) login (interativo) se ainda nao autenticou nesta maquina
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

# 3) config apontando o hostname -> ssh local
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

# 4) servico (reconecta no boot)
echo "==> instalando o servico do cloudflared"
cloudflared service install 2>/dev/null || true
systemctl enable --now cloudflared 2>/dev/null || echo "[!] sem systemd ativo; rode manual: cloudflared tunnel run ${NAME}"

cat <<FIM

======================================================================
 cloudflared OK. Tunel: ${NAME}
   TUNNEL_ID:    ${TID}
   CNAME target: ${TID}.cfargotunnel.com
   hostname SSH: ${HOST}
======================================================================

FALTA (feito a parte):
  1) DNS:    CNAME ${HOST}  ->  ${TID}.cfargotunnel.com   (proxied)  <-- me passe o TUNNEL_ID que eu crio aqui via API
  2) Access: protegja ${HOST} no Zero Trust com policy do seu e-mail (one.dash.cloudflare.com -> Access -> Applications)

Testar (da sua maquina, com cloudflared instalado):
  ssh -o ProxyCommand="cloudflared access ssh --hostname %h" root@${HOST}

Status local:  systemctl status cloudflared   |   journalctl -u cloudflared -n 20
FIM

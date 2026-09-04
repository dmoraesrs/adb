#!/usr/bin/env bash
#
# setup-frpc.sh - instala e configura o FRP client (frpc) no WSL para acessar a phone farm
# remotamente atraves de um bastion com IP publico. Publica DOIS servicos:
#   - SSH do WSL      (localhost:22)        -> <bastion>:<ssh-port>
#   - adb server      (Windows host:5037)   -> <bastion>:<adb-port>
#
# O adb server roda no Windows (as placas estao no USB dele); o WSL alcanca o Windows pelo
# gateway padrao, entao o frpc faz o proxy do 5037 do Windows.
#
# O acesso e restrito ao SEU IP pelo FIREWALL DO BASTION (ver bloco impresso no final e
# frp/BASTION.md). O token do FRP autentica o tunel; o firewall fecha as portas ao mundo.
#
# Uso:
#   sudo bash scripts/setup-frpc.sh --server <IP_BASTION> --token <SEGREDO> \
#        [--ssh-port 6022] [--adb-port 6037] [--allow-ip <SEU_IP_PUBLICO>]
#
set -euo pipefail

SERVER=""; TOKEN=""; SSH_PORT="6022"; ADB_PORT="6037"; ALLOW_IP="SEU_IP_PUBLICO"; SERVER_PORT="7000"
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    --adb-port) ADB_PORT="$2"; shift 2;;
    --allow-ip) ALLOW_IP="$2"; shift 2;;
    --server-port) SERVER_PORT="$2"; shift 2;;
    *) echo "flag desconhecida: $1"; exit 1;;
  esac
done
[ -z "$SERVER" ] || [ -z "$TOKEN" ] && {
  echo "uso: sudo bash scripts/setup-frpc.sh --server <IP_BASTION> --token <SEGREDO> [--ssh-port 6022] [--adb-port 6037] [--allow-ip <SEU_IP>]"
  exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
echo "==> dependencias (openssh-server, wget, tar)"
apt-get update -y
apt-get install -y --no-install-recommends openssh-server wget tar ca-certificates
# sshd do WSL de pe (o frpc publica a porta 22 local)
ssh-keygen -A 2>/dev/null || true
service ssh start 2>/dev/null || systemctl start ssh 2>/dev/null || true

echo "==> baixando o FRP"
arch="$(uname -m)"; case "$arch" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) A=amd64;; esac
VER="${FRP_VERSION:-$(wget -qO- https://api.github.com/repos/fatedier/frp/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)}"
[ -z "$VER" ] && VER="0.61.1"   # fallback fixo se a API falhar
tmp="$(mktemp -d)"
wget -q "https://github.com/fatedier/frp/releases/download/v${VER}/frp_${VER}_linux_${A}.tar.gz" -O "$tmp/frp.tgz"
tar xzf "$tmp/frp.tgz" -C "$tmp"
install -m0755 "$tmp/frp_${VER}_linux_${A}/frpc" /usr/local/bin/frpc
rm -rf "$tmp"
echo "    frpc $(frpc --version 2>/dev/null || echo v$VER)"

# IP do Windows (host) visto pelo WSL - onde roda o adb server
WIN_IP="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
[ -z "$WIN_IP" ] && WIN_IP="127.0.0.1"

echo "==> gerando /etc/frp/frpc.toml"
mkdir -p /etc/frp
cat > /etc/frp/frpc.toml <<EOF
serverAddr = "${SERVER}"
serverPort = ${SERVER_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
loginFailExit = false

# SSH do WSL -> <bastion>:${SSH_PORT}
[[proxies]]
name = "farm-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${SSH_PORT}

# adb server (roda no Windows host ${WIN_IP}:5037) -> <bastion>:${ADB_PORT}
[[proxies]]
name = "farm-adb"
type = "tcp"
localIP = "${WIN_IP}"
localPort = 5037
remotePort = ${ADB_PORT}
EOF
chmod 600 /etc/frp/frpc.toml

echo "==> servico systemd (frpc), reconecta no boot"
cat > /etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=FRP client (phone farm)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=8
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now frpc 2>/dev/null || { echo "[!] systemd indisponivel; rode manual: frpc -c /etc/frp/frpc.toml &"; }

cat <<FIM

======================================================================
 frpc instalado e conectando em ${SERVER}:${SERVER_PORT}
 publica:  SSH  -> ${SERVER}:${SSH_PORT}    |  adb -> ${SERVER}:${ADB_PORT}
======================================================================

NO BASTION (servidor com IP publico) faca UMA vez:

 1) frps.toml:
      bindPort = ${SERVER_PORT}
      auth.token = "${TOKEN}"

 2) suba o frps (baixe o mesmo frp; use um systemd igual ao frpc).

 3) FECHE as portas so para o SEU IP (aqui via ufw; ajuste ${ALLOW_IP}):
      ufw allow from ${ALLOW_IP} to any port ${SSH_PORT} proto tcp
      ufw allow from ${ALLOW_IP} to any port ${ADB_PORT} proto tcp
      ufw deny ${SSH_PORT}/tcp
      ufw deny ${ADB_PORT}/tcp
    (a bindPort ${SERVER_PORT} do frps fica protegida pelo token)

DA SUA MAQUINA (${ALLOW_IP}) voce acessa:

   ssh -p ${SSH_PORT} <user_do_wsl>@${SERVER}                 # entra no WSL
   ADB_SERVER_SOCKET=tcp:${SERVER}:${ADB_PORT} adb devices -l # ve os telefones
   ADB_SERVER_SOCKET=tcp:${SERVER}:${ADB_PORT} scrcpy -s <serial>   # espelha a tela

Detalhes do bastion em frp/BASTION.md.
FIM

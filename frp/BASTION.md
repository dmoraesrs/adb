# FRP - servidor (bastion)

O bastion e um servidor com **IP publico** (uma VM sua: VPS, Azure, etc). Ele roda o
`frps`, recebe a conexao de saida do `frpc` (que esta no WSL, atras do CGNAT) e **publica**
as portas do SSH e do adb. O acesso a essas portas e **fechado ao seu IP** pelo firewall.

```
[sua maquina] --(so seu IP)--> [BASTION frps] <--frpc-- [WSL] --> sshd 22 / adb 5037 (Windows)
```

## 1. Instalar o frps

```bash
VER=0.61.1   # use a mesma versao do frpc
A=amd64      # ou arm64
wget -q "https://github.com/fatedier/frp/releases/download/v${VER}/frp_${VER}_linux_${A}.tar.gz" -O /tmp/frp.tgz
tar xzf /tmp/frp.tgz -C /tmp
sudo install -m0755 /tmp/frp_${VER}_linux_${A}/frps /usr/local/bin/frps
sudo mkdir -p /etc/frp
```

## 2. `frps.toml`

```toml
bindPort = 7000
auth.method = "token"
auth.token = "USE_O_MESMO_TOKEN_DO_FRPC"

# opcional: so aceita as portas remotas que voce definiu (defesa em profundidade)
allowPorts = [
  { start = 6000, end = 6100 },
]

# opcional: dashboard (feche tambem no firewall!)
# webServer.addr = "127.0.0.1"
# webServer.port = 7500
# webServer.user = "admin"
# webServer.password = "trocar"
```

Salve em `/etc/frp/frps.toml`.

## 3. Serviço systemd

```bash
sudo tee /etc/systemd/system/frps.service >/dev/null <<'EOF'
[Unit]
Description=FRP server
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=8
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now frps
```

## 4. Firewall: fechar tudo, liberar só o SEU IP

Substitua `SEU_IP` pelo IP publico da sua maquina (veja em https://ifconfig.me).
As portas remotas aqui sao as do `setup-frpc.sh` (default 6022 = SSH, 6037 = adb).

**ufw:**
```bash
sudo ufw allow from SEU_IP to any port 6022 proto tcp   # SSH do WSL
sudo ufw allow from SEU_IP to any port 6037 proto tcp   # adb dos telefones
sudo ufw deny 6022/tcp
sudo ufw deny 6037/tcp
# a bindPort 7000 do frps: o frpc precisa alcancar. Protegida pelo token;
# se o IP de saida do WSL for fixo, restrinja tambem. Se for CGNAT (variavel), deixe:
sudo ufw allow 7000/tcp
```

**iptables (alternativa):**
```bash
sudo iptables -A INPUT -p tcp -s SEU_IP --dport 6022 -j ACCEPT
sudo iptables -A INPUT -p tcp -s SEU_IP --dport 6037 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 6022 -j DROP
sudo iptables -A INPUT -p tcp --dport 6037 -j DROP
```

> Se o bastion for uma VM de nuvem, faca o MESMO no **Security Group / NSG**: origem =
> `SEU_IP/32` nas portas 6022 e 6037. Nunca `0.0.0.0/0` nessas portas.

## 5. Acessar (da sua maquina)

```bash
ssh -p 6022 <user_do_wsl>@IP_DO_BASTION                      # entra no WSL da farm
ADB_SERVER_SOCKET=tcp:IP_DO_BASTION:6037 adb devices -l      # lista os telefones
ADB_SERVER_SOCKET=tcp:IP_DO_BASTION:6037 scrcpy -s <serial>  # espelha a tela
```

## Segurança

- **Token forte** no `auth.token` (compartilhado frps/frpc).
- Firewall fechado ao seu IP nas portas 6022/6037 (passos acima). O adb sem isso = shell
  na sua rede de telefones exposto na internet.
- No `sshd` do WSL, prefira **login por chave** (desabilite senha) e mantenha o chassi em
  **VLAN isolada** (ver README principal).

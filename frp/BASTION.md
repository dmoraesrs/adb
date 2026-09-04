# FRP - servidor (bastion)

O bastion e um servidor com **IP publico** (uma VM sua: VPS, Azure, etc). Ele roda o
`frps`, recebe a conexao de saida do `frpc` (que esta na VM Ubuntu da farm, atras do CGNAT)
e **publica** a porta do SSH. O acesso a essa porta e **fechado ao seu IP** pelo firewall.

```
[sua maquina] --(so seu IP)--> [BASTION frps] <--frpc-- [VM Ubuntu] --> sshd 22 (adb local)
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
A porta remota aqui e a do `setup-frpc.sh` (default 6022 = SSH).

**ufw:**
```bash
sudo ufw allow from SEU_IP to any port 6022 proto tcp   # SSH da VM
sudo ufw deny 6022/tcp
# a bindPort 7000 do frps: o frpc precisa alcancar. Protegida pelo token;
# se o IP de saida da VM for fixo, restrinja tambem. Se for CGNAT (variavel), deixe:
sudo ufw allow 7000/tcp
```

**iptables (alternativa):**
```bash
sudo iptables -A INPUT -p tcp -s SEU_IP --dport 6022 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 6022 -j DROP
```

> Se o bastion for uma VM de nuvem, faca o MESMO no **Security Group / NSG**: origem =
> `SEU_IP/32` na porta 6022. Nunca `0.0.0.0/0` nessa porta.

## 5. Acessar (da sua maquina)

```bash
ssh -p 6022 <user_da_vm>@IP_DO_BASTION      # entra na VM da farm; o adb ja e local la
```

Uma vez dentro da VM por SSH, rode `adb devices -l`, `scrcpy -s <serial>`, os scripts de
scan, etc. As placas estao no USB da propria VM.

## Segurança

- **Token forte** no `auth.token` (compartilhado frps/frpc).
- Firewall fechado ao seu IP na porta 6022 (passos acima).
- No `sshd` da VM, prefira **login por chave** (desabilite senha) e mantenha o chassi em
  **VLAN isolada** (ver README principal).

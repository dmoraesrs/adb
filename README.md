# adb - estação Ubuntu para phone farm

Deixa uma **VM Ubuntu/Linux 100% pronta** para plugar um chassi de phone farm
(várias placas Android num hub USB) e falar com as placas por **ADB** direto pelo
USB. Sem Windows, sem WSL: o adb conversa com o USB da própria máquina.

O foco aqui é **operação segura**: antes de confiar em qualquer placa, o toolkit
tira um retrato de segurança de cada uma (ROM, root, estado da porta 5555,
pacotes suspeitos, antivírus nos APKs, portas expostas), porque hardware genérico
de "group control" costuma vir com ADB aberto, root pré-integrado e, em muitos
casos, firmware malicioso de fábrica (famílias BadBox/Triada/Adups) que
**sobrevive a factory reset**.

## O que o setup instala

Na **VM Ubuntu/Debian** (`setup-linux.sh`):

- `platform-tools` do Google (adb/fastboot), versão oficial mais recente
- udev rules do Android + grupo `plugdev` (enxergar as placas por USB sem root)
- `nmap`, `clamav`, `jq`, `scrcpy`, `curl`/`wget`/`unzip`

## Como usar

1. Clone o repo na VM e rode o setup (instala tudo):

   ```bash
   git clone https://github.com/dmoraesrs/adb.git
   cd adb
   sudo bash scripts/setup-linux.sh
   ```

   Depois **relogue a sessão** (ou `newgrp plugdev`) para o acesso USB valer sem `sudo`.

2. Ligue a **fonte do chassi**, plugue o **cabo USB** e liste as placas:

   ```bash
   adb devices -l          # deve listar todas as placas
   ```

   Se aparecer `unauthorized`, autorize a chave RSA na placa. Se `no permissions`,
   confira o grupo `plugdev` e as udev rules (rode o `setup-linux.sh` de novo e relogue).

3. Rode a auditoria completa num comando:

   ```bash
   sudo bash scripts/farm-scan.sh ~/farm-audit
   ```

   Instala o que faltar, **valida** as placas, passa **antivírus** nos APKs e
   **escaneia as portas** de cada telefone, gerando `~/farm-audit/farm-scan-*/index.html`.

## Auditoria de segurança

| Script | O que faz |
|--------|-----------|
| `farm-scan.sh` | **Tudo num comando**: instala + valida + antivírus + portas -> `index.html` consolidado |
| `validate-farm.sh` | Integridade + root/Magisk + apps de terceiros + device admins -> veredito por placa |
| `scan-apks.sh` | Antivírus off-device: puxa os APKs e escaneia (ClamAV; +VirusTotal com `VT_API_KEY`) |
| `port-scan.sh` | Portas em LISTEN + 5555/adb-tcp + nmap externo -> superfície de rede exposta |
| `hardening-check.sh` | Config de segurança do Android vs baseline CIS/AOSP -> score por placa |
| `health-report.sh` | Saúde/identidade: Verified Boot, SELinux, patch, bateria/storage |
| `check-all.sh` | Auditoria estendida (saúde + validação + hardening + antivírus + rede) |
| `net-watch.sh` | Monitora conexões das placas e sinaliza destinos suspeitos (C2/backdoor) |
| `baseline-farm.sh` | Retrato rápido de segurança das placas em CSV |

### Bandeiras vermelhas

| Sinal | Risco |
|-------|-------|
| porta `5555` em LISTEN | shell root sem senha na rede (vetor dos worms ADB.Miner/Fbot) |
| `ro_adb_secure=0` / `ro_secure=0` | ADB aberto sem autorização de chave |
| `build_type=userdebug`/`eng` ou `debuggable=1` | ROM de desenvolvimento/adulterada |
| `root=SIM` / `su` presente / Magisk | root pré-integrado, superfície total |
| SELinux `Permissive` | proteção do kernel desligada |
| bootloader unlocked / Verified Boot `orange` | firmware pode ter sido trocado |
| pacote suspeito / detecção ClamAV | app com nome de firmware malicioso conhecido |
| patch antigo | sem atualização de segurança há anos |

## Segurança (leia antes de ligar na rede)

- **VLAN isolada obrigatória.** A porta 5555 aberta é shell root sem senha na
  rede; foi o vetor dos worms ADB.Miner e Fbot. O chassi nunca deve ter rota
  para a sua LAN interna.
- **Egress filtrado + logado.** Deixe a saída das placas passar por um gateway
  (pfSense/OPNsense) com default-deny e logging. É o seu detector contínuo: se
  uma placa comprometida chamar um C2, aparece no log.
- **Placa não confiável não guarda credencial real.** Até reflashar com ROM
  limpa, trate cada placa como comprometida.
- **Factory reset não limpa** firmware backdoor tipo BadBox/Triada. A única
  remediação real é reflash com ROM stock oficial (Odin/heimdall) ou AOSP que
  você mesmo baixou.

## Acesso remoto (SSH pela internet, atravessa CGNAT)

A VM está atrás de ADSL/CGNAT (sem IP público). Para chegar nela por SSH sem
abrir porta no roteador, use o **Cloudflare Tunnel**:

```bash
sudo bash scripts/setup-cloudflared.sh farm.tilabs.com.br
```

Ele instala o `cloudflared` + `sshd`, autentica na Cloudflare, cria o túnel,
**cria o registro DNS** e sobe como serviço systemd (já inicia e reconecta no boot).
Depois, proteja o hostname no **Zero Trust Access** com o seu e-mail (1 passo no
painel) para o SSH não ficar público. Conectar da sua máquina:

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" USUARIO@farm.tilabs.com.br
```

Alternativa por bastion com IP público: `setup-frpc.sh` (+ `frp/BASTION.md`),
fechado ao seu IP no firewall.

## Estrutura

```
scripts/setup-linux.sh          # prepara a VM Ubuntu (adb Google + udev + deps)
scripts/farm-scan.sh            # TUDO num comando: instala + valida + antivírus + portas -> index.html
scripts/validate-farm.sh        # integridade + Magisk/apps/admins -> veredito por placa (HTML+CSV)
scripts/scan-apks.sh            # antivírus off-device dos APKs (ClamAV / VirusTotal)
scripts/port-scan.sh            # portas em LISTEN + 5555/adb-tcp + nmap externo (HTML+CSV)
scripts/hardening-check.sh      # config de segurança do Android vs CIS/AOSP -> score por placa
scripts/health-report.sh        # relatório HTML de saúde/identidade + referências oficiais
scripts/check-all.sh            # auditoria estendida (saúde+validação+hardening+antivírus+rede)
scripts/net-watch.sh            # monitora conexões das placas e sinaliza destinos suspeitos
scripts/baseline-farm.sh        # retrato rápido de segurança das placas (CSV)
scripts/install-scrcpy.sh       # instala o scrcpy (espelho/controle de tela das placas)
scripts/update-platform-tools.sh# atualiza o adb/fastboot para a versão mais recente do Google
scripts/setup-cloudflared.sh    # acesso SSH remoto via Cloudflare Tunnel (atravessa CGNAT)
scripts/setup-frpc.sh           # acesso remoto via FRP (SSH das placas), fechado ao seu IP
frp/BASTION.md                  # setup do servidor FRP (frps) no bastion + firewall restrito
```

## Próximo passo

Com a farm auditada e o acesso remoto no ar, o próximo bloco é a **app de
gerência** (controlar e automatizar as placas sem o software chinês de origem
desconhecida). Base recomendada: DeviceFarmer/STF ou `@devicefarmer/adbkit`
(Node), com `scrcpy` para tela e `Appium` para automação.

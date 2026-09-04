# adb - setup de estação para phone farm

Deixa um **Windows padrão 100% pronto** para plugar um chassi de phone farm
(várias placas Android num hub USB) e falar com as placas por **ADB**, com o
ambiente Linux rodando por cima via **WSL2**.

O foco aqui é **operação segura**: antes de confiar em qualquer placa, o toolkit
tira um retrato de segurança de cada uma (ROM, root, estado da porta 5555,
pacotes suspeitos), porque hardware genérico de "group control" costuma vir com
ADB aberto, root pré-integrado e, em muitos casos, firmware malicioso de fábrica
(famílias BadBox/Triada/Adups) que **sobrevive a factory reset**.

## O que o setup instala

No **Windows** (roda o adb server e os drivers USB):

- `platform-tools` (adb/fastboot) via winget
- `scrcpy` (espelho/controle de tela) via winget
- Universal ADB Driver (para o Windows reconhecer as placas)

No **WSL2 / Ubuntu** (onde você desenvolve e roda os scripts):

- `platform-tools` do Google, **mesma versão** do Windows (evita mismatch de server)
- `nmap`, `jq`, `wget`, `unzip`, `curl`
- `ADB_SERVER_SOCKET` já configurado apontando para o adb server do Windows

## Como usar

1. Clone este repo no Windows e rode o setup num PowerShell (ele se auto-eleva):

   ```powershell
   git clone https://github.com/dmoraesrs/adb.git
   cd adb
   .\setup-windows.ps1
   ```

   Se o WSL ainda não estava habilitado, o script pede um **reboot**. Reinicie e
   rode `.\setup-windows.ps1` de novo para concluir o provisionamento do Ubuntu.

2. Ligue a **fonte do chassi** e plugue o **cabo USB** no PC.

3. Suba o adb server no **Windows**:

   ```powershell
   adb kill-server
   adb -a nodaemon server start
   ```

4. Abra o **WSL** e liste as placas:

   ```bash
   wsl
   adb devices -l        # deve listar todas as placas
   ```

5. Tire o baseline de segurança antes de confiar nas placas:

   ```bash
   bash scripts/baseline-farm.sh
   ```

   Gera `farm-baseline-<timestamp>/baseline.csv` com uma linha por placa.

### Lendo o baseline

| Coluna | Bandeira vermelha |
|--------|-------------------|
| `adb_tcp_port=5555` | a porta 5555 (shell root sem senha) já vem ligada de fábrica |
| `ro_adb_secure=0` / `ro_secure=0` | ADB aberto sem autorização de chave |
| `build_type=userdebug`/`eng` ou `debuggable=1` | ROM de desenvolvimento/adulterada |
| `root=SIM`/`BIN` | root pré-integrado |
| `suspeitos` preenchido | pacote com nome de firmware malicioso conhecido |
| `patch` antigo | sem atualização de segurança há anos |

Para pacote suspeito, puxe o APK e mande pro scanner:

```bash
adb -s <serial> shell pm path com.pacote.suspeito
adb -s <serial> pull /data/app/.../base.apk ./suspeito.apk
# suba suspeito.apk no MobSF (local) ou no VirusTotal
```

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
  remediação real é reflash com ROM stock oficial ou AOSP que você mesmo baixou.
- **adb -a expõe a 5037 na rede.** Use só com a máquina dentro do segmento
  isolado; em WSL2 mirrored networking, prefira `ADB_SERVER_SOCKET=tcp:localhost:5037`.

## Só preparar o WSL nas máquinas do time

Se você só quer deixar o WSL2 pronto numa máquina (sem instalar o resto do
toolkit de phone farm), use o script standalone `ativar-wsl.ps1`. É o que dá pra
distribuir pro time rodar:

```powershell
# baixa e roda direto
irm https://raw.githubusercontent.com/dmoraesrs/adb/main/ativar-wsl.ps1 -OutFile ativar-wsl.ps1
powershell -ExecutionPolicy Bypass -File .\ativar-wsl.ps1
```

Ele habilita as features do WSL2, instala o Ubuntu e define o WSL2 como padrão.
Se as features precisarem ser habilitadas, pede um reboot; rode de novo depois
para concluir. É idempotente (se já estiver pronto, só mostra o estado).

## Estrutura

```
ativar-wsl.ps1           # standalone: só ativa o WSL2 + Ubuntu (pro time)
setup-windows.ps1        # instala tudo no Windows + provisiona o WSL
wsl/provision.sh         # provisiona o Ubuntu do WSL (chamado pelo ps1)
scripts/baseline-farm.sh # retrato de segurança das placas (CSV)
scripts/health-report.sh # relatório HTML de saúde/segurança + referências oficiais (AOSP/Google/Samsung)
scripts/install-scrcpy.sh# instala o scrcpy no Ubuntu/WSL (espelho de tela das placas)
scripts/update-platform-tools.sh # atualiza o adb/fastboot (platform-tools) p/ a versão mais recente do Google
scripts/net-watch.sh     # monitora conexões das placas e sinaliza destinos suspeitos (C2/backdoor)
```

## Próximo passo

Com o baseline na mão, o próximo bloco é a **app de gerência** (controlar e
automatizar as placas sem o software chinês de origem desconhecida). Base
recomendada: DeviceFarmer/STF ou `@devicefarmer/adbkit` (Node), com `scrcpy`
para tela e `Appium` para automação.

# adb - setup de estacao para phone farm

Deixa um **Windows padrao 100% pronto** para plugar um chassi de phone farm
(varias placas Android num hub USB) e falar com as placas por **ADB**, com o
ambiente Linux rodando por cima via **WSL2**.

O foco aqui e **operacao segura**: antes de confiar em qualquer placa, o toolkit
tira um retrato de seguranca de cada uma (ROM, root, estado da porta 5555,
pacotes suspeitos), porque hardware generico de "group control" costuma vir com
ADB aberto, root pre-integrado e, em muitos casos, firmware malicioso de fabrica
(familias BadBox/Triada/Adups) que **sobrevive a factory reset**.

## O que o setup instala

No **Windows** (roda o adb server e os drivers USB):

- `platform-tools` (adb/fastboot) via winget
- `scrcpy` (espelho/controle de tela) via winget
- Universal ADB Driver (para o Windows reconhecer as placas)

No **WSL2 / Ubuntu** (onde voce desenvolve e roda os scripts):

- `platform-tools` do Google, **mesma versao** do Windows (evita mismatch de server)
- `nmap`, `jq`, `wget`, `unzip`, `curl`
- `ADB_SERVER_SOCKET` ja configurado apontando para o adb server do Windows

## Como usar

1. Clone este repo no Windows e rode o setup num PowerShell (ele se auto-eleva):

   ```powershell
   git clone https://github.com/dmoraesrs/adb.git
   cd adb
   .\setup-windows.ps1
   ```

   Se o WSL ainda nao estava habilitado, o script pede um **reboot**. Reinicie e
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

5. Tire o baseline de seguranca antes de confiar nas placas:

   ```bash
   bash scripts/baseline-farm.sh
   ```

   Gera `farm-baseline-<timestamp>/baseline.csv` com uma linha por placa.

### Lendo o baseline

| Coluna | Bandeira vermelha |
|--------|-------------------|
| `adb_tcp_port=5555` | a porta 5555 (shell root sem senha) ja vem ligada de fabrica |
| `ro_adb_secure=0` / `ro_secure=0` | ADB aberto sem autorizacao de chave |
| `build_type=userdebug`/`eng` ou `debuggable=1` | ROM de desenvolvimento/adulterada |
| `root=SIM`/`BIN` | root pre-integrado |
| `suspeitos` preenchido | pacote com nome de firmware malicioso conhecido |
| `patch` antigo | sem atualizacao de seguranca ha anos |

Para pacote suspeito, puxe o APK e mande pro scanner:

```bash
adb -s <serial> shell pm path com.pacote.suspeito
adb -s <serial> pull /data/app/.../base.apk ./suspeito.apk
# suba suspeito.apk no MobSF (local) ou no VirusTotal
```

## Seguranca (leia antes de ligar na rede)

- **VLAN isolada obrigatoria.** A porta 5555 aberta e shell root sem senha na
  rede; foi o vetor dos worms ADB.Miner e Fbot. O chassi nunca deve ter rota
  para a sua LAN interna.
- **Egress filtrado + logado.** Deixe a saida das placas passar por um gateway
  (pfSense/OPNsense) com default-deny e logging. E o seu detector continuo: se
  uma placa comprometida chamar um C2, aparece no log.
- **Placa nao confiavel nao guarda credencial real.** Ate reflashar com ROM
  limpa, trate cada placa como comprometida.
- **Factory reset nao limpa** firmware backdoor tipo BadBox/Triada. A unica
  remediacao real e reflash com ROM stock oficial ou AOSP que voce mesmo baixou.
- **adb -a expoe a 5037 na rede.** Use so com a maquina dentro do segmento
  isolado; em WSL2 mirrored networking, prefira `ADB_SERVER_SOCKET=tcp:localhost:5037`.

## Estrutura

```
setup-windows.ps1        # instala tudo no Windows + provisiona o WSL
wsl/provision.sh         # provisiona o Ubuntu do WSL (chamado pelo ps1)
scripts/baseline-farm.sh # retrato de seguranca das placas (CSV)
```

## Proximo passo

Com o baseline na mao, o proximo bloco e a **app de gerencia** (controlar e
automatizar as placas sem o software chines de origem desconhecida). Base
recomendada: DeviceFarmer/STF ou `@devicefarmer/adbkit` (Node), com `scrcpy`
para tela e `Appium` para automacao.

# Switch Mac

Aplicativo nativo para macOS que conecta o **Nintendo Switch** ao Mac por USB e deixa você
navegar pelo armazenamento dele — cartão SD, NAND, jogos instalados e saves. Escrito em
SwiftUI, com o protocolo MTP implementado do zero.

Com um *responder* homebrew como o **DBI** rodando no console, o acesso é completo, de
leitura e escrita. Também funciona com aparelhos Android, no espírito do Android File
Transfer.

```
┌──────────────────┬────────────────────────────────────────────────┐
│ Switch           │ ⌂ Cartão SD › switch › dbi                      │
│ Nintendo 22.5.0  │────────────────────────────────────────────────│
│                  │ Nome                  Tamanho  Tipo   Modificado│
│ ARMAZENAMENTO    │ 📁 saves                    —  Pasta  31/12     │
│ ▸ Cartão SD      │ 📦 jogo-exemplo.nsp   12,4 GB  NSP    31/12     │
│   ████████░░ 42G │ 📦 atualizacao.nsp     1,93 GB NSP    31/12     │
│ ▸ NAND USER      │ 🖼 album-captura.jpg   1,2 MB  JPEG   31/12     │
│   █████████▌ 3G  │                                                 │
│ ▸ Jogos, saves…  │                                                 │
├──────────────────┴────────────────────────────────────────────────┤
│ ↑ Enviando jogo-exemplo.nsp                                  62% ⓧ │
│   ██████████████████░░░░░░░░░░                                     │
│   7,7 GB de 12,4 GB · 25,6 MB/s · decorrido 00:47 · 3 min restantes│
└────────────────────────────────────────────────────────────────────┘
```

## In English

**Switch Mac** is a native macOS app that connects your **Nintendo Switch** to your Mac
over USB and lets you browse its storage — SD card, NAND, installed games and saves. The
MTP protocol is implemented from scratch in Swift; no Android File Transfer, no Java, no
background daemon.

With a homebrew MTP responder such as **DBI** running on the console, access is full
read/write across all eight storages it exposes. On stock firmware the Switch only exposes
the screenshot album, read-only. **Android** devices work too.

- **Download:** [latest release](https://github.com/oflaus/switch-mac/releases/latest) —
  signed and notarized by Apple, so it opens with a double click, no security warnings.
- **Requirements:** macOS 14 or later · Apple Silicon or Intel (universal binary) · a USB
  **data** cable (charge-only cables will not work).
- **Not connecting?** The usual culprit is macOS itself holding the USB interface. Use
  **Device → Release USB interface** in the app.

The rest of this README, the documentation and the code comments are in Portuguese. Feel
free to open an issue in English — it will be answered.

## Recursos

- **Detecção automática.** Basta conectar o cabo e ativar o MTP no aparelho; o app conecta
  sozinho em até dois segundos.
- **Armazenamento interno e cartão SD**, cada um com espaço usado e livre.
- **Navegação completa**: lista ordenável por nome, tamanho, tipo e data; trilha de
  navegação clicável; voltar, avançar e pasta acima; filtro por nome.
- **Download** de arquivos e de pastas inteiras (recursivo).
- **Envio** de arquivos e pastas para o aparelho — pelo botão, pelo menu, ou arrastando do
  Finder direto para a janela.
- **Arrastar para fora**: puxe um item da lista para o Finder e o download só acontece
  quando você solta.
- **Barra de progresso fixa no rodapé** durante qualquer transferência, com porcentagem,
  bytes transferidos, velocidade, tempo decorrido, tempo restante e botão de cancelar.
- **Gerenciamento no aparelho**: criar pasta, renomear e apagar.
- **Abrir no Mac** com duplo clique — baixa para uma pasta temporária e abre no app padrão.
- **Liberar interface USB**: resolve com um clique o bloqueio mais comum do macOS
  (veja [Solução de problemas](docs/solucao-de-problemas.md)).
- **Janela de diagnóstico** com o registro do protocolo e a lista de serviços do sistema
  que estejam segurando o aparelho.

## Requisitos

| Item | Versão |
| --- | --- |
| macOS | 14 ou mais recente |
| Processador | Apple Silicon ou Intel (o app é universal) |
| Command Line Tools | `xcode-select --install` |
| Conexão à internet | só na primeira compilação, para baixar a `libusb` |

O Xcode completo **não** é necessário: o projeto compila com Swift Package Manager e o
ícone é gerado por um script próprio.

## Instalação

```bash
git clone https://github.com/oflaus/switch-mac.git "Switch Mac"
cd "Switch Mac"
./build.sh
```

O script compila a `libusb` do fonte na primeira vez (uns 40 segundos, com o resultado
guardado em cache), compila o app em modo release, monta o pacote, gera o ícone, embute a
`libusb` dentro do `.app` e assina.

O app é **universal**: uma única build roda nativa em Apple Silicon e em Macs Intel. A
`libusb` embutida é compilada para as duas arquiteturas e unida com `lipo`, e o `build.sh`
recusa gerar o pacote se as arquiteturas do app e da biblioteca não baterem.

O Homebrew **não** é necessário. A `libusb` é compilada aqui de propósito: a versão que o
Homebrew distribui é feita para o macOS mais recente e exigiria macOS 26, o que quebraria
o app para quem está em versões anteriores. Compilando, o alvo fica em macOS 14 — e o
`build.sh` confere isso a cada build, recusando gerar um pacote cujas versões mínimas não
batam.

O resultado é `build/Switch Mac.app`:

```bash
open "build/Switch Mac.app"
```

Para instalar de vez, arraste esse `.app` para a pasta **Aplicativos**.

Como a `libusb` viaja dentro do pacote, o `.app` funciona em qualquer Mac com macOS 14 ou
mais recente, sem instalar nada.

## Distribuição

Quem baixa um app da internet passa pelo Gatekeeper. Para que o download abra com um
duplo clique, sem aviso nenhum, o pacote precisa ser assinado com um certificado
**Developer ID Application** e notarizado pela Apple.

O `build.sh` detecta esse certificado sozinho: se ele estiver no Chaveiro, assina com ele
e ativa o hardened runtime; se não, cai numa assinatura ad-hoc, que só serve para rodar na
máquina onde o app foi compilado.

Para gerar o `.dmg` publicável:

```bash
./release.sh
```

O script compila, assina de dentro para fora (a `libusb` antes do bundle), monta o `.dmg`,
envia para a notarização, aguarda o retorno da Apple, grampeia o ticket e mostra o veredito
que o Gatekeeper vai dar. O arquivo final vai para `build/` e é o que se anexa numa
[Release](https://github.com/oflaus/switch-mac/releases).

Antes do primeiro uso, duas coisas precisam existir — uma vez só:

1. **O certificado Developer ID Application**, criado em
   [developer.apple.com](https://developer.apple.com/account/resources/certificates) ou pelo
   Xcode em *Settings → Accounts → Manage Certificates → +*. Exige o Apple Developer Program
   pago; o certificado *Apple Development*, que vem com qualquer Apple ID, **não** serve para
   distribuir.

2. **A credencial do `notarytool`** guardada no Chaveiro. Com uma chave da App Store
   Connect API (`AuthKey_XXXXXXXXXX.p8`):

   ```bash
   xcrun notarytool store-credentials "switchmac" --key "/caminho/AuthKey_XXXXXXXXXX.p8" --key-id "XXXXXXXXXX" --issuer "<uuid-do-issuer>"
   ```

   O `key-id` é o trecho do nome do arquivo; o `issuer` é um UUID que fica em App Store
   Connect → Usuários e Acesso → Integrações → App Store Connect API. Como alternativa,
   dá para usar Apple ID e uma senha de app gerada em
   [account.apple.com](https://account.apple.com) → Segurança → Senhas específicas do app:

   ```bash
   xcrun notarytool store-credentials "switchmac" --apple-id "seu@email.com" --team-id "SEUTEAMID" --password "senha-de-app"
   ```

   Nos dois casos a credencial passa a viver no Chaveiro, e o `.p8` não precisa mais ficar
   acessível no disco. O time do certificado do passo 1 e o time desta credencial precisam
   ser o mesmo — assinar com um time e notarizar com outro faz a Apple recusar o envio.

Sem esses dois itens o `release.sh` para logo no começo e explica o que falta, em vez de
gastar uma compilação inteira para falhar no fim.

## Como usar

1. Conecte o aparelho com um cabo USB **de dados** — cabo só de carga não funciona.
2. **No Switch**: abra o DBI e escolha a opção de MTP (*Run MTP responder*). Sem homebrew,
   o console expõe só o álbum de capturas, em modo somente leitura.
3. **No Android**: desbloqueie a tela, puxe a barra de notificações, toque em "Carregando
   este dispositivo via USB" e escolha **Transferência de arquivos** (ou **MTP**).

Para enviar arquivos, arraste do Finder para a janela. Para trazer arquivos, arraste da
janela para o Finder, ou selecione e use **Baixar**.

### Atalhos

| Atalho | Ação |
| --- | --- |
| `⌘R` | Recarregar a pasta |
| `⌘⇧N` | Nova pasta no aparelho |
| `⌘U` | Enviar arquivos para o aparelho |
| `⌘D` | Baixar seleção escolhendo a pasta |
| `⌘⇧D` | Baixar para a pasta padrão |
| `⌘⌫` | Apagar do aparelho |
| `⌘[` / `⌘]` | Voltar / avançar |
| `⌘↑` | Pasta acima |

A pasta padrão de download fica em **Switch Mac → Ajustes**.

## Não conectou?

O caso mais comum não é cabo nem aparelho: é o próprio macOS segurando a interface USB.
Use **Dispositivo → Liberar interface USB**.

O guia completo está em **[docs/solucao-de-problemas.md](docs/solucao-de-problemas.md)**.

## Documentação

| Documento | Conteúdo |
| --- | --- |
| [Arquitetura](docs/arquitetura.md) | Como o app é organizado e por que foi feito assim |
| [Protocolo MTP](docs/protocolo-mtp.md) | O protocolo no fio, operações usadas e as armadilhas |
| [Solução de problemas](docs/solucao-de-problemas.md) | Diagnóstico de conexão, `ptpcamerad`, cabos, permissões |
| [Desenvolvimento](docs/desenvolvimento.md) | Compilar, depurar, modos `--scan` e `--demo`, onde mexer |

## Estado do projeto

Funciona e está em uso.

Verificado com hardware real — Nintendo Switch rodando o *responder* MTP do **DBI**:
conexão, oito armazenamentos com espaço livre correto, navegação por pastas em vários
níveis, filtro, seleção, download de arquivo com verificação de integridade no disco, barra
de progresso e recuperação da interface bloqueada pelo macOS.

As limitações conhecidas e os detalhes do aparelho testado estão em
[Arquitetura](docs/arquitetura.md#limitações-conhecidas).

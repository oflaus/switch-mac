# Desenvolvimento

## Preparar o ambiente

```bash
xcode-select --install     # Command Line Tools (o Xcode completo não é necessário)
brew install libusb        # o build.sh faz isso sozinho se faltar
```

## Compilar

```bash
./build.sh              # release + pacote .app completo
./build.sh debug        # mesma coisa, em modo debug
```

Para iterar rápido, sem montar o pacote:

```bash
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$PKG_CONFIG_PATH"
swift build                       # tudo
swift build --target MTPKit       # só a biblioteca do protocolo
```

O `PKG_CONFIG_PATH` é necessário porque o SwiftPM não procura em `/opt/homebrew` por
padrão. O `build.sh` exporta essa variável por conta própria.

## O que o `build.sh` faz

1. Instala a `libusb` se faltar.
2. Compila com o Swift Package Manager.
3. Monta `build/Switch Mac.app` com `Info.plist` e `PkgInfo`.
4. Gera o ícone com `Tools/GenerateIcon.swift` e converte com `iconutil`.
5. Copia a `libusb` para `Contents/Frameworks` e reescreve os caminhos de carregamento com
   `install_name_tool`, deixando o pacote autocontido.
6. Assina de forma ad-hoc.

## Modos de linha de comando

### `--scan` — inspeção do barramento

```bash
"build/Switch Mac.app/Contents/MacOS/SwitchMac" --scan
```

Lista todos os dispositivos USB com as classes de interface de cada um e marca qual expõe
MTP. Não abre janela; imprime e sai.

### `--demo` — interface com dados fictícios

```bash
open "build/Switch Mac.app" --args --demo
```

Preenche a interface com dois armazenamentos, sete arquivos e uma transferência em
andamento. Serve para conferir layout sem nenhum aparelho conectado. Os dados vivem em
`Sources/SwitchMac/DemoData.swift`.

## Depurar o protocolo

Ligue **Registro detalhado do protocolo** em **Ajustes** e abra
**Dispositivo → Diagnóstico…**. Cada comando e cada resposta aparecem com código e ID de
transação. O botão *Copiar* leva tudo para a área de transferência.

Pelo código, `MTPLog.shared.verbose = true` tem o mesmo efeito.

## Onde mexer

| Quero… | Mexo em… |
| --- | --- |
| Adicionar uma operação MTP | `MTPCodes.swift` (o código) e `MTPSession.swift` (a chamada) |
| Mudar como um *dataset* é lido | `MTPModels.swift` |
| Mudar detecção de aparelho | `USB.swift`, em `parseMTPInterface` e `inspect` |
| Mudar a tabela de arquivos | `BrowserView.swift` |
| Mudar a barra de progresso | `TransferBar.swift` |
| Mudar a lógica de transferência | `AppModel.swift`, em `runDownload` e `runUpload` |
| Mudar o ícone | `Tools/GenerateIcon.swift` (CoreGraphics puro) |

## Regras da casa

- **Toda I/O USB roda em `MTPBus.queue`.** Métodos que só podem ser chamados de lá terminam
  em `OnQueue`. Nunca chame `libusb` de outra thread.
- **`MTPKit` não importa SwiftUI nem AppKit.** A separação é o que permite reaproveitar a
  biblioteca.
- **`AppModel` é `@MainActor`.** Retornos de progresso vindos da fila USB precisam saltar
  para o ator principal antes de tocar em estado publicado.
- **Erros voltam com mensagem acionável.** `MTPError` já produz texto em português dizendo o
  que o usuário pode fazer, e não só o código numérico.

## Armadilha de layout já encontrada

`Text(...).fixedSize(horizontal: false, vertical: true)` dentro do painel de detalhe fez a
janela inteira ser medida com uma altura absurda: o texto era medido em uma largura
degenerada, quebrava em uma letra por linha e o resultado se propagava para a barra lateral,
que ficava em branco. A correção foi trocar `fixedSize` por larguras mínimas explícitas
(`.frame(minWidth:maxWidth:)`).

Se algum painel aparecer em branco ou desalinhado, desconfie primeiro de `fixedSize` e de
`Spacer` em contexto de proposta de tamanho ilimitada.

## Estrutura

```
Package.swift
build.sh
Resources/Info.plist
Tools/GenerateIcon.swift
Sources/
  CLibUSB/     module map para a libusb do sistema
  MTPKit/      protocolo MTP puro, sem interface
  SwitchMac/   aplicativo SwiftUI
docs/          esta documentação
```

## O que ainda não foi feito

- Testes automatizados. O `ByteReader`/`ByteWriter` e o parser de *datasets* são as partes
  mais fáceis e mais úteis de cobrir, porque não precisam de hardware.
- Retomada de transferência interrompida (`GetPartialObject`, código `0x101B`).
- Miniaturas de imagem (`GetThumb`, código `0x100A`).
- Suporte a mais de um aparelho ao mesmo tempo.

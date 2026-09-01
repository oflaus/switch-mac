# Desenvolvimento

## Preparar o ambiente

```bash
xcode-select --install     # Command Line Tools (o Xcode completo não é necessário)
```

Só isso. A `libusb` é baixada e compilada pelo `build.sh` na primeira execução, e não vem
do Homebrew — veja o porquê em [O que o `build.sh` faz](#o-que-o-buildsh-faz).

## Compilar

```bash
./build.sh              # release + pacote .app completo
./build.sh debug        # mesma coisa, em modo debug
```

Para iterar rápido, sem montar o pacote:

```bash
export PKG_CONFIG_PATH="$HOME/Library/Caches/switch-mac/libusb-1.0.30-universal/lib/pkgconfig:$PKG_CONFIG_PATH"
swift build                       # tudo
swift build --target MTPKit       # só a biblioteca do protocolo
```

O `PKG_CONFIG_PATH` é necessário porque o SwiftPM não sabe onde a `libusb` foi parar. O
`build.sh` exporta essa variável por conta própria; rode-o ao menos uma vez antes, para
que a `libusb` exista no cache.

## O que o `build.sh` faz

1. Baixa a `libusb`, confere o SHA-256 e a compila para `arm64` e `x86_64` com alvo
   macOS 14, unindo as duas com `lipo` e guardando o resultado em
   `~/Library/Caches/switch-mac/`.

   Cada arquitetura é compilada numa passada separada porque o `configure` roda testes
   que compilam e executam programas, e esses testes não funcionam com um binário de duas
   arquiteturas.

   Ela não vem do Homebrew porque os binários de lá são compilados para o macOS mais
   recente: a `libusb` do Homebrew hoje exige macOS 26, e como a dylib viaja dentro do
   `.app`, isso quebraria o app em todas as versões anteriores. O cache também mora fora
   do repositório de propósito — o `libtool` não põe aspas nos caminhos ao instalar, e o
   espaço em "Switch Mac" faria o `make install` falhar.

2. Compila com o Swift Package Manager, universal (`--arch arm64 --arch x86_64`).
3. Monta o `.app` com `Info.plist` e `PkgInfo` — num diretório temporário em APFS, porque
   em exFAT os arquivos `._*` fazem o `codesign` recusar o pacote.
4. Gera o ícone com `Tools/GenerateIcon.swift` e converte com `iconutil`.
5. Copia a `libusb` para `Contents/Frameworks` e reescreve os caminhos de carregamento com
   `install_name_tool`, deixando o pacote autocontido.
6. Confere que app, `libusb` e `Info.plist` concordam sobre a versão mínima de macOS e
   que app e `libusb` têm as mesmas arquiteturas, recusando continuar se divergirem.
7. Assina: com o certificado Developer ID, se houver um; senão, de forma ad-hoc.
8. Copia o resultado para `build/Switch Mac.app`.

Para gerar o `.dmg` assinado e notarizado que vai para o GitHub, use `./release.sh` —
veja [Distribuição](../README.md#distribuição) no README.

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

### `--probe` — investigar um aparelho específico

```bash
"build/Switch Mac.app/Contents/MacOS/SwitchMac" --probe
```

Conecta, imprime as operações que o aparelho anuncia, lista os armazenamentos, mostra a
raiz do primeiro com handle, formato, pai e storage de cada item, e então tenta entrar na
primeira pasta de três maneiras diferentes. Com o registro detalhado ligado, cada comando e
cada resposta saem no `stderr`.

É a ferramenta que separa "o protocolo não funciona com este aparelho" de "a interface tem
um bug" — foi assim que se descobriu que a navegação por pasta funcionava no MTP e quebrava
só na tabela.

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

## Armadilhas de SwiftUI já encontradas

Duas custaram caro. Ficam registradas para não morderem de novo.

### `fixedSize` inflando a janela inteira

`Text(...).fixedSize(horizontal: false, vertical: true)` dentro do painel de detalhe fez a
janela inteira ser medida com uma altura absurda: o texto era medido em uma largura
degenerada, quebrava em uma letra por linha e o resultado se propagava para a barra lateral,
que ficava completamente em branco. A correção foi trocar `fixedSize` por larguras mínimas
explícitas (`.frame(minWidth:maxWidth:)`).

Se algum painel aparecer em branco ou desalinhado, desconfie primeiro de `fixedSize` e de
`Spacer` em contexto de proposta de tamanho ilimitada.

### `onDrag` dentro de célula matando o clique

Um `.onDrag` em uma célula da `Table` intercepta o mouse: a linha deixa de ser selecionada e
o duplo clique não dispara o `primaryAction`. O sintoma era cruel — clicar no *nome* da
pasta não fazia nada, mas clicar na coluna "Modificado" da mesma linha entrava na pasta
normalmente.

A correção foi mover o arrastar para a linha, com `TableRow(...).draggable(...)` e um tipo
`Transferable` que baixa o arquivo sob demanda. A tabela passa a arbitrar clique e arrasto,
que é o comportamento correto.

**Regra:** nunca coloque gestos em conteúdo de célula de `Table`; use os modificadores de
`TableRow`.

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

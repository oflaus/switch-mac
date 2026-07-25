# Switch Mac

Aplicativo nativo para macOS que conecta um aparelho Android ao Mac por USB e deixa você
navegar pelo armazenamento dele — no espírito do Android File Transfer, mas escrito em
SwiftUI, com o protocolo MTP implementado do zero e sem depender do app descontinuado da
Google.

```
┌──────────────────┬────────────────────────────────────────────────┐
│ Galaxy S24       │ ⌂ Armazenamento interno › DCIM › Camera         │
│ Samsung SM-S921B │────────────────────────────────────────────────│
│                  │ Nome                  Tamanho  Tipo   Modificado│
│ ARMAZENAMENTO    │ 📁 Camera                   —  Pasta  24/07     │
│ ▸ Interno        │ 🖼 IMG_20260714.jpg     4,8 MB  JPEG   24/07     │
│   ████████░░ 42G │ 🎬 viagem-praia.mp4    1,93 GB  MPEG-4 24/07     │
│ ▸ Cartão SD      │                                                 │
│   █████████▌ 3G  │                                                 │
├──────────────────┴────────────────────────────────────────────────┤
│ ↓ Baixando viagem-praia.mp4                                  62% ⓧ │
│   ██████████████████░░░░░░░░░░                                     │
│   1,2 GB de 1,93 GB · 25,6 MB/s · decorrido 00:47 · 28 s restantes │
└────────────────────────────────────────────────────────────────────┘
```

## Recursos

- **Detecção automática.** Basta conectar o cabo e escolher "Transferência de arquivos" no
  celular; o app conecta sozinho em até dois segundos.
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
| Command Line Tools | `xcode-select --install` |
| Homebrew | para instalar a `libusb` (o script faz isso) |

O Xcode completo **não** é necessário: o projeto compila com Swift Package Manager e o
ícone é gerado por um script próprio.

## Instalação

```bash
git clone https://github.com/oflaus/switch-mac.git "Switch Mac"
cd "Switch Mac"
./build.sh
```

O script instala a `libusb` se faltar, compila em modo release, monta o pacote, gera o
ícone, embute a `libusb` dentro do `.app` e assina de forma ad-hoc.

O resultado é `build/Switch Mac.app`:

```bash
open "build/Switch Mac.app"
```

Para instalar de vez, arraste esse `.app` para a pasta **Aplicativos**.

Como a `libusb` viaja dentro do pacote, o `.app` funciona em outro Mac mesmo sem Homebrew.
A assinatura ad-hoc basta para rodar na sua máquina; distribuir para terceiros exigiria um
certificado Developer ID e notarização.

## Como usar

1. Conecte o aparelho com um cabo USB **de dados** — cabo só de carga não funciona.
2. Desbloqueie a tela do celular.
3. Puxe a barra de notificações, toque em "Carregando este dispositivo via USB" e escolha
   **Transferência de arquivos** (ou **MTP**).

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

Funciona e está em uso. O que **foi verificado**: compilação sem avisos, detecção e
enumeração USB reais, interface completa, liberação da interface bloqueada pelo sistema.
As limitações conhecidas estão listadas em [Arquitetura](docs/arquitetura.md#limitações-conhecidas).

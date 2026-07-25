# Solução de problemas

## "Acesso negado à interface MTP"

É de longe o problema mais comum, e **não é defeito de cabo nem do aparelho**. É o próprio
macOS.

### O que acontece

O macOS trata qualquer dispositivo da classe USB "still image" como se fosse uma câmera — e
é exatamente essa classe que Android e Nintendo Switch usam para expor MTP. Assim que o
aparelho aparece no barramento, dois serviços do sistema o reservam para si:

```
/usr/libexec/ptpcamerad
/System/Library/Frameworks/ImageCaptureCore.framework/.../mscamerad-xpc
```

Enquanto eles seguram a interface, nenhum outro programa consegue conversar com o aparelho.
O sintoma típico é justamente o seu: funciona na primeira conexão, e depois para de
funcionar — porque o serviço subiu e ficou.

### A solução

Use **Dispositivo → Liberar interface USB** (o mesmo botão aparece na tela de erro).

O app encerra os dois serviços e tenta reconectar imediatamente, repetindo até três vezes.
Os dois processos rodam com o usuário comum e o `launchd` os reinicia sozinho quando forem
necessários — nada é desinstalado nem desativado permanentemente.

Detalhes que valem saber:

- Esses serviços **ignoram `SIGTERM`**. O app manda `SIGTERM` por educação e, se o processo
  continuar vivo, usa `SIGKILL`, que é o que de fato funciona.
- O `launchd` relança o `ptpcamerad` quase instantaneamente, então é uma corrida. Por isso o
  app tenta reivindicar a interface logo em seguida e insiste algumas vezes.
- O rodapé da janela de **Diagnóstico** mostra, em laranja, quais serviços estão segurando a
  interface naquele momento.

### Manualmente, pelo terminal

```bash
sudo pkill -9 -x ptpcamerad
```

Não precisa de `sudo` se os processos forem do seu usuário — que é o caso normal:

```bash
pkill -9 -x ptpcamerad
pkill -9 -x mscamerad-xpc
```

### Outros programas que também seguram a interface

Feche, se estiverem abertos:

- **Captura de Imagem** (Image Capture)
- **Fotos**
- **Android File Transfer**
- **OpenMTP**
- Qualquer outro cliente MTP

## "Conectado só para carregar"

O aparelho foi reconhecido, mas não expôs a interface MTP. No celular:

1. Desbloqueie a tela.
2. Puxe a barra de notificações.
3. Toque em "Carregando este dispositivo via USB".
4. Escolha **Transferência de arquivos** (ou **MTP**).

Em alguns aparelhos essa escolha volta ao padrão toda vez que o cabo é reconectado. Nas
opções de desenvolvedor existe "Configuração USB padrão", onde dá para fixar em MTP.

## "Nenhum aparelho Android conectado"

Nessa altura o Mac nem viu o aparelho no barramento USB.

1. **Troque o cabo.** É a causa mais frequente. Muitos cabos que acompanham carregadores só
   têm as linhas de energia, sem as de dados. Um cabo que carrega não prova nada.
2. **Troque a porta.** Prefira uma porta direta do Mac em vez de hub ou dock.
3. **Desbloqueie a tela** antes de conectar.
4. **Confirme pelo terminal**:

   ```bash
   "build/Switch Mac.app/Contents/MacOS/SwitchMac" --scan
   ```

   Se o aparelho não aparecer nessa lista, o problema é físico (cabo, porta ou aparelho) e
   nenhum ajuste no app resolve. Se aparecer sem a marcação "interface MTP", é o caso da
   seção anterior.

## A transferência trava ou fica muito lenta

- Cabos e portas USB 2.0 limitam a cerca de 30–35 MB/s. É o teto do barramento, não do app.
- Enquanto uma transferência grande está em andamento, navegar em outra pasta espera. É uma
  limitação da sessão MTP única, não um travamento.
- Muitos arquivos pequenos são naturalmente mais lentos que um arquivo grande: cada arquivo
  custa uma transação completa de ida e volta.

## Uma transferência falhou no meio

Depois de uma interrupção, o app reabre a conexão automaticamente — bytes pendentes no
*endpoint* deixariam a sessão fora de sincronia. Se o erro se repetir sempre no mesmo
arquivo, ligue "Registro detalhado do protocolo" em **Ajustes**, refaça a operação e copie o
conteúdo do **Diagnóstico**: o código de resposta MTP diz exatamente o que o aparelho
recusou.

Códigos que aparecem com mais frequência:

| Código | Significado |
| --- | --- |
| `0x200C` | Sem espaço livre no aparelho |
| `0x200F` | Acesso negado pelo aparelho |
| `0x2013` | Armazenamento indisponível — cartão removido ou desmontado |
| `0x2019` | Aparelho ocupado; tente de novo |
| `0xA809` | Arquivo grande demais para o sistema de arquivos do destino (FAT32 tem limite de 4 GiB) |

## Nintendo Switch

O app funciona com o Switch, mas o que dá para fazer depende de quem responde no console:

- **Firmware de fábrica**: o console expõe MTP apenas para o álbum de capturas e é somente
  leitura. Dá para trazer capturas de tela e vídeos para o Mac, mas não enviar arquivos.
- **Responder homebrew (DBI e semelhantes)**: acesso completo de leitura e escrita, com
  vários armazenamentos virtuais — cartão SD, NAND USER, NAND SYSTEM, jogos instalados,
  saves e álbum. Verificado nesta combinação.

Duas coisas que chamam a atenção e **não são defeito do app**:

- **Todas as datas aparecem como 31/12/1969** — o DBI não informa data de modificação, e a
  época zero do Unix no fuso do Brasil cai nesse dia.
- **Arquivos `._alguma-coisa` de 4 KB** espalhados pelo cartão são metadados que o próprio
  macOS cria ao gravar em sistemas de arquivos que não têm atributos estendidos. Podem ser
  apagados sem risco.

## O app não abre depois de copiado para outro Mac

A assinatura é ad-hoc, então o Gatekeeper reclama em uma máquina que não compilou o app.
Clique com o botão direito no `.app` → **Abrir** → **Abrir** na caixa de diálogo. Ou compile
localmente com `./build.sh`.

## Como reportar um problema

Junte estas três coisas:

1. Saída de `"build/Switch Mac.app/Contents/MacOS/SwitchMac" --scan`
2. Conteúdo do **Diagnóstico** com "Registro detalhado do protocolo" ligado (botão *Copiar*)
3. Marca, modelo e versão do Android do aparelho

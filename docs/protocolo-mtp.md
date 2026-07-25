# O protocolo MTP no fio

Notas sobre a implementação em `Sources/MTPKit`. Serve tanto para manutenção quanto para
quem quiser reaproveitar a biblioteca.

MTP (*Media Transfer Protocol*) é uma extensão do PTP (*Picture Transfer Protocol*,
ISO 15740). Do lado do Android, quem responde é o `MtpServer` do AOSP; do lado do Nintendo
Switch, um servidor próprio bem mais limitado.

## Como o aparelho é reconhecido

O aparelho expõe uma interface USB da classe **"still image"**:

| Campo | Valor |
| --- | --- |
| `bInterfaceClass` | `0x06` |
| `bInterfaceSubClass` | `0x01` |
| `bInterfaceProtocol` | `0x01` |

Essa interface traz três *endpoints*: um **bulk IN**, um **bulk OUT** e um **interrupt IN**
(eventos assíncronos, que o app ignora). Alguns aparelhos usam classe `0xFF`
(*vendor specific*) com os mesmos três *endpoints*; `parseMTPInterface` aceita os dois casos.

Quando existe uma interface ADB (`0xFF/0x42/0x01`) mas nenhuma MTP, o aparelho está
conectado só para carregar — é assim que o app distingue "não tem nada plugado" de
"tem um Android plugado no modo errado".

## O container

Todo tráfego são *containers* com um cabeçalho de 12 bytes, sempre *little-endian*:

| Deslocamento | Tamanho | Campo |
| --- | --- | --- |
| 0 | 4 | Comprimento total, cabeçalho incluído |
| 4 | 2 | Tipo: 1 comando, 2 dados, 3 resposta, 4 evento |
| 6 | 2 | Código da operação ou da resposta |
| 8 | 4 | ID da transação |
| 12 | … | Parâmetros (até 5 × `uint32`) ou dados brutos |

Uma operação é uma sequência fixa: **comando** → **fase de dados opcional** → **resposta**.
Nunca há duas transações em voo ao mesmo tempo.

## Operações usadas

| Código | Nome | Para quê |
| --- | --- | --- |
| `0x1001` | GetDeviceInfo | Fabricante, modelo e a lista de operações suportadas |
| `0x1002` | OpenSession | Abre a sessão (transação obrigatoriamente 0) |
| `0x1003` | CloseSession | Fecha a sessão |
| `0x1004` | GetStorageIDs | Lista os armazenamentos |
| `0x1005` | GetStorageInfo | Nome, capacidade e espaço livre |
| `0x1007` | GetObjectHandles | Identificadores dos filhos de uma pasta |
| `0x1008` | GetObjectInfo | Nome, formato, tamanho e datas de um item |
| `0x1009` | GetObject | Baixa o conteúdo |
| `0x100B` | DeleteObject | Apaga |
| `0x100C` | SendObjectInfo | Anuncia o arquivo ou a pasta a ser criada |
| `0x100D` | SendObject | Envia o conteúdo |
| `0x1015` | GetDevicePropValue | Nome amigável do aparelho |
| `0x9803` | GetObjectPropValue | Tamanho de 64 bits para arquivos acima de 4 GiB |
| `0x9804` | SetObjectPropValue | Renomear |

Antes de usar qualquer operação opcional, o app confere se ela aparece em
`GetDeviceInfo.operationsSupported`.

## Strings e datas

Strings PTP são: **1 byte** com a quantidade de unidades UTF-16 (incluindo o terminador
nulo), seguido dos code units. String vazia é um único byte zero. Um nome não cabe em mais
de 254 unidades.

Datas vêm como `YYYYMMDDThhmmss`, opcionalmente com fração de segundo e com sufixo `Z` para
UTC. Sem sufixo, é hora local do aparelho — na prática a mesma do Mac.

## As armadilhas

Estes são os detalhes que quebram uma implementação ingênua. Todos estão tratados.

### 1. O cabeçalho da fase de dados não pode viajar sozinho

Ao enviar (`SendObject`), é tentador escrever os 12 bytes do cabeçalho e depois o arquivo.
Não funciona: 12 bytes é menor que o tamanho máximo de pacote do *endpoint*, então o USB
trata isso como **pacote curto**, que significa "fim da transferência". O aparelho conclui
que o arquivo tem zero byte.

O cabeçalho precisa ir no mesmo pacote que o início do conteúdo, e toda escrita intermediária
precisa ser múltiplo do tamanho de pacote do *endpoint*.

### 2. O pacote de tamanho zero no fim

Se o total enviado for múltiplo exato do tamanho de pacote, o aparelho fica esperando mais
dados indefinidamente. É preciso terminar com um pacote de comprimento zero para sinalizar
o fim da transferência.

### 3. Arquivos acima de 4 GiB

O campo de comprimento do container tem 32 bits. Para conteúdos maiores, o valor
`0xFFFFFFFF` significa "comprimento indefinido": a leitura vai até chegar um pacote curto.
O app detecta esse caso tanto ao receber quanto ao enviar.

Além disso, o `ObjectCompressedSize` do `GetObjectInfo` também tem 32 bits. Quando ele vem
saturado, o tamanho real é pedido pela propriedade `ObjectSize` (`0xDC04`), que é de 64 bits.

### 4. A resposta pode vir colada nos dados

Se o tamanho da fase de dados for múltiplo do tamanho de pacote, uma única leitura pode
trazer o fim dos dados **e** o container de resposta. O leitor guarda o excedente em um
buffer de sobra, consumido na leitura seguinte.

### 5. Pacotes de tamanho zero no meio do caminho

Uma leitura pode devolver zero byte — é o terminador de uma transferência anterior. O
leitor ignora e tenta de novo, algumas vezes, antes de considerar erro.

### 6. A raiz de um armazenamento

Em `GetObjectHandles` e em `SendObjectInfo`, o identificador de pasta pai `0xFFFFFFFF`
significa "raiz do armazenamento". O AOSP converte esse valor para `0` internamente, mas
espera receber `0xFFFFFFFF`.

### 7. `OpenSession` usa transação zero

A especificação exige que o `OpenSession` use o ID de transação `0`. O contador reinicia
depois disso. Se o aparelho responder `SessionAlreadyOpen` (`0x201E`), está tudo bem — a
sessão anterior sobreviveu e pode ser usada.

## Diagnóstico

O modo `--scan` imprime o barramento inteiro com as classes de interface de cada
dispositivo e marca qual expõe MTP:

```bash
"build/Switch Mac.app/Contents/MacOS/SwitchMac" --scan
```

Dentro do app, **Dispositivo → Diagnóstico…** mostra o histórico. Ligando "Registro
detalhado do protocolo" em **Ajustes**, cada comando e cada resposta são registrados com
código e ID de transação — é o que resolve um caso de aparelho que se comporta fora do
padrão.

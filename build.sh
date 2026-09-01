#!/bin/bash
#
# Compila o Switch Mac e monta o pacote "Switch Mac.app" pronto para uso.
#
# Se houver um certificado "Developer ID Application" instalado, o pacote sai
# assinado com ele e com o hardened runtime — o formato que a notarização da
# Apple exige. Sem o certificado, cai numa assinatura ad-hoc, que só serve para
# rodar nesta máquina.
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Switch Mac"
CONFIG="${1:-release}"

# --- Área de montagem -------------------------------------------------------
# O pacote é montado fora do repositório de propósito. Este projeto costuma
# viver num volume exFAT, que não guarda atributos estendidos; o macOS despeja
# esses dados em arquivos "._*" e o codesign recusa o bundle com o erro "resource
# fork, Finder information, or similar detritus not allowed". Montar em APFS
# (o $TMPDIR) evita isso; no fim o resultado é copiado de volta para build/.

if [ -n "${SWITCHMAC_STAGE:-}" ]; then
    STAGE="$SWITCHMAC_STAGE"      # o release.sh escolhe o diretório e o limpa
    mkdir -p "$STAGE"
else
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/switchmac-build.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
fi

BUNDLE="$STAGE/$APP_NAME.app"

# --- libusb -----------------------------------------------------------------
# A libusb é compilada do fonte, e não instalada pelo Homebrew, por um motivo
# específico: o Homebrew distribui binários compilados para a versão mais nova
# do macOS (hoje, mínimo 26.0). Como a dylib viaja dentro do .app, usar a do
# Homebrew faria o app falhar ao abrir em qualquer macOS anterior — apesar de o
# Info.plist prometer 14.0. Compilando aqui, o alvo fica sob nosso controle.
#
# O resultado é guardado em cache e reaproveitado nas próximas compilações,
# então esse custo (~25s) só aparece na primeira vez.

LIBUSB_VERSION="1.0.30"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
DEPLOYMENT_TARGET="14.0"   # precisa bater com o Package.swift e o Info.plist

# O app é universal: roda nativo em Apple Silicon e em Macs Intel. A libusb
# embutida precisa ter as mesmas fatias, senão o app carrega numa arquitetura e
# quebra na outra.
ARCHS="arm64 x86_64"

# O cache fica fora do repositório de propósito. O libtool, usado pelo "make
# install" da libusb, não põe aspas nos caminhos de destino: instalar em
# ".../Switch Mac/.build/..." faz o caminho ser partido no espaço e o install
# falha. Um diretório sem espaços resolve. Para forçar uma recompilação, apague
# a pasta impressa abaixo.
CACHE_BASE="$HOME/Library/Caches/switch-mac"
case "$CACHE_BASE" in
    *\ *) CACHE_BASE="/tmp/switch-mac-cache" ;;   # se o próprio $HOME tiver espaço
esac
LIBUSB_PREFIX="$CACHE_BASE/libusb-$LIBUSB_VERSION-universal"

if [ ! -f "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" ]; then
    echo "==> compilando libusb $LIBUSB_VERSION (alvo macOS $DEPLOYMENT_TARGET)"
    echo "    cache: $LIBUSB_PREFIX"
    mkdir -p "$CACHE_BASE"

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/libusb-src.XXXXXX")"
    TARBALL="$WORK/libusb.tar.bz2"
    URL="https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2"

    curl -fsSL -o "$TARBALL" "$URL"

    # Confere o fonte antes de compilar: é código de terceiros que vai acabar
    # assinado com o nosso certificado e distribuído no nosso nome.
    if ! echo "$LIBUSB_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "erro: o checksum da libusb não confere. download corrompido ou adulterado." >&2
        echo "      esperado: $LIBUSB_SHA256" >&2
        echo "      obtido:   $(shasum -a 256 "$TARBALL" | awk '{print $1}')" >&2
        rm -rf "$WORK"
        exit 1
    fi

    tar xjf "$TARBALL" -C "$WORK"

    # Cada arquitetura é compilada separadamente e depois unida com o lipo.
    # Passar "-arch arm64 -arch x86_64" de uma vez não serve: o configure roda
    # testes que compilam e executam programas, e eles não sobrevivem a um
    # binário de duas arquiteturas.
    #
    # O --prefix é o mesmo para as duas, e o destino real é separado com
    # DESTDIR. Assim o libusb-1.0.pc já nasce apontando para o diretório final,
    # sem precisar de remendo depois.
    LOG="$WORK/build.log"
    (
        export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        for arch in $ARCHS; do
            echo "### compilando para $arch"
            rm -rf "$WORK/src-$arch"
            cp -R "$WORK/libusb-$LIBUSB_VERSION" "$WORK/src-$arch"
            cd "$WORK/src-$arch"
            ./configure --prefix="$LIBUSB_PREFIX" \
                --host="$arch-apple-darwin" \
                --disable-dependency-tracking --enable-shared --disable-static \
                CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET -O2" \
                LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET"
            make -j"$(sysctl -n hw.ncpu)"
            make install DESTDIR="$WORK/dest-$arch"
        done
    ) >"$LOG" 2>&1 || {
        echo "erro: falha ao compilar a libusb. últimas linhas do log:" >&2
        echo >&2
        tail -25 "$LOG" | sed 's/^/      /' >&2
        echo >&2
        mkdir -p "$CACHE_BASE"
        cp "$LOG" "$CACHE_BASE/libusb-build.log" 2>/dev/null && \
            echo "      log completo: $CACHE_BASE/libusb-build.log" >&2
        rm -rf "$WORK"
        exit 1
    }

    # Uma das instalações vira a base (cabeçalhos e o .pc, que são iguais nas
    # duas); só a dylib precisa ser unida.
    BASE_ARCH="${ARCHS%% *}"
    rm -rf "$LIBUSB_PREFIX"
    mkdir -p "$(dirname "$LIBUSB_PREFIX")"
    ditto "$WORK/dest-$BASE_ARCH$LIBUSB_PREFIX" "$LIBUSB_PREFIX"

    LIPO_INPUTS=""
    for arch in $ARCHS; do
        LIPO_INPUTS="$LIPO_INPUTS $WORK/dest-$arch$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
    done
    # shellcheck disable=SC2086
    lipo -create $LIPO_INPUTS -output "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"

    echo "    libusb pronta: $(lipo -archs "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib")"

    rm -rf "$WORK"
fi

export PKG_CONFIG_PATH="$LIBUSB_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- Compilação -------------------------------------------------------------

echo "==> compilando ($CONFIG, $ARCHS)"

# shellcheck disable=SC2086
SWIFT_ARCH_FLAGS=""
for arch in $ARCHS; do SWIFT_ARCH_FLAGS="$SWIFT_ARCH_FLAGS --arch $arch"; done

# shellcheck disable=SC2086
swift build -c "$CONFIG" $SWIFT_ARCH_FLAGS
# shellcheck disable=SC2086
BINARY="$(swift build -c "$CONFIG" $SWIFT_ARCH_FLAGS --show-bin-path)/SwitchMac"

# --- Pacote .app ------------------------------------------------------------

echo "==> montando $APP_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"

cp "$BINARY" "$BUNDLE/Contents/MacOS/SwitchMac"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# --- Ícone ------------------------------------------------------------------

echo "==> gerando ícone"
ICONSET="$STAGE/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Tools/GenerateIcon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# --- libusb embutida --------------------------------------------------------
# Copiar a dylib para dentro do pacote deixa o app autocontido: quem receber o
# .app não precisa ter o Homebrew nem a libusb instalados.

DYLIB="$BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"
DYLIB_SRC="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
if [ -f "$DYLIB_SRC" ]; then
    echo "==> embutindo libusb"
    cp "$DYLIB_SRC" "$DYLIB"
    chmod u+w "$DYLIB"
    install_name_tool -id "@executable_path/../Frameworks/libusb-1.0.0.dylib" "$DYLIB"

    # Reescreve todas as referências à libusb do Homebrew no binário.
    otool -L "$BUNDLE/Contents/MacOS/SwitchMac" \
        | awk '/libusb-1\.0/ {print $1}' \
        | while read -r ref; do
            install_name_tool -change "$ref" \
                "@executable_path/../Frameworks/libusb-1.0.0.dylib" \
                "$BUNDLE/Contents/MacOS/SwitchMac"
        done
else
    DYLIB=""
fi

# --- Trava de compatibilidade -----------------------------------------------
# Confere que a dylib embutida aceita a mesma versão de macOS que o Info.plist
# promete. Esse erro já aconteceu uma vez, silenciosamente: a libusb do Homebrew
# exigia macOS 26 enquanto o app anunciava 14, e o resultado seria um .dmg que
# não abre para quase ninguém. O custo de checar é zero; o de não checar é uma
# release quebrada.

# Num binário universal cada fatia carrega a sua própria versão mínima, então
# junta todas e exige que sobre um valor só.
minos_of() {
    otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; f=0}' \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
}

EMBEDDED_MINOS="$(minos_of "$BUNDLE/Contents/MacOS/SwitchMac")"
if [ -n "$DYLIB" ]; then
    DYLIB_MINOS="$(minos_of "$DYLIB")"
else
    DYLIB_MINOS="$DEPLOYMENT_TARGET"
fi
PLIST_MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$BUNDLE/Contents/Info.plist")"

if [ "$DYLIB_MINOS" != "$PLIST_MINOS" ] || [ "$EMBEDDED_MINOS" != "$PLIST_MINOS" ]; then
    echo "erro: as versões mínimas de macOS não batem." >&2
    echo "      Info.plist promete: $PLIST_MINOS" >&2
    echo "      binário do app:     $EMBEDDED_MINOS" >&2
    echo "      libusb embutida:    $DYLIB_MINOS" >&2
    echo >&2
    echo "      distribuir assim gera um app que falha ao abrir em macOS mais" >&2
    echo "      antigos que a maior das três. alinhe DEPLOYMENT_TARGET aqui, o" >&2
    echo "      platforms: do Package.swift e o LSMinimumSystemVersion." >&2
    echo "      (mais de um valor numa linha = as fatias discordam entre si.)" >&2
    exit 1
fi

# As arquiteturas também precisam bater: um app universal com uma libusb só de
# arm64 carrega no Apple Silicon e falha no Intel, que é justamente o caso que
# ninguém testa antes de publicar.
APP_ARCHS="$(lipo -archs "$BUNDLE/Contents/MacOS/SwitchMac" | tr ' ' '\n' | sort | tr '\n' ' ')"
if [ -n "$DYLIB" ]; then
    DYLIB_ARCHS="$(lipo -archs "$DYLIB" | tr ' ' '\n' | sort | tr '\n' ' ')"
    if [ "$APP_ARCHS" != "$DYLIB_ARCHS" ]; then
        echo "erro: as arquiteturas do app e da libusb não batem." >&2
        echo "      app:    $APP_ARCHS" >&2
        echo "      libusb: $DYLIB_ARCHS" >&2
        exit 1
    fi
fi
EXPECTED_ARCHS="$(printf '%s' "$ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ')"
if [ "$APP_ARCHS" != "$EXPECTED_ARCHS" ]; then
    echo "erro: esperava as arquiteturas [$EXPECTED_ARCHS], o app tem [$APP_ARCHS]." >&2
    exit 1
fi

# --- Assinatura -------------------------------------------------------------
# Procura um certificado Developer ID Application. É ele — e não o "Apple
# Development", que só vale para testar localmente — que permite distribuir o
# app fora da Mac App Store.
#
# A assinatura é de dentro para fora: a dylib primeiro, o bundle depois.
# Assinar o bundle antes invalidaria a assinatura ao mexer no conteúdo.
#
# Note que não há arquivo de entitlements. Como a libusb é reassinada aqui com
# o mesmo certificado do app, a validação de biblioteca do hardened runtime
# passa sozinha, sem precisar de disable-library-validation. O acesso USB bruto
# também não exige entitlement: isso só valeria num app em sandbox, e este não
# usa sandbox (nem poderia, sendo distribuído fora da App Store).

if [ -n "${SWITCHMAC_SIGN_ID:-}" ]; then
    SIGN_ID="$SWITCHMAC_SIGN_ID"
else
    # Pode haver certificados de mais de um time no Chaveiro. Escolher um
    # sozinho seria um tiro no escuro: assinar com o time errado só falha lá na
    # frente, na notarização, com uma mensagem pouco clara. Melhor parar aqui.
    FOUND="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' || true)"
    COUNT="$(printf '%s' "$FOUND" | grep -c . || true)"

    if [ "$COUNT" -gt 1 ]; then
        echo "erro: há mais de um certificado Developer ID Application:" >&2
        printf '%s\n' "$FOUND" | sed 's/^/      /' >&2
        echo >&2
        echo "      diga qual usar (o nome inteiro entre aspas):" >&2
        echo "      SWITCHMAC_SIGN_ID=\"Developer ID Application: ...\" ./build.sh" >&2
        exit 1
    fi

    SIGN_ID="$(printf '%s' "$FOUND" | awk -F'\"' '{print $2}')"
fi

# O codesign não aceita xattrs no bundle; limpa por precaução.
xattr -cr "$BUNDLE" 2>/dev/null || true

if [ -n "$SIGN_ID" ]; then
    echo "==> assinando com Developer ID"
    echo "    $SIGN_ID"
    [ -n "$DYLIB" ] && codesign --force --timestamp --options runtime \
        --sign "$SIGN_ID" "$DYLIB"
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_ID" "$BUNDLE"

    codesign --verify --strict --deep --verbose=2 "$BUNDLE"
    SIGNED_FOR_RELEASE=1
else
    echo "==> assinando (ad-hoc)"
    echo "    aviso: nenhum certificado Developer ID Application encontrado."
    echo "    o app roda nesta máquina, mas outro Mac vai barrar no Gatekeeper."
    [ -n "$DYLIB" ] && codesign --force --sign - "$DYLIB"
    codesign --force --sign - "$BUNDLE"
    SIGNED_FOR_RELEASE=0
fi

# --- Entrega ----------------------------------------------------------------

mkdir -p "$ROOT/build"
rm -rf "$ROOT/build/$APP_NAME.app"
ditto "$BUNDLE" "$ROOT/build/$APP_NAME.app"

echo
echo "pronto: $ROOT/build/$APP_NAME.app"
echo "abra com:  open \"$ROOT/build/$APP_NAME.app\""
if [ "$SIGNED_FOR_RELEASE" = "0" ]; then
    echo
    echo "para distribuir no GitHub, rode ./release.sh (exige Developer ID)."
fi

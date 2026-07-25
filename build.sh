#!/bin/bash
#
# Compila o Switch Mac e monta o pacote "Switch Mac.app" pronto para uso.
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Switch Mac"
BUNDLE="$ROOT/build/$APP_NAME.app"
CONFIG="${1:-release}"

# --- Dependências -----------------------------------------------------------

if ! command -v brew >/dev/null 2>&1; then
    echo "erro: o Homebrew é necessário para instalar a libusb." >&2
    echo "      instale em https://brew.sh e rode este script de novo." >&2
    exit 1
fi

if ! brew list --versions libusb >/dev/null 2>&1; then
    echo "==> instalando libusb (dependência de acesso USB)"
    brew install libusb
fi

LIBUSB_PREFIX="$(brew --prefix libusb)"
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- Compilação -------------------------------------------------------------

echo "==> compilando ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/SwitchMac"

# --- Pacote .app ------------------------------------------------------------

echo "==> montando $APP_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"

cp "$BINARY" "$BUNDLE/Contents/MacOS/SwitchMac"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# --- Ícone ------------------------------------------------------------------

echo "==> gerando ícone"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Tools/GenerateIcon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# --- libusb embutida --------------------------------------------------------
# Copiar a dylib para dentro do pacote deixa o app autocontido: quem receber o
# .app não precisa ter o Homebrew nem a libusb instalados.

DYLIB_SRC="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
if [ -f "$DYLIB_SRC" ]; then
    echo "==> embutindo libusb"
    cp "$DYLIB_SRC" "$BUNDLE/Contents/Frameworks/"
    chmod u+w "$BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"
    install_name_tool -id "@executable_path/../Frameworks/libusb-1.0.0.dylib" \
        "$BUNDLE/Contents/Frameworks/libusb-1.0.0.dylib"

    # Reescreve todas as referências à libusb do Homebrew no binário.
    otool -L "$BUNDLE/Contents/MacOS/SwitchMac" \
        | awk '/libusb-1\.0/ {print $1}' \
        | while read -r ref; do
            install_name_tool -change "$ref" \
                "@executable_path/../Frameworks/libusb-1.0.0.dylib" \
                "$BUNDLE/Contents/MacOS/SwitchMac"
        done
fi

# --- Assinatura -------------------------------------------------------------
# Assinatura ad-hoc: suficiente para o app rodar nesta máquina sem alertas de
# binário corrompido. Para distribuir para outras pessoas é preciso um
# certificado Developer ID e notarização.

echo "==> assinando (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || \
    echo "aviso: não foi possível assinar o pacote; o app ainda deve abrir."

echo
echo "pronto: $BUNDLE"
echo "abra com:  open \"$BUNDLE\""

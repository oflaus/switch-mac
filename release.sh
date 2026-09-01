#!/bin/bash
#
# Gera o "Switch Mac.dmg" assinado, notarizado e grampeado, pronto para anexar
# numa Release do GitHub.
#
# Pré-requisitos, feitos uma vez só:
#
#   1. Um certificado "Developer ID Application" instalado no Chaveiro.
#      Crie em https://developer.apple.com/account/resources/certificates
#      (ou no Xcode: Settings → Accounts → Manage Certificates → +).
#
#   2. Uma credencial do notarytool guardada no Chaveiro. Há dois caminhos.
#
#      Com uma chave da App Store Connect API (arquivo AuthKey_XXX.p8):
#
#        xcrun notarytool store-credentials "switchmac" \
#            --key "/caminho/AuthKey_XXXXXXXXXX.p8" \
#            --key-id "XXXXXXXXXX" \
#            --issuer "00000000-0000-0000-0000-000000000000"
#
#      O key-id é o trecho do nome do arquivo. O issuer é um UUID que fica em
#      App Store Connect → Usuários e Acesso → Integrações → App Store Connect
#      API, no topo da lista de chaves.
#
#      Ou com Apple ID e senha de app:
#
#        xcrun notarytool store-credentials "switchmac" \
#            --apple-id "seu@email.com" \
#            --team-id "SEUTEAMID" \
#            --password "senha-de-app"
#
#      A senha de app é gerada em https://account.apple.com → Segurança →
#      Senhas específicas do app. Não é a senha do seu Apple ID.
#
#      Feito isso, a credencial vive no Chaveiro e o .p8 não precisa mais ficar
#      acessível no disco. O time do certificado do passo 1 e o time desta
#      credencial precisam ser o mesmo, senão a notarização recusa o envio.
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP_NAME="Switch Mac"
PROFILE="${SWITCHMAC_NOTARY_PROFILE:-switchmac}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/$APP_NAME $VERSION.dmg"

# --- Checagens antecipadas --------------------------------------------------
# Vale falhar aqui, antes de gastar uma compilação inteira.

FOUND="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' || true)"
COUNT="$(printf '%s' "$FOUND" | grep -c . || true)"

if [ -n "${SWITCHMAC_SIGN_ID:-}" ]; then
    SIGN_ID="$SWITCHMAC_SIGN_ID"
elif [ "$COUNT" -gt 1 ]; then
    echo "erro: há mais de um certificado Developer ID Application:" >&2
    printf '%s\n' "$FOUND" | sed 's/^/      /' >&2
    echo >&2
    echo "      assinar com o time errado faz a notarização falhar. diga qual usar:" >&2
    echo "      SWITCHMAC_SIGN_ID=\"Developer ID Application: ...\" ./release.sh" >&2
    exit 1
else
    SIGN_ID="$(printf '%s' "$FOUND" | awk -F'\"' '{print $2}')"
fi

if [ -z "$SIGN_ID" ]; then
    echo "erro: nenhum certificado \"Developer ID Application\" no Chaveiro." >&2
    echo >&2
    echo "      o certificado \"Apple Development\" NÃO serve para distribuir." >&2
    echo "      crie o Developer ID em:" >&2
    echo "      https://developer.apple.com/account/resources/certificates" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "erro: credencial \"$PROFILE\" do notarytool não encontrada." >&2
    echo >&2
    echo "      guarde uma com a chave da App Store Connect API:" >&2
    echo "      xcrun notarytool store-credentials \"$PROFILE\" \\" >&2
    echo "          --key \"/caminho/AuthKey_XXXXXXXXXX.p8\" \\" >&2
    echo "          --key-id \"XXXXXXXXXX\" --issuer \"<uuid-do-issuer>\"" >&2
    echo >&2
    echo "      ou com Apple ID e senha de app:" >&2
    echo "      xcrun notarytool store-credentials \"$PROFILE\" \\" >&2
    echo "          --apple-id \"seu@email.com\" --team-id \"SEUTEAMID\" \\" >&2
    echo "          --password \"senha-de-app\"" >&2
    exit 1
fi

# --- Compilação e assinatura ------------------------------------------------
# O build.sh monta em APFS e assina com o Developer ID. Reaproveitamos a área
# de montagem dele para gerar o .dmg longe do exFAT.

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/switchmac-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

SWITCHMAC_STAGE="$STAGE" SWITCHMAC_SIGN_ID="$SIGN_ID" "$ROOT/build.sh" release

APP="$STAGE/$APP_NAME.app"

# --- Notarização do .app ----------------------------------------------------
# O app é notarizado e grampeado ANTES de entrar no .dmg, e não só depois.
#
# Grampear apenas o .dmg não basta: assim que a pessoa arrasta o app para a
# pasta Aplicativos, ele sai da imagem sem ticket próprio, e o Gatekeeper passa
# a depender de uma consulta online à Apple na primeira abertura. Quem estiver
# sem internet nesse momento vê o app ser bloqueado. Com o ticket dentro do
# .app, a verificação funciona offline.
#
# São duas idas ao serviço da Apple, uma para o app e outra para a imagem.

notarize() {   # notarize <arquivo>
    if ! xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait; then
        echo >&2
        echo "erro: a notarização falhou. para ver o motivo exato:" >&2
        echo "      xcrun notarytool history --keychain-profile \"$PROFILE\"" >&2
        echo "      xcrun notarytool log <id-do-envio> --keychain-profile \"$PROFILE\"" >&2
        exit 1
    fi
}

echo "==> notarizando o app (pode demorar alguns minutos)"
# O serviço não aceita um bundle solto: vai zipado. O .zip é só o transporte,
# o que importa é o ticket que volta e é grampeado no .app.
ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
notarize "$STAGE/app.zip"

echo "==> grampeando o ticket no app"
xcrun stapler staple "$APP"

# --- Imagem de disco --------------------------------------------------------
# Uma pasta com o .app e um atalho para /Applications: o arrastar-e-soltar que
# todo mundo já conhece.

echo "==> montando o .dmg"
DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Aplicativos"

mkdir -p "$ROOT/build"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" \
    -ov -format UDZO "$DMG" >/dev/null

# O .dmg também é assinado: sem isso o Gatekeeper avalia só o que está dentro,
# e o usuário ainda vê aviso ao montar a imagem.
echo "==> assinando o .dmg"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# --- Notarização ------------------------------------------------------------
# --wait segura até a Apple responder. Costuma levar de 1 a 5 minutos.

echo "==> notarizando o .dmg (pode demorar alguns minutos)"
notarize "$DMG"

echo "==> grampeando o ticket na imagem"
xcrun stapler staple "$DMG"

# --- Conferência final ------------------------------------------------------
# Vale a pena verificar aqui: é exatamente o veredito que o Mac de quem baixar
# vai dar. "source=Notarized Developer ID" é o resultado esperado.

echo
echo "==> conferindo como o Gatekeeper vai enxergar"
spctl --assess --type open --context context:primary-signature -vv "$DMG" || true

# Confere o que realmente importa: o app dentro da imagem, já com o ticket
# grampeado, que é o que sobra depois que a pessoa arrasta para Aplicativos.
MNT="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*$' | tail -1)"
if [ -n "$MNT" ]; then
    echo
    spctl --assess --type execute -vv "$MNT/$APP_NAME.app" 2>&1 || true
    xcrun stapler validate "$MNT/$APP_NAME.app" 2>&1 || \
        echo "AVISO: o app dentro da imagem está sem ticket grampeado." >&2
    hdiutil detach "$MNT" >/dev/null 2>&1 || true
fi

echo
echo "pronto: $DMG"
echo "anexe esse arquivo numa Release em https://github.com/oflaus/switch-mac/releases"

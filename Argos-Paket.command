#!/bin/bash
# ───────────────────────────────────────────────────────────
#  Argos – sauberes Weitergabe-Paket bauen
#
#  Baugleich mit Zerberus-Paket.command. Der Anlass dort (30.07.2026):
#  Ein mit dem Finder gepacktes ZIP ging an einen Prüfer — darin steckte
#  die ECHTE Datenbank, während .env.example und .gitignore FEHLTEN,
#  weil der Finder versteckte Dateien ausließ. Genau falsch herum.
#
#  Dieses Skript macht es andersherum und prüft das Ergebnis nach:
#    RAUS: data/ (Datenbank!), Wissen/, zeichen/, .claude/, .env, .venv/,
#          .git/, staticfiles/, __pycache__, *.pyc, .DS_Store, ._*
#    REIN: .env.example, .dockerignore, .gitignore, Dockerfile, compose …
#
#  Der Wächter am Ende ist der eigentliche Zweck: Findet er eine .env,
#  eine Datenbank oder einen Wissen-Ordner im fertigen Paket, wird es
#  GELÖSCHT statt ausgeliefert.
# ───────────────────────────────────────────────────────────

QUELLE="$HOME/Code/Firma/argos"
ABLAGE="$HOME/Desktop"

clear
echo "════════════════════════════════════════════════"
echo "   📦  Argos – Weitergabe-Paket"
echo "════════════════════════════════════════════════"
echo ""

cd "$QUELLE" 2>/dev/null || {
  echo "   ⚠️  $QUELLE gibt es nicht."; read -n 1 -s -r; exit 1; }

VERSION=$(grep VERSION core/version.py | tail -1 | cut -d'"' -f2)
ZIEL="$ABLAGE/argos-$VERSION.zip"
echo "   Quelle:  $QUELLE"
echo "   Version: $VERSION"
echo "   Ziel:    $ZIEL"
echo ""

rm -f "$ZIEL"

# -X lässt macOS-Zusatzattribute weg; __MACOSX entsteht nur beim Finder.
echo "   📦  Packen …"
zip -r -q -X "$ZIEL" . \
  -x 'data/*' 'data' \
     'Wissen/*' 'Wissen' \
     'zeichen/*' 'zeichen' \
     '.claude/*' '.claude' \
     '.env' \
     '.venv/*' \
     '.git/*' \
     'staticfiles/*' \
     '*__pycache__/*' '*.pyc' \
     '.DS_Store' '*/.DS_Store' \
     '._*' '*/._*' \
     '*@eaDir/*' \
  || { echo "   ⚠️  Packen fehlgeschlagen."; read -n 1 -s -r; exit 1; }

# ── Der Wächter ────────────────────────────────────────────
echo "   🔍  Paket prüfen …"
INHALT=$(unzip -Z1 "$ZIEL")
FEHLER=0

verboten() {   # verboten <muster> <klartext>
  local treffer
  treffer=$(echo "$INHALT" | grep -E "$1" || true)
  if [ -n "$treffer" ]; then
    echo ""
    echo "   ⛔  $2 im Paket:"
    echo "$treffer" | sed 's/^/        /' | head -5
    FEHLER=1
  fi
}
verboten '(^|/)\.env$'        "Zugangsdaten (.env)"
verboten '\.sqlite3'          "Datenbank"
verboten '^Wissen/'           "interne Notizen"
verboten '__MACOSX'           "macOS-Beilagen"
verboten '(^|/)\.DS_Store$'   "Finder-Reste"
verboten '__pycache__'        "Bytecode"

noetig() {     # noetig <datei>
  if ! echo "$INHALT" | grep -qx "$1"; then
    echo "   ⚠️  FEHLT im Paket: $1"; FEHLER=1
  fi
}
noetig ".env.example"
noetig ".dockerignore"
noetig ".gitignore"
noetig "Dockerfile"
noetig "docker-compose.yml"
noetig "entrypoint.sh"
noetig "requirements.txt"
noetig "README.md"

if [ "$FEHLER" -ne 0 ]; then
  rm -f "$ZIEL"
  echo ""
  echo "════════════════════════════════════════════════"
  echo "   ⛔  Paket wurde GELÖSCHT statt ausgeliefert."
  echo "       Lieber kein Paket als eines mit deinen Daten."
  echo "════════════════════════════════════════════════"
  echo ""
  read -n 1 -s -r -p "   (beliebige Taste zum Schließen)"; echo ""; exit 1
fi

ANZ=$(echo "$INHALT" | grep -vc '/$')
GR=$(( $(stat -f%z "$ZIEL") / 1024 ))
echo "   ✅  $ANZ Dateien, ${GR} KB — keine .env, keine Datenbank, keine Notizen"
echo ""
echo "   Enthalten sind unter anderem:"
echo "$INHALT" | grep -E '^(\.env\.example|\.dockerignore|\.gitignore|Dockerfile|docker-compose\.yml|entrypoint\.sh|README\.md|CHANGELOG\.md|manage\.py|requirements\.txt)$' \
  | sed 's/^/      /'
echo ""
echo "════════════════════════════════════════════════"
echo "   ✅  Liegt auf dem Schreibtisch:"
echo "       argos-$VERSION.zip"
echo ""
echo "   Der Empfänger braucht zusätzlich eine eigene .env —"
echo "   Vorlage ist .env.example, Anleitung in der README."
echo "════════════════════════════════════════════════"
echo ""
read -n 1 -s -r -p "   (beliebige Taste zum Schließen)"
echo ""

#!/bin/bash
# ───────────────────────────────────────────────────────────
#  Zerberus – Übertragen UND bauen, in einem Vorgang (über SSH)
#
#  Warum zusammen: Am 29.07. lief ein Rebuild in ein noch laufendes rsync
#  hinein. Im Bild lag die neue urls.py neben der alten views.py, und der
#  Container kam in die Neustart-Schleife. Hier ist das ausgeschlossen —
#  gebaut wird ERST, wenn alle Prüfsummen stimmen. Sonst bricht es ab.
#
#  Warum SSH statt SMB: Über SMB fragt der Mac für jede der ~70 Dateien
#  mehrfach über den Tunnel nach. Bei 355 ms Verzögerung sind das Minuten
#  reinen Wartens, und irgendwann reißt es ab. Hier geht EIN gepackter Strom
#  durch EINE Verbindung. Die Freigabe „docker" muss nicht eingebunden sein.
#
#  Warum drei SSH-Sitzungen und nicht eine:
#    sudo verlangt auf der NAS ein Terminal (ssh -t). Über ein Terminal darf
#    aber kein tar-Strom laufen — die Zeilenumbruch-Umwandlung verstümmelt
#    ihn. Also: erst das Paket ohne Terminal hochladen, dann mit Terminal
#    entpacken, dann bauen. Das Passwort kommt jedes Mal aus dem Schlüsselbund.
#
#  Sicherheit:
#    * Die .env wird NIE mitgeschickt — beim Packen ausgeschlossen UND vor
#      dem Senden im Inhaltsverzeichnis geprüft. Findet sich dort eine,
#      bricht das Skript ab, bevor ein Byte rausgeht.
#    * data/ bleibt unangetastet — dort liegt die Datenbank.
#    * Entpackt wird erst, wenn das Paket vollständig oben liegt. Ein
#      Abbruch während der Übertragung lässt die NAS unverändert.
#    * Entpacken überschreibt, löscht aber nichts (wie rsync ohne --delete).
#
#  Passwort einmalig im Schlüsselbund hinterlegen:
#     security add-generic-password -s mailsort-deploy -a deploy -w
# ───────────────────────────────────────────────────────────

# ── HIER EINTRAGEN ─────────────────────────────────────────
NAS_USER="mailsort-deploy"
NAS_HOST="192.168.100.2"
ZIEL="/volume1/docker/mailsort"
QUELLE="$HOME/Code/Firma/mailsort"
CONTAINER="mailsort-taiji"
BESITZER="1026:101"          # DSM-Benutzer + Gruppe administrators
SCHLUESSEL_DIENST="mailsort-deploy"
SCHLUESSEL_KONTO="deploy"
# ───────────────────────────────────────────────────────────

FERNPAKET="/tmp/zerberus-sync-$$.tgz"   # /tmp gibt es auf DSM immer und ist
                                        # beschreibbar — ein Heimatverzeichnis
                                        # hat ein DSM-Benutzer nur, wenn der
                                        # Dienst „Benutzer-Heim" aktiv ist.

AUS=(--exclude=./.env --exclude=./.git --exclude=./.venv --exclude=./data
     --exclude=./staticfiles --exclude='__pycache__' --exclude='*.pyc'
     --exclude='._*' --exclude='.DS_Store')

SSH_OPT="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"

# ── Laufsperre ─────────────────────────────────────────────
# Zwei gleichzeitige Durchgänge kommen sich ins Gehege: Sie schreiben
# dasselbe Paket, laden gegeneinander hoch und bauen womöglich einen
# halb übertragenen Stand. mkdir ist dafür der richtige Riegel — es ist
# atomar, im Gegensatz zu „Datei da? dann anlegen".
SPERRE="/tmp/zerberus-sync.lock"
abbruch_mktemp() {
  echo ""
  echo "   ✗ Konnte keine Arbeitsdatei in /tmp anlegen."
  echo "     Sehr wahrscheinlich liegen dort Leichen eines abgebrochenen"
  echo "     Laufs. Das räumt sie weg:"
  echo ""
  echo "       rm -f /tmp/zerberus-*XXXXXX*"
  echo ""
  rmdir "$SPERRE" 2>/dev/null
  exit 1
}
if ! mkdir "$SPERRE" 2>/dev/null; then
  echo ""
  echo "   ✗ Es läuft bereits ein Durchgang (Sperre: $SPERRE)."
  echo ""
  echo "     Läuft wirklich noch einer? Dann in dessen Fenster Strg-C."
  echo "     Ist keiner mehr da, war es ein Abbruch — dann:"
  echo ""
  echo "       rmdir $SPERRE"
  echo ""
  exit 1
fi

# ⚠️ Die X-Platzhalter MÜSSEN am Ende stehen. Auf macOS (BSD-mktemp) ersetzt
# eine Vorlage mit Endung — /tmp/zerberus-paket-XXXXXX.tgz — die X gar nicht,
# sondern legt die Datei wörtlich so an. Der ZWEITE Lauf scheitert dann mit
# „File exists", mktemp liefert nichts, und das Skript arbeitet mit einer
# LEEREN Pfadvariablen weiter. Weil die Leiche liegen bleibt, scheitert danach
# jeder weitere Start — nicht nur der zweite. Genau so am 03.08.2026 passiert:
# Lauf hing bei stehendem VPN, Neustart, seitdem ging gar nichts mehr.
PAKET=$(mktemp "/tmp/zerberus-paket-XXXXXX") || abbruch_mktemp
MITSCHRIFT=$(mktemp "/tmp/zerberus-mit-XXXXXX") || abbruch_mktemp
SKRIPT=$(mktemp "/tmp/zerberus-lauf-XXXXXX") || abbruch_mktemp
NASSUM=$(mktemp "/tmp/zerberus-nas-XXXXXX") || abbruch_mktemp
LOKSUM=$(mktemp "/tmp/zerberus-lok-XXXXXX") || abbruch_mktemp
trap 'rm -f "$PAKET" "$MITSCHRIFT" "$SKRIPT" "$NASSUM" "$LOKSUM"; rmdir "$SPERRE" 2>/dev/null' EXIT

# Zeigt bei einem Fehlschlag, was die NAS wirklich gesagt hat. Das Passwort
# wird dabei herausgefiltert — und es steht nie in einer Befehlszeile.
zeige_mitschrift() {
  echo ""
  echo "   ── Was die NAS gemeldet hat ─────────────────────"
  if [ -s "$MITSCHRIFT" ]; then
    PW_FILTER="$LETZTES_PW" awk 'ENVIRON["PW_FILTER"] == "" || index($0, ENVIRON["PW_FILTER"]) == 0' \
      "$MITSCHRIFT" | tr -d '\r' | tail -20 | sed 's/^/   /'
  else
    echo "   (die Mitschrift ist leer — die Verbindung kam nicht zustande)"
  fi
  echo "   ─────────────────────────────────────────────────"
}

ende() {   # ende <code> <zeile…>
  local code=$1; shift
  echo ""
  echo "════════════════════════════════════════════════"
  for z in "$@"; do echo "   $z"; done
  echo "════════════════════════════════════════════════"
  echo ""
  read -n 1 -s -r -p "   (beliebige Taste zum Schließen)"
  echo ""
  exit "$code"
}

# ueber_ssh <fernbefehl> <modus> [datei-auf-stdin]
#   modus "still"    – Ausgabe nur in die Mitschrift (Prüfsummen)
#   modus "sichtbar" – Ausgabe auch auf den Schirm (Bau-Fortschritt)
#   Mit Datei auf stdin wird OHNE Terminal gearbeitet (sonst wird der Strom
#   verstümmelt); ohne Datei MIT Terminal, damit sudo nach dem Passwort
#   fragen kann.
ueber_ssh() {
  local fern="$1" modus="$2" strom="$3"
  if [ -n "$strom" ]; then
    printf 'set -o pipefail\ncat %q | ssh %s %q %q\n' \
           "$strom" "$SSH_OPT" "$NAS_USER@$NAS_HOST" "$fern" > "$SKRIPT"
  else
    printf 'set -o pipefail\nssh -t %s %q %q\n' \
           "$SSH_OPT" "$NAS_USER@$NAS_HOST" "$fern" > "$SKRIPT"
  fi

  local pw
  pw=$(security find-generic-password -s "$SCHLUESSEL_DIENST" -a "$SCHLUESSEL_KONTO" -w 2>/dev/null)
  if [ -z "$pw" ]; then
    echo "   ℹ️  Kein Schlüsselbund-Eintrag → Passwort bitte eingeben."
    bash "$SKRIPT" 2>&1 | tee -a "$MITSCHRIFT"
    return "${PIPESTATUS[0]}"
  fi
  LETZTES_PW="$pw"
  # Ein haengender Schritt soll nach Minuten auffallen, nicht nach einer
  # halben Stunde. Nur der Bau darf lange dauern.
  local zeit=240; [ "$modus" = "bau" ] && zeit=1800
  export DEPLOY_PW="$pw" DEPLOY_SKRIPT="$SKRIPT" DEPLOY_MIT="$MITSCHRIFT" \
         DEPLOY_MODUS="$modus" DEPLOY_TIMEOUT="$zeit"
  /usr/bin/expect <<'EXP'
set timeout $env(DEPLOY_TIMEOUT)
set pw   $env(DEPLOY_PW)
set skr  $env(DEPLOY_SKRIPT)
set mit  $env(DEPLOY_MIT)
if {$env(DEPLOY_MODUS) eq "still"} { log_user 0 }
log_file -a $mit
spawn bash $skr
expect {
  -re {(?i)(passwor|kennwor)[^\r\n]{0,40}:}  { send "$pw\r"; exp_continue }
  eof
}
catch wait ergebnis
exit [lindex $ergebnis 3]
EXP
}

clear
echo "════════════════════════════════════════════════"
echo "   📤  Zerberus – Übertragen und bauen"
echo "════════════════════════════════════════════════"
echo ""
cd "$QUELLE" 2>/dev/null || ende 1 "⚠️  $QUELLE gibt es nicht."
VERSION=$(grep VERSION core/version.py | tail -1 | cut -d'"' -f2)
echo "   Version: $VERSION"
echo "   Ziel:    $NAS_USER@$NAS_HOST:$ZIEL"

# ── Git-Stand anzeigen ─────────────────────────────────────
# Gepackt wird der ARBEITSSTAND, nicht der letzte Commit. Nicht eingecheckte
# Änderungen gehen also live — landen aber nicht auf GitHub. Dann stimmt
# „was oben liegt" nicht mehr mit „was läuft" überein, und genau das soll
# diese Zeile verhindern. Nur ein Hinweis, kein Riegel: Zum Ausprobieren
# muss man auch mal etwas Uneingechecktes bauen dürfen.
GIT_ZWEIG=$(git branch --show-current 2>/dev/null)
GIT_STAND=$(git rev-parse --short HEAD 2>/dev/null)
GIT_SAUBER=""
if [ -n "$GIT_STAND" ]; then
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    GIT_SAUBER="ja"
    echo "   Git:     $GIT_ZWEIG $GIT_STAND — alles eingecheckt"
  else
    echo "   Git:     $GIT_ZWEIG $GIT_STAND  ⚠️  nicht eingecheckte Änderungen"
    echo "            Die gehen mit live, stehen danach aber nicht auf GitHub."
  fi
fi
echo ""

# ── 1. Leitung ─────────────────────────────────────────────
echo "   🔌  Leitung …"
nc -z -G 8 "$NAS_HOST" 22 2>/dev/null \
  || ende 1 "⚠️  $NAS_HOST antwortet nicht auf Port 22." "VPN an? NAS wach?"
VERZ=$(ping -c 3 -W 2000 "$NAS_HOST" 2>/dev/null | awk -F'/' '/round-trip/ {printf "%.0f", $5}')
echo "   ✅  erreichbar${VERZ:+, Verzögerung ~${VERZ} ms}"
echo ""

# ── 2. Packen, mit Wächter über der .env ───────────────────
echo "   📦  Packen …"
COPYFILE_DISABLE=1 tar czf "$PAKET" "${AUS[@]}" . || ende 1 "⚠️  Packen fehlgeschlagen."
if tar tzf "$PAKET" | grep -qE '(^|/)\.env$'; then
  ende 1 "⛔  ABBRUCH: Im Paket steckt eine .env." \
         "Es wurde nichts gesendet. Das darf nie passieren — bitte melden."
fi
ANZ=$(tar tzf "$PAKET" | grep -vc '/$')
echo "   ✅  $ANZ Dateien, $(( $(stat -f%z "$PAKET") / 1024 )) KB — keine .env drin"
echo ""

# ── 3. Paket hochladen (ohne Terminal, ohne sudo) ──────────
echo "   📡  Übertragen … (bei zäher Leitung gut eine Minute)"
ueber_ssh "rm -f /tmp/zerberus-sync-*.tgz; cat > $FERNPAKET && ls -l $FERNPAKET" still "$PAKET" || { zeige_mitschrift; ende 1 \
  "⚠️  Übertragung abgebrochen." \
  "Auf der NAS wurde nichts entpackt — der alte Stand läuft unverändert weiter." \
  "Häufig: Leitung weg, falsches Passwort, oder /tmp auf der NAS nicht beschreibbar."; }
echo "   ✅  Paket liegt auf der NAS"
echo ""

# ── 4. Entpacken und Prüfsummen holen (EIN sudo-Aufruf) ────
# Auf dieser NAS braucht jeder sudo-Aufruf ~18 s (es wartet auf eine
# DNS-Auflösung, die ins Leere läuft). Deshalb werden die Schritte drüben als
# kleines Skript abgelegt und mit EINEM sudo ausgeführt — aus einer Minute
# Warten wird so einmal Warten. An der NAS muss dafür nichts geändert werden.
echo "   📂  Entpacken und prüfen … (ein sudo-Aufruf, dauert ~20 s)"
# @eaDir: DSM legt neben jeder Datei einen eigenen Indexordner an. Die gibt es
# lokal nicht — ohne diesen Ausschluss meldet der Vergleich lauter Abweichungen,
# die gar keine sind (30.07. genau so passiert).
FIND_AUS="! -name .env ! -path './.git/*' ! -path './data/*' ! -path './staticfiles/*' ! -name '._*' ! -name .DS_Store ! -name '*.pyc' ! -path '*/__pycache__/*' ! -path '*/@eaDir/*' ! -name '*@SynoEAStream'"
FERN4=$(cat <<EOS
cat > /tmp/zerberus-schritt4.sh <<'ZENDE'
set -e
tar xzf $FERNPAKET -C $ZIEL --no-same-owner
chown -R $BESITZER $ZIEL
rm -f $FERNPAKET
cd $ZIEL
echo ---PRUEFSUMMEN---
find . -type f $FIND_AUS -exec md5sum {} ';'
ZENDE
sudo sh /tmp/zerberus-schritt4.sh; rc=\$?; rm -f /tmp/zerberus-schritt4.sh; exit \$rc
EOS
)
ueber_ssh "$FERN4" sichtbar || { zeige_mitschrift; ende 1 \
  "⚠️  Entpacken fehlgeschlagen." \
  "Falsches sudo-Passwort? Kein Schreibrecht auf $ZIEL?" \
  "Der Container läuft unverändert weiter."; }
echo "   ✅  entpackt"
echo ""

# ── 5. Prüfen — und nur bei Gleichheit weiter ──────────────
echo "   🔍  Prüfsummen vergleichen …"
# tr VOR grep: über ein Terminal enden Zeilen mit \r
sed -n '/---PRUEFSUMMEN---/,$p' "$MITSCHRIFT" | tr -d '\r' \
  | grep -Eo '^[0-9a-f]{32}  \./.*$' | sort -u > "$NASSUM"
find . -type f ! -name .env ! -path './.git/*' ! -path './.venv/*' \
     ! -path './data/*' ! -path './staticfiles/*' ! -name '._*' \
     ! -name '.DS_Store' ! -name '*.pyc' ! -path '*/__pycache__/*' \
  | while read -r f; do printf '%s  %s\n' "$(md5 -q "$f")" "$f"; done | sort -u > "$LOKSUM"

NAS_N=$(wc -l < "$NASSUM" | tr -d ' ')
[ "$NAS_N" -eq 0 ] && ende 1 \
  "⚠️  Von der NAS kamen keine Prüfsummen zurück — ES WIRD NICHT GEBAUT." \
  "Übertragen und entpackt wurde vermutlich trotzdem." \
  "Bitte von Hand nachsehen, ob der Stand oben stimmt."

if ! diff -q "$NASSUM" "$LOKSUM" >/dev/null; then
  echo ""
  echo "   Abweichungen (< nur NAS, > nur lokal):"
  diff "$NASSUM" "$LOKSUM" | grep -E '^[<>]' | awk '{print "     " $1, $3}' | head -15
  ende 1 "⚠️  ES WIRD NICHT GEBAUT — genau das hat am 29.07. den Container zerlegt." \
         "Meist genügt: dieses Skript noch einmal laufen lassen."
fi
echo "   ✅  $NAS_N Dateien, alle Prüfsummen gleich"
echo ""

# ── 6. Erst jetzt bauen (ebenfalls EIN sudo-Aufruf) ────────
echo "   🔨  Bauen … (rechnet auf der NAS, durch den Tunnel fließt nur die Anzeige)"
echo ""
FERN6=$(cat <<EOS
cat > /tmp/zerberus-schritt6.sh <<'ZENDE'
set -e
export PATH=/usr/local/bin:\$PATH
cd $ZIEL
docker compose up -d --build
docker image prune -f
docker builder prune -f
echo ---LAUFENDE-VERSION---
docker exec $CONTAINER tail -1 core/version.py
ZENDE
sudo sh /tmp/zerberus-schritt6.sh; rc=\$?; rm -f /tmp/zerberus-schritt6.sh; exit \$rc
EOS
)
ueber_ssh "$FERN6" bau || { zeige_mitschrift; ende 1 \
  "⚠️  Bau fehlgeschlagen — Meldung oben lesen." \
  "Der alte Container läuft in dem Fall unverändert weiter."; }

LAEUFT=$(sed -n '/---LAUFENDE-VERSION---/,$p' "$MITSCHRIFT" | tr -d '\r' \
         | grep -o '"[0-9][0-9.]*"' | tr -d '"' | head -1)
if [ "$LAEUFT" = "$VERSION" ]; then
# ── Auf GitHub schieben ────────────────────────────────────
# ERST nach dem erfolgreichen Bau: Auf GitHub soll stehen, was wirklich
# läuft — nicht ein Stand, der nie gestartet ist.
#
# Ein Fehlschlag hier macht den Durchgang NICHT zum Fehlschlag. Der
# Container läuft dann trotzdem; es fehlt nur die Sicherung, und die holt
# der nächste Lauf nach.
#
# BatchMode=yes: Fragt der Schlüssel nach einer Passphrase, soll das Skript
# abbrechen und nicht stumm auf eine Eingabe warten, die niemand sieht.
GIT_MELDUNG=""
if [ -n "$GIT_STAND" ] && git remote get-url origin >/dev/null 2>&1; then
  echo ""
  echo "   ☁️   Auf GitHub schieben …"
  if GIT_SSH_COMMAND="ssh -o ConnectTimeout=15 -o BatchMode=yes" \
     git push --follow-tags origin "$GIT_ZWEIG" >>"$MITSCHRIFT" 2>&1; then
    if [ -n "$GIT_SAUBER" ]; then
      GIT_MELDUNG="☁️  GitHub steht auf demselben Stand ($GIT_STAND)."
    else
      GIT_MELDUNG="⚠️  GitHub hat $GIT_STAND — die uneingecheckten Änderungen fehlen dort."
    fi
    echo "   ✅  geschoben"
  else
    GIT_MELDUNG="⚠️  Push nach GitHub fehlgeschlagen — es fehlt nur die Sicherung."
    echo "   ⚠️   Push fehlgeschlagen (VPN? Schlüssel?) — der Bau ist trotzdem durch."
  fi
fi

  ende 0 "✅  Version $VERSION läuft." "$GIT_MELDUNG" "" "Oberfläche: http://$NAS_HOST:8642/"
else
  ende 1 "⚠️  Gebaut, aber der Container meldet ${LAEUFT:-unbekannt} statt $VERSION." \
         "Bitte im Container Manager ins Protokoll schauen."
fi

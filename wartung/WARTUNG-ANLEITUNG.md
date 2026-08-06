# Wartungsmodus per .htaccess (kein Plugin)

> Für `umbrella-security.de`. Lag bis 06.08.2026 unter
> `~/Code/Firma/_deploy-tools/` — also auf genau einer Platte und ohne
> Historie. Steht jetzt hier, weil es beim nächsten WordPress-Update wieder
> gebraucht wird und man es sonst genau dann nicht findet.

Sperrt während eines Updates alle Besucher aus **außer deiner IP** — du kannst normal
testen, alle anderen sehen `wartung.html`. Kein Plugin, nichts dauerhaft installiert.

## Der .htaccess-Block

Diese 5 Zeilen kommen **GANZ OBEN** in die `/umbrella/.htaccess` (VOR `# BEGIN WordPress`):

```apache
# === WARTUNGSMODUS AN — nach dem Update wieder ENTFERNEN! ===
RewriteEngine On
RewriteCond %{REMOTE_ADDR} !=217.91.124.225
RewriteRule .* - [R=503,L]
ErrorDocument 503 /wartung.html
# === WARTUNGSMODUS ENDE ===
```

`217.91.124.225` war die öffentliche IP am **23.07.2026** (über VPN/Tailscale-DE).
⚠️ **Diese Zahl ist mit Sicherheit veraltet** — sie ändert sich mit jedem
Anschluss und jedem VPN-Ausgang. Am 06.08. saß Markus über ein anderes VPN in
Taiwan; da stimmte sie schon nicht mehr.
**Vor dem Aktivieren IMMER prüfen**: https://api.ipify.org im Browser öffnen.
Stimmt sie nicht → Zahl im Block ersetzen, sonst sperrst du dich selbst aus.

## Ablauf mit Cyberduck

**Einschalten (Start des Update-Fensters):**
1. `wartung.html` nach `/umbrella/` hochladen.
2. `/umbrella/.htaccess` herunterladen → **Kopie als `.htaccess.backup` sichern** (Sicherheit).
3. Die 5 Zeilen oben in die `.htaccess` einfügen, speichern, hochladen.
4. Kurz testen: Seite in einem anderen Browser/Handy (ohne dein VPN) → muss „Kurz in Wartung" zeigen.
   Bei dir selbst → normale Seite. ✓

**Ausschalten (nach dem Update):**
1. Die 5 Wartungs-Zeilen wieder aus der `.htaccess` löschen (oder `.htaccess.backup` zurückspielen).
2. Hochladen. Fertig — Seite ist wieder für alle offen.

## Reihenfolge im Fenster
1. Wartungsmodus AN (dieser Block)
2. phpMyAdmin → SQL-Dump
3. Updates: 🟢 Yoast/Themes → 🟡 Limit Login/WP 2FA → 🟠 Snippet-Plugin → 🔴 Core 7.0
   (nach 🟠 und 🔴 jeweils Voucher-/Payment-Flow testen)
4. Läuft → Wartungsmodus AUS · Kaputt → Restore → Wartungsmodus AUS

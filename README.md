# Deploy-Skripte

Die Auslieferung von **Zerberus** (Port 8642) und **Argos** (8643) auf die
Synology „Valhalla". Doppelklick im Finder, kein Terminal nötig.

| Skript | Zweck |
|---|---|
| `Zerberus-Sync-und-Bauen.command` | Übertragen **und** bauen, in einem Vorgang |
| `Argos-Sync-und-Bauen.command` | dasselbe für Argos |
| `*-Paket.command` | nur packen, ohne zu senden |

## Warum das ein Repo ist

Bis zum 05.08.2026 lagen diese Dateien nur auf einer Platte. Das Wissen,
**wie** ausgeliefert wird, hatte damit keine Historie — und es steckt eine
Menge davon darin: warum drei SSH-Sitzungen statt einer, warum die
Prüfsummen vor dem Bau verglichen werden, warum die X in `mktemp` am Ende
stehen müssen. Jede dieser Zeilen ist die Narbe eines Abends.

## Arbeitsregel

**Sync macht die KI, Rebuild macht Markus.** Diese Skripte klickt Markus.

## Zugangsdaten

Stehen nirgends in diesen Dateien. Das NAS-Passwort kommt aus dem
macOS-Schlüsselbund:

    security add-generic-password -s mailsort-deploy -a deploy -w

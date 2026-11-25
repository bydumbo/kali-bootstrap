# kali-bootstrap (Kali-Sync Setup)

Automatische Synchronisation ausgewählter Dateien aus `$HOME` zwischen mehreren Kali-Linux-Maschinen über ein privates GitHub-Repository (`kali-sync`) mit gerätegebundenem Deploy Key, Whitelist (`~/.gitignore`), `pre-commit`-Schutz und `systemd`-User-Timer.

- **Kein GitHub-Account-Login auf Kali:** Jedes Gerät erhält einen eigenen SSH-Deploy-Key (`~/.ssh/kali_sync_<hostname>`), der ausschließlich auf das eine private `kali-sync`-Repo zugreifen darf.
- **Dateien bleiben im normalen `$HOME`:** Bare-Repository in `~/.kali-sync` mit `$HOME` als Work-Tree.
- **Whitelist statt Blacklist:** Standardmäßig synchronisiert werden `htb/`, `notes/`, `scripts/`, `.zshrc`, `.tmux.conf` und `.gitignore`. Alles andere (z. B. `~/Downloads/`, `~/.ssh/`, `*.ovpn`, `*.kdbx`, `*.pcap`, `.venv/`) bleibt lokal.

## Schnellstart

1. Auf GitHub einmalig ein leeres, **privates** Repository mit dem Namen `kali-sync` anlegen – ohne `README`, ohne `.gitignore` und ohne Lizenz.
2. Dieses Bootstrap-Repository auf dem ersten Kali-Gerät klonen und in das Verzeichnis wechseln:
   ```bash
   git clone https://github.com/<github-user>/kali-bootstrap
   cd kali-bootstrap
   ```
3. Das idempotente Setup-Skript starten:
   ```bash
   ./setup.sh
   ```
   Beim ersten Lauf legt `./setup.sh` die lokale `config.env` an, fragt `GITHUB_USER` sowie `KEY_MODE` (`plain` bei LUKS-Verschlüsselung, sonst `keychain`) ab und erzeugt den gerätespezifischen SSH-Deploy-Key.
4. Den von `./setup.sh` angezeigten Public Key unter `https://github.com/<github-user>/kali-sync/settings/keys/new` als Deploy Key eintragen, unbedingt **Allow write access** aktivieren und anschließend im Terminal mit Enter bestätigen.
5. Auf jedem weiteren Kali-Gerät die Schritte 2 bis 4 wiederholen. `./setup.sh` erkennt das bereits gefüllte Repository, sichert eventuell kollidierende lokale Dateien (z. B. `~/.zshrc`) automatisch nach `~/.kali-sync-backup/<zeitstempel>/`, checkt den gemeinsamen Stand aus und aktiviert den Timer.

## Befehle

Nach dem Setup (neues Terminal oder `source ~/.zshrc`) stehen folgende Befehle zur Verfügung:

| Befehl | Wirkung |
| --- | --- |
| `kali-sync sync` | Führt einen leisen Sync-Lauf aus (Commit, Pull mit `--rebase --autostash`, Push). Wird regulär vom `systemd`-Timer aufgerufen. |
| `kali-sync now` | Wie `kali-sync sync`, jedoch mit direkter Statusausgabe im Terminal (empfohlen vor dem Zuklappen/Herunterfahren). |
| `kali-sync status` | Zeigt den letzten erfolgreichen Sync (`last_success`), eventuelle letzte Fehlermeldungen, offene Änderungen (`ks status --short`) und den `systemd`-Timer-Status. |
| `kali-sync log` | Zeigt die letzten 50 Zeilen aus `~/.local/state/kali-sync/sync.log` (rotiert automatisch ab 1 MB). |
| `kali-sync add <pfad>` | Ergänzt `<pfad>` direkt über `# END WHITELIST` in `~/.gitignore` (bei verschachtelten Pfaden wie `.config/obsidian` inkl. Elternkette), prüft die Erfassung per `ks check-ignore -v` und committet `~/.gitignore`. |
| `ks <git-befehl>` | Shell-Alias für `git --git-dir=$HOME/.kali-sync --work-tree=$HOME`, um direkt Git-Befehle auf dem Sync-Repo auszuführen (z. B. `ks status`, `ks log`, `ks diff`). |
| `./setup.sh` | Richtet ein Gerät ein oder aktualisiert Skripte, Hooks, Units und Konfiguration idempotent. |
| `./uninstall.sh` | Stoppt/deaktiviert den Timer und entfernt systemd-Units, `~/.local/bin/kali-sync` sowie die `# BEGIN kali-sync`-Blöcke in `~/.zshrc`, `~/.zshrc.local` und `~/.ssh/config`. Lässt `~/.kali-sync`, Deploy Keys und alle Nutzerdaten unangetastet. |

**Hinweis zu `kali-sync add <pfad>`:** Relative Pfade werden immer relativ zu `$HOME` aufgelöst – unabhängig vom aktuellen Arbeitsverzeichnis (z. B. `kali-sync add .config/obsidian` bezieht sich auf `~/.config/obsidian`). Absolute Pfade innerhalb von `$HOME` werden ebenfalls akzeptiert.

## Updates & Entwicklung

- **Werkzeug aktualisieren:** Änderungen im `kali-bootstrap`-Repository auf jedem Kali-Gerät einfach mit folgendem Befehl übernehmen:
  ```bash
  git pull && ./setup.sh
  ```
- **Entwicklung unter Windows:** `.gitattributes` erzwingt `* text=auto eol=lf`, damit alle Bash-Skripte mit LF-Zeilenenden ausgecheckt und committet werden und unter Kali nicht mit `$'\r': command not found` abbrechen.

## Troubleshooting

### Merge- oder Rebase-Konflikt

Automatische Sync-Läufe lösen Konflikte niemals selbst auf und überschreiben keine Daten. Bei einem Konflikt bricht `kali-sync` den Rebase sauber ab (`ks rebase --abort`), meldet den Konflikt per Desktop-Benachrichtigung und pusht nicht.

Manuelle Lösung im Terminal:

```bash
ks status
ks pull --rebase
# Konfliktmarkierungen in den betroffenen Dateien beheben, dann:
ks add <betroffene-datei>
ks rebase --continue
kali-sync now
```

### Gesperrter SSH-Agent (`keychain`-Modus) & Passphrase bei `./setup.sh`

- **Nach dem Systemstart:** Im Modus `KEY_MODE=keychain` liest `kali-sync` `~/.keychain/$(hostname)-sh`. Solange der Schlüssel noch nicht entsperrt wurde, pausiert der Hintergrund-Sync (`Agent gesperrt, übersprungen`, Exit 0, keine Fehler-Benachrichtigung). Sobald ein Terminal geöffnet wird, fragt `keychain` über `~/.zshrc.local` einmalig die Passphrase ab.
- **Mehrfache Passphrase-Abfragen während `./setup.sh`:** Solange noch kein SSH-Agent geladen ist, fragt `ssh` bei `ssh -T`, `git clone`/`fetch` und `push` jeweils erneut nach der Passphrase. Um das zu vermeiden, den Key vor `./setup.sh` einmalig in den Agent laden (z. B. `eval "$(keychain --eval ~/.ssh/kali_sync_$(hostname))"` oder `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/kali_sync_$(hostname)`).

### Offline vs. Auth-Fehler / widerrufener Deploy Key

- **Offline:** Ist das Netzwerk nicht erreichbar, schlägt die Vorprüfung (`ls-remote`) ohne Benachrichtigung fehl, protokolliert „Offline“ und endet mit Exit 0.
- **Auth-Fehler / widerrufener Deploy Key:** Wurde der Deploy Key bei GitHub gelöscht oder fehlen Schreibrechte, meldet `kali-sync` einen Auth-Fehler (`Permission denied` / `Repository not found`) per Benachrichtigung und endet mit Exit 1. Neuen Deploy Key hinterlegen oder Rechte prüfen.
- **Fehlkonfiguriertes Remote:** Nicht-Netzwerkfehler bei `ls-remote` (z. B. fehlendes Remote `origin` oder geänderte URL) können ebenfalls als Offline-Eintrag im Log erscheinen. Bei anhaltendem „Offline“ trotz Internetverbindung `kali-sync log`, `ks remote -v` und `ssh -T kali-sync` prüfen.

### Abgelehnter Commit durch den `pre-commit`-Hook

Der `pre-commit`-Hook in `~/.kali-sync/hooks/pre-commit` blockiert Commits, wenn eine gestagte Datei:

- größer als `MAX_FILE_MB` (Standard: 50 MB) ist,
- einem Secret-Dateinamen entspricht (`id_*`, `*.ovpn`, `*.kdbx`, `*.pem`),
- einen privaten Schlüssel enthält (`BEGIN OPENSSH PRIVATE KEY`), oder
- ein eingebettetes Git-Repository (Gitlink, Mode `160000`) ist.

In diesem Fall setzt `kali-sync` den Index zurück (`ks reset -q`), führt den Pull trotzdem aus und lässt nur den Push aus. Die betroffene Datei aus den freigegebenen Ordnern entfernen oder verschieben (z. B. nach `~/tools/` oder `~/Downloads/`) und anschließend `kali-sync now` ausführen. Erst nach erfolgreichem Push erscheint die Meldung „wieder in Ordnung“.

### Keine Desktop-Benachrichtigungen aus systemd

Wenn `notify-send` im Terminal funktioniert, aber bei Timer-Läufen keine Benachrichtigung erscheint, fehlt dem `systemd`-User-Daemon meist `DBUS_SESSION_BUS_ADDRESS`. `./setup.sh` importiert die Variable automatisch (`systemctl --user import-environment DBUS_SESSION_BUS_ADDRESS`). Bei Bedarf in der laufenden Desktop-Sitzung manuell nachholen:

```bash
systemctl --user import-environment DBUS_SESSION_BUS_ADDRESS DISPLAY
```

### Rotierte GitHub-SSH-Hostkeys (`known_hosts`)

`./setup.sh` pinnt die offiziellen GitHub-SSH-Hostkeys aus `templates/known_hosts_github` in `~/.ssh/known_hosts`. Falls GitHub seine Hostkeys rotiert und `Host key verification failed` auftritt:

1. Aktuelle offizielle GitHub-SSH-Hostkeys in `templates/known_hosts_github` aktualisieren (oder `git pull` im aktualisierten `kali-bootstrap`-Repo).
2. Veraltete `github.com`-Einträge aus `~/.ssh/known_hosts` entfernen (`ssh-keygen -R github.com`).
3. `./setup.sh` erneut ausführen, um die neuen gepinnten Keys einzutragen.

### Diagnose mit `kali-sync log` und `kali-sync status`

Bei unklaren Fehlern zuerst den letzten Zustand und das Protokoll prüfen:

```bash
kali-sync status
kali-sync log
```

Das vollständige Protokoll liegt unter `~/.local/state/kali-sync/sync.log` (ältere Einträge nach Rotation unter `sync.log.1`).

#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'
    C_CYAN=$'\033[0;36m'
    C_YELLOW=$'\033[0;33m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_CYAN=""
    C_YELLOW=""
    C_RESET=""
fi

_TEMP_FILES=()
_LAST_TEMP=""
_HAD_ERROR=0

cleanup() {
    local f=""
    for f in "${_TEMP_FILES[@]}"; do
        if [[ -n "$f" ]]; then
            rm -f -- "$f"
        fi
    done
    _TEMP_FILES=()
}
trap cleanup EXIT

make_temp() {
    _LAST_TEMP="$(mktemp "${TMPDIR:-/tmp}/kali-sync-uninstall.XXXXXX")"
    _TEMP_FILES+=("$_LAST_TEMP")
}

ok() {
    printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

entfernt() {
    printf '%s[ENTFERNT]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
}

aktion() {
    printf '%s[AKTION NÖTIG]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

die() {
    printf 'uninstall.sh: Fehler: %s\n' "$*" >&2
    exit 1
}

step_preflight() {
    local uid=""
    uid="$(id -u)"
    if [[ "$uid" == "0" ]]; then
        die "uninstall.sh darf nicht als root ausgeführt werden."
    fi

    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        die "HOME ist nicht gesetzt oder kein Verzeichnis."
    fi
}

step_systemd() {
    local systemctl_available=0
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl_available=1
    else
        aktion "systemd User-Bus nicht erreichbar – systemd-Schritte übersprungen (Timer ggf. manuell stoppen: systemctl --user disable --now kali-sync.timer)."
    fi

    if (( systemctl_available )); then
        local timer_enabled=0 timer_active=0 stop_failed=0
        if systemctl --user is-enabled kali-sync.timer >/dev/null 2>&1; then
            timer_enabled=1
        fi
        if systemctl --user is-active kali-sync.timer >/dev/null 2>&1; then
            timer_active=1
        fi

        if (( timer_enabled || timer_active )); then
            if (( timer_enabled )); then
                if ! systemctl --user disable --now kali-sync.timer >/dev/null 2>&1; then
                    stop_failed=1
                fi
            elif (( timer_active )); then
                if ! systemctl --user stop kali-sync.timer >/dev/null 2>&1; then
                    stop_failed=1
                fi
            fi
            systemctl --user stop kali-sync.service >/dev/null 2>&1 || true

            if (( stop_failed )); then
                aktion "systemd-Timer konnte nicht vollständig gestoppt/deaktiviert werden: kali-sync.timer"
                _HAD_ERROR=1
            else
                entfernt "systemd-Timer gestoppt und deaktiviert: kali-sync.timer"
            fi
        else
            ok "systemd-Timer bereits inaktiv und deaktiviert: kali-sync.timer"
        fi
    fi

    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local unit_service="${unit_dir}/kali-sync.service"
    local unit_timer="${unit_dir}/kali-sync.timer"
    local units_removed=0
    local unit_file=""

    for unit_file in "$unit_service" "$unit_timer"; do
        if [[ -e "$unit_file" || -L "$unit_file" ]]; then
            if rm -f -- "$unit_file"; then
                entfernt "systemd-Unit entfernt: ${unit_file}"
                units_removed=1
            else
                aktion "systemd-Unit konnte nicht entfernt werden: ${unit_file}"
                _HAD_ERROR=1
            fi
        else
            ok "systemd-Unit nicht vorhanden: ${unit_file}"
        fi
    done

    if (( units_removed && systemctl_available )); then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

step_remove_bin() {
    local bin_file="${HOME%/}/.local/bin/kali-sync"
    if [[ -e "$bin_file" || -L "$bin_file" ]]; then
        if rm -f -- "$bin_file"; then
            entfernt "Sync-Skript entfernt: ${bin_file}"
        else
            aktion "Sync-Skript konnte nicht entfernt werden: ${bin_file}"
            _HAD_ERROR=1
        fi
    else
        ok "Sync-Skript nicht vorhanden: ${bin_file}"
    fi
}

remove_marker_block() {
    local file="$1"
    local strip_trailing_blank="$2"
    local label="$3"
    local tmp="" line="" orig_mode=""
    local in_block=0 found=0 skip_next_blank=0

    if [[ ! -f "$file" ]]; then
        ok "${label}: Datei nicht vorhanden (${file})"
        return 0
    fi

    make_temp
    tmp="$_LAST_TEMP"
    : > "$tmp"

    while IFS= read -r line; do
        if (( ! in_block )) && [[ "$line" == "# BEGIN kali-sync" ]]; then
            in_block=1
            found=1
            skip_next_blank=0
            continue
        fi
        if (( in_block )); then
            if [[ "$line" == "# END kali-sync" ]]; then
                in_block=0
                if (( strip_trailing_blank )); then
                    skip_next_blank=1
                fi
            fi
            continue
        fi
        if (( skip_next_blank )); then
            skip_next_blank=0
            if [[ -z "$line" ]]; then
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    if [[ -n "$line" ]]; then
        if (( ! in_block )) && [[ "$line" == "# BEGIN kali-sync" ]]; then
            in_block=1
            found=1
        elif (( in_block )); then
            if [[ "$line" == "# END kali-sync" ]]; then
                in_block=0
            fi
        else
            printf '%s' "$line" >> "$tmp"
        fi
    fi

    if (( in_block )); then
        aktion "Unvollständiger Marker-Block in ${file} ('# BEGIN kali-sync' ohne '# END kali-sync') – Datei unverändert gelassen."
        _HAD_ERROR=1
        return 0
    fi

    if (( ! found )) || cmp -s -- "$file" "$tmp"; then
        ok "${label}: kein Marker-Block vorhanden (${file})"
        return 0
    fi

    orig_mode="$(stat -L -c '%a' -- "$file")"
    chmod "$orig_mode" -- "$tmp"
    mv -f -- "$tmp" "$file"
    entfernt "${label}: Marker-Block entfernt (${file})"
}

step_shell_configs() {
    remove_marker_block "${HOME%/}/.zshrc" 0 "Shell-Konfiguration"
    remove_marker_block "${HOME%/}/.zshrc.local" 0 "Lokale Shell-Konfiguration"
}

step_ssh_config() {
    remove_marker_block "${HOME%/}/.ssh/config" 1 "SSH-Konfiguration"
}

step_summary() {
    printf '\nHinweis: ~/.kali-sync, ~/.gitignore, Nutzerdaten, ~/.ssh/known_hosts und Deploy Keys (~/.ssh/kali_sync_*) bleiben erhalten.\n'
    printf 'Um den Zugriff dieses Geräts zu sperren, den zugehörigen Deploy Key bei GitHub unter Settings -> Deploy keys löschen.\n'
}

main() {
    step_preflight
    step_systemd
    step_remove_bin
    step_shell_configs
    step_ssh_config
    step_summary

    cleanup
    exit "$_HAD_ERROR"
}

main "$@"

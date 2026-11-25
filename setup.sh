#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
_FILE_CHANGED=0
_KS_CFG_CHANGED=0
BACKUP_DIR=""
_WHITELIST_RULES=()

cleanup() {
    local f=""
    for f in "${_TEMP_FILES[@]}"; do
        if [[ -n "$f" ]]; then
            rm -f -- "$f"
        fi
    done
}
trap cleanup EXIT

make_temp() {
    _LAST_TEMP="$(mktemp "${TMPDIR:-/tmp}/kali-sync-setup.XXXXXX")"
    _TEMP_FILES+=("$_LAST_TEMP")
}

ok() {
    printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

neu() {
    printf '%s[NEU]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
}

aktion() {
    printf '%s[AKTION NÖTIG]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

die() {
    printf 'setup.sh: Fehler: %s\n' "$*" >&2
    exit 1
}

ks() {
    git --git-dir="$HOME/.kali-sync" --work-tree="$HOME" -C "$HOME" "$@"
}

ensure_mode() {
    local path="$1"
    local expected="$2"
    local current=""
    current="$(stat -c '%a' -- "$path")"
    if [[ "$current" != "$expected" ]]; then
        chmod "$expected" -- "$path"
    fi
}

install_file_if_changed() {
    local src="$1"
    local dst="$2"
    local mode="${3:-}"
    local current="" tmp_dst=""
    _FILE_CHANGED=0

    if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s -- "$src" "$dst"; then
        if [[ -n "$mode" ]]; then
            current="$(stat -c '%a' -- "$dst")"
            if [[ "$current" != "$mode" ]]; then
                chmod "$mode" -- "$dst"
                _FILE_CHANGED=1
            fi
        fi
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dst")"
    make_temp
    tmp_dst="$_LAST_TEMP"
    cp -- "$src" "$tmp_dst"
    if [[ -n "$mode" ]]; then
        chmod "$mode" -- "$tmp_dst"
    fi
    mv -f -- "$tmp_dst" "$dst"
    _FILE_CHANGED=1
}

ensure_backup_dir() {
    if [[ -z "$BACKUP_DIR" ]]; then
        local ts="" base="" candidate="" n=1
        ts="$(date +%Y%m%d-%H%M%S)"
        base="${HOME%/}/.kali-sync-backup"
        candidate="${base}/${ts}"
        while [[ -e "$candidate" ]]; do
            candidate="${base}/${ts}-${n}"
            n=$((n + 1))
        done
        mkdir -p -- "$candidate"
        BACKUP_DIR="$candidate"
    fi
}

backup_home_file() {
    local rel="$1"
    local src="${HOME%/}/${rel}"
    ensure_backup_dir
    local dst="${BACKUP_DIR}/${rel}"
    mkdir -p -- "$(dirname -- "$dst")"
    mv -- "$src" "$dst"
}

upsert_marker_block() {
    local file="$1"
    local block="$2"
    local tmp="" line="" in_block=0 replaced=0
    _FILE_CHANGED=0

    make_temp
    tmp="$_LAST_TEMP"

    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if (( ! in_block )) && [[ "$line" == "# BEGIN kali-sync" ]]; then
                in_block=1
                if (( ! replaced )); then
                    printf '%s\n' "$block" >> "$tmp"
                    replaced=1
                fi
                continue
            fi
            if (( in_block )); then
                if [[ "$line" == "# END kali-sync" ]]; then
                    in_block=0
                fi
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"

        if (( in_block )); then
            die "Unvollständiger Marker-Block in ${file} ('# BEGIN kali-sync' ohne '# END kali-sync')."
        fi

        if (( ! replaced )); then
            printf '%s\n' "$block" >> "$tmp"
        fi
    else
        printf '%s\n' "$block" > "$tmp"
    fi

    if [[ -f "$file" && ! -L "$file" ]] && cmp -s -- "$file" "$tmp"; then
        return 0
    fi

    mkdir -p -- "$(dirname -- "$file")"
    mv -f -- "$tmp" "$file"
    _FILE_CHANGED=1
}

remove_marker_block() {
    local file="$1"
    local tmp="" line="" in_block=0 found=0
    _FILE_CHANGED=0

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    make_temp
    tmp="$_LAST_TEMP"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! in_block )) && [[ "$line" == "# BEGIN kali-sync" ]]; then
            in_block=1
            found=1
            continue
        fi
        if (( in_block )); then
            if [[ "$line" == "# END kali-sync" ]]; then
                in_block=0
            fi
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    if (( in_block )); then
        die "Unvollständiger Marker-Block in ${file} ('# BEGIN kali-sync' ohne '# END kali-sync')."
    fi

    if (( ! found )); then
        return 0
    fi

    if cmp -s -- "$file" "$tmp"; then
        return 0
    fi

    mv -f -- "$tmp" "$file"
    _FILE_CHANGED=1
}

file_has_exact_line() {
    local file="$1"
    local needle="$2"
    local line=""
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$needle" ]]; then
            return 0
        fi
    done < "$file"
    return 1
}

set_config_var() {
    local file="$1"
    local name="$2"
    local value="$3"
    local tmp_file="" line="" found=0

    make_temp
    tmp_file="$_LAST_TEMP"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! found )) && [[ "$line" == "${name}="* ]]; then
            printf '%s="%s"\n' "$name" "$value"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$tmp_file"

    if (( ! found )); then
        printf '%s="%s"\n' "$name" "$value" >> "$tmp_file"
    fi

    mv -f -- "$tmp_file" "$file"
}

detect_key_mode_default() {
    local lsblk_out=""
    if command -v lsblk >/dev/null 2>&1 && lsblk_out="$(lsblk -o TYPE 2>/dev/null)"; then
        if grep -Eq '^[[:space:]]*crypt[[:space:]]*$' <<< "$lsblk_out"; then
            printf 'plain\n'
            return 0
        fi
    fi
    printf 'keychain\n'
}

step_preflight() {
    local uid=""
    uid="$(id -u)"
    if [[ "$uid" == "0" ]]; then
        die "setup.sh darf nicht als root ausgeführt werden."
    fi

    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        die "HOME ist nicht gesetzt oder kein Verzeichnis."
    fi

    local dep=""
    for dep in git ssh ssh-keygen systemctl; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            die "Benötigter Befehl fehlt: ${dep}"
        fi
    done

    local sys_out=""
    if ! sys_out="$(systemctl --user show-environment 2>&1)"; then
        die "systemd User-Bus nicht erreichbar (systemctl --user show-environment fehlgeschlagen): ${sys_out}"
    fi

    ok "Vorprüfung erfolgreich (Nutzer, Werkzeuge, systemd --user)."
}

step_config() {
    local boot_cfg="${SCRIPT_DIR}/config.env"
    local example_cfg="${SCRIPT_DIR}/config.env.example"
    local dev_cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/kali-sync"
    local dev_cfg="${dev_cfg_dir}/config.env"
    local boot_created=0

    if [[ -f "$boot_cfg" ]]; then
        :
    elif [[ -f "$dev_cfg" ]]; then
        cp -- "$dev_cfg" "$boot_cfg"
        boot_created=1
        neu "Konfiguration aus Gerätekopie übernommen: ${boot_cfg}"
    elif [[ -f "$example_cfg" ]]; then
        cp -- "$example_cfg" "$boot_cfg"
        boot_created=1
        neu "Konfiguration aus Vorlage angelegt: ${boot_cfg}"
    else
        die "Vorlage nicht gefunden: ${example_cfg}"
    fi

    GITHUB_USER=""
    SYNC_REPO=""
    KEY_MODE=""
    WHITELIST=()
    unset SYNC_INTERVAL

    # shellcheck source=/dev/null
    source "$boot_cfg"

    SYNC_REPO="${SYNC_REPO:-kali-sync}"
    if [[ -z "${SYNC_INTERVAL+x}" ]]; then
        SYNC_INTERVAL="10min"
    fi
    if [[ -z "${SYNC_INTERVAL// /}" || ! "$SYNC_INTERVAL" =~ ^[0-9A-Za-z\ ]+$ ]]; then
        die "Ungültiges SYNC_INTERVAL in ${boot_cfg}: '${SYNC_INTERVAL}' (erlaubt: nicht leer, nur [0-9A-Za-z ])."
    fi

    local user_re='^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$'
    local need_write_user=0 need_write_mode=0 updated_cfg=0

    if [[ -z "$GITHUB_USER" ]]; then
        local input=""
        while true; do
            printf 'GitHub-Benutzername: '
            if ! IFS= read -r input; then
                if [[ -z "$input" ]]; then
                    die "Unerwartetes Eingabeende (EOF) bei der Abfrage von GITHUB_USER."
                fi
            fi
            input="${input%$'\r'}"
            if [[ "$input" =~ $user_re ]]; then
                GITHUB_USER="$input"
                break
            fi
            printf 'Ungültiger GitHub-Benutzername (erlaubt: Buchstaben, Ziffern, Bindestrich, nicht am Anfang, max. 39 Zeichen).\n' >&2
        done
        need_write_user=1
    elif [[ ! "$GITHUB_USER" =~ $user_re ]]; then
        die "Ungültiger GITHUB_USER in ${boot_cfg}: '${GITHUB_USER}'"
    fi

    if [[ -z "$KEY_MODE" ]]; then
        local default_mode="" input=""
        default_mode="$(detect_key_mode_default)"
        while true; do
            printf 'SSH-Key-Modus [plain/keychain] (Default: %s): ' "$default_mode"
            if ! IFS= read -r input; then
                if [[ -z "$input" ]]; then
                    die "Unerwartetes Eingabeende (EOF) bei der Abfrage von KEY_MODE."
                fi
            fi
            input="${input%$'\r'}"
            if [[ -z "$input" ]]; then
                KEY_MODE="$default_mode"
                break
            fi
            if [[ "$input" == "plain" || "$input" == "keychain" ]]; then
                KEY_MODE="$input"
                break
            fi
            printf 'Ungültiger KEY_MODE (erlaubt: plain oder keychain).\n' >&2
        done
        need_write_mode=1
    elif [[ "$KEY_MODE" != "plain" && "$KEY_MODE" != "keychain" ]]; then
        die "Ungültiger KEY_MODE in ${boot_cfg}: '${KEY_MODE}' (erlaubt: plain oder keychain)."
    fi

    if (( need_write_user )); then
        set_config_var "$boot_cfg" "GITHUB_USER" "$GITHUB_USER"
        updated_cfg=1
    fi
    if (( need_write_mode )); then
        set_config_var "$boot_cfg" "KEY_MODE" "$KEY_MODE"
        updated_cfg=1
    fi

    if (( updated_cfg )); then
        neu "Konfiguration aktualisiert: ${boot_cfg}"
    elif (( ! boot_created )); then
        ok "Konfiguration geladen: ${boot_cfg}"
    fi

    local dev_cfg_updated=0
    if [[ -f "$dev_cfg" ]] && cmp -s -- "$boot_cfg" "$dev_cfg"; then
        ok "Gerätekonfiguration aktuell: ${dev_cfg}"
    else
        mkdir -p -- "$dev_cfg_dir"
        cp -- "$boot_cfg" "$dev_cfg"
        dev_cfg_updated=1
        neu "Gerätekonfiguration geschrieben: ${dev_cfg}"
    fi

    if (( boot_created || updated_cfg || dev_cfg_updated )) \
       && [[ "$KEY_MODE" == "keychain" ]] && ! command -v keychain >/dev/null 2>&1; then
        aktion "KEY_MODE=keychain gewählt, aber 'keychain' ist nicht installiert (sudo apt install keychain)."
    fi
}

step_deploy_key() {
    local host="$1"
    local ssh_dir="${HOME%/}/.ssh"
    local key_file="${ssh_dir}/kali_sync_${host}"
    local pub_file="${key_file}.pub"

    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p -- "$ssh_dir"
    fi
    ensure_mode "$ssh_dir" 700

    if [[ -f "$key_file" ]]; then
        ensure_mode "$key_file" 600
        if [[ ! -f "$pub_file" ]]; then
            local tmp_pub=""
            make_temp
            tmp_pub="$_LAST_TEMP"
            ssh-keygen -y -f "$key_file" > "$tmp_pub"
            mv -f -- "$tmp_pub" "$pub_file"
            ensure_mode "$pub_file" 644
            neu "Public Key aus bestehendem Deploy Key erzeugt: ${pub_file}"
        else
            ok "Deploy Key vorhanden: ${key_file}"
        fi
    else
        if [[ "$KEY_MODE" == "plain" ]]; then
            ssh-keygen -q -t ed25519 -N "" -C "kali-sync@${host}" -f "$key_file"
        else
            ssh-keygen -t ed25519 -C "kali-sync@${host}" -f "$key_file"
        fi
        ensure_mode "$key_file" 600
        neu "Deploy Key erzeugt: ${key_file}"
    fi
}

write_ssh_config_block() {
    local host="$1"
    cat <<EOF
# BEGIN kali-sync
Host kali-sync
    HostName github.com
    User git
    IdentityFile ~/.ssh/kali_sync_${host}
    IdentitiesOnly yes
    ControlMaster no
# END kali-sync
EOF
}

step_ssh_config() {
    local host="$1"
    local ssh_dir="${HOME%/}/.ssh"
    local ssh_config="${ssh_dir}/config"
    local rest_tmp="" target_tmp=""
    local in_block=0 has_rest=0 line=""

    make_temp
    rest_tmp="$_LAST_TEMP"
    make_temp
    target_tmp="$_LAST_TEMP"

    if [[ -f "$ssh_config" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "# BEGIN kali-sync" ]]; then
                in_block=1
                continue
            fi
            if (( in_block )); then
                if [[ "$line" == "# END kali-sync" ]]; then
                    in_block=0
                fi
                continue
            fi
            if (( ! has_rest )) && [[ -z "$line" ]]; then
                continue
            fi
            has_rest=1
            printf '%s\n' "$line" >> "$rest_tmp"
        done < "$ssh_config"

        if (( in_block )); then
            die "Unvollständiger Marker-Block in ${ssh_config} ('# BEGIN kali-sync' ohne '# END kali-sync')."
        fi
    fi

    write_ssh_config_block "$host" > "$target_tmp"
    if (( has_rest )); then
        printf '\n' >> "$target_tmp"
        cat -- "$rest_tmp" >> "$target_tmp"
    fi

    if [[ -f "$ssh_config" ]] && cmp -s -- "$ssh_config" "$target_tmp"; then
        ensure_mode "$ssh_config" 600
        ok "SSH-Konfiguration aktuell: ${ssh_config}"
    else
        mv -f -- "$target_tmp" "$ssh_config"
        ensure_mode "$ssh_config" 600
        neu "SSH-Konfiguration aktualisiert: ${ssh_config}"
    fi
}

step_known_hosts() {
    local ssh_dir="${HOME%/}/.ssh"
    local known_hosts="${ssh_dir}/known_hosts"
    local tpl="${SCRIPT_DIR}/templates/known_hosts_github"
    local -a missing=()
    local line="" existing_mode="" tmp_kh="" seen=0 item=""

    if [[ ! -f "$tpl" ]]; then
        die "Vorlage nicht gefunden: ${tpl}"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]]; then
            continue
        fi
        if file_has_exact_line "$known_hosts" "$line"; then
            continue
        fi
        seen=0
        for item in "${missing[@]}"; do
            if [[ "$item" == "$line" ]]; then
                seen=1
                break
            fi
        done
        if (( ! seen )); then
            missing+=("$line")
        fi
    done < "$tpl"

    if (( ${#missing[@]} == 0 )) && [[ -f "$known_hosts" ]]; then
        existing_mode="$(stat -c '%a' -- "$known_hosts")"
        if [[ "$existing_mode" != "600" && "$existing_mode" != "644" ]]; then
            chmod 600 -- "$known_hosts"
        fi
        ok "GitHub-Hostkeys aktuell: ${known_hosts}"
        return 0
    fi

    make_temp
    tmp_kh="$_LAST_TEMP"

    if [[ -f "$known_hosts" ]]; then
        existing_mode="$(stat -c '%a' -- "$known_hosts")"
        cp -- "$known_hosts" "$tmp_kh"
        if [[ -s "$tmp_kh" ]] && [[ "$(tail -c 1 -- "$tmp_kh" | wc -l)" -eq 0 ]]; then
            printf '\n' >> "$tmp_kh"
        fi
    fi

    for line in "${missing[@]}"; do
        printf '%s\n' "$line" >> "$tmp_kh"
    done

    mv -f -- "$tmp_kh" "$known_hosts"
    if [[ "$existing_mode" == "644" ]]; then
        ensure_mode "$known_hosts" 644
    else
        ensure_mode "$known_hosts" 600
    fi
    neu "GitHub-Hostkeys ergänzt: ${known_hosts}"
}

SSH_LAST_OUTPUT=""

check_ssh_connection() {
    local out=""
    out="$(ssh -T kali-sync </dev/null 2>&1 || true)"
    if [[ "$out" == *"successfully authenticated"* ]]; then
        SSH_LAST_OUTPUT="$out"
        return 0
    fi
    SSH_LAST_OUTPUT="$out"
    return 1
}

step_verify_connection() {
    local host="$1"
    local pub_file="${HOME%/}/.ssh/kali_sync_${host}.pub"
    local keys_url="https://github.com/${GITHUB_USER}/${SYNC_REPO}/settings/keys/new"

    if check_ssh_connection; then
        ok "SSH-Verbindung zu GitHub (kali-sync) erfolgreich."
        return 0
    fi

    if [[ ! -f "$pub_file" ]]; then
        die "Public Key nicht gefunden: ${pub_file}"
    fi

    aktion "Deploy Key bei GitHub hinterlegen (Schritt 3):"
    printf '\nPublic Key (%s):\n' "$pub_file"
    cat -- "$pub_file"
    printf '\nLink: %s\n' "$keys_url"
    printf 'Hinweis: Option "Allow write access" aktivieren.\n'
    printf 'Nach dem Hinterlegen mit Enter fortfahren ... '

    if ! IFS= read -r; then
        printf '\n' >&2
        die "Verbindungstest abgebrochen (EOF). Bitte Deploy Key gemäß Schritt 3 unter ${keys_url} (mit \"Allow write access\") hinterlegen und setup.sh erneut starten."
    fi

    if check_ssh_connection; then
        ok "SSH-Verbindung zu GitHub (kali-sync) erfolgreich."
        return 0
    fi

    die "SSH-Verbindung zu GitHub fehlgeschlagen. Bitte Deploy Key gemäß Schritt 3 unter ${keys_url} (mit \"Allow write access\") prüfen. Ausgabe: ${SSH_LAST_OUTPUT}"
}

ensure_ks_config() {
    local key="$1"
    local expected="$2"
    local current=""
    current="$(ks config --local --get "$key" 2>/dev/null || true)"
    if [[ "$current" != "$expected" ]]; then
        ks config --local "$key" "$expected"
        _KS_CFG_CHANGED=1
    fi
}

step_bare_repo() {
    local host="$1"
    local git_dir="${HOME%/}/.kali-sync"
    local remote_url="kali-sync:${GITHUB_USER}/${SYNC_REPO}.git"
    local cloned=0

    if [[ ! -d "$git_dir" ]]; then
        git clone --bare "$remote_url" "$git_dir"
        cloned=1
    fi

    _KS_CFG_CHANGED=0
    ensure_ks_config "core.bare" "false"
    ensure_ks_config "core.worktree" "$HOME"
    ensure_ks_config "remote.origin.url" "$remote_url"
    ensure_ks_config "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"
    ensure_ks_config "status.showUntrackedFiles" "no"
    ensure_ks_config "user.name" "kali-${host}"
    ensure_ks_config "user.email" "kali@${host}.local"

    ks fetch origin

    if (( cloned )); then
        neu "Bare-Repository geklont und konfiguriert: ${git_dir}"
    elif (( _KS_CFG_CHANGED )); then
        neu "Bare-Repository-Konfiguration aktualisiert: ${git_dir}"
    else
        ok "Bare-Repository aktuell: ${git_dir}"
    fi
}

step_install_hook() {
    local src="${SCRIPT_DIR}/hooks/pre-commit"
    local dst="${HOME%/}/.kali-sync/hooks/pre-commit"

    if [[ ! -f "$src" ]]; then
        die "Hook-Vorlage nicht gefunden: ${src}"
    fi

    install_file_if_changed "$src" "$dst" 755
    if (( _FILE_CHANGED )); then
        neu "pre-commit-Hook installiert: ${dst}"
    else
        ok "pre-commit-Hook aktuell: ${dst}"
    fi
}

array_contains() {
    local needle="$1"
    shift
    local item=""
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

build_whitelist_rules() {
    _WHITELIST_RULES=("!/.gitignore")
    local raw="" clean="" seg="" prefix="" unignore_parent="" reignore_children="" target_rule="" abs_path=""
    local -a parts=()
    local i=0 covered_by_parent=0

    if (( ${#WHITELIST[@]} == 0 )); then
        return 0
    fi

    for raw in "${WHITELIST[@]}"; do
        if [[ -z "$raw" ]]; then
            die "Ungültiger WHITELIST-Eintrag: leerer Pfad."
        fi
        if [[ "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
            die "Ungültiger WHITELIST-Eintrag (Zeilenumbruch): '${raw}'"
        fi
        if [[ "$raw" == /* ]]; then
            die "Ungültiger WHITELIST-Eintrag (absoluter Pfad nicht erlaubt): '${raw}'"
        fi

        clean="$raw"
        while [[ "$clean" == */ ]]; do
            clean="${clean%/}"
        done
        if [[ -z "$clean" ]]; then
            die "Ungültiger WHITELIST-Eintrag: '${raw}'"
        fi

        IFS='/' read -r -a parts <<< "$clean"
        for seg in "${parts[@]}"; do
            if [[ -z "$seg" || "$seg" == "." || "$seg" == ".." ]]; then
                die "Ungültiger WHITELIST-Eintrag (unzulässiges Pfadsegment): '${raw}'"
            fi
        done

        if [[ "$clean" == ".kali-sync" || "$clean" == ".kali-sync/"* ]]; then
            die "Ungültiger WHITELIST-Eintrag ('.kali-sync' nicht erlaubt): '${raw}'"
        fi

        prefix=""
        covered_by_parent=0
        for (( i = 0; i < ${#parts[@]} - 1; i++ )); do
            if [[ -z "$prefix" ]]; then
                prefix="${parts[i]}"
            else
                prefix="${prefix}/${parts[i]}"
            fi

            unignore_parent="!/${prefix}/"
            reignore_children="/${prefix}/*"

            if array_contains "$unignore_parent" "${_WHITELIST_RULES[@]}" \
               || array_contains "!/${prefix}" "${_WHITELIST_RULES[@]}"; then
                if ! array_contains "$reignore_children" "${_WHITELIST_RULES[@]}"; then
                    covered_by_parent=1
                    break
                fi
            else
                _WHITELIST_RULES+=("$unignore_parent")
                if ! array_contains "$reignore_children" "${_WHITELIST_RULES[@]}"; then
                    _WHITELIST_RULES+=("$reignore_children")
                fi
            fi
        done

        if (( covered_by_parent )); then
            continue
        fi

        abs_path="${HOME%/}/${clean}"
        if [[ -d "$abs_path" && ! -L "$abs_path" ]]; then
            target_rule="!/${clean}/"
        else
            target_rule="!/${clean}"
        fi

        if ! array_contains "$target_rule" "${_WHITELIST_RULES[@]}"; then
            _WHITELIST_RULES+=("$target_rule")
        fi
    done
}

render_gitignore_template() {
    local tpl="$1"
    local out="$2"
    local line="" state="before" rule=""
    local begin_count=0 end_count=0

    if [[ ! -f "$tpl" ]]; then
        die "Vorlage nicht gefunden: ${tpl}"
    fi

    : > "$out"
    while IFS= read -r line; do
        if [[ "$state" == "before" && "$line" == "# BEGIN WHITELIST"* ]]; then
            begin_count=$((begin_count + 1))
            printf '%s\n' "$line" >> "$out"
            for rule in "${_WHITELIST_RULES[@]}"; do
                printf '%s\n' "$rule" >> "$out"
            done
            state="inside"
        elif [[ "$state" == "inside" ]]; then
            if [[ "$line" == "# END WHITELIST" ]]; then
                end_count=$((end_count + 1))
                printf '%s\n' "$line" >> "$out"
                state="after"
            fi
        else
            if [[ "$line" == "# BEGIN WHITELIST"* ]]; then
                begin_count=$((begin_count + 1))
            elif [[ "$line" == "# END WHITELIST" ]]; then
                end_count=$((end_count + 1))
            fi
            printf '%s\n' "$line" >> "$out"
        fi
    done < "$tpl"

    if [[ -n "$line" ]]; then
        if [[ "$state" == "inside" && "$line" == "# END WHITELIST" ]]; then
            end_count=$((end_count + 1))
            printf '%s' "$line" >> "$out"
            state="after"
        elif [[ "$state" != "inside" ]]; then
            printf '%s' "$line" >> "$out"
        fi
    fi

    if (( begin_count != 1 || end_count != 1 )) || [[ "$state" != "after" ]]; then
        die "Ungültige Whitelist-Marker in Vorlage: ${tpl}"
    fi
}

has_staged_changes() {
    if ks rev-parse --verify -q HEAD >/dev/null 2>&1; then
        if ks diff --cached --quiet; then
            return 1
        fi
        return 0
    else
        [[ -n "$(ks ls-files --cached)" ]]
    fi
}

reset_staged_index() {
    if ks rev-parse --verify -q HEAD >/dev/null 2>&1; then
        ks reset -q >/dev/null 2>&1 || true
    else
        ks read-tree --empty >/dev/null 2>&1 || ks reset -q >/dev/null 2>&1 || true
    fi
}

step_init_or_join_repo() {
    local host="$1"
    local upstream=""
    upstream="$(ks rev-parse --abbrev-ref 'main@{upstream}' 2>/dev/null || true)"
    if [[ "$upstream" == "origin/main" ]]; then
        ok "Synchronisations-Branch aktuell (main -> origin/main)."
        return 0
    fi

    if ! ks rev-parse --verify -q refs/remotes/origin/main >/dev/null 2>&1; then
        # Erstgerät (Remote leer)
        build_whitelist_rules

        local tpl="${SCRIPT_DIR}/templates/gitignore"
        local tmp_gi=""
        make_temp
        tmp_gi="$_LAST_TEMP"
        render_gitignore_template "$tpl" "$tmp_gi"

        ks symbolic-ref HEAD refs/heads/main

        local dst_gi="${HOME%/}/.gitignore"
        if [[ -e "$dst_gi" || -L "$dst_gi" ]]; then
            if [[ -f "$dst_gi" && ! -L "$dst_gi" ]] && cmp -s -- "$dst_gi" "$tmp_gi"; then
                ok "Whitelist aktuell: ${dst_gi}"
            else
                backup_home_file ".gitignore"
                neu "Bestehende .gitignore gesichert: ${BACKUP_DIR}/.gitignore"
                mv -f -- "$tmp_gi" "$dst_gi"
                neu "Whitelist angelegt: ${dst_gi}"
            fi
        else
            mv -f -- "$tmp_gi" "$dst_gi"
            neu "Whitelist angelegt: ${dst_gi}"
        fi

        ks add -A
        if has_staged_changes; then
            local commit_out="" commit_rc=0
            commit_out="$(ks commit -q -m "init von ${host}" 2>&1)" || commit_rc=$?
            if (( commit_rc != 0 )); then
                reset_staged_index
                if [[ -n "$commit_out" ]]; then
                    printf '%s\n' "$commit_out" >&2
                fi
                die "Initial-Commit vom pre-commit-Hook abgelehnt. Bitte Ursache beheben und setup.sh erneut ausführen."
            fi
            neu "Initial-Commit erstellt: init von ${host}"
        fi

        ks push -u origin main
        neu "Erstgerät initialisiert und nach origin/main gepusht."
    else
        # Zweitgerät (Remote gefüllt)
        local rel=""
        while IFS= read -r -d '' rel; do
            if [[ -e "${HOME%/}/${rel}" || -L "${HOME%/}/${rel}" ]]; then
                backup_home_file "$rel"
                neu "Konfliktdatei gesichert: ${rel} -> ${BACKUP_DIR}/${rel}"
            fi
        done < <(ks ls-tree -r --name-only -z origin/main)

        ks checkout -B main origin/main
        ks branch --set-upstream-to=origin/main main
        neu "Remote-Stand ausgecheckt (main -> origin/main)."
    fi
}

step_install_script_and_shell() {
    local host="$1"
    local src_bin="${SCRIPT_DIR}/bin/kali-sync"
    local dst_bin="${HOME%/}/.local/bin/kali-sync"

    if [[ ! -f "$src_bin" ]]; then
        die "Sync-Skript nicht gefunden: ${src_bin}"
    fi

    install_file_if_changed "$src_bin" "$dst_bin" 755
    if (( _FILE_CHANGED )); then
        neu "Sync-Skript installiert: ${dst_bin}"
    else
        ok "Sync-Skript aktuell: ${dst_bin}"
    fi

    local zshrc="${HOME%/}/.zshrc"
    local zshrc_block=""
    printf -v zshrc_block '%s\n%s\n%s\n%s' \
        '# BEGIN kali-sync' \
        "alias ks='git --git-dir=\$HOME/.kali-sync --work-tree=\$HOME'" \
        '[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local' \
        '# END kali-sync'

    upsert_marker_block "$zshrc" "$zshrc_block"
    if (( _FILE_CHANGED )); then
        neu "Shell-Konfiguration aktualisiert: ${zshrc}"
    else
        ok "Shell-Konfiguration aktuell: ${zshrc}"
    fi

    local zshrc_local="${HOME%/}/.zshrc.local"
    if [[ "$KEY_MODE" == "keychain" ]]; then
        local local_block=""
        printf -v local_block '%s\n%s\n%s' \
            '# BEGIN kali-sync' \
            "eval \"\$(keychain --eval --quiet ~/.ssh/kali_sync_${host})\"" \
            '# END kali-sync'

        upsert_marker_block "$zshrc_local" "$local_block"
        if (( _FILE_CHANGED )); then
            neu "Lokale Shell-Konfiguration (keychain) aktualisiert: ${zshrc_local}"
        else
            ok "Lokale Shell-Konfiguration (keychain) aktuell: ${zshrc_local}"
        fi
    else
        remove_marker_block "$zshrc_local"
        if (( _FILE_CHANGED )); then
            neu "keychain-Block entfernt: ${zshrc_local}"
        else
            ok "Lokale Shell-Konfiguration ohne keychain-Block."
        fi
    fi
}

render_timer_template() {
    local src="$1"
    local dst="$2"
    local interval="$3"
    local line=""

    : > "$dst"
    while IFS= read -r line; do
        printf '%s\n' "${line//\$\{SYNC_INTERVAL\}/$interval}" >> "$dst"
    done < "$src"
    if [[ -n "$line" ]]; then
        printf '%s' "${line//\$\{SYNC_INTERVAL\}/$interval}" >> "$dst"
    fi
}

step_systemd() {
    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local src_service="${SCRIPT_DIR}/systemd/kali-sync.service"
    local src_timer="${SCRIPT_DIR}/systemd/kali-sync.timer"
    local dst_service="${unit_dir}/kali-sync.service"
    local dst_timer="${unit_dir}/kali-sync.timer"
    local units_changed=0

    if [[ ! -f "$src_service" ]]; then
        die "Vorlage nicht gefunden: ${src_service}"
    fi
    if [[ ! -f "$src_timer" ]]; then
        die "Vorlage nicht gefunden: ${src_timer}"
    fi

    install_file_if_changed "$src_service" "$dst_service" 644
    if (( _FILE_CHANGED )); then
        units_changed=1
        neu "systemd-Service installiert: ${dst_service}"
    else
        ok "systemd-Service aktuell: ${dst_service}"
    fi

    local tmp_timer=""
    make_temp
    tmp_timer="$_LAST_TEMP"
    render_timer_template "$src_timer" "$tmp_timer" "$SYNC_INTERVAL"

    install_file_if_changed "$tmp_timer" "$dst_timer" 644
    if (( _FILE_CHANGED )); then
        units_changed=1
        neu "systemd-Timer installiert: ${dst_timer}"
    else
        ok "systemd-Timer aktuell: ${dst_timer}"
    fi

    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        systemctl --user import-environment DBUS_SESSION_BUS_ADDRESS
    fi

    local is_enabled=0 is_active=0
    if systemctl --user is-enabled kali-sync.timer >/dev/null 2>&1; then
        is_enabled=1
    fi
    if systemctl --user is-active kali-sync.timer >/dev/null 2>&1; then
        is_active=1
    fi

    if (( units_changed )); then
        systemctl --user daemon-reload
        if (( is_active )); then
            systemctl --user restart kali-sync.timer
            neu "systemd-Timer neu geladen und neu gestartet: kali-sync.timer"
        fi
    fi

    if (( ! is_enabled || ! is_active )); then
        systemctl --user enable --now kali-sync.timer
        neu "systemd-Timer aktiviert: kali-sync.timer"
    elif (( ! units_changed )); then
        ok "systemd-Timer aktiv: kali-sync.timer"
    fi
}

step_finish() {
    local host="$1"
    local sync_bin="${HOME%/}/.local/bin/kali-sync"
    local sync_rc=0

    "$sync_bin" now || sync_rc=$?
    if (( sync_rc != 0 )); then
        aktion "Erster Sync fehlgeschlagen (Exit ${sync_rc}). Details siehe: kali-sync log"
        exit "$sync_rc"
    fi
    ok "Synchronisation erfolgreich ausgeführt (kali-sync now)."

    if [[ ":${PATH:-}:" != *":${HOME%/}/.local/bin:"* ]]; then
        printf 'Hinweis: %s/.local/bin ist nicht im PATH.\n' "${HOME%/}"
    fi

    local pub_file="${HOME%/}/.ssh/kali_sync_${host}.pub"
    local key_fp="unbekannt"
    if [[ -f "$pub_file" ]]; then
        key_fp="$(ssh-keygen -l -f "$pub_file" 2>/dev/null || printf 'unbekannt')"
    fi

    local timer_info=""
    timer_info="$(systemctl --user list-timers kali-sync.timer --no-pager 2>/dev/null || true)"
    if [[ -z "$timer_info" ]]; then
        timer_info="(nicht verfügbar)"
    fi

    printf '\n--- Zusammenfassung ---\n'
    printf 'Repository:      %s/%s\n' "$GITHUB_USER" "$SYNC_REPO"
    printf 'Key-Fingerprint: %s\n' "$key_fp"
    if [[ -n "$BACKUP_DIR" ]]; then
        printf 'Backup-Ordner:   %s\n' "$BACKUP_DIR"
    fi
    printf 'Nächster Timer-Lauf:\n%s\n' "$timer_info"
}

main() {
    step_preflight
    step_config

    local host=""
    host="$(hostname)"
    if [[ -z "$host" ]]; then
        die "Hostname konnte nicht ermittelt werden."
    fi

    step_deploy_key "$host"
    step_ssh_config "$host"
    step_known_hosts
    step_verify_connection "$host"
    step_bare_repo "$host"
    step_install_hook
    step_init_or_join_repo "$host"
    step_install_script_and_shell "$host"
    step_systemd
    step_finish "$host"
}

main "$@"

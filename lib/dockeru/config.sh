#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/config.sh
# INI-style config file parsing, loading, and merging
# =============================================================================

# --- State (populated by config_load) -----------------------------------------

# Associative arrays: daemon_name → value
declare -gA DOCKERU_DAEMON_UIDS=()        # daemon_name → uid
declare -gA DOCKERU_DAEMON_HOMES=()       # daemon_name → home directory
declare -gA DOCKERU_CONTAINER_MAP=()       # container_name → daemon_name
declare -gA DOCKERU_EXCLUDED=()            # container_name → "1" (set membership)

# Settings
DOCKERU_SOCKET_PATTERN="/run/user/%UID%/docker.sock"
DOCKERU_AUTO_REFRESH="true"
DOCKERU_CONFIG_LOADED=false

# --- INI parser ---------------------------------------------------------------

# Parse an INI-style config file.
# Calls handler functions for sections and key=value pairs.
#
# Section handlers:
#   _on_section <section_type> <section_name>
#   _on_keyval  <key> <value>
#
_parse_ini_file() {
    local file="$1"
    local current_section_type="" current_section_name=""

    [[ -f "$file" ]] || return 0

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num += 1 ))

        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Section header: [type "name"] or [type]
        if [[ "$line" =~ ^\[([a-zA-Z_-]+)(\ +\"([^\"]+)\")?\]$ ]]; then
            current_section_type="${BASH_REMATCH[1]}"
            current_section_name="${BASH_REMATCH[3]:-}"
            _on_section "$current_section_type" "$current_section_name"
            continue
        fi

        # Key=value pair
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Strip surrounding quotes if present
            if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            _on_keyval "$key" "$value" "$current_section_type" "$current_section_name"
            continue
        fi

        # Bare value (used in exclusion lists)
        if [[ "$current_section_type" == "excluded" ]] && validate_container_name "$line"; then
            DOCKERU_EXCLUDED["$line"]=1
            continue
        fi

        log_warn "${file}:${line_num}: unrecognized line: ${line}"
    done < "$file"
}

# --- Section/key handlers -----------------------------------------------------

_current_parse_section=""
_current_parse_name=""

_on_section() {
    _current_parse_section="$1"
    _current_parse_name="$2"
}

_on_keyval() {
    local key="$1" value="$2" section="$3" name="$4"

    case "$section" in
        settings)
            case "$key" in
                verbose)         [[ "$value" == true ]] && DOCKERU_VERBOSE=true ;;
                socket_pattern)  DOCKERU_SOCKET_PATTERN="$value" ;;
                auto_refresh)    DOCKERU_AUTO_REFRESH="$value" ;;
                docker_bin)      [[ -n "$value" ]] && DOCKERU_DOCKER_BIN="$value" ;;
            esac
            ;;
        daemon)
            if [[ -z "$name" ]]; then
                log_warn "Daemon section missing name: [daemon \"name\"]"
                return
            fi
            case "$key" in
                uid)
                    if validate_uid "$value"; then
                        DOCKERU_DAEMON_UIDS["$name"]="$value"
                    else
                        log_warn "Invalid UID '${value}' for daemon '${name}'"
                    fi
                    ;;
                home)
                    DOCKERU_DAEMON_HOMES["$name"]="$value"
                    ;;
            esac
            ;;
        excluded)
            # Key=value form in excluded section (unlikely, but handle gracefully)
            DOCKERU_EXCLUDED["$key"]=1
            ;;
    esac
}

# --- Loading ------------------------------------------------------------------

# Load container map from cache file
_load_container_map() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS='=' read -r container daemon || [[ -n "$container" ]]; do
        # Strip whitespace
        container="${container#"${container%%[![:space:]]*}"}"
        container="${container%"${container##*[![:space:]]}"}"
        daemon="${daemon#"${daemon%%[![:space:]]*}"}"
        daemon="${daemon%"${daemon##*[![:space:]]}"}"

        # Skip comments and empty lines
        [[ -z "$container" || "$container" == \#* ]] && continue

        if validate_container_name "$container" && [[ -n "$daemon" ]]; then
            DOCKERU_CONTAINER_MAP["$container"]="$daemon"
        fi
    done < "$file"
}

# Load excluded container names
_load_excluded() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        DOCKERU_EXCLUDED["$line"]=1
    done < "$file"
}

# Main config loader — reads system config, then user config (overlay)
config_load() {
    [[ "$DOCKERU_CONFIG_LOADED" == true ]] && return 0

    detect_platform

    local sys_dir user_dir
    sys_dir="$(get_system_config_dir)"
    user_dir="$(get_user_config_dir)"

    # System config (base layer)
    _parse_ini_file "${sys_dir}/dockeru.conf"
    _load_container_map "${sys_dir}/containers.map"
    _load_excluded "${sys_dir}/excluded.conf"

    # User config (overlay — per-user additions/overrides)
    _parse_ini_file "${user_dir}/dockeru.conf"
    _load_container_map "${user_dir}/containers.map"
    _load_excluded "${user_dir}/excluded.conf"

    # Auto-detect UIDs for daemons that don't have one set
    local daemon
    for daemon in "${!DOCKERU_DAEMON_UIDS[@]}"; do
        : # Already has UID
    done
    # Check if any daemon names were loaded without UIDs (from container map references)
    # and try to resolve them
    for daemon in "${!DOCKERU_DAEMON_HOMES[@]}"; do
        if [[ -z "${DOCKERU_DAEMON_UIDS[$daemon]:-}" ]]; then
            local resolved_uid
            resolved_uid="$(get_uid_for_user "$daemon" 2>/dev/null || true)"
            if [[ -n "$resolved_uid" ]]; then
                DOCKERU_DAEMON_UIDS["$daemon"]="$resolved_uid"
            fi
        fi
    done

    DOCKERU_CONFIG_LOADED=true
    log_verbose "Config loaded: ${#DOCKERU_DAEMON_UIDS[@]} daemons, ${#DOCKERU_CONTAINER_MAP[@]} containers, ${#DOCKERU_EXCLUDED[@]} excluded"
}

# --- Config writers -----------------------------------------------------------

# Write the current container map to a cache file
config_write_container_map() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"

    [[ -d "$dir" ]] || mkdir -p "$dir"

    {
        printf '# Auto-generated by: dockeru --refresh\n'
        printf '# Last refreshed: %s\n' "$(date -Iseconds)"
        printf '# DO NOT EDIT — regenerated on --refresh\n'
        printf '#\n'
        printf '# Format: container_name=daemon_name\n'

        # Sort by daemon name then container name for readability
        local container
        for container in $(printf '%s\n' "${!DOCKERU_CONTAINER_MAP[@]}" | sort); do
            printf '%s=%s\n' "$container" "${DOCKERU_CONTAINER_MAP[$container]}"
        done
    } > "$file"
}

# Write excluded containers to file
config_write_excluded() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"

    [[ -d "$dir" ]] || mkdir -p "$dir"

    {
        printf '# Containers present in multiple daemons — require --daemon flag\n'
        printf '# Auto-detected by: dockeru --refresh\n'
        printf '# Last updated: %s\n' "$(date -Iseconds)"
        printf '#\n'

        local name
        for name in $(printf '%s\n' "${!DOCKERU_EXCLUDED[@]}" | sort); do
            printf '%s\n' "$name"
        done
    } > "$file"
}

# --- Query helpers ------------------------------------------------------------

# Get list of all configured daemon names
config_get_daemon_names() {
    (( ${#DOCKERU_DAEMON_UIDS[@]} == 0 )) && return 0
    printf '%s\n' "${!DOCKERU_DAEMON_UIDS[@]}" | sort
}

# Get UID for a daemon name
config_get_uid() {
    local daemon="$1"
    echo "${DOCKERU_DAEMON_UIDS[$daemon]:-}"
}

# Get home directory for a daemon name
config_get_home() {
    local daemon="$1"
    echo "${DOCKERU_DAEMON_HOMES[$daemon]:-}"
}

# Look up which daemon owns a container
config_lookup_container() {
    local container="$1"

    # Check exclusion list first
    if [[ -n "${DOCKERU_EXCLUDED[$container]:-}" ]]; then
        return 1  # Excluded — caller must handle
    fi

    local daemon="${DOCKERU_CONTAINER_MAP[$container]:-}"
    if [[ -n "$daemon" ]]; then
        echo "$daemon"
        return 0
    fi

    return 2  # Not found
}

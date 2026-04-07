#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/management.sh
# Management commands: --add, --remove, --refresh, --list, --status, --doctor
# =============================================================================

# --- --add --------------------------------------------------------------------

cmd_add() {
    config_load

    local target="${1:-}"

    if [[ -n "$target" ]]; then
        # Non-interactive: add specific daemon
        _add_daemon_auto "$target"
    else
        # Interactive: discover and select
        _add_daemon_interactive
    fi
}

_add_daemon_auto() {
    local daemon_user="$1"

    # Validate name
    if ! validate_daemon_name "$daemon_user"; then
        die "Invalid daemon username: '${daemon_user}'"
    fi

    # Check if already configured
    if [[ -n "${DOCKERU_DAEMON_UIDS[$daemon_user]:-}" ]]; then
        die "Daemon '${daemon_user}' is already configured (UID ${DOCKERU_DAEMON_UIDS[$daemon_user]})"
    fi

    # Resolve UID
    local uid
    uid="$(get_uid_for_user "$daemon_user" 2>/dev/null || true)"
    if [[ -z "$uid" ]]; then
        die "User '${daemon_user}' does not exist on this system"
    fi

    # Check for Docker socket
    local socket
    socket="$(get_socket_path "$uid")"
    if [[ ! -S "$socket" ]]; then
        log_warn "Docker socket not found at ${socket}. The daemon may not be running."
    fi

    # Resolve home directory
    local home
    home="$(getent passwd "$daemon_user" 2>/dev/null | cut -d: -f6 || true)"

    # Confirm
    printf '\n%sAdding daemon:%s\n' "$CLR_BOLD" "$CLR_RESET"
    printf '  User:   %s\n' "$daemon_user"
    printf '  UID:    %s\n' "$uid"
    printf '  Socket: %s\n' "$socket"
    printf '  Home:   %s\n' "${home:-<not set>}"
    printf '\n'

    read -rp "Proceed? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log_info "Cancelled."
        return 1
    fi

    # Write to config
    _append_daemon_to_config "$daemon_user" "$uid" "$home"

    # Refresh containers for new daemon
    DOCKERU_DAEMON_UIDS["$daemon_user"]="$uid"
    [[ -n "$home" ]] && DOCKERU_DAEMON_HOMES["$daemon_user"]="$home"
    refresh_daemon_containers "$daemon_user" "$uid"
    _save_container_cache

    local count=0
    local c
    for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
        [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon_user" ]] && (( count++ ))
    done

    log_info "Added '${daemon_user}' with ${count} container(s)."
}

_add_daemon_interactive() {
    log_info "Discovering rootless Docker daemons..."

    local -a unconfigured=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && unconfigured+=("$line")
    done < <(discover_unconfigured_daemons)

    if (( ${#unconfigured[@]} == 0 )); then
        log_info "No unconfigured daemons found. All detected sockets are already configured."
        return 0
    fi

    printf '\n%sUnconfigured daemons found:%s\n\n' "$CLR_BOLD" "$CLR_RESET"
    local i=1
    for entry in "${unconfigured[@]}"; do
        local uid username socket
        IFS=: read -r uid username socket <<< "$entry"
        printf '  %s%d%s) %s (UID %s) — %s\n' "$CLR_CYAN" "$i" "$CLR_RESET" "$username" "$uid" "$socket"
        (( i++ ))
    done
    printf '  %s%d%s) Add all\n' "$CLR_CYAN" "$i" "$CLR_RESET"
    printf '\n'

    read -rp "Select daemon(s) to add (comma-separated numbers, or 'q' to quit): " selection

    [[ "$selection" == "q" ]] && return 0

    # Parse selection
    IFS=',' read -ra selections <<< "$selection"
    local all_option=$i

    for sel in "${selections[@]}"; do
        sel="${sel// /}"  # trim whitespace
        if (( sel == all_option )); then
            # Add all
            for entry in "${unconfigured[@]}"; do
                IFS=: read -r uid username socket <<< "$entry"
                _add_daemon_auto "$username"
            done
            return 0
        elif (( sel >= 1 && sel <= ${#unconfigured[@]} )); then
            local entry="${unconfigured[$((sel-1))]}"
            IFS=: read -r uid username socket <<< "$entry"
            _add_daemon_auto "$username"
        else
            log_warn "Invalid selection: ${sel}"
        fi
    done
}

# --- --remove -----------------------------------------------------------------

cmd_remove() {
    config_load

    local target="${1:-}"

    if [[ -n "$target" ]]; then
        _remove_daemon "$target"
    else
        _remove_daemon_interactive
    fi
}

_remove_daemon() {
    local daemon_user="$1"

    if [[ -z "${DOCKERU_DAEMON_UIDS[$daemon_user]:-}" ]]; then
        die "Daemon '${daemon_user}' is not configured."
    fi

    # Count containers that will be unregistered
    local count=0 c
    for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
        [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon_user" ]] && (( count++ ))
    done

    printf '%sRemoving daemon:%s %s (UID %s, %d containers)\n' \
        "$CLR_YELLOW" "$CLR_RESET" "$daemon_user" "${DOCKERU_DAEMON_UIDS[$daemon_user]}" "$count"

    read -rp "Proceed? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_info "Cancelled."
        return 1
    fi

    # Remove from in-memory state
    unset 'DOCKERU_DAEMON_UIDS[$daemon_user]'
    unset 'DOCKERU_DAEMON_HOMES[$daemon_user]'
    for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
        [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon_user" ]] && unset 'DOCKERU_CONTAINER_MAP[$c]'
    done

    # Remove from config file
    _remove_daemon_from_config "$daemon_user"
    _save_container_cache

    log_info "Removed '${daemon_user}'."
}

_remove_daemon_interactive() {
    local -a daemons=()
    readarray -t daemons < <(config_get_daemon_names)

    if (( ${#daemons[@]} == 0 )); then
        log_info "No daemons configured."
        return 0
    fi

    printf '\n%sConfigured daemons:%s\n\n' "$CLR_BOLD" "$CLR_RESET"
    local i=1 d
    for d in "${daemons[@]}"; do
        printf '  %s%d%s) %s (UID %s)\n' "$CLR_CYAN" "$i" "$CLR_RESET" "$d" "${DOCKERU_DAEMON_UIDS[$d]}"
        (( i++ ))
    done
    printf '\n'

    read -rp "Select daemon to remove (number, or 'q' to quit): " selection
    [[ "$selection" == "q" ]] && return 0

    if (( selection >= 1 && selection <= ${#daemons[@]} )); then
        _remove_daemon "${daemons[$((selection-1))]}"
    else
        log_warn "Invalid selection."
    fi
}

# --- --list -------------------------------------------------------------------

cmd_list() {
    config_load

    local target="${1:-}"
    local names_only=false containers_only=false

    # Handle special flags for completion support
    case "$target" in
        --names-only)     names_only=true; target="" ;;
        --containers-only) containers_only=true; target="" ;;
    esac

    if [[ "$names_only" == true ]]; then
        config_get_daemon_names
        return 0
    fi

    if [[ "$containers_only" == true ]]; then
        printf '%s\n' "${!DOCKERU_CONTAINER_MAP[@]}" | sort
        return 0
    fi

    if [[ -n "$target" ]]; then
        _list_daemon "$target"
    else
        _list_all
    fi
}

_list_all() {
    local -a daemons=()
    readarray -t daemons < <(config_get_daemon_names)

    if (( ${#daemons[@]} == 0 )); then
        log_info "No daemons configured. Run 'dockeru --add' to discover daemons."
        return 0
    fi

    local d
    for d in "${daemons[@]}"; do
        _list_daemon "$d"
        printf '\n'
    done

    if (( ${#DOCKERU_EXCLUDED[@]} > 0 )); then
        printf '%sExcluded containers:%s\n' "$CLR_YELLOW" "$CLR_RESET"
        local name
        for name in $(printf '%s\n' "${!DOCKERU_EXCLUDED[@]}" | sort); do
            printf '  %s\n' "$name"
        done
    fi
}

_list_daemon() {
    local daemon="$1"
    local uid="${DOCKERU_DAEMON_UIDS[$daemon]:-<unknown>}"
    local home="${DOCKERU_DAEMON_HOMES[$daemon]:-<not set>}"

    printf '%s%s%s (UID %s, home: %s)\n' "$CLR_BOLD" "$daemon" "$CLR_RESET" "$uid" "$home"

    local count=0 c
    for c in $(printf '%s\n' "${!DOCKERU_CONTAINER_MAP[@]}" | sort); do
        if [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon" ]]; then
            printf '  └─ %s\n' "$c"
            (( count++ ))
        fi
    done
    if (( count == 0 )); then
        printf '  %s(no containers — run dockeru --refresh)%s\n' "$CLR_DIM" "$CLR_RESET"
    fi
}

# --- --refresh ----------------------------------------------------------------

cmd_refresh() {
    config_load

    local target="${1:-}"
    local refresh_all=false

    [[ "$target" == "--all" ]] && { refresh_all=true; target=""; }

    if [[ -n "$target" ]]; then
        # Refresh specific daemon
        local uid
        uid="$(config_get_uid "$target")"
        [[ -z "$uid" ]] && die "Daemon '${target}' not found in configuration."

        log_info "Refreshing containers for ${target}..."
        printf '%sNote:%s Ensure all containers are created/built for auto-detection.\n' "$CLR_YELLOW" "$CLR_RESET"
        printf '      DockerU uses "docker ps -a" — stopped containers are included.\n\n'

        refresh_daemon_containers "$target" "$uid"
        _save_container_cache

        local count=0 c
        for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$target" ]] && (( count++ ))
        done
        log_info "Found ${count} container(s) for ${target}."

    elif [[ "$refresh_all" == true ]]; then
        # Non-interactive refresh all
        log_info "Refreshing all daemons..."
        refresh_all_containers
        _save_container_cache
        log_info "Refresh complete. ${#DOCKERU_CONTAINER_MAP[@]} containers across ${#DOCKERU_DAEMON_UIDS[@]} daemons."

    else
        # Interactive refresh
        _refresh_interactive
    fi
}

_refresh_interactive() {
    local -a daemons=()
    readarray -t daemons < <(config_get_daemon_names)

    if (( ${#daemons[@]} == 0 )); then
        log_info "No daemons configured."
        return 0
    fi

    printf '\n%sNote:%s Make sure all containers are created/built for accurate detection.\n' "$CLR_YELLOW" "$CLR_RESET"
    printf '      DockerU uses "docker ps -a" — stopped containers are included.\n\n'
    printf '%sConfigured daemons:%s\n\n' "$CLR_BOLD" "$CLR_RESET"

    local i=1 d
    printf '  %s%d%s) Refresh ALL\n' "$CLR_CYAN" "$i" "$CLR_RESET"
    (( i++ ))
    for d in "${daemons[@]}"; do
        printf '  %s%d%s) %s (UID %s)\n' "$CLR_CYAN" "$i" "$CLR_RESET" "$d" "${DOCKERU_DAEMON_UIDS[$d]}"
        (( i++ ))
    done
    printf '\n'

    read -rp "Select (comma-separated numbers, or 'q' to quit): " selection
    [[ "$selection" == "q" ]] && return 0

    IFS=',' read -ra selections <<< "$selection"

    for sel in "${selections[@]}"; do
        sel="${sel// /}"
        if (( sel == 1 )); then
            refresh_all_containers
            _save_container_cache
            log_info "Refresh complete."
            return 0
        elif (( sel >= 2 && sel <= ${#daemons[@]} + 1 )); then
            local idx=$((sel - 2))
            local uid
            uid="$(config_get_uid "${daemons[$idx]}")"
            refresh_daemon_containers "${daemons[$idx]}" "$uid"
        fi
    done

    _save_container_cache
    log_info "Refresh complete."
}

# --- --status -----------------------------------------------------------------

cmd_status() {
    config_load

    local -a daemons=()
    readarray -t daemons < <(config_get_daemon_names)

    if (( ${#daemons[@]} == 0 )); then
        log_info "No daemons configured."
        return 0
    fi

    printf '\n%s%-30s %-8s %-10s %-12s %s%s\n' "$CLR_BOLD" \
        "DAEMON" "UID" "SOCKET" "CONTAINERS" "DOCKER" "$CLR_RESET"
    printf '%s\n' "$(printf '%.0s─' {1..80})"

    local d
    for d in "${daemons[@]}"; do
        local uid socket status container_count docker_ok

        uid="${DOCKERU_DAEMON_UIDS[$d]}"
        socket="$(get_socket_path "$uid")"

        # Socket status
        if [[ -S "$socket" ]]; then
            status="${CLR_GREEN}running${CLR_RESET}"
        else
            status="${CLR_RED}no socket${CLR_RESET}"
        fi

        # Container count
        container_count=0
        local c
        for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$d" ]] && (( container_count++ ))
        done

        # Docker version check (brief)
        if [[ -S "$socket" ]]; then
            docker_ok="${CLR_GREEN}ok${CLR_RESET}"
        else
            docker_ok="${CLR_DIM}n/a${CLR_RESET}"
        fi

        printf '%-30s %-8s %-10b %-12s %b\n' \
            "$d" "$uid" "$status" "$container_count" "$docker_ok"
    done

    printf '\n'
    printf 'Total: %d daemons, %d containers, %d excluded\n' \
        "${#daemons[@]}" "${#DOCKERU_CONTAINER_MAP[@]}" "${#DOCKERU_EXCLUDED[@]}"
}

# --- --doctor -----------------------------------------------------------------

cmd_doctor() {
    printf '\n%sDockerU Environment Check%s\n' "$CLR_BOLD" "$CLR_RESET"
    printf '%s\n\n' "$(printf '%.0s─' {1..40})"

    local issues=0

    # Bash version
    printf 'Bash version: %s ... ' "$BASH_VERSION"
    if (( BASH_VERSINFO[0] >= 5 )); then
        printf '%sok%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%sFAIL (need 5.0+)%s\n' "$CLR_RED" "$CLR_RESET"
        (( issues++ ))
    fi

    # Docker
    detect_platform
    printf 'Docker binary: %s ... ' "${DOCKERU_DOCKER_BIN:-not found}"
    if [[ -n "$DOCKERU_DOCKER_BIN" ]]; then
        printf '%sok%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%sFAIL%s\n' "$CLR_RED" "$CLR_RESET"
        (( issues++ ))
    fi

    # sudo
    printf 'sudo: '
    if has_command sudo; then
        printf '%sok%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%sFAIL (required)%s\n' "$CLR_RED" "$CLR_RESET"
        (( issues++ ))
    fi

    # Platform
    printf 'Platform: %s %s (%s)\n' "$DOCKERU_DISTRO" "$DOCKERU_DISTRO_VERSION" "$DOCKERU_DISTRO_FAMILY"

    # Config files
    local sys_conf usr_conf
    sys_conf="$(get_system_config_dir)/dockeru.conf"
    usr_conf="$(get_user_config_dir)/dockeru.conf"
    printf 'System config: %s ... ' "$sys_conf"
    if [[ -f "$sys_conf" ]]; then
        printf '%sfound%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%snot found%s\n' "$CLR_YELLOW" "$CLR_RESET"
    fi
    printf 'User config:   %s ... ' "$usr_conf"
    if [[ -f "$usr_conf" ]]; then
        printf '%sfound%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%snot found%s\n' "$CLR_DIM" "$CLR_RESET"
    fi

    # Check sudo access to each daemon
    config_load
    if (( ${#DOCKERU_DAEMON_UIDS[@]} > 0 )); then
        printf '\nDaemon access:\n'
        local d
        for d in $(config_get_daemon_names); do
            local uid="${DOCKERU_DAEMON_UIDS[$d]}"
            local username
            username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$d")"

            printf '  %s (UID %s): ' "$d" "$uid"

            # Check if user exists
            if ! user_exists "$username"; then
                printf '%suser not found%s\n' "$CLR_RED" "$CLR_RESET"
                (( issues++ ))
                continue
            fi

            # Check sudo access
            if sudo -n -u "$username" true 2>/dev/null; then
                printf '%ssudo ok%s' "$CLR_GREEN" "$CLR_RESET"
            else
                printf '%ssudo denied%s' "$CLR_RED" "$CLR_RESET"
                (( issues++ ))
            fi

            # Check socket
            local socket
            socket="$(get_socket_path "$uid")"
            if [[ -S "$socket" ]]; then
                printf ' / %ssocket ok%s' "$CLR_GREEN" "$CLR_RESET"
            else
                printf ' / %sno socket%s' "$CLR_YELLOW" "$CLR_RESET"
            fi

            printf '\n'
        done
    fi

    printf '\n'
    if (( issues == 0 )); then
        printf '%s✓ All checks passed.%s\n\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%s✗ %d issue(s) found.%s\n\n' "$CLR_RED" "$issues" "$CLR_RESET"
    fi

    return "$issues"
}

# --- Config file manipulation -------------------------------------------------

_get_config_file() {
    if is_root || [[ "${DOCKERU_MODIFY_SYSTEM:-false}" == true ]]; then
        echo "$(get_system_config_dir)/dockeru.conf"
    else
        echo "$(get_user_config_dir)/dockeru.conf"
    fi
}

_append_daemon_to_config() {
    local daemon="$1" uid="$2" home="${3:-}"
    local conf
    conf="$(_get_config_file)"
    local dir
    dir="$(dirname "$conf")"

    [[ -d "$dir" ]] || mkdir -p "$dir"

    # Create file with header if new
    if [[ ! -f "$conf" ]]; then
        {
            printf '# DockerU Configuration\n'
            printf '# See: dockeru --help | man dockeru\n\n'
            printf '[settings]\n'
            printf 'auto_refresh=true\n\n'
        } > "$conf"
    fi

    # Append daemon section
    {
        printf '\n[daemon "%s"]\n' "$daemon"
        printf 'uid=%s\n' "$uid"
        [[ -n "$home" ]] && printf 'home=%s\n' "$home"
    } >> "$conf"

    log_verbose "Wrote daemon definition to ${conf}"
}

_remove_daemon_from_config() {
    local daemon="$1"
    local conf
    conf="$(_get_config_file)"

    [[ -f "$conf" ]] || return 0

    # Remove the [daemon "name"] section and its keys
    # Uses awk to skip from the matching section header to the next section
    local tmpfile
    tmpfile="$(mktemp)"
    awk -v daemon="$daemon" '
        /^\[daemon "/ {
            if (index($0, "\"" daemon "\"") > 0) {
                skip = 1
                next
            }
        }
        /^\[/ { skip = 0 }
        !skip { print }
    ' "$conf" > "$tmpfile"

    mv "$tmpfile" "$conf"
    log_verbose "Removed daemon '${daemon}' from ${conf}"
}

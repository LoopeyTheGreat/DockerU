#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/management.sh
# Management commands: --add, --remove, --refresh, --list, --status, --doctor
# =============================================================================

# --- --add --------------------------------------------------------------------

cmd_add() {
    config_load

    if ! is_root; then
        printf '%sNote:%s Daemon registration writes to the system config (/etc/dockeru/).\n' \
            "$CLR_YELLOW" "$CLR_RESET"
        printf '       Run %ssudo dockeru --add%s to persist changes for all users.\n\n' \
            "$CLR_BOLD" "$CLR_RESET"
    fi

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
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon_user" ]] && (( count += 1 ))
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
        (( i += 1 ))
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

    if ! is_root; then
        printf '%sNote:%s Daemon removal modifies the system config (/etc/dockeru/).\n' \
            "$CLR_YELLOW" "$CLR_RESET"
        printf '       Run %ssudo dockeru --remove%s to modify system-wide configuration.\n\n' \
            "$CLR_BOLD" "$CLR_RESET"
    fi

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
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$daemon_user" ]] && (( count += 1 ))
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
        (( i += 1 ))
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
            (( count += 1 ))
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
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$target" ]] && (( count += 1 ))
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
    (( i += 1 ))
    for d in "${daemons[@]}"; do
        printf '  %s%d%s) %s (UID %s)\n' "$CLR_CYAN" "$i" "$CLR_RESET" "$d" "${DOCKERU_DAEMON_UIDS[$d]}"
        (( i += 1 ))
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

        # Socket status — use socket_reachable() so non-root users don't get
        # false "no socket" on /run/user/<other-uid>/ dirs (mode 700).
        if is_root; then
            if [[ -S "$socket" ]]; then
                status="${CLR_GREEN}running${CLR_RESET}"
            else
                status="${CLR_RED}no socket${CLR_RESET}"
            fi
        else
            # Can't stat other users' sockets without root; show as unknown
            status="${CLR_YELLOW}unknown${CLR_RESET}"
        fi

        # Container count
        container_count=0
        local c
        for c in "${!DOCKERU_CONTAINER_MAP[@]}"; do
            [[ "${DOCKERU_CONTAINER_MAP[$c]}" == "$d" ]] && (( container_count += 1 ))
        done

        # Docker version check (brief) — only reliable when root
        if is_root && [[ -S "$socket" ]]; then
            docker_ok="${CLR_GREEN}ok${CLR_RESET}"
        elif is_root; then
            docker_ok="${CLR_DIM}n/a${CLR_RESET}"
        else
            docker_ok="${CLR_DIM}(use sudo)${CLR_RESET}"
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
        (( issues += 1 ))
    fi

    # Docker
    detect_platform
    printf 'Docker binary: %s ... ' "${DOCKERU_DOCKER_BIN:-not found}"
    if [[ -n "$DOCKERU_DOCKER_BIN" ]]; then
        printf '%sok%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%sFAIL%s\n' "$CLR_RED" "$CLR_RESET"
        (( issues += 1 ))
    fi

    # sudo
    printf 'sudo: '
    if has_command sudo; then
        printf '%sok%s\n' "$CLR_GREEN" "$CLR_RESET"
    else
        printf '%sFAIL (required)%s\n' "$CLR_RED" "$CLR_RESET"
        (( issues += 1 ))
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
                (( issues += 1 ))
                continue
            fi

            # Check sudo access
            if ! sudo -n -u "$username" true 2>/dev/null; then
                printf '%ssudo denied%s' "$CLR_RED" "$CLR_RESET"
                (( issues += 1 ))
            # Check that DOCKER_HOST env passthrough works (requires SETENV in sudoers)
            elif sudo -n -u "$username" env DOCKERU_TEST=1 sh -c 'test "$DOCKERU_TEST" = "1"' 2>/dev/null; then
                printf '%ssudo ok (env passthrough ok)%s' "$CLR_GREEN" "$CLR_RESET"
            else
                printf '%ssudo ok but SETENV missing%s — run: sudo dockeru --setup-sudo' \
                    "$CLR_YELLOW" "$CLR_RESET"
                (( issues += 1 ))
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

# --- --setup-sudo ------------------------------------------------------------

cmd_setup_sudo() {
    if ! is_root; then
        die "'--setup-sudo' must be run as root. Use: sudo dockeru --setup-sudo"
    fi

    config_load
    detect_platform

    local docker_bin="${DOCKERU_DOCKER_BIN:-$(command -v docker 2>/dev/null || echo /usr/bin/docker)}"

    local -a daemon_names
    readarray -t daemon_names < <(config_get_daemon_names)

    if (( ${#daemon_names[@]} == 0 )); then
        die "No daemons configured. Run 'sudo dockeru --add' first."
    fi

    printf '\n%sSudo Setup for DockerU%s\n' "$CLR_BOLD" "$CLR_RESET"
    printf '%s\n\n' "$(printf '%.0s─' {1..40})"
    printf 'This will write sudoers drop-in files so that users can run\n'
    printf 'dockeru commands (e.g. %sdockeru ps%s) without prefixing sudo.\n\n' \
        "$CLR_BOLD" "$CLR_RESET"

    # Collect local users who should get access (non-system, non-daemon)
    local -a target_users=()
    local entry uid username home
    while IFS=: read -r username _ uid _ _ home _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        # Skip system accounts and daemon users (UID < 1000)
        (( uid < 1000 )) && continue
        # Skip daemon users (home under /home/docker-* pattern or matching configured daemons)
        local is_daemon=false
        local d
        for d in "${daemon_names[@]}"; do
            [[ "$username" == "$d" ]] && { is_daemon=true; break; }
        done
        "$is_daemon" && continue
        target_users+=("$username")
    done < <(getent passwd)

    if (( ${#target_users[@]} == 0 )); then
        log_info "No regular user accounts found to configure."
        return 0
    fi

    printf 'Regular users found:\n'
    local i=1 u
    for u in "${target_users[@]}"; do
        printf '  %s%d%s) %s\n' "$CLR_CYAN" "$i" "$CLR_RESET" "$u"
        (( i += 1 ))
    done
    printf '  %s%d%s) Configure all\n' "$CLR_CYAN" "$i" "$CLR_RESET"
    printf '\n'

    local selection
    read -rp "Select user(s) to configure (comma-separated numbers, or 'q' to quit): " selection
    [[ "$selection" == 'q' ]] && return 0

    local -a selected_users=()
    local all_opt=$i
    IFS=',' read -ra sels <<< "$selection"
    for sel in "${sels[@]}"; do
        sel="${sel// /}"
        if (( sel == all_opt )); then
            selected_users=("${target_users[@]}")
            break
        elif (( sel >= 1 && sel <= ${#target_users[@]} )); then
            selected_users+=("${target_users[$((sel-1))]}") 
        else
            log_warn "Invalid selection: ${sel}"
        fi
    done

    (( ${#selected_users[@]} == 0 )) && return 0

    for u in "${selected_users[@]}"; do
        local sudoers_file="/etc/sudoers.d/dockeru-${u}"
        local content="# DockerU — passwordless sudo for docker daemon users\n"
        content+="# Generated by 'sudo dockeru --setup-sudo' on $(date -Iseconds)\n"
        content+="# SETENV is required so dockeru can pass DOCKER_HOST to the docker binary.\n\n"

        for d in "${daemon_names[@]}"; do
            local duid="${DOCKERU_DAEMON_UIDS[$d]}"
            local duser
            duser="$(get_user_for_uid "$duid" 2>/dev/null || echo "$d")"
            content+="${u} ALL=(${duser}) NOPASSWD: SETENV: ${docker_bin}\n"
        done

        local tmpfile
        tmpfile="$(mktemp)"
        printf '%b' "$content" > "$tmpfile"

        if visudo -c -f "$tmpfile" 2>/dev/null; then
            install -m 440 "$tmpfile" "$sudoers_file"
            rm -f "$tmpfile"
            log_info "Configured sudo for '${u}': ${sudoers_file}"
        else
            rm -f "$tmpfile"
            log_error "sudoers validation failed for '${u}' — file NOT written."
        fi
    done

    printf '\n%s✓ Sudo setup complete.%s Now run %sdockeru ps%s (without sudo).\n\n' \
        "$CLR_GREEN" "$CLR_RESET" "$CLR_BOLD" "$CLR_RESET"
}

# --- Config file manipulation -------------------------------------------------

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

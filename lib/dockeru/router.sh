#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/router.sh
# Command routing: parse Docker args, resolve daemon, execute
# =============================================================================

# Docker subcommands that never take a container name as a positional argument.
# For these, we default to aggregation or require --daemon.
readonly -a DOCKERU_AGGREGATE_SUBCOMMANDS=(
    ps ls images stats
)

# Docker subcommands that operate on infrastructure, not containers.
# These need --daemon if the target daemon isn't obvious from context.
readonly -a DOCKERU_INFRA_SUBCOMMANDS=(
    network volume system builder buildx plugin trust manifest
    config secret node service stack swarm context image
)

# Docker subcommands that take a container name as first positional arg.
readonly -a DOCKERU_CONTAINER_SUBCOMMANDS=(
    start stop restart kill pause unpause rm remove
    logs attach top port diff export wait
    rename update commit cp
)

# --- Routing ------------------------------------------------------------------

# Main entry point for Docker command routing and execution.
# Args: all remaining CLI arguments (Docker command + args)
route_and_exec() {
    local subcommand="${1:-}"
    local args=("$@")

    # 0. If explicit daemon was set via -d, skip auto-routing
    if [[ -n "$DOCKERU_TARGET_DAEMON" ]]; then
        _exec_for_daemon "$DOCKERU_TARGET_DAEMON" "${args[@]}"
        return $?
    fi

    # 1. Check for aggregate commands (ps, ls, images, stats)
    if _is_aggregate_subcommand "$subcommand"; then
        aggregate_command "${args[@]}"
        return $?
    fi

    # 2. Check for compose → route by CWD
    if [[ "$subcommand" == "compose" ]]; then
        local daemon
        daemon="$(_resolve_daemon_from_cwd)"
        if [[ -n "$daemon" ]]; then
            _exec_for_daemon "$daemon" "${args[@]}"
            return $?
        fi
        die "Cannot detect daemon from directory '${PWD}'." \
            "Use: dockeru -d <daemon> compose ..."
    fi

    # 3. Check for exec (special: container name is after possible flags)
    if [[ "$subcommand" == "exec" ]]; then
        local container
        container="$(_extract_exec_container "${args[@]}")"
        if [[ -n "$container" ]]; then
            local daemon
            daemon="$(_resolve_daemon_for_container "$container")"
            if [[ -n "$daemon" ]]; then
                _exec_for_daemon "$daemon" "${args[@]}"
                return $?
            fi
        fi
    fi

    # 4. Check for inspect (can be container or image — try container first)
    if [[ "$subcommand" == "inspect" ]]; then
        local target="${2:-}"
        if [[ -n "$target" ]]; then
            local daemon
            daemon="$(_resolve_daemon_for_container "$target" 2>/dev/null || true)"
            if [[ -n "$daemon" ]]; then
                _exec_for_daemon "$daemon" "${args[@]}"
                return $?
            fi
        fi
    fi

    # 5. For container subcommands, extract the container name
    if _is_container_subcommand "$subcommand"; then
        local container="${2:-}"
        if [[ -n "$container" ]]; then
            local daemon
            daemon="$(_resolve_daemon_for_container "$container")"
            if [[ -n "$daemon" ]]; then
                _exec_for_daemon "$daemon" "${args[@]}"
                return $?
            fi
        fi
    fi

    # 6. Try to find a container name anywhere in the args
    local daemon
    daemon="$(_scan_args_for_container "${args[@]}")"
    if [[ -n "$daemon" ]]; then
        _exec_for_daemon "$daemon" "${args[@]}"
        return $?
    fi

    # 7. Try CWD-based routing as last resort
    daemon="$(_resolve_daemon_from_cwd 2>/dev/null || true)"
    if [[ -n "$daemon" ]]; then
        _exec_for_daemon "$daemon" "${args[@]}"
        return $?
    fi

    # 8. Infrastructure subcommands → aggregate if possible, else error
    if _is_infra_subcommand "$subcommand"; then
        aggregate_command "${args[@]}"
        return $?
    fi

    die "Cannot determine target daemon for: docker ${args[*]}" \
        "" \
        "Hint: Use 'dockeru -d <daemon> ${args[*]}' to specify the daemon," \
        "or run 'dockeru --refresh' to update the container registry."
}

# --- Daemon resolution --------------------------------------------------------

# Resolve daemon name from a container name. Handles exclusions and auto-refresh.
_resolve_daemon_for_container() {
    local container="$1"
    local daemon

    # Try direct lookup
    daemon="$(config_lookup_container "$container" 2>/dev/null || true)"
    local status=$?

    if [[ -n "$daemon" ]]; then
        echo "$daemon"
        return 0
    fi

    # Check if it was excluded (multi-daemon conflict)
    if [[ -n "${DOCKERU_EXCLUDED[$container]:-}" ]]; then
        die "Container '${container}' exists in multiple daemons." \
            "Use: dockeru -d <daemon> ... ${container}"
    fi

    # Not found — try auto-refresh if enabled
    if [[ "${DOCKERU_AUTO_REFRESH}" == "true" ]]; then
        log_verbose "Container '${container}' not in registry. Auto-refreshing..."
        refresh_all_containers

        daemon="$(config_lookup_container "$container" 2>/dev/null || true)"
        if [[ -n "$daemon" ]]; then
            # Write updated map to cache
            _save_container_cache
            echo "$daemon"
            return 0
        fi
    fi

    die "Container '${container}' not found in any configured daemon." \
        "Run 'dockeru --refresh' to update, or use 'dockeru -d <daemon>'."
}

# Resolve daemon from current working directory
_resolve_daemon_from_cwd() {
    local cwd="$PWD"
    local daemon home

    for daemon in $(config_get_daemon_names); do
        home="$(config_get_home "$daemon")"
        [[ -z "$home" ]] && continue

        # Check if CWD is inside the daemon's home directory
        if [[ "$cwd" == "$home" || "$cwd" == "$home"/* ]]; then
            echo "$daemon"
            return 0
        fi
    done

    return 1
}

# --- Container name extraction ------------------------------------------------

# Extract container name from exec command (skipping flags like -it, -u, etc.)
_extract_exec_container() {
    shift  # Skip "exec"
    while (( $# )); do
        case "$1" in
            -*)
                # Skip flags. Some take an argument.
                case "$1" in
                    -e|--env|-u|--user|-w|--workdir|--env-file)
                        shift  # Skip the flag's value too
                        ;;
                esac
                shift
                ;;
            *)
                # First non-flag argument is the container name
                echo "$1"
                return 0
                ;;
        esac
    done
    return 1
}

# Scan all args looking for any known container name
_scan_args_for_container() {
    local arg
    for arg in "$@"; do
        # Skip flags
        [[ "$arg" == -* ]] && continue
        # Check if this arg is a known container
        if [[ -n "${DOCKERU_CONTAINER_MAP[$arg]:-}" ]]; then
            echo "${DOCKERU_CONTAINER_MAP[$arg]}"
            return 0
        fi
    done
    return 1
}

# --- Subcommand classification ------------------------------------------------

_is_aggregate_subcommand() {
    local cmd="$1"
    local sub
    for sub in "${DOCKERU_AGGREGATE_SUBCOMMANDS[@]}"; do
        [[ "$cmd" == "$sub" ]] && return 0
    done
    return 1
}

_is_container_subcommand() {
    local cmd="$1"
    local sub
    for sub in "${DOCKERU_CONTAINER_SUBCOMMANDS[@]}"; do
        [[ "$cmd" == "$sub" ]] && return 0
    done
    return 1
}

_is_infra_subcommand() {
    local cmd="$1"
    local sub
    for sub in "${DOCKERU_INFRA_SUBCOMMANDS[@]}"; do
        [[ "$cmd" == "$sub" ]] && return 0
    done
    return 1
}

# --- Execution ----------------------------------------------------------------

# Execute a Docker command as a specific daemon user.
# Args: daemon_name docker_args...
_exec_for_daemon() {
    local daemon="$1"
    shift
    local uid socket docker_bin username

    uid="$(config_get_uid "$daemon")"
    if [[ -z "$uid" ]]; then
        die "Daemon '${daemon}' not found in configuration."
    fi

    socket="$(get_socket_path "$uid")"
    docker_bin="${DOCKERU_DOCKER_BIN:-docker}"
    username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$daemon")"

    # Build the command
    local -a cmd

    if is_root; then
        # Running as root: use su to switch
        cmd=(
            su -s /bin/sh "$username" -c
            "XDG_RUNTIME_DIR='/run/user/${uid}' DOCKER_HOST='unix://${socket}' '${docker_bin}' $*"
        )
    else
        # Normal user: use sudo -u
        cmd=(
            sudo -u "$username"
            "XDG_RUNTIME_DIR=/run/user/${uid}"
            "DOCKER_HOST=unix://${socket}"
            "$docker_bin" "$@"
        )
    fi

    log_verbose "Executing: ${cmd[*]}"

    if [[ "${DOCKERU_DRY_RUN:-false}" == true ]]; then
        printf '%s[dry-run]%s %s\n' "$CLR_YELLOW" "$CLR_RESET" "${cmd[*]}"
        return 0
    fi

    exec "${cmd[@]}"
}

# Save container cache to the appropriate config directory
_save_container_cache() {
    local dir
    if is_root || [[ -w "$(get_system_config_dir)" ]]; then
        dir="$(get_system_config_dir)"
    else
        dir="$(get_user_config_dir)"
    fi
    config_write_container_map "${dir}/containers.map"
    config_write_excluded "${dir}/excluded.conf"
}

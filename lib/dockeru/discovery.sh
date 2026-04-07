#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/discovery.sh
# Daemon and container auto-discovery
# =============================================================================

# --- Daemon discovery ---------------------------------------------------------

# Discover rootless Docker daemon sockets on the system.
# Outputs lines: uid:username:socket_path
# Only reports sockets that actually exist and belong to real users.
discover_daemon_sockets() {
    local uid username socket

    for runtime_dir in /run/user/*/; do
        [[ -d "$runtime_dir" ]] || continue

        uid="${runtime_dir#/run/user/}"
        uid="${uid%/}"

        # Skip non-numeric
        [[ "$uid" =~ ^[0-9]+$ ]] || continue

        socket="${runtime_dir}docker.sock"
        [[ -S "$socket" ]] || continue

        username="$(get_user_for_uid "$uid" 2>/dev/null || true)"
        [[ -n "$username" ]] || continue

        # Skip system users below UID 100 (root, daemon, etc.)
        (( uid < 100 )) && continue

        printf '%s:%s:%s\n' "$uid" "$username" "$socket"
    done
}

# Discover daemon users that are NOT yet configured.
# Outputs lines: uid:username:socket_path
discover_unconfigured_daemons() {
    local line uid username socket

    while IFS=: read -r uid username socket; do
        if [[ -z "${DOCKERU_DAEMON_UIDS[$username]:-}" ]]; then
            printf '%s:%s:%s\n' "$uid" "$username" "$socket"
        fi
    done < <(discover_daemon_sockets)
}

# --- Container discovery ------------------------------------------------------

# Enumerate all containers (running + stopped) for a specific daemon.
# Args: daemon_name uid
# Outputs container names, one per line.
discover_containers() {
    local daemon_name="$1"
    local uid="$2"
    local socket

    socket="$(get_socket_path "$uid")"

    if [[ ! -S "$socket" ]]; then
        log_warn "Socket not found for ${daemon_name} (${socket})"
        return 1
    fi

    local docker_bin="${DOCKERU_DOCKER_BIN:-docker}"

    # Use sudo -u to switch to daemon user, set DOCKER_HOST, list all containers
    if is_root; then
        local username
        username="$(get_user_for_uid "$uid")"
        su -s /bin/sh "$username" -c \
            "DOCKER_HOST='unix://${socket}' '${docker_bin}' ps -a --format '{{.Names}}'" 2>/dev/null
    else
        sudo -u "$(get_user_for_uid "$uid")" \
            DOCKER_HOST="unix://${socket}" \
            "$docker_bin" ps -a --format '{{.Names}}' 2>/dev/null
    fi
}

# Refresh container map for a specific daemon.
# Updates DOCKERU_CONTAINER_MAP in memory.
# Args: daemon_name uid
# Returns: number of containers found
refresh_daemon_containers() {
    local daemon_name="$1"
    local uid="$2"
    local containers count=0

    # Remove old entries for this daemon
    local container
    for container in "${!DOCKERU_CONTAINER_MAP[@]}"; do
        if [[ "${DOCKERU_CONTAINER_MAP[$container]}" == "$daemon_name" ]]; then
            unset 'DOCKERU_CONTAINER_MAP[$container]'
        fi
    done

    # Discover current containers
    if containers="$(discover_containers "$daemon_name" "$uid" 2>/dev/null)"; then
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            DOCKERU_CONTAINER_MAP["$container"]="$daemon_name"
            (( count++ ))
        done <<< "$containers"
    fi

    return 0
}

# Refresh all daemons and detect duplicate container names.
# Returns: 0 on success
refresh_all_containers() {
    local daemon uid

    # Refresh each daemon
    for daemon in $(config_get_daemon_names); do
        uid="$(config_get_uid "$daemon")"
        [[ -n "$uid" ]] || continue
        log_verbose "Refreshing containers for ${daemon} (UID ${uid})..."
        refresh_daemon_containers "$daemon" "$uid"
    done

    # Detect duplicates — container names appearing in multiple daemons
    _detect_duplicates

    return 0
}

# Internal: find container names that appear under multiple daemons
_detect_duplicates() {
    # Build name → daemon[] map
    local -A name_daemons=()
    local container daemon

    for container in "${!DOCKERU_CONTAINER_MAP[@]}"; do
        daemon="${DOCKERU_CONTAINER_MAP[$container]}"
        if [[ -n "${name_daemons[$container]:-}" ]]; then
            name_daemons["$container"]="${name_daemons[$container]} ${daemon}"
        else
            name_daemons["$container"]="$daemon"
        fi
    done

    # Check for names with multiple daemons
    for container in "${!name_daemons[@]}"; do
        local daemons="${name_daemons[$container]}"
        local count
        count=$(echo "$daemons" | wc -w)
        if (( count > 1 )); then
            DOCKERU_EXCLUDED["$container"]=1
            unset 'DOCKERU_CONTAINER_MAP[$container]'
            log_warn "Container '${container}' found in multiple daemons (${daemons}). Added to exclusions."
        fi
    done
}

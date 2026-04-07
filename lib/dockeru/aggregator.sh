#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/aggregator.sh
# Cross-daemon aggregation for ps, images, stats
# =============================================================================

# Execute a Docker command against all configured daemons and merge output.
# Prepends a DAEMON column for context.
aggregate_command() {
    local subcommand="${1:-ps}"
    local -a extra_args=("${@:2}")

    local -a daemons=()
    readarray -t daemons < <(config_get_daemon_names)

    if (( ${#daemons[@]} == 0 )); then
        die "No daemons configured. Run 'dockeru --add' to get started."
    fi

    case "$subcommand" in
        ps|ls)      _aggregate_ps "${extra_args[@]}" ;;
        images)     _aggregate_images "${extra_args[@]}" ;;
        stats)      _aggregate_stats "${extra_args[@]}" ;;
        *)          _aggregate_generic "$subcommand" "${extra_args[@]}" ;;
    esac
}

# --- ps / ls ------------------------------------------------------------------

_aggregate_ps() {
    local -a extra_args=("$@")
    local docker_bin="${DOCKERU_DOCKER_BIN:-docker}"
    local header_printed=false
    local d uid socket username

    for d in $(config_get_daemon_names); do
        uid="$(config_get_uid "$d")"
        [[ -n "$uid" ]] || continue
        socket="$(get_socket_path "$uid")"
        [[ -S "$socket" ]] || continue
        username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$d")"

        local output
        if is_root; then
            output="$(su -s /bin/sh "$username" -c \
                "DOCKER_HOST='unix://${socket}' '${docker_bin}' ps ${extra_args[*]:+${extra_args[*]}}" 2>/dev/null || true)"
        else
            output="$(sudo -u "$username" \
                DOCKER_HOST="unix://${socket}" \
                "$docker_bin" ps "${extra_args[@]:+${extra_args[@]}}" 2>/dev/null || true)"
        fi

        [[ -z "$output" ]] && continue

        # Print header from first daemon, prepend DAEMON column
        if [[ "$header_printed" == false ]]; then
            local header
            header="$(head -1 <<< "$output")"
            printf '%s%-28s%s %s\n' "$CLR_BOLD" "DAEMON" "$CLR_RESET" "$header"
            header_printed=true
        fi

        # Print data rows (skip header line)
        tail -n +2 <<< "$output" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%-28s %s\n' "$d" "$line"
        done
    done

    if [[ "$header_printed" == false ]]; then
        log_info "No running containers across any daemon."
    fi
}

# --- images -------------------------------------------------------------------

_aggregate_images() {
    local -a extra_args=("$@")
    local docker_bin="${DOCKERU_DOCKER_BIN:-docker}"
    local header_printed=false

    for d in $(config_get_daemon_names); do
        local uid socket username
        uid="$(config_get_uid "$d")"
        [[ -n "$uid" ]] || continue
        socket="$(get_socket_path "$uid")"
        [[ -S "$socket" ]] || continue
        username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$d")"

        local output
        if is_root; then
            output="$(su -s /bin/sh "$username" -c \
                "DOCKER_HOST='unix://${socket}' '${docker_bin}' images ${extra_args[*]:+${extra_args[*]}}" 2>/dev/null || true)"
        else
            output="$(sudo -u "$username" \
                DOCKER_HOST="unix://${socket}" \
                "$docker_bin" images "${extra_args[@]:+${extra_args[@]}}" 2>/dev/null || true)"
        fi

        [[ -z "$output" ]] && continue

        if [[ "$header_printed" == false ]]; then
            local header
            header="$(head -1 <<< "$output")"
            printf '%s%-28s%s %s\n' "$CLR_BOLD" "DAEMON" "$CLR_RESET" "$header"
            header_printed=true
        fi

        tail -n +2 <<< "$output" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%-28s %s\n' "$d" "$line"
        done
    done
}

# --- stats --------------------------------------------------------------------

_aggregate_stats() {
    local -a extra_args=("$@")
    local docker_bin="${DOCKERU_DOCKER_BIN:-docker}"
    local header_printed=false

    # Force --no-stream for aggregation (streaming across multiple daemons is impractical)
    local has_no_stream=false
    local arg
    for arg in "${extra_args[@]}"; do
        [[ "$arg" == "--no-stream" ]] && has_no_stream=true
    done
    [[ "$has_no_stream" == false ]] && extra_args+=("--no-stream")

    for d in $(config_get_daemon_names); do
        local uid socket username
        uid="$(config_get_uid "$d")"
        [[ -n "$uid" ]] || continue
        socket="$(get_socket_path "$uid")"
        [[ -S "$socket" ]] || continue
        username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$d")"

        local output
        if is_root; then
            output="$(su -s /bin/sh "$username" -c \
                "DOCKER_HOST='unix://${socket}' '${docker_bin}' stats ${extra_args[*]:+${extra_args[*]}}" 2>/dev/null || true)"
        else
            output="$(sudo -u "$username" \
                DOCKER_HOST="unix://${socket}" \
                "$docker_bin" stats "${extra_args[@]:+${extra_args[@]}}" 2>/dev/null || true)"
        fi

        [[ -z "$output" ]] && continue

        if [[ "$header_printed" == false ]]; then
            local header
            header="$(head -1 <<< "$output")"
            printf '%s%-28s%s %s\n' "$CLR_BOLD" "DAEMON" "$CLR_RESET" "$header"
            header_printed=true
        fi

        tail -n +2 <<< "$output" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%-28s %s\n' "$d" "$line"
        done
    done
}

# --- generic (fallback) -------------------------------------------------------

_aggregate_generic() {
    local subcommand="$1"
    shift
    local -a extra_args=("$@")
    local docker_bin="${DOCKERU_DOCKER_BIN:-docker}"

    for d in $(config_get_daemon_names); do
        local uid socket username
        uid="$(config_get_uid "$d")"
        [[ -n "$uid" ]] || continue
        socket="$(get_socket_path "$uid")"
        [[ -S "$socket" ]] || continue
        username="$(get_user_for_uid "$uid" 2>/dev/null || echo "$d")"

        printf '\n%s── %s ──%s\n' "$CLR_CYAN" "$d" "$CLR_RESET"

        if is_root; then
            su -s /bin/sh "$username" -c \
                "DOCKER_HOST='unix://${socket}' '${docker_bin}' ${subcommand} ${extra_args[*]:+${extra_args[*]}}" 2>/dev/null || true
        else
            sudo -u "$username" \
                DOCKER_HOST="unix://${socket}" \
                "$docker_bin" "$subcommand" "${extra_args[@]:+${extra_args[@]}}" 2>/dev/null || true
        fi
    done
}

#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/platform.sh
# Platform detection, path resolution, prerequisite checks
# =============================================================================

# Populated by detect_platform()
DOCKERU_DISTRO=""
DOCKERU_DISTRO_VERSION=""
DOCKERU_DISTRO_FAMILY=""
DOCKERU_DOCKER_BIN=""

# --- Platform detection -------------------------------------------------------

detect_platform() {
    # Distro identification
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DOCKERU_DISTRO="${ID:-unknown}"
        DOCKERU_DISTRO_VERSION="${VERSION_ID:-unknown}"
        DOCKERU_DISTRO_FAMILY="${ID_LIKE:-$DOCKERU_DISTRO}"
    else
        DOCKERU_DISTRO="unknown"
        DOCKERU_DISTRO_VERSION="unknown"
        DOCKERU_DISTRO_FAMILY="unknown"
    fi

    # Docker binary
    DOCKERU_DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
    if [[ -z "$DOCKERU_DOCKER_BIN" ]]; then
        # Common fallback locations
        for path in /usr/bin/docker /usr/local/bin/docker; do
            if [[ -x "$path" ]]; then
                DOCKERU_DOCKER_BIN="$path"
                break
            fi
        done
    fi
}

# --- Path resolution ----------------------------------------------------------

# Resolve system-wide config directory
get_system_config_dir() {
    echo "/etc/dockeru"
}

# Resolve per-user config directory (XDG compliant)
get_user_config_dir() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/dockeru"
}

# Resolve the bash completion install directory
get_bash_completion_dir() {
    # System-wide locations (in preference order)
    local dirs=(
        "/usr/share/bash-completion/completions"
        "/etc/bash_completion.d"
    )
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    # Fallback
    echo "/etc/bash_completion.d"
}

# Resolve rootless Docker socket path for a UID
get_socket_path() {
    local uid="$1"
    local pattern="${DOCKERU_SOCKET_PATTERN:-/run/user/%UID%/docker.sock}"
    echo "${pattern//%UID%/$uid}"
}

# --- Prerequisite checks ------------------------------------------------------

# Check all prerequisites, return 0 if OK, print issues to stderr
check_prerequisites() {
    local issues=0

    # Bash version
    if (( BASH_VERSINFO[0] < 5 )); then
        log_error "Bash 5.0+ required (current: ${BASH_VERSION})"
        (( issues += 1 ))
    fi

    # Docker binary
    detect_platform
    if [[ -z "$DOCKERU_DOCKER_BIN" ]]; then
        log_error "Docker not found in PATH or common locations"
        (( issues += 1 ))
    fi

    # sudo
    if ! has_command sudo; then
        log_error "'sudo' not found — required for daemon user switching"
        (( issues += 1 ))
    fi

    # getent (used for user lookups)
    if ! has_command getent; then
        log_warn "'getent' not found — user lookup will fall back to /etc/passwd parsing"
    fi

    # systemd (for /run/user/ runtime directories)
    if ! has_command loginctl; then
        log_warn "'loginctl' not found — rootless Docker socket detection may be limited"
    fi

    return "$issues"
}

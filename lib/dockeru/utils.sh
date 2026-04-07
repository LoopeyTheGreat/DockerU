#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/utils.sh
# Common utilities: logging, colors, error handling, validation
# =============================================================================

# --- Colors -------------------------------------------------------------------

_init_colors() {
    if [[ "${DOCKERU_USE_COLOR:-true}" == true ]] && [[ -t 1 ]]; then
        readonly CLR_RED=$'\033[0;31m'
        readonly CLR_GREEN=$'\033[0;32m'
        readonly CLR_YELLOW=$'\033[1;33m'
        readonly CLR_BLUE=$'\033[0;34m'
        readonly CLR_CYAN=$'\033[0;36m'
        readonly CLR_BOLD=$'\033[1m'
        readonly CLR_DIM=$'\033[2m'
        readonly CLR_RESET=$'\033[0m'
    else
        readonly CLR_RED="" CLR_GREEN="" CLR_YELLOW="" CLR_BLUE=""
        readonly CLR_CYAN="" CLR_BOLD="" CLR_DIM="" CLR_RESET=""
    fi
}

# --- Logging ------------------------------------------------------------------

# Log informational message (suppressed by --quiet)
log_info() {
    [[ "${DOCKERU_QUIET:-false}" == true ]] && return 0
    printf '%s[dockeru]%s %s\n' "$CLR_CYAN" "$CLR_RESET" "$*" >&2
}

# Log warning
log_warn() {
    printf '%s[dockeru] WARNING:%s %s\n' "$CLR_YELLOW" "$CLR_RESET" "$*" >&2
}

# Log error
log_error() {
    printf '%s[dockeru] ERROR:%s %s\n' "$CLR_RED" "$CLR_RESET" "$*" >&2
}

# Log verbose message (only when --verbose)
log_verbose() {
    [[ "${DOCKERU_VERBOSE:-false}" == true ]] || return 0
    printf '%s[dockeru] >>%s %s\n' "$CLR_DIM" "$CLR_RESET" "$*" >&2
}

# Fatal error — log and exit
die() {
    log_error "$@"
    exit 1
}

# --- Validation ---------------------------------------------------------------

# Validate Docker container name (Docker's own naming rules)
validate_container_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

# Validate Linux username
validate_daemon_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]
}

# Validate numeric UID (reasonable range for daemon users)
validate_uid() {
    local uid="$1"
    [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 100 && uid <= 65534 ))
}

# --- Helpers ------------------------------------------------------------------

# Check if a command exists
has_command() {
    command -v "$1" &>/dev/null
}

# Get UID for a username (cross-distro)
get_uid_for_user() {
    local user="$1"
    id -u "$user" 2>/dev/null
}

# Get username for a UID (cross-distro)
get_user_for_uid() {
    local uid="$1"
    getent passwd "$uid" 2>/dev/null | cut -d: -f1
}

# Check if a user exists on the system
user_exists() {
    local user="$1"
    getent passwd "$user" &>/dev/null
}

# Check if running as root
is_root() {
    (( EUID == 0 ))
}

# Require a minimum bash version
require_bash_version() {
    local required="$1"
    local major="${required%%.*}"
    local minor="${required#*.}"
    minor="${minor%%.*}"

    if (( BASH_VERSINFO[0] < major )) || \
       (( BASH_VERSINFO[0] == major && BASH_VERSINFO[1] < minor )); then
        die "DockerU requires bash ${required}+. Current: ${BASH_VERSION}"
    fi
}

# Initialize colors on source
_init_colors

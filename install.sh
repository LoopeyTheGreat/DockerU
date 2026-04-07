#!/usr/bin/env bash
# =============================================================================
# DockerU — Installer / Uninstaller
#
# Usage:
#   ./install.sh              Interactive installation
#   ./install.sh --system     System-wide install (requires sudo)
#   ./install.sh --user       Current-user install only
#   ./install.sh --uninstall  Remove DockerU
#
# Supports: Debian 12+, Ubuntu 22.04+, Fedora 36+, RHEL 9+, Arch, openSUSE
# Requires: bash 5.0+, sudo
# =============================================================================

set -euo pipefail

readonly INSTALLER_VERSION="0.1.0-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Colors
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'
    DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" RESET=""
fi

# --- Helpers ------------------------------------------------------------------

info()  { printf '%s[install]%s %s\n' "$CYAN" "$RESET" "$*"; }
warn()  { printf '%s[install] WARNING:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%s[install] ERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()   { error "$@"; exit 1; }

confirm() {
    local prompt="${1:-Proceed?}" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "${prompt} [Y/n] " yn
        [[ "${yn,,}" == "n" ]] && return 1
    else
        read -rp "${prompt} [y/N] " yn
        [[ "${yn,,}" != "y" ]] && return 1
    fi
    return 0
}

# --- Pre-flight checks --------------------------------------------------------

preflight() {
    # Bash version
    if (( BASH_VERSINFO[0] < 5 )); then
        die "Bash 5.0+ required (current: ${BASH_VERSION})"
    fi

    # Source files exist
    if [[ ! -f "${SCRIPT_DIR}/bin/dockeru" ]]; then
        die "Source files not found. Run install.sh from the DockerU repository root."
    fi

    # Docker installed
    if ! command -v docker &>/dev/null; then
        warn "Docker not found in PATH. DockerU requires Docker to function."
    fi
}

# --- Installation paths -------------------------------------------------------

set_paths_system() {
    INSTALL_BIN="/usr/local/bin"
    INSTALL_LIB="/usr/local/lib/dockeru"
    INSTALL_COMPLETION="$(find_completion_dir_system)"
    INSTALL_CONFIG="/etc/dockeru"
    INSTALL_MAN="/usr/local/share/man/man1"
    NEEDS_SUDO=true
}

set_paths_user() {
    INSTALL_BIN="${HOME}/.local/bin"
    INSTALL_LIB="${HOME}/.local/lib/dockeru"
    INSTALL_COMPLETION="${HOME}/.bash_completion.d"
    INSTALL_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/dockeru"
    INSTALL_MAN="${HOME}/.local/share/man/man1"
    NEEDS_SUDO=false
}

find_completion_dir_system() {
    local dirs=(
        "/usr/share/bash-completion/completions"
        "/etc/bash_completion.d"
    )
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    echo "/etc/bash_completion.d"
}

# --- Install ------------------------------------------------------------------

do_install() {
    local mode="${1:-}"

    preflight

    if [[ -z "$mode" ]]; then
        # Interactive mode selection
        printf '\n%sDockerU Installer v%s%s\n\n' "$BOLD" "$INSTALLER_VERSION" "$RESET"
        printf 'Select installation scope:\n\n'
        printf '  %s1%s) System-wide (/usr/local/bin — requires sudo)\n' "$CYAN" "$RESET"
        printf '  %s2%s) Current user only (~/.local/bin)\n' "$CYAN" "$RESET"
        printf '\n'
        read -rp "Selection [1/2]: " choice
        case "$choice" in
            1) mode="system" ;;
            2) mode="user" ;;
            *) die "Invalid selection" ;;
        esac
    fi

    case "$mode" in
        system) set_paths_system ;;
        user)   set_paths_user ;;
        *)      die "Invalid mode: ${mode}" ;;
    esac

    printf '\n%sInstallation plan:%s\n' "$BOLD" "$RESET"
    printf '  Binary:      %s/dockeru\n' "$INSTALL_BIN"
    printf '  Libraries:   %s/\n' "$INSTALL_LIB"
    printf '  Completion:  %s/dockeru\n' "$INSTALL_COMPLETION"
    printf '  Config:      %s/\n' "$INSTALL_CONFIG"
    printf '\n'

    confirm "Install DockerU?" || { info "Cancelled."; exit 0; }

    local MAYBE_SUDO=""
    [[ "$NEEDS_SUDO" == true ]] && MAYBE_SUDO="sudo"

    # Create directories
    $MAYBE_SUDO mkdir -p "$INSTALL_BIN" "$INSTALL_LIB" "$INSTALL_COMPLETION" "$INSTALL_CONFIG"

    # Install binary
    $MAYBE_SUDO install -m 755 "${SCRIPT_DIR}/bin/dockeru" "${INSTALL_BIN}/dockeru"
    info "Installed binary: ${INSTALL_BIN}/dockeru"

    # Install libraries
    $MAYBE_SUDO install -m 644 "${SCRIPT_DIR}"/lib/dockeru/*.sh "${INSTALL_LIB}/"
    info "Installed libraries: ${INSTALL_LIB}/"

    # Patch lib path in binary if non-standard location
    local expected_lib="${INSTALL_BIN}/../lib/dockeru"
    local real_expected real_install
    real_expected="$(cd "${INSTALL_BIN}" && cd "../lib/dockeru" 2>/dev/null && pwd || echo "")"
    real_install="$(cd "$INSTALL_LIB" 2>/dev/null && pwd || echo "$INSTALL_LIB")"

    if [[ "$real_expected" != "$real_install" ]]; then
        $MAYBE_SUDO sed -i "s|readonly DOCKERU_LIB_DIR=.*|readonly DOCKERU_LIB_DIR=\"${INSTALL_LIB}\"|" \
            "${INSTALL_BIN}/dockeru"
        info "Patched library path to: ${INSTALL_LIB}"
    fi

    # Install bash completion
    $MAYBE_SUDO install -m 644 "${SCRIPT_DIR}/completions/dockeru.bash" "${INSTALL_COMPLETION}/dockeru"
    info "Installed bash completion: ${INSTALL_COMPLETION}/dockeru"

    # Install example config if no config exists yet
    if [[ ! -f "${INSTALL_CONFIG}/dockeru.conf" ]]; then
        $MAYBE_SUDO install -m 644 "${SCRIPT_DIR}/config/dockeru.conf.example" "${INSTALL_CONFIG}/dockeru.conf.example"
        info "Installed example config: ${INSTALL_CONFIG}/dockeru.conf.example"
    else
        info "Config already exists — preserved: ${INSTALL_CONFIG}/dockeru.conf"
    fi

    # Install man page if present
    if [[ -f "${SCRIPT_DIR}/man/dockeru.1" ]]; then
        $MAYBE_SUDO mkdir -p "$INSTALL_MAN"
        $MAYBE_SUDO install -m 644 "${SCRIPT_DIR}/man/dockeru.1" "${INSTALL_MAN}/dockeru.1"
        info "Installed man page"
    fi

    # PATH check
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_BIN"; then
        printf '\n%sNote:%s %s is not in your PATH.\n' "$YELLOW" "$RESET" "$INSTALL_BIN"
        printf 'Add to your shell profile:\n'
        printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_BIN"
    fi

    # Sudoers check
    _check_sudoers

    printf '\n%s✓ DockerU installed successfully.%s\n\n' "$GREEN" "$RESET"
    printf 'Next steps:\n'
    printf '  1. Source completion: %ssource %s/dockeru%s\n' "$DIM" "$INSTALL_COMPLETION" "$RESET"
    printf '  2. Discover daemons: %sdockeru --add%s\n' "$DIM" "$RESET"
    printf '  3. Refresh containers: %sdockeru --refresh --all%s\n' "$DIM" "$RESET"
    printf '  4. Verify setup: %sdockeru --doctor%s\n\n' "$DIM" "$RESET"
}

# --- Sudoers check/setup -----------------------------------------------------

_check_sudoers() {
    # Only relevant for non-root users
    (( EUID == 0 )) && return

    printf '\n%sSudo Configuration%s\n' "$BOLD" "$RESET"
    printf 'DockerU needs passwordless sudo to switch to daemon users.\n\n'

    # Quick test: can we sudo -u to any user?
    local test_user
    test_user="$(getent passwd 1101 2>/dev/null | cut -d: -f1 || true)"

    if [[ -n "$test_user" ]] && sudo -n -u "$test_user" true 2>/dev/null; then
        printf '%s✓ sudo access to daemon users appears to work.%s\n' "$GREEN" "$RESET"
        return
    fi

    printf '%s⚠ You may need to configure sudoers for daemon user access.%s\n' "$YELLOW" "$RESET"
    printf '\nDockerU can create a sudoers drop-in file. This would allow\n'
    printf 'your user (%s) to run docker as daemon users without a password.\n\n' "$(whoami)"

    printf '%s⚠ SECURITY NOTE:%s Passwordless sudo grants the ability to run\n' "$YELLOW" "$RESET"
    printf 'docker commands as other users. Only enable this on systems where\n'
    printf 'you trust the user account and all daemon users.\n\n'

    if ! confirm "Configure sudoers for DockerU?" "n"; then
        printf '\nSkipped. You can configure sudoers manually later.\n'
        printf 'See: dockeru --doctor\n'
        return
    fi

    local docker_bin
    docker_bin="$(command -v docker 2>/dev/null || echo "/usr/bin/docker")"
    local current_user
    current_user="$(whoami)"
    local sudoers_file="/etc/sudoers.d/dockeru-${current_user}"

    # Find all daemon-like users
    printf '\nScanning for rootless Docker daemon users...\n'
    local -a daemon_users=()
    local line
    while IFS=: read -r _ _ uid _ _ _ _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 900 && uid <= 65534 )) || continue
        local socket="/run/user/${uid}/docker.sock"
        [[ -S "$socket" ]] || continue
        local username
        username="$(getent passwd "$uid" | cut -d: -f1)"
        [[ -n "$username" ]] && daemon_users+=("$username")
    done < <(getent passwd)

    if (( ${#daemon_users[@]} == 0 )); then
        warn "No active rootless Docker daemons found. Skipping sudoers setup."
        return
    fi

    # Build sudoers content
    local sudoers_content="# DockerU — passwordless sudo for docker daemon users\n"
    sudoers_content+="# Generated by DockerU installer on $(date -Iseconds)\n"
    sudoers_content+="# User: ${current_user}\n\n"

    for du in "${daemon_users[@]}"; do
        sudoers_content+="${current_user} ALL=(${du}) NOPASSWD: ${docker_bin}\n"
    done

    printf '\nProposed sudoers rules:\n\n'
    printf '%b' "$sudoers_content"
    printf '\n'

    if ! confirm "Write to ${sudoers_file}?" "n"; then
        printf 'Skipped.\n'
        return
    fi

    # Write and validate
    local tmpfile
    tmpfile="$(mktemp)"
    printf '%b' "$sudoers_content" > "$tmpfile"

    if sudo visudo -c -f "$tmpfile" 2>/dev/null; then
        sudo install -m 440 "$tmpfile" "$sudoers_file"
        rm -f "$tmpfile"
        printf '%s✓ Sudoers configured: %s%s\n' "$GREEN" "$sudoers_file" "$RESET"
    else
        rm -f "$tmpfile"
        error "Sudoers validation failed — file NOT installed."
    fi
}

# --- Uninstall ----------------------------------------------------------------

do_uninstall() {
    printf '\n%sDockerU Uninstaller%s\n\n' "$BOLD" "$RESET"

    local found=false

    # Check system install
    if [[ -f "/usr/local/bin/dockeru" ]]; then
        printf '  Found system install: /usr/local/bin/dockeru\n'
        found=true
    fi

    # Check user install
    if [[ -f "${HOME}/.local/bin/dockeru" ]]; then
        printf '  Found user install: %s/.local/bin/dockeru\n' "$HOME"
        found=true
    fi

    if [[ "$found" == false ]]; then
        info "No DockerU installation found."
        exit 0
    fi

    printf '\n'
    confirm "Remove DockerU?" "n" || { info "Cancelled."; exit 0; }

    # Remove system install
    if [[ -f "/usr/local/bin/dockeru" ]]; then
        sudo rm -f /usr/local/bin/dockeru
        sudo rm -rf /usr/local/lib/dockeru
        local comp_dir
        for comp_dir in /usr/share/bash-completion/completions /etc/bash_completion.d; do
            sudo rm -f "${comp_dir}/dockeru" 2>/dev/null || true
        done
        sudo rm -f /usr/local/share/man/man1/dockeru.1 2>/dev/null || true
        info "Removed system installation."
    fi

    # Remove user install
    if [[ -f "${HOME}/.local/bin/dockeru" ]]; then
        rm -f "${HOME}/.local/bin/dockeru"
        rm -rf "${HOME}/.local/lib/dockeru"
        rm -f "${HOME}/.bash_completion.d/dockeru" 2>/dev/null || true
        rm -f "${HOME}/.local/share/man/man1/dockeru.1" 2>/dev/null || true
        info "Removed user installation."
    fi

    # Config cleanup
    printf '\n'
    if [[ -d "/etc/dockeru" ]]; then
        if confirm "Remove system config (/etc/dockeru/)?" "n"; then
            sudo rm -rf /etc/dockeru
            info "Removed /etc/dockeru/"
        fi
    fi

    local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/dockeru"
    if [[ -d "$user_conf" ]]; then
        if confirm "Remove user config (${user_conf}/)?" "n"; then
            rm -rf "$user_conf"
            info "Removed ${user_conf}/"
        fi
    fi

    # Sudoers cleanup
    local sudoers_file
    sudoers_file="/etc/sudoers.d/dockeru-$(whoami)"
    if [[ -f "$sudoers_file" ]]; then
        if confirm "Remove sudoers rules (${sudoers_file})?" "n"; then
            sudo rm -f "$sudoers_file"
            info "Removed sudoers file."
        fi
    fi

    printf '\n%s✓ DockerU uninstalled.%s\n\n' "$GREEN" "$RESET"
}

# --- Main ---------------------------------------------------------------------

main() {
    case "${1:-}" in
        --system)    do_install "system" ;;
        --user)      do_install "user" ;;
        --uninstall) do_uninstall ;;
        --help|-h)
            printf 'DockerU Installer\n\n'
            printf 'Usage:\n'
            printf '  ./install.sh              Interactive installation\n'
            printf '  ./install.sh --system     System-wide install (sudo)\n'
            printf '  ./install.sh --user       Current-user install\n'
            printf '  ./install.sh --uninstall  Remove DockerU\n'
            ;;
        "")          do_install ;;
        *)           die "Unknown option: ${1}. Try: ./install.sh --help" ;;
    esac
}

main "$@"

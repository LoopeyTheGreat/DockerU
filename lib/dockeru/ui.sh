#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — lib/ui.sh
# Interactive UI: menus, prompts, help text
# =============================================================================

# --- Help text ----------------------------------------------------------------

show_brief_help() {
    cat <<EOF
${CLR_BOLD}DockerU${CLR_RESET} v${DOCKERU_VERSION} — Multi-Daemon Rootless Docker Wrapper

${CLR_BOLD}Usage:${CLR_RESET}
  dockeru [OPTIONS] <docker-command> [args...]
  dockeru [MANAGEMENT-COMMAND] [args...]

${CLR_BOLD}Quick start:${CLR_RESET}
  dockeru --add                  Discover and add daemons
  dockeru --refresh              Update container registry
  dockeru ps                     Show all containers (all daemons)
  dockeru restart <container>    Restart a container (auto-routed)

Run ${CLR_CYAN}dockeru --help${CLR_RESET} for full usage.
EOF
}

show_help() {
    cat <<EOF
${CLR_BOLD}DockerU${CLR_RESET} v${DOCKERU_VERSION} — Multi-Daemon Rootless Docker Wrapper

Routes Docker commands to the correct rootless Docker daemon automatically.
Eliminates the need for: sudo -u <daemon_user> DOCKER_HOST=... docker ...

${CLR_BOLD}USAGE${CLR_RESET}
  dockeru [OPTIONS] <docker-command> [args...]
  dockeru [MANAGEMENT-COMMAND] [args...]

${CLR_BOLD}DOCKER PASSTHROUGH${CLR_RESET}
  dockeru restart <container>     Auto-route to the owning daemon
  dockeru logs -f <container>     Follow logs (auto-routed)
  dockeru exec <container> bash   Open shell (auto-routed)
  dockeru compose up -d           Route by working directory
  dockeru ps                      Show containers across ALL daemons
  dockeru images                  Show images across all daemons

${CLR_BOLD}OPTIONS${CLR_RESET}
  -d, --daemon <name>     Target a specific daemon (skip auto-routing)
  -v, --verbose           Show the resolved command before execution
  -n, --dry-run           Print the command without executing
  -q, --quiet             Suppress informational messages
  --no-color              Disable colored output
  --sudo                  Modify system-wide config (/etc/dockeru/)

${CLR_BOLD}MANAGEMENT COMMANDS${CLR_RESET}
  --add [daemon_user]     Add a daemon (interactive if no name given)
  --remove [daemon_user]  Remove a daemon (interactive if no name given)
  --list [daemon_user]    List daemons and their containers
  --refresh [daemon|--all] Refresh the container registry
  --status                Show daemon socket status and container counts
  --doctor                Check prerequisites, permissions, and configuration
  --version               Show version
  --help                  Show this help

${CLR_BOLD}EXAMPLES${CLR_RESET}
  ${CLR_DIM}# Add all discovered daemons${CLR_RESET}
  dockeru --add

  ${CLR_DIM}# Refresh container map for a specific daemon${CLR_RESET}
  dockeru --refresh docker-nextcloud

  ${CLR_DIM}# Restart a container (auto-detects correct daemon)${CLR_RESET}
  dockeru restart nextcloud_app

  ${CLR_DIM}# Run compose in a specific daemon context${CLR_RESET}
  dockeru -d docker-nextcloud compose up -d

  ${CLR_DIM}# See what command would run without executing${CLR_RESET}
  dockeru --dry-run exec traefik sh

  ${CLR_DIM}# View running containers across all daemons${CLR_RESET}
  dockeru ps

${CLR_BOLD}CONFIGURATION${CLR_RESET}
  System-wide:  /etc/dockeru/dockeru.conf
  Per-user:     ~/.config/dockeru/dockeru.conf

  Config file uses INI format with [daemon "name"] sections.
  Container mappings are auto-generated in containers.map files.
  Run ${CLR_CYAN}dockeru --doctor${CLR_RESET} to verify your environment.

${CLR_BOLD}HOW ROUTING WORKS${CLR_RESET}
  1. If --daemon is specified, use that daemon directly
  2. For 'compose' commands, detect daemon from working directory
  3. For other commands, look up container name in the registry
  4. For 'ps', 'images', 'stats' — aggregate across all daemons
  5. If no daemon can be determined, show a helpful error

${CLR_BOLD}MORE INFORMATION${CLR_RESET}
  Repository: https://github.com/LoopeyTheGreat/DockerU
  Man page:   man dockeru
EOF
}

# DockerU — Design & Implementation Plan

**Version:** 0.1.0-draft  
**Date:** April 6, 2026  
**Status:** Planning

---

## 1. Executive Summary

**DockerU** is a CLI wrapper for Docker commands on hosts running **multiple rootless Docker daemons** under separate system users. It eliminates the repetitive `sudo -u <daemon_user> DOCKER_HOST=unix:///run/user/<UID>/docker.sock docker ...` boilerplate by:

1. Maintaining a registry of daemon users → container name mappings
2. Auto-routing Docker commands to the correct daemon based on container name, working directory, or explicit flag
3. Providing unified cross-daemon views (`dockeru ps` shows all daemons at once)
4. Managing the registry with interactive and scriptable CLI commands

**Primary target:** Debian 12 (Bookworm) and later, with systemd-based rootless Docker.  
**Broad support:** Any Linux distro running systemd + rootless Docker (Ubuntu, Fedora, RHEL, Arch, etc).  
**Public repo:** Clean, documented, tested, and useful to anyone with multi-daemon rootless Docker.

### The Problem

On a multi-daemon rootless Docker host, every Docker operation requires:

```bash
# Current: 78 characters of boilerplate per command
sudo -u docker-nextcloud XDG_RUNTIME_DIR=/run/user/1105 DOCKER_HOST=unix:///run/user/1105/docker.sock docker ps

# DockerU: 11 characters
dockeru ps
```

No existing tool addresses this. Docker contexts can switch endpoints but don't auto-route by container name or aggregate across daemons.

---

## 2. Technical Design Decisions

### 2.1 Language: Bash (5.0+)

**Rationale:**
- Zero runtime dependencies beyond coreutils + Docker itself
- Universal presence on Docker hosts (every supported distro ships bash 5.0+)
- Native shell integration (tab completion, sourcing, piping)
- The tool wraps shell commands — bash is the natural fit
- Minimal footprint on headless servers

**Minimum bash version:** 5.0 (Debian Bullseye+, Ubuntu 20.04+, Fedora 32+, RHEL 9+)  
**Why 5.0:** Associative arrays (4.0), `readarray` (4.0), `${var@Q}` quoting (4.4), `EPOCHSECONDS` (5.0)

**Code quality gates:**
- ShellCheck clean (SC compliance, no suppression without justification)
- `set -euo pipefail` in all scripts
- Consistent quoting of all variables
- POSIX-compatible where practical; bashisms documented where used

### 2.2 Execution Model: `sudo -u` + `DOCKER_HOST`

The canonical execution pattern:

```bash
sudo -u "${daemon_user}" \
  XDG_RUNTIME_DIR="/run/user/${daemon_uid}" \
  DOCKER_HOST="unix:///run/user/${daemon_uid}/docker.sock" \
  docker "$@"
```

**Why both `XDG_RUNTIME_DIR` and `DOCKER_HOST`:**
- `DOCKER_HOST` tells the Docker client where the socket is
- `XDG_RUNTIME_DIR` is needed by some Docker/BuildKit operations that read runtime dir
- `sudo -u` switches to the daemon user's identity (required for socket permissions)

**Why not just `DOCKER_HOST` without `sudo -u`:**
- Rootless Docker sockets are typically `0700` in `/run/user/{UID}/`
- Only the owning user (or root) can access them
- Running as the daemon user is the correct security model

### 2.3 Configuration Layers

```
/etc/dockeru/                      # System-wide config (requires sudo to modify)
├── dockeru.conf                   # Daemon definitions
├── containers.map                 # Auto-generated container→daemon map
└── excluded.conf                  # Container names excluded from routing

~/.config/dockeru/                 # Per-user overrides
├── dockeru.conf                   # Additional/override daemon definitions
├── containers.map                 # Per-user container map
└── excluded.conf                  # Per-user exclusions
```

**Merge order:** System config loaded first, then per-user config overlays (per-user wins on conflict).

**Rationale for `/etc/dockeru` default:**
- Multi-daemon hosts are typically shared servers
- System-wide config means all operators see the same daemons
- Per-user config handles edge cases (personal dev environments, testing)

### 2.4 Config File Format

INI-style with sections — simple to parse in bash, readable for humans, easy for automation:

```ini
# /etc/dockeru/dockeru.conf
# DockerU - Multi-Daemon Rootless Docker Wrapper
# See: dockeru --help | man dockeru

[settings]
# Show the resolved command before execution (true/false)
verbose=false
# Socket path pattern (%UID% replaced at runtime)
socket_pattern=/run/user/%UID%/docker.sock
# Auto-refresh container map on management commands (true/false)
auto_refresh=true
# Default docker binary path (auto-detected if empty)
docker_bin=

[daemon "docker-proxy_tunnel"]
uid=1101
home=/opt/proxy_tunnel

[daemon "docker-nextcloud"]
uid=1105
home=/opt/nextcloud

[daemon "docker-immich_prism"]
uid=1104
home=/opt/immich_prism
```

**Why INI over YAML/TOML/JSON:**
- Bash can parse INI natively (no `yq`, `jq`, `python3` dependency)
- Human-readable and manually editable
- Ansible can template it trivially (Jinja2 `{% for %}`)
- `grep`/`sed`/`awk` friendly for one-liner automation

### 2.5 Container Map (Auto-Generated Cache)

Separate from config so it can be regenerated without touching manual settings:

```
# /etc/dockeru/containers.map
# Auto-generated by: dockeru --refresh
# Last refreshed: 2026-04-06T14:30:00Z
# DO NOT EDIT — regenerated on --refresh
#
# Format: container_name=daemon_name
traefik=docker-proxy_tunnel
cloudflared=docker-proxy_tunnel
crowdsec=docker-proxy_tunnel
nextcloud_app=docker-nextcloud
nextcloud_db=docker-nextcloud
collabora=docker-nextcloud
immich_server=docker-immich_prism
immich_db=docker-immich_prism
```

**Exclusion file** (container names that appear in multiple daemons):

```
# /etc/dockeru/excluded.conf
# Containers present in multiple daemons — require --daemon flag
# Auto-detected duplicates are listed first; manual additions below
#
# Auto-detected:
komodo_periphery
socket_proxy
# Manual:
portainer_agent
```

---

## 3. Command Interface

### 3.1 Docker Passthrough (Primary Use)

```bash
# Auto-routed by container name
dockeru restart nextcloud_app          # Finds daemon → runs restart
dockeru logs -f crowdsec               # Auto-routes, passes -f through
dockeru exec nextcloud_app bash        # Auto-routes, opens shell
dockeru inspect traefik                # Auto-routes

# Docker compose — routes by CWD or --daemon
dockeru compose up -d                  # Detects daemon from CWD (/opt/nextcloud → docker-nextcloud)
dockeru compose ps                     # Same
dockeru compose -f custom.yaml up      # Same

# Explicit daemon targeting (skips auto-routing)
dockeru -d docker-nextcloud ps         # All containers in this daemon
dockeru -d docker-nextcloud compose up -d

# Global aggregation
dockeru ps                             # docker ps across ALL daemons (merged table)
dockeru ls                             # Alias for ps
dockeru images                         # docker images across all daemons
```

### 3.2 Management Commands

```bash
# Daemon management
dockeru --add                          # Interactive: discover socket users, select which to add
dockeru --add docker-nextcloud         # Non-interactive: add specific user (auto-detect UID)
dockeru --remove                       # Interactive: select daemon to remove
dockeru --remove docker-nextcloud      # Non-interactive: remove with confirmation
dockeru --list                         # List all daemons + their containers
dockeru --list docker-nextcloud        # List containers for specific daemon

# Container registry
dockeru --refresh                      # Interactive: select daemons to refresh
dockeru --refresh docker-nextcloud     # Non-interactive: refresh specific daemon
dockeru --refresh --all                # Refresh all daemons non-interactively

# Diagnostics
dockeru --status                       # Show daemon socket status, container counts
dockeru --doctor                       # Check prerequisites, permissions, sudo config
dockeru --version                      # Version info
dockeru --help                         # Full help text
```

### 3.3 Options (Flags)

```
-d, --daemon <name>     Target specific daemon (skip auto-routing)
-v, --verbose           Show the resolved command before execution
-n, --dry-run           Print command without executing
-q, --quiet             Suppress dockeru status messages
--no-color              Disable colored output
--sudo                  Modify system config (prompts for privilege escalation)
```

### 3.4 Command Routing Logic

When the user runs `dockeru <args...>`, routing proceeds through this priority chain:

```
1. Is it a management command (--add, --refresh, etc.)? → Handle internally
2. Is --daemon/-d specified? → Use that daemon directly
3. Is the subcommand "compose"? → Route by CWD (see §3.5)
4. Parse args for container/service names → Look up in containers.map
   a. Found in exactly one daemon → Use that daemon
   b. Found in excluded list → Error: "Container 'X' exists in multiple daemons. Use -d <daemon>"
   c. Not found → Route by CWD (if in a known daemon home), else error
5. Is it a daemon-agnostic command (ps, images, ls)? → Aggregate across all daemons
6. Can't determine daemon → Error with helpful suggestion
```

### 3.5 Compose Routing (CWD-based)

For `docker compose` commands, daemon detection uses working directory:

```
1. Is --daemon specified? → Use that daemon
2. Check CWD and ancestors against daemon home directories:
   - CWD = /opt/nextcloud/      → docker-nextcloud
   - CWD = /opt/nextcloud/data/ → docker-nextcloud (ancestor match)
3. Not found → Error: "Cannot detect daemon from working directory. Use -d <daemon>"
```

### 3.6 Aggregated Commands

These commands iterate all configured daemons and merge output:

| Command | Behavior |
|---------|----------|
| `dockeru ps` | Merged `docker ps` with daemon column prepended |
| `dockeru ls` | Alias for `ps` |
| `dockeru images` | Merged `docker images` |
| `dockeru stats` | Merged `docker stats --no-stream` |

Output format (ps example):
```
DAEMON                    CONTAINER ID   IMAGE              STATUS          NAMES
docker-proxy_tunnel       a1b2c3d4       traefik:v3.6.1     Up 3 days      traefik
docker-proxy_tunnel       e5f6g7h8       cloudflared:...     Up 3 days      cloudflared
docker-nextcloud          i9j0k1l2       nextcloud:29        Up 12 hours    nextcloud_app
docker-nextcloud          m3n4o5p6       postgres:16         Up 12 hours    nextcloud_db
docker-immich_prism       q7r8s9t0       immich-server       Up 6 days      immich_server
```

---

## 4. Discovery System

### 4.1 Daemon Discovery (`dockeru --add`)

Discover rootless Docker daemon users automatically:

```bash
# Strategy: scan for active rootless Docker sockets
for dir in /run/user/*/; do
    uid="${dir#/run/user/}"
    uid="${uid%/}"
    socket="/run/user/${uid}/docker.sock"
    if [[ -S "$socket" ]]; then
        username=$(getent passwd "$uid" | cut -d: -f1)
        # Offer to add this daemon user
    fi
done
```

**Cross-distro notes:**
- `/run/user/{UID}/` is a systemd-logind convention (universal on systemd distros)
- `getent passwd` works on all Linux distros (POSIX)
- Fallback: parse `/etc/passwd` directly if `getent` is somehow unavailable

### 4.2 Container Discovery (`dockeru --refresh`)

For each configured daemon, enumerate ALL containers (not just running):

```bash
sudo -u "${daemon_user}" \
  DOCKER_HOST="unix:///run/user/${uid}/docker.sock" \
  docker ps -a --format '{{.Names}}' 2>/dev/null
```

**Uses `docker ps -a`** (all containers, not just running) because:
- Stopped containers still need routing for `docker start`, `docker logs`, `docker rm`
- The user's objective specifically stated "not just ones running"

### 4.3 Duplicate Detection

After refreshing, scan for container names that appear in multiple daemons:

```bash
# Sort all container→daemon entries, find duplicated names
sort containers.map | awk -F= '{print $1}' | uniq -d
```

Duplicates are:
1. Removed from `containers.map`
2. Added to `excluded.conf` (auto-detected section)
3. User is alerted with a clear message

---

## 5. Installation

### 5.1 Installer Overview (`install.sh`)

```bash
./install.sh                  # Interactive installer
./install.sh --uninstall      # Remove DockerU
./install.sh --user           # Install for current user only
./install.sh --system         # Install system-wide (requires sudo)
```

### 5.2 Installation Modes

| Mode | Binary Location | Config Location | Completion | Who Can Use |
|------|----------------|-----------------|------------|-------------|
| Current user only | `~/.local/bin/dockeru` | `~/.config/dockeru/` | `~/.bash_completion.d/` | Invoking user |
| System-wide | `/usr/local/bin/dockeru` | `/etc/dockeru/` | `/etc/bash_completion.d/` | All users |

### 5.3 Installer Steps

1. **Pre-flight checks:**
   - Verify bash 5.0+
   - Verify Docker is installed (`docker --version`)
   - Verify `sudo` is available
   - Detect OS/distro for any platform-specific adjustments

2. **Select installation scope** (interactive arrow-key menu):
   - Current user only
   - All users (system-wide, requires sudo)

3. **Install files:**
   - Copy `dockeru` binary to appropriate `bin/` directory
   - Copy library files to `lib/` directory alongside binary
   - Install bash completion script
   - Install zsh completion if zsh is present
   - Create config directory with example config

4. **Sudo configuration check:**
   - Detect if user has NOPASSWD sudo for target daemon users
   - If not, offer to create sudoers drop-in file (`/etc/sudoers.d/dockeru-<user>`)
   - **Warn about security implications** of NOPASSWD sudo
   - Show exact sudoers rule before applying, require confirmation
   - Validate with `visudo -c` before activating

5. **Initial daemon setup:**
   - Offer to run `dockeru --add` to discover and configure daemons
   - Skip if user wants to configure manually later

6. **Post-install:**
   - Display README summary
   - Show config file locations
   - Show how to `source` completion if shell restart isn't desired

### 5.4 Sudoers Configuration

DockerU needs passwordless `sudo -u <daemon>` for each daemon user. The minimal sudoers rule:

```
# /etc/sudoers.d/dockeru-dht-tech
dht-tech ALL=(docker-proxy_tunnel) NOPASSWD: /usr/bin/docker, /usr/bin/docker-compose
dht-tech ALL=(docker-nextcloud) NOPASSWD: /usr/bin/docker, /usr/bin/docker-compose
dht-tech ALL=(docker-immich_prism) NOPASSWD: /usr/bin/docker, /usr/bin/docker-compose
```

**Security approach:**
- Only allow `sudo -u` to specific daemon users (not ALL)
- Only allow specific binaries (docker, docker-compose)
- Warn user about risks and explain what the rule permits
- Never grant blanket NOPASSWD

### 5.5 Uninstaller

```bash
./install.sh --uninstall             # Interactive: choose what to remove
./install.sh --uninstall --user      # Remove current-user install
./install.sh --uninstall --system    # Remove system-wide install
```

Removes:
- Binary and library files
- Completion scripts
- Optionally: config files (prompt before deletion)
- Optionally: sudoers drop-in (prompt with warning)

---

## 6. Tab Completion

### 6.1 Bash Completion

```bash
# Completes:
# - Management commands: --add, --remove, --list, --refresh, --status, --help, --version, --doctor
# - Flags: -d, --daemon, -v, --verbose, -n, --dry-run
# - Daemon names: docker-proxy_tunnel, docker-nextcloud, ...
# - Container names: traefik, nextcloud_app, ...
# - Docker subcommands: ps, restart, logs, exec, compose, ...

_dockeru_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # After --daemon / -d, complete daemon names
    if [[ "$prev" == "--daemon" || "$prev" == "-d" ]]; then
        COMPREPLY=($(compgen -W "$(dockeru --list --names-only 2>/dev/null)" -- "$cur"))
        return
    fi

    # Management commands
    if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--add --remove --list --refresh --status --doctor --help --version --daemon --verbose --dry-run --quiet --no-color --sudo" -- "$cur"))
        return
    fi

    # Docker subcommands + container names
    COMPREPLY=($(compgen -W "ps ls images stats restart stop start rm logs exec inspect compose $(dockeru --list --containers-only 2>/dev/null)" -- "$cur"))
}
complete -F _dockeru_completions dockeru
```

### 6.2 Zsh Completion

Provide a `_dockeru` completion function installed to zsh's `fpath`.

### 6.3 Fish Completion

Provide `dockeru.fish` for fish shell users.

---

## 7. Cross-Distro Support

### 7.1 Supported Platforms

| Distro | Version | Init | Status | Notes |
|--------|---------|------|--------|-------|
| **Debian** | 12+ (Bookworm) | systemd | **Primary** | DHT production target |
| **Ubuntu** | 22.04+ (Jammy) | systemd | Full | Near-identical to Debian |
| **Fedora** | 36+ | systemd | Full | SELinux considerations |
| **RHEL/Rocky/Alma** | 9+ | systemd | Full | `docker-ce` from Docker repo |
| **Arch Linux** | Rolling | systemd | Full | Latest packages |
| **openSUSE** | Leap 15.4+ / TW | systemd | Full | Zypper-based install |

### 7.2 Non-Supported (Documented)

| Platform | Reason |
|----------|--------|
| Alpine Linux | OpenRC (no `/run/user/` by default) |
| macOS | Docker Desktop uses VM, not rootless daemons |
| WSL2 | Single Docker daemon typical; rootless possible but unusual |
| Non-systemd distros | Rootless Docker requires `systemctl --user` / `loginctl enable-linger` |

### 7.3 Distro-Specific Adaptations

```bash
detect_platform() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DOCKERU_DISTRO="${ID}"                    # debian, ubuntu, fedora, arch, etc.
        DOCKERU_DISTRO_VERSION="${VERSION_ID}"     # 12, 22.04, 39, etc.
        DOCKERU_DISTRO_FAMILY="${ID_LIKE:-$ID}"    # debian, rhel fedora, arch, etc.
    fi
}
```

**What varies:**
- Docker binary path: usually `/usr/bin/docker`, but check with `command -v docker`
- Sudoers path: `/etc/sudoers.d/` (universal on modern distros)
- Bash completion dir: `/etc/bash_completion.d/` or `/usr/share/bash-completion/completions/`
- User shell config: `~/.bashrc` (Debian/Ubuntu), `~/.bash_profile` (Fedora/RHEL)

**What doesn't vary:**
- Rootless Docker socket path: `/run/user/{UID}/docker.sock` (systemd-logind convention)
- `getent passwd`, `id`, `sudo`: universal POSIX/Linux
- Docker CLI syntax: identical across all distros

---

## 8. Project Structure

```
DockerU/
├── README.md                         # Comprehensive end-user documentation
├── LICENSE                           # MIT License
├── DESIGN.md                         # This file (architecture reference)
├── CONTRIBUTING.md                   # Contribution guidelines
├── CHANGELOG.md                      # Version history
├── install.sh                        # Installer / uninstaller script
│
├── bin/
│   └── dockeru                       # Main CLI entry point
│
├── lib/dockeru/
│   ├── config.sh                     # Config file parsing and merging
│   ├── discovery.sh                  # Daemon and container discovery
│   ├── router.sh                     # Command routing logic
│   ├── management.sh                 # --add, --remove, --refresh, --list
│   ├── aggregator.sh                 # Cross-daemon ps/images/stats
│   ├── ui.sh                         # Interactive menus, colored output
│   ├── platform.sh                   # Distro detection, path resolution
│   └── utils.sh                      # Logging, error handling, version info
│
├── completions/
│   ├── dockeru.bash                  # Bash tab completion
│   ├── _dockeru                      # Zsh completion function
│   └── dockeru.fish                  # Fish completion
│
├── config/
│   ├── dockeru.conf.example          # Annotated example config
│   └── excluded.conf.example         # Example exclusion list
│
├── tests/
│   ├── test_helper/
│   │   └── common.bash               # Shared test fixtures
│   ├── config.bats                   # Config parsing tests
│   ├── router.bats                   # Routing logic tests
│   ├── discovery.bats                # Discovery tests
│   ├── management.bats               # Management command tests
│   ├── aggregator.bats               # Aggregation tests
│   ├── platform.bats                 # Platform detection tests
│   └── integration.bats              # End-to-end (requires Docker)
│
├── man/
│   └── dockeru.1                     # Man page (groff format)
│
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                    # ShellCheck + bats on push/PR
│   │   └── release.yml               # Tag-triggered release
│   └── copilot-instructions.md       # AI development context
│
├── .shellcheckrc                     # ShellCheck configuration
├── .editorconfig                     # Editor consistency
│
└── _AI_Notes_/
    └── objective.md                  # Original concept (dev reference only)
```

---

## 9. Edge Cases & Safety

### 9.1 Container Name Conflicts

**Problem:** Container named `redis` exists in both `docker-nextcloud` and `docker-immich_prism`.

**Solution:**
1. `dockeru --refresh` detects the duplicate
2. Adds `redis` to `excluded.conf` automatically
3. Alerts user: `"Container 'redis' found in daemons: docker-nextcloud, docker-immich_prism. Added to exclusions."`
4. `dockeru restart redis` → Error: `"Container 'redis' exists in multiple daemons. Use: dockeru -d <daemon> restart redis"`

### 9.2 Daemon User Doesn't Exist

**Problem:** Config references `docker-nextcloud` but user doesn't exist on this host.

**Solution:** `dockeru --status` and `dockeru --doctor` flag this. Commands targeting this daemon produce:
`"Error: User 'docker-nextcloud' does not exist on this system. Run 'dockeru --remove docker-nextcloud' to clean config."`

### 9.3 Docker Socket Not Running

**Problem:** Daemon user exists but rootless Docker isn't running.

**Solution:** Detect missing socket file:
`"Warning: Docker socket not found for docker-nextcloud (expected /run/user/1105/docker.sock). Is the daemon running? Try: sudo loginctl enable-linger docker-nextcloud && sudo -u docker-nextcloud systemctl --user start docker"`

### 9.4 No Sudo Permission

**Problem:** User can't `sudo -u docker-nextcloud`.

**Solution:** `dockeru --doctor` tests each daemon with a lightweight probe:
```bash
sudo -u "$daemon" echo "ok" 2>/dev/null
```
Reports which daemons the user can/can't access and suggests sudoers fixes.

### 9.5 Container Created After Refresh

**Problem:** New container `nextcloud_cron` created but not in the map.

**Solution:**
- Error message includes: `"Container 'nextcloud_cron' not found. Run 'dockeru --refresh' to update, or use -d <daemon>."`
- If `auto_refresh=true` in settings, auto-refresh and retry once before erroring

### 9.6 Compose Project Without Known Home

**Problem:** `dockeru compose up` in `/tmp/test-stack/` (no daemon home match).

**Solution:**
`"Cannot detect daemon from directory '/tmp/test-stack/'. Use: dockeru -d <daemon> compose up -d"`

### 9.7 Running as Root

**Problem:** User runs `dockeru` as root.

**Solution:** Root doesn't need `sudo -u` to switch users. DockerU detects `EUID == 0` and adjusts execution:
```bash
# As root: skip sudo, just set env and run as target user
su - "${daemon_user}" -s /bin/bash -c "DOCKER_HOST=... docker $*"
```

### 9.8 Non-Docker Commands in Args

**Problem:** `dockeru network ls` — `ls` is not a container name, and `network` is a Docker subcommand, not a container.

**Solution:** Maintain a list of Docker subcommands that don't take container names:
```
network, volume, system, builder, buildx, plugin, trust, manifest, config, secret, node, service, stack, swarm, context, image (when used as subcommand)
```
For these, if no `-d` flag and no CWD match, aggregate across all daemons or require explicit daemon.

---

## 10. Testing Strategy

### 10.1 Unit Tests (bats-core)

Test individual functions in isolation by sourcing lib files and mocking `sudo`/`docker`:

```bash
# Mock docker to return predictable output
docker() {
    echo "nextcloud_app"
    echo "nextcloud_db"
}
export -f docker

# Test container discovery
source lib/dockeru/discovery.sh
run discover_containers "docker-nextcloud" 1105
assert_output --partial "nextcloud_app"
```

### 10.2 Integration Tests

Require a real multi-daemon Docker setup. Run in CI via:
- Dedicated test VM
- Or containerized test (docker-in-docker with multiple rootless setups)

### 10.3 CI Pipeline

```yaml
# .github/workflows/ci.yml
jobs:
  lint:
    - shellcheck bin/dockeru lib/dockeru/*.sh install.sh
    - shfmt -d bin/dockeru lib/dockeru/*.sh  # Formatting check

  test:
    strategy:
      matrix:
        os: [debian-12, ubuntu-24.04, fedora-40]
    steps:
      - Run bats unit tests
      - Run integration tests (if Docker available)
```

---

## 11. Implementation Phases

### Phase 1: Core MVP
**Goal:** Working command routing + basic management. Enough to be useful.

| Task | Description |
|------|-------------|
| 1.1 | Project scaffold: directories, `.shellcheckrc`, `.editorconfig`, stub files |
| 1.2 | `lib/utils.sh` — logging, color output, error handling, version |
| 1.3 | `lib/platform.sh` — distro detection, path resolution, prerequisite checks |
| 1.4 | `lib/config.sh` — INI parser, config loading, merge logic |
| 1.5 | `lib/discovery.sh` — daemon discovery (socket scan), container enumeration |
| 1.6 | `lib/router.sh` — command parsing, container lookup, daemon resolution, execution |
| 1.7 | `bin/dockeru` — CLI entry point, argument parsing, dispatch |
| 1.8 | Management: `--add`, `--list`, `--refresh`, `--remove` (non-interactive first) |
| 1.9 | Aggregated commands: `ps`, `ls`, `images` |
| 1.10 | `--help` and `--version` |
| 1.11 | Unit tests for all core modules |
| 1.12 | `README.md` — installation, usage, examples |

### Phase 2: Polish
**Goal:** Interactive UX, tab completion, installer.

| Task | Description |
|------|-------------|
| 2.1 | `lib/ui.sh` — arrow-key selection menus (pure bash, no dialog dependency) |
| 2.2 | Interactive mode for `--add`, `--remove`, `--refresh` |
| 2.3 | `completions/dockeru.bash` — tab completion |
| 2.4 | `completions/_dockeru` — zsh completion |
| 2.5 | `install.sh` — full installer with scope selection, sudoers setup |
| 2.6 | `install.sh --uninstall` — clean removal |
| 2.7 | `--doctor` command — comprehensive environment check |
| 2.8 | `--status` command — daemon health overview |
| 2.9 | `--dry-run` and `--verbose` flags |
| 2.10 | Compose CWD-based routing |

### Phase 3: Hardening
**Goal:** Production polish, documentation, CI.

| Task | Description |
|------|-------------|
| 3.1 | `man/dockeru.1` — manual page |
| 3.2 | `CONTRIBUTING.md` — contributor guide |
| 3.3 | `CHANGELOG.md` — version history |
| 3.4 | GitHub Actions CI (ShellCheck + bats + multi-distro matrix) |
| 3.5 | Integration test suite |
| 3.6 | `completions/dockeru.fish` — fish shell completion |
| 3.7 | Edge case hardening (root execution, missing daemons, broken sockets) |
| 3.8 | Performance: cache container map in memory, lazy loading |
| 3.9 | First tagged release (v0.1.0) |

### Phase 4: DHT Integration (Optional / Separate)
**Goal:** DHT-specific features that don't belong in the public tool.

| Task | Description |
|------|-------------|
| 4.1 | Pre-populated config generator from DHT UID_Registry |
| 4.2 | Ansible role to deploy DockerU on DHT hosts |
| 4.3 | Integration with `deploy.sh` scripts |

---

## 12. Security Considerations

### 12.1 Threat Model

DockerU runs with the invoking user's privileges and uses `sudo` to escalate to daemon users. Risks:

1. **Config file tampering** — malicious daemon entries could redirect commands
   - Mitigation: `/etc/dockeru/` requires root to modify; file permissions enforced
2. **Container name injection** — crafted container names in the map
   - Mitigation: validate container names against Docker naming rules (`[a-zA-Z0-9][a-zA-Z0-9_.-]`)
3. **Command injection via arguments** — user-supplied args passed to sudo
   - Mitigation: all arguments passed as discrete array elements, never interpolated into strings
4. **Sudoers over-permission** — granting too-broad sudo access
   - Mitigation: installer creates minimal sudoers rules; `dockeru --doctor` audits them

### 12.2 Input Validation

```bash
# Container names: Docker's own pattern
validate_container_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
}

# Daemon usernames: Linux username pattern
validate_daemon_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

# UID: numeric only
validate_uid() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1000 && $1 <= 65534 ))
}
```

### 12.3 No Secrets in Config

DockerU config files contain **no secrets** — only usernames, UIDs, and container names. This is safe for unencrypted storage and version control.

---

## 13. Open Questions / Decisions Needed

1. **License:** MIT (permissive) or Apache 2.0 (patent protection)? Recommendation: **MIT** for maximum adoption.

2. **`dockeru` or `dkru`?** Shorter alias? Could support both via symlink. The full name is clearer for a public tool.

3. **Auto-refresh behavior:** Should `dockeru restart <unknown_container>` auto-refresh once and retry? Or always require explicit `--refresh`? Recommendation: **auto-refresh once** if not found, with `auto_refresh=true` as default setting.

4. **Compose project directory mapping:** Should config store a `home=` path per daemon, or should it auto-detect from `/etc/passwd` home directory? Recommendation: **explicit `home=` in config** with fallback to passwd home.

5. **UID validation range:** DHT uses 1101-1199 for daemon UIDs. The public tool should accept the range 1000-65534. The 900-range system users (like `docker` UID 920) should also be configurable for rootful/base daemon support.

---

## 14. Non-Goals (Explicit Scope Boundaries)

- **Not a Docker replacement** — DockerU does not implement Docker functionality. It wraps it.
- **Not a container orchestrator** — No scheduling, scaling, or deployment logic.
- **Not a Docker context manager** — We don't modify Docker contexts. We run commands as specific users.
- **Not Podman-compatible** (yet) — Future consideration if there's demand. Same rootless multi-user pattern applies.
- **No daemon lifecycle management** — DockerU doesn't start/stop Docker daemons themselves. It operates on already-running daemons.

---

*This document is a living specification. Update it as implementation reveals better approaches.*

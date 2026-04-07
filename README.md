# DockerU

**Multi-Daemon Rootless Docker Command Wrapper**

DockerU eliminates the boilerplate of managing multiple rootless Docker daemons on a single host. Instead of typing:

```bash
sudo -u docker-nextcloud XDG_RUNTIME_DIR=/run/user/1105 DOCKER_HOST=unix:///run/user/1105/docker.sock docker restart nextcloud_app
```

Just type:

```bash
dockeru restart nextcloud_app
```

DockerU automatically detects which daemon owns the container and routes the command for you.

## The Problem

Rootless Docker is a security best practice — each service runs its own Docker daemon under a dedicated system user. But this creates operational friction:

- Every `docker` command needs `sudo -u <daemon_user>` + environment variables
- You must remember which containers belong to which daemon
- There's no unified view across daemons (`docker ps` only shows one)
- Tab completion doesn't work across daemon boundaries
- `docker compose` needs the right user context for the right directory

## Features

- **Auto-routing** — Detects the correct daemon from container name, working directory, or explicit flag
- **Unified view** — `dockeru ps` shows containers across all daemons in one table
- **Zero dependencies** — Pure bash, requires nothing beyond Docker and sudo
- **Tab completion** — Bash/Zsh completion for daemons, containers, and Docker subcommands
- **Smart discovery** — Scans for rootless Docker sockets and auto-builds the container registry
- **Cross-distro** — Supports any Linux with systemd + rootless Docker (Debian, Ubuntu, Fedora, RHEL, Arch, etc.)
- **Safe** — No secrets in config, minimal sudoers rules, input validation on all paths

## Quick Start

```bash
# Clone the repository
git clone https://github.com/LoopeyTheGreat/DockerU.git
cd DockerU

# Install (interactive — choose system-wide or current user)
./install.sh

# Discover your rootless Docker daemons
dockeru --add

# Build the container registry
dockeru --refresh --all

# Verify everything works
dockeru --doctor

# See all your containers
dockeru ps
```

## Usage

### Docker Passthrough (Primary Use)

```bash
# Auto-routed by container name
dockeru restart nextcloud_app          # Finds correct daemon automatically
dockeru logs -f traefik                # Follow logs from the right daemon
dockeru exec immich_server bash        # Shell into container

# Docker Compose (routes by working directory)
cd /opt/nextcloud
dockeru compose up -d                  # Runs as docker-nextcloud daemon
dockeru compose logs                   # Same daemon context

# Explicit daemon targeting
dockeru -d docker-nextcloud ps         # Force specific daemon

# Unified cross-daemon views
dockeru ps                             # All containers, all daemons
dockeru images                         # All images, all daemons
dockeru stats                          # Resource usage, all daemons
```

### Management Commands

```bash
# Daemon management
dockeru --add                          # Interactive discovery
dockeru --add docker-nextcloud         # Add specific daemon
dockeru --remove docker-nextcloud      # Remove from registry
dockeru --list                         # Show all daemons + containers

# Container registry
dockeru --refresh                      # Interactive refresh
dockeru --refresh docker-nextcloud     # Refresh specific daemon
dockeru --refresh --all                # Refresh all daemons

# Diagnostics
dockeru --status                       # Socket status, container counts
dockeru --doctor                       # Full environment check
```

### Useful Flags

```bash
dockeru -v restart nextcloud_app       # Show the resolved command
dockeru -n restart nextcloud_app       # Dry-run: print without executing
dockeru -d docker-proxy_tunnel ps      # Target specific daemon
```

## Configuration

DockerU uses INI-style config files:

**System-wide:** `/etc/dockeru/dockeru.conf`  
**Per-user:** `~/.config/dockeru/dockeru.conf`

```ini
[settings]
auto_refresh=true
socket_pattern=/run/user/%UID%/docker.sock

[daemon "docker-nextcloud"]
uid=1105
home=/opt/nextcloud

[daemon "docker-immich_prism"]
uid=1104
home=/opt/immich_prism
```

Container mappings are auto-generated in `containers.map` files by `dockeru --refresh`.

## How Routing Works

1. **`--daemon` flag?** → Use that daemon directly
2. **`compose` command?** → Match working directory to daemon home paths
3. **Container name in args?** → Look up in the container registry
4. **`ps`/`images`/`stats`?** → Aggregate across all daemons
5. **Not found?** → Auto-refresh once (if enabled), then helpful error

## Supported Platforms

| Distro | Version | Status |
|--------|---------|--------|
| **Debian** | 12+ (Bookworm) | Primary target |
| **Ubuntu** | 22.04+ | Full support |
| **Fedora** | 36+ | Full support |
| **RHEL/Rocky/Alma** | 9+ | Full support |
| **Arch Linux** | Rolling | Full support |
| **openSUSE** | Leap 15.4+ | Full support |

**Requirements:** bash 5.0+, Docker (rootless), sudo, systemd

## Installation Details

### System-Wide (Recommended for Servers)

```bash
./install.sh --system
```

Installs to `/usr/local/bin/`, `/usr/local/lib/dockeru/`, `/etc/dockeru/`.

### Current User Only

```bash
./install.sh --user
```

Installs to `~/.local/bin/`, `~/.local/lib/dockeru/`, `~/.config/dockeru/`.

### Uninstall

```bash
./install.sh --uninstall
```

### Sudoers Setup

DockerU needs passwordless `sudo -u <daemon_user>` access. The installer can create minimal sudoers rules:

```
# /etc/sudoers.d/dockeru-myuser
myuser ALL=(docker-nextcloud) NOPASSWD: /usr/bin/docker
myuser ALL=(docker-immich_prism) NOPASSWD: /usr/bin/docker
```

## Security

- **No secrets** — Config files contain only usernames, UIDs, and container names
- **Minimal sudo** — Only grants `sudo -u` to specific daemon users for Docker binary
- **Input validation** — Container names, daemon names, and UIDs are validated
- **No shell injection** — Arguments passed as discrete array elements, never string-interpolated
- **Socket permissions** — Respects rootless Docker's per-user socket ownership model

## Project Structure

```
DockerU/
├── bin/dockeru                   # CLI entry point
├── lib/dockeru/                  # Modular bash libraries
│   ├── utils.sh                  # Logging, colors, validation
│   ├── platform.sh               # Distro detection, path resolution
│   ├── config.sh                 # INI parser, config loading
│   ├── discovery.sh              # Daemon/container auto-discovery
│   ├── router.sh                 # Command routing and execution
│   ├── management.sh             # --add, --remove, --refresh, --list
│   ├── aggregator.sh             # Cross-daemon ps/images/stats
│   └── ui.sh                     # Help text, interactive prompts
├── completions/                  # Shell completions (bash, zsh, fish)
├── config/                       # Example configuration files
├── install.sh                    # Installer/uninstaller
├── tests/                        # bats-core test suite
└── DESIGN.md                     # Architecture documentation
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License — see [LICENSE](LICENSE) for details.

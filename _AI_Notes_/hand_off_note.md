# DockerU — Handoff to Dev/Test System

**Date:** April 6, 2026  
**Version:** 0.1.0-dev  
**Author:** GitHub Copilot (initial scaffold session)  
**Status:** Phase 1 scaffold complete — needs live multi-daemon testing

---

## What This Is

DockerU is a CLI wrapper for Docker commands on hosts running **multiple rootless Docker daemons** under separate system users. It eliminates the `sudo -u <daemon_user> XDG_RUNTIME_DIR=... DOCKER_HOST=... docker ...` boilerplate by auto-routing commands to the correct daemon based on container name, working directory, or explicit flag.

**This is a public repo tool** — designed to be useful to anyone with multi-daemon rootless Docker, not just DHT. Clean code, thorough docs, no DHT-specific assumptions baked in.

---

## What's Built

### Files (2,457 lines total, ShellCheck clean at warning severity)

```
bin/dockeru                    (127 lines) — CLI entry point, arg parsing, dispatch
lib/dockeru/
├── utils.sh                   (120 lines) — Logging, colors, validation, helpers
├── platform.sh                (112 lines) — Distro detection, path resolution, prereq checks
├── config.sh                  (283 lines) — INI parser, config load/merge/write, query helpers
├── discovery.sh               (156 lines) — Daemon socket scanning, container enumeration, duplicate detection
├── router.sh                  (313 lines) — Command parsing, container lookup, daemon resolution, execution
├── management.sh              (601 lines) — --add, --remove, --refresh, --list, --status, --doctor, config I/O
├── aggregator.sh              (193 lines) — Cross-daemon ps/images/stats with merged DAEMON column
└── ui.sh                      (103 lines) — Help text (brief + full)
completions/dockeru.bash        (61 lines) — Bash tab completion
install.sh                     (388 lines) — Interactive installer/uninstaller with sudoers setup
config/dockeru.conf.example                — Annotated example config
config/excluded.conf.example               — Example exclusion list
DESIGN.md                                  — Full architecture document (14 sections)
README.md                                  — User-facing documentation
LICENSE                                    — MIT
.shellcheckrc                              — ShellCheck config (cross-file suppression)
.editorconfig                              — Editor consistency
```

### Commands Verified Working (on dev workstation, no daemons configured)

| Command | Status | Notes |
|---------|--------|-------|
| `dockeru` (no args) | ✅ | Shows brief help |
| `dockeru --version` | ✅ | Prints `dockeru 0.1.0-dev` |
| `dockeru --help` | ✅ | Full usage with examples |
| `dockeru --doctor` | ✅ | Checks bash, docker, sudo, platform, config files, daemon access |
| `dockeru --status` | ✅ | Reports "No daemons configured" gracefully |
| `dockeru --list` | ✅ | Reports "No daemons configured" with hint to `--add` |
| `dockeru ps` | ✅ | Error: "No daemons configured" (correct — no daemons) |
| `dockeru --dry-run restart foo` | ✅ | Verbose trace → auto-refresh attempt → "not found" error |
| ShellCheck (warning level) | ✅ | **CLEAN** — no warnings or errors |

### Commands That NEED Multi-Daemon Testing

These are implemented but **untested** without real rootless daemon sockets:

| Command | What to Test |
|---------|-------------|
| `dockeru --add` | Interactive discovery of `/run/user/*/docker.sock` — should find all daemon users |
| `dockeru --add docker-nextcloud` | Non-interactive add — should detect UID, verify socket, write to config |
| `dockeru --refresh --all` | Enumerate containers via `docker ps -a` per daemon, build `containers.map` |
| `dockeru --refresh docker-nextcloud` | Single-daemon refresh |
| `dockeru restart <container>` | **Core feature:** container name → lookup map → correct daemon → `sudo -u` execution |
| `dockeru exec <container> bash` | Exec routing (skips `-it` flags to find container name) |
| `dockeru logs -f <container>` | Passthrough with auto-routing |
| `dockeru compose up -d` | CWD-based routing (e.g., from `/opt/nextcloud/` → `docker-nextcloud`) |
| `dockeru -d docker-nextcloud ps` | Explicit daemon targeting |
| `dockeru ps` (with daemons) | Aggregated cross-daemon table with DAEMON column |
| `dockeru images` | Aggregated cross-daemon images |
| `dockeru stats` | Aggregated stats (auto-adds `--no-stream`) |
| Tab completion | Daemon names + container names from `--list` |
| `install.sh` | Full install flow: scope selection, file copy, PATH, sudoers, post-install |
| `install.sh --uninstall` | Clean removal |

---

## Architecture Quick Reference

### Execution Model

```bash
# What dockeru does internally:
sudo -u "${daemon_user}" \
  XDG_RUNTIME_DIR="/run/user/${uid}" \
  DOCKER_HOST="unix:///run/user/${uid}/docker.sock" \
  docker "$@"

# When running as root, uses su instead of sudo
```

### Config Files

```
/etc/dockeru/dockeru.conf        — System-wide daemon definitions (INI format)
/etc/dockeru/containers.map      — Auto-generated container→daemon map
/etc/dockeru/excluded.conf       — Container names in multiple daemons (auto-detected)
~/.config/dockeru/                — Per-user overrides (same files, overlay merge)
```

### Routing Priority Chain

```
1. Is --daemon/-d specified?          → Use that daemon
2. Is it ps/ls/images/stats?          → Aggregate across all daemons
3. Is it compose?                     → Match CWD to daemon home dirs
4. Is it exec?                        → Parse past flags to find container name
5. Is it a container subcommand?      → Lookup container in map
6. Scan all args for known container  → Use if found
7. Try CWD match as fallback          → Use if matched
8. Try infra subcommand aggregation   → Aggregate if applicable
9. Fail with helpful error            → Suggest -d or --refresh
```

### Auto-Refresh

When `auto_refresh=true` (default) and a container name isn't found, DockerU will:
1. Run `docker ps -a` against all configured daemons
2. Rebuild the container map
3. Retry the lookup once
4. If still not found, error with suggestions

---

## Known Issues / Incomplete Items

### Must Fix During Testing

1. **`exec` as root path** — The `is_root` branch in `_exec_for_daemon()` uses `su -s /bin/sh -c "... $*"` which string-interpolates args. This is safe for simple commands but may break with special characters in container args. Consider switching to a proper array-based execution for the root path. **Test with:** `sudo dockeru exec nextcloud_app bash -c "echo hello world"`

2. **Compose passthrough completeness** — `dockeru compose` routes the command but the `exec` call replaces the dockeru process. This is intentional (direct passthrough) but means post-compose hooks or chained commands won't work. Verify this is acceptable for real use.

3. **Socket pattern override** — The `socket_pattern` setting in config allows `/run/user/%UID%/docker.sock` customization but hasn't been tested with non-standard paths.

### Not Yet Implemented (Phase 2)

- **Interactive arrow-key menus** — Currently uses numbered selection. `lib/ui.sh` is a stub for the interactive menu system described in the objective.
- **Zsh completion** (`completions/_dockeru`) — Not created yet
- **Fish completion** (`completions/dockeru.fish`) — Not created yet
- **Man page** (`man/dockeru.1`) — Not created yet
- **Test suite** (`tests/*.bats`) — No bats-core tests yet
- **CI pipeline** (`.github/workflows/`) — Not created yet
- **`CONTRIBUTING.md`** — Not created yet
- **`CHANGELOG.md`** — Not created yet

### Design Decisions to Validate

1. **INI config format** — Should work well but the parser hasn't been tested with malformed input. Run garbage through it.
2. **`exec` vs forking** — `_exec_for_daemon()` uses `exec` which replaces the process. This is efficient but means dockeru can't do post-execution cleanup. If cleanup is needed later, switch to direct execution without `exec`.
3. **Aggregation output alignment** — The DAEMON column is 28 chars wide. If daemon names are longer, output will misalign. Check with real DHT daemon names like `docker-gimp_mpaint_bitmapper` (29 chars).

---

## Testing Plan for Dev System

### Prerequisites

- Debian 12+ or 13 host with at least 2 rootless Docker daemons configured
- DHT setup ideal: `docker-proxy_tunnel` (UID 1101), `docker-nextcloud` (UID 1105), etc.
- User with sudo access to those daemon users
- Some containers running in each daemon

### Step-by-Step Test Sequence

```bash
# 1. Clone and install
cd /opt/DockerU  # or wherever
./install.sh --system
source /etc/bash_completion.d/dockeru  # or restart shell

# 2. Verify prereqs
dockeru --doctor

# 3. Discover daemons
dockeru --add   # Interactive: should find all rootless sockets

# 4. Build container registry
dockeru --refresh --all

# 5. Verify configuration
dockeru --list                        # All daemons + containers
dockeru --list docker-proxy_tunnel    # Specific daemon
dockeru --status                      # Socket status table
cat /etc/dockeru/dockeru.conf         # Check daemon definitions
cat /etc/dockeru/containers.map       # Check container mappings
cat /etc/dockeru/excluded.conf        # Check duplicates

# 6. Test core routing
dockeru ps                            # Aggregated view — DAEMON column
dockeru -n restart traefik            # Dry-run: verify resolved command
dockeru restart traefik               # Live: should work
dockeru logs --tail 5 traefik         # Auto-routed logs
dockeru exec traefik sh               # Auto-routed exec

# 7. Test compose routing
cd /opt/nextcloud                     # Or whatever daemon home
dockeru compose ps                    # Should detect docker-nextcloud
dockeru -d docker-proxy_tunnel compose ps  # Explicit override

# 8. Test explicit daemon
dockeru -d docker-proxy_tunnel ps
dockeru -d docker-nextcloud images

# 9. Test edge cases
dockeru restart nonexistent_container  # Should auto-refresh then error
dockeru restart socket_proxy           # If this name exists in multiple daemons → exclusion error
dockeru compose ps                     # From a non-daemon directory → should error with hint

# 10. Test tab completion
dockeru --<TAB>                       # Management commands
dockeru -d <TAB>                      # Daemon names
dockeru restart <TAB>                 # Container names
dockeru <TAB>                         # Docker subcommands + containers

# 11. Stress test
dockeru --verbose restart traefik     # Verify the full sudo -u command shown
sudo dockeru ps                       # Running as root — should use su instead of sudo
dockeru stats                         # Aggregated stats across daemons

# 12. Test install/uninstall
./install.sh --uninstall              # Clean removal, verify nothing left behind
./install.sh --system                 # Reinstall, verify idempotent
```

### What to Report Back

- Which commands worked / failed
- Any output formatting issues (column alignment, color, etc.)
- Whether auto-refresh correctly finds new containers
- Whether duplicate detection works (e.g., `socket_proxy`, `komodo_periphery`)
- Edge cases: long daemon names, special characters in container names
- Sudoers: did the installer create correct rules? Can user run dockeru without password?
- Any security concerns noticed

---

## Key Design Documents

- **`DESIGN.md`** — Full technical architecture (14 sections: execution model, routing, config, discovery, installation, cross-distro, edge cases, security, phases)
- **`_AI_Notes_/objective.md`** — Original concept from the user (raw notes, typos preserved)
- **`README.md`** — Public-facing documentation

---

## Repo Memory Notes

From repository memories worth carrying forward:
- DHT uses unified index pattern: Index X → UID 110X → subnet 172.20.X.0/24
- Open_Kasm is Index 7 (not 6 — Cloud_Puller already had 6)
- Cloud_Puller Phase 1.5 was validated end-to-end on Dev-Scout
- Daemon names follow `docker-{repo_name}` convention
- Rootless Docker sockets at `/run/user/{UID}/docker.sock`
- Cross-daemon routing uses dummy0 at `10.255.255.1`

---

*This scaffold was built in a single session on the dev workstation (Debian 12, no rootless daemons available). All code paths are implemented but the core value — live command routing — requires a multi-daemon host to validate. The code is clean, modular, and ready for real testing.*
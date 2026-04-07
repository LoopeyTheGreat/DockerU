#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# DockerU — Bash Tab Completion
# =============================================================================

_dockeru_completions() {
    local cur prev words cword
    _init_completion || return

    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # After --daemon / -d, complete with daemon names
    if [[ "$prev" == "--daemon" || "$prev" == "-d" ]]; then
        local names
        names="$(dockeru --list --names-only 2>/dev/null)"
        COMPREPLY=($(compgen -W "$names" -- "$cur"))
        return
    fi

    # Management commands and flags
    if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "\
            --add --remove --list --refresh --status --doctor \
            --help --version --daemon --verbose --dry-run \
            --quiet --no-color --sudo --all" -- "$cur"))
        return
    fi

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-d -v -n -q -h" -- "$cur"))
        return
    fi

    # After management commands that take a daemon name
    case "$prev" in
        --add|--remove|--list|--refresh)
            local names
            names="$(dockeru --list --names-only 2>/dev/null)"
            COMPREPLY=($(compgen -W "$names" -- "$cur"))
            return
            ;;
    esac

    # Docker subcommands and container names
    local docker_subcmds="ps ls images stats restart stop start rm logs exec \
        inspect top port diff export wait rename update commit cp \
        compose run build pull push tag save load history create \
        network volume system prune"

    local containers
    containers="$(dockeru --list --containers-only 2>/dev/null)"

    local daemon_names
    daemon_names="$(dockeru --list --names-only 2>/dev/null)"

    COMPREPLY=($(compgen -W "${docker_subcmds} ${containers} ${daemon_names}" -- "$cur"))
}

complete -F _dockeru_completions dockeru

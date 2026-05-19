#!/bin/sh
# Drop privileges to the agent user before exec'ing molecule-runtime.
#
# Why this exists (per-template privilege contract — RFC internal#456)
# --------------------------------------------------------------------
# Previously this template had NO entrypoint wrapper: the Dockerfile's
# `ENTRYPOINT ["molecule-runtime"]` ran the runtime as ROOT. That posture
# is *insecure* (untrusted agent workload runs with root capabilities
# in-container) and is *fragile*: in SaaS mode the runtime itself writes
# /configs/.auth_token, owned by whatever uid molecule-runtime executes
# as. If a later hardening change drops privilege to uid-1000 WITHOUT
# atomically guaranteeing token agent-ownership, list_peers / any
# platform-bearer call regresses with HTTP 401 — the exact Hermes
# list_peers-401 class (RFC internal#456 §10).
#
# Therefore the class fix MUST atomically:
#   1. chown /configs (and thus /configs/.auth_token) to agent:agent
#      while still root, BEFORE the runtime writes its token
#   2. re-exec the runtime via `gosu agent` so molecule-runtime is
#      uid-1000 from the moment it starts — every token write,
#      every config write, every adapter import happens agent-owned
#
# Both halves ship in the same image revision; the t4-conformance CI
# gate (Layer-3 of the RFC) asserts both on a live container
# (final-process uid == 1000 AND /configs/.auth_token owner_uid == 1000)
# and fails closed on any future revert.
#
# Pattern matches template-claude-code/entrypoint.sh (the proven
# reference contract) and template-autogen/entrypoint.sh (PR#8, the
# parallel close for the bare-runtime shape).

# Boot-context snapshot — emitted on EVERY container start, including
# every restart of a crash-loop. Lets `docker logs` answer "what env
# was present?" without docker exec into a dying container. Logs NAMES
# of auth-relevant env vars, never VALUES. Fires twice (once as root
# pre-gosu, once as agent post-gosu) so an operator can see whether a
# value or the token ownership survived the privilege drop.
log_boot_context() {
    echo "----- entrypoint boot $(date -u +%Y-%m-%dT%H:%M:%SZ) -----"
    echo "uid=$(id -u) gid=$(id -g) user=$(id -un 2>/dev/null || echo unknown)"
    echo "hostname=$(hostname) workspace_id=${WORKSPACE_ID:-<unset>}"
    echo "platform_url=${PLATFORM_URL:-<unset>}"
    echo "configs_dir: $(ls -ld /configs 2>/dev/null || echo MISSING)"
    echo "configs_contents: $(ls /configs 2>/dev/null | tr '\n' ' ' || echo MISSING)"
    if [ -e /configs/.auth_token ]; then
        echo "auth_token: $(ls -l /configs/.auth_token 2>/dev/null) owner_uid=$(stat -c '%u' /configs/.auth_token 2>/dev/null)"
    else
        echo "auth_token: <not yet issued>"
    fi
    echo "workspace_dir: $(ls -ld /workspace 2>/dev/null || echo MISSING)"
    for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL MINIMAX_API_KEY GLM_API_KEY KIMI_API_KEY DEEPSEEK_API_KEY OPENAI_API_KEY; do
        eval "val=\$$var"
        if [ -n "$val" ]; then
            echo "env $var=set"
        else
            echo "env $var=unset"
        fi
    done
    echo "------------------------------------------------"
}
log_boot_context

if [ "$(id -u)" = "0" ]; then
    # /configs is created by Docker as root; the uid-1000 agent needs
    # read access to /configs/.auth_token (platform bearer token, the
    # list_peers auth) and write access for token rotation, adapter
    # config writes, and per-tenant config drops. The chown lands BEFORE
    # the gosu re-exec so the runtime's own first token write happens
    # agent-owned (SaaS mode writes /configs/.auth_token in-container).
    chown -R agent:agent /configs 2>/dev/null
    # /workspace handling — only chown when the contents are root-owned
    # (typical on Docker Desktop on Windows where host uid maps to 0).
    # On Linux Docker with matching uids the recursive chown is skipped
    # to keep startup fast.
    chown agent:agent /workspace 2>/dev/null || true
    if [ -d /workspace ]; then
        first_entry=$(find /workspace -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
        if [ -n "$first_entry" ] && [ "$(stat -c '%u' "$first_entry" 2>/dev/null)" = "0" ]; then
            chown -R agent:agent /workspace 2>/dev/null
        fi
    fi

    exec gosu agent "$0" "$@"
fi

# Now running as agent (uid 1000)
#
# Third-party provider routing is handled by adapter.py at boot — it
# reads the `providers:` registry from /configs/config.yaml and sets
# ANTHROPIC_BASE_URL based on the picked MODEL. Operator-set
# ANTHROPIC_BASE_URL still wins as the escape hatch for regional
# endpoints.

exec molecule-runtime "$@"

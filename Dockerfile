FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gosu ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI
RUN npm install -g @google/gemini-cli 2>/dev/null || true

RUN useradd -u 1000 -m -s /bin/bash agent
# --- Pre-bake the org-management MCP for DETERMINISTIC concierge warm-up (core#3082). ---
# The kind=platform concierge's management MCP is delivered as a plugin
# (molecule-ai-plugin-molecule-platform-mcp) whose settings-fragment launches
#   npx --prefer-offline @molecule-ai/mcp-server@<ver>
# On a FRESH concierge that npx would otherwise COLD-PULL the full ~100-dep tree
# from the Cloudflare-fronted Gitea npm registry — a network fetch that races the
# runtime readiness probe's per-server 20s handshake budget and, under CF-WAF
# throttling / concurrent-npx contention, can blow past the readiness window
# entirely (observed: a fresh concierge stuck 503 past 300s while a warm one
# reached its tools in ~48s — the whole "flaky warm-up" is that ONE network pull).
#
# Baking the exact version + its dep tree into the AGENT user's npm caches at
# BUILD time makes the runtime's `npx --prefer-offline` resolve ENTIRELY FROM
# CACHE — ZERO network pull — so warm-up is fast + deterministic every time.
# `--prefer-offline` (set in the plugin fragment) keeps the registry as a
# SELF-HEALING fallback if the cache ever misses (older image, cache evicted).
#
# ORDERING (fix vs the #210 claude-code block): the `npm install` into $warm only
# seeds the CONTENT cache (_cacache tarballs) — it does NOT create the npx run
# cache (_npx). npx --offline resolves a package via _npx + the cached PACKUMENT;
# with neither present it dies `ENOTCACHED: cache mode is only-if-cached but no
# cached response is available`. If the seeding `npx --prefer-offline` runs while
# cwd=$warm (node_modules still present) npx executes the LOCAL copy and never
# builds an _npx entry, so a later --offline resolve fails. We therefore DISCARD
# $warm FIRST, then run the seeding `npx --prefer-offline` from a clean cwd so it
# actually creates the _npx entry + caches the packument — making the strict
# --offline self-check (and the runtime --prefer-offline) resolve with zero
# network. Verified deterministic (3/3 fresh HOMEs) in node:22.
#
# HYGIENE: we warm only the caches (throwaway install, then discard node_modules)
# — the admin MCP is NOT globally installed and NOT on PATH here, so an ordinary
# (non-concierge) workspace on this shared image gains only inert cached tarballs,
# never an active admin tool surface (the tools require MOLECULE_MCP_MODE=management
# + a CP-authenticated bearer, injected only into the concierge). Run as `agent` so
# the cache lands in the SAME /home/agent/.npm the gosu-dropped runtime reads at boot.
#
# MCP_SERVER_VERSION MUST match the plugin fragment's pinned version
# (molecule-ai-plugin-molecule-platform-mcp settings-fragment.json). A stale bake
# still WORKS (npx --prefer-offline network-fallback) but forfeits determinism, so
# keep them in lockstep. Declared as an ARG so the publish workflow can override.
ARG MCP_SERVER_VERSION=1.7.0
USER agent
RUN set -eux; \
    mkdir -p /home/agent/.npm; \
    printf '@molecule-ai:registry=https://git.moleculesai.app/api/packages/molecule-ai/npm/\n' > /home/agent/.npmrc; \
    warm="$(mktemp -d)"; cd "$warm"; npm init -y >/dev/null 2>&1; \
    npm install --no-audit --no-fund --loglevel=error "@molecule-ai/mcp-server@${MCP_SERVER_VERSION}"; \
    cd /; rm -rf "$warm"; \
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"prebake","version":"1"}}}' \
      | MOLECULE_MCP_MODE=management timeout 60 npx -y --prefer-offline "@molecule-ai/mcp-server@${MCP_SERVER_VERSION}" >/dev/null 2>&1 || true; \
    printf '%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      | MOLECULE_MCP_MODE=management timeout 60 npx -y --offline "@molecule-ai/mcp-server@${MCP_SERVER_VERSION}" 2>/dev/null | grep -q provision_workspace \
      || (echo "ERROR: pre-baked @molecule-ai/mcp-server@${MCP_SERVER_VERSION} did not resolve OFFLINE or provision_workspace missing — the concierge warm-up bake is broken" >&2 && exit 1)
USER root

WORKDIR /app

# RUNTIME_VERSION is forwarded from molecule-ci's reusable publish
# workflow as a docker build-arg. Cascade-triggered builds set it to
# the exact runtime version PyPI just published. Including it as an
# ARG changes the cache key for the pip install layer below — the
# fix for the cascade cache trap that bit us 5x on 2026-04-27.
ARG RUNTIME_VERSION=

# Gitea PyPI registry is the PRIMARY internal index (RFC internal#596; CTO GO
# 2026-05-19). It serves the private molecule-ai-workspace-runtime wheel,
# including versions that are Gitea-only (e.g. 0.2.x / 0.3.x). Anonymous reads
# work because molecule-ai is a public org -- no auth wired into the build.
# pypi.org stays as the extra index for transitive deps that are PyPI-only.
# Without the Gitea index, a cascade-pinned RUNTIME_VERSION newer than what is
# mirrored to public PyPI (max 0.1.131) fails to resolve and the build dies.
ARG PIP_INDEX_URL=https://git.moleculesai.app/api/packages/molecule-ai/pypi/simple/
ARG PIP_EXTRA_INDEX_URL=https://pypi.org/simple/

COPY requirements.txt .
RUN pip install --no-cache-dir \
      --index-url "${PIP_INDEX_URL}" \
      --extra-index-url "${PIP_EXTRA_INDEX_URL}" \
      -r requirements.txt && \
    if [ -n "${RUNTIME_VERSION}" ]; then \
      pip install --no-cache-dir --upgrade \
        --index-url "${PIP_INDEX_URL}" \
        --extra-index-url "${PIP_EXTRA_INDEX_URL}" \
        "molecule-ai-workspace-runtime==${RUNTIME_VERSION}"; \
    fi

COPY adapter.py .
COPY __init__.py .
# Adapter-specific executor — owned by THIS template (universal-runtime
# refactor, molecule-core task #87 / #122). Lives alongside adapter.py
# so Python's import system picks the local /app/cli_executor.py before
# any same-named module under site-packages. Once molecule-core drops
# the file from its workspace/ package, this template becomes the sole
# source of truth (codex/ollama presets in the file are dead — neither
# has a template repo today, so the file lives here only for gemini-cli).
COPY cli_executor.py .

ENV ADAPTER_MODULE=adapter

# Drop-priv entrypoint — per-template privilege contract
# (RFC internal#456). Without this, molecule-runtime ran as ROOT and the
# untrusted agent workload had root capabilities in-container. The
# entrypoint runs as root only long enough to chown /configs to
# agent:agent (so /configs/.auth_token stays agent-readable when the
# runtime writes it in SaaS mode) then re-execs the runtime via
# `gosu agent` so the final process is uid-1000. Both halves are atomic
# — dropping privilege without the chown would regress list_peers to
# the Hermes 401 class.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

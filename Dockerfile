FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gosu ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI
RUN npm install -g @google/gemini-cli 2>/dev/null || true

RUN useradd -u 1000 -m -s /bin/bash agent
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

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

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    if [ -n "${RUNTIME_VERSION}" ]; then \
      pip install --no-cache-dir --upgrade "molecule-ai-workspace-runtime==${RUNTIME_VERSION}"; \
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

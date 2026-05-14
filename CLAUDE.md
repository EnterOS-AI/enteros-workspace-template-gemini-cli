# Coding Discipline (Karpathy 4)

All code changes in this workspace follow these principles:

1. **Think Before Coding** — State assumptions explicitly. If unclear, ask, don't guess.
2. **Simplicity First** — Minimum code that solves the problem. No speculative abstractions.
3. **Surgical Changes** — Only touch what the task requires. Match existing style exactly.
4. **Goal-Driven Execution** — Define verifiable success criteria before implementing.

For concrete anti-pattern examples, see the `coding-discipline` skill or `EXAMPLES.md` in the Karpathy guidelines repo.

---

# Molecule AI Workspace Template — gemini-cli Runtime

## Purpose

This template provides a self-contained Docker workspace for the gemini-cli agent runtime used by Molecule AI platforms. It packages a configured gemini-cli agent inside a Docker container, wired to connect back to the Molecule AI platform via `adapter.py`.

It is NOT a plugin. It has no `plugin.yaml` and no `rules/` directory. It is a workspace *environment* — a Dockerfile, a runtime config, and an adapter — that the platform spins up on behalf of an agent.

## Key Files

### `config.yaml`

Runtime configuration for the gemini-cli agent.

```yaml
schema_version: "1"
runtime:
  agent: gemini-cli
  model: gemini-2.5-flash
  api_key_env: GEMINI_API_KEY
skills:
  enabled: true
  list:
    - name: file-search
      path: /workspace/skills/file-search
    - name: web-fetch
      path: /workspace/skills/web-fetch
adapter:
  platform_url: https://platform.molecule.ai
  workspace_id_env: WORKSPACE_ID
  timeout_seconds: 30
```

- `model` selects the Gemini model variant. Common values: `gemini-2.0-flash`, `gemini-2.5-flash`, `gemini-2.5-pro`.
- `api_key_env` names the env var that holds the Gemini API key at container startup. The key itself is injected by the Molecule AI platform or set locally during dev.
- `skills` lists local skill directories to expose to the agent. These are loaded at startup by gemini-cli.

### `adapter.py`

Thin shim that translates Molecule AI platform events into gemini-cli tool calls and streams responses back. Key entry points:

```python
# adapter.py
import os, sys

def connect(platform_url: str, workspace_id: str, timeout: int = 30):
    """Called by the platform shim to hand off a session to gemini-cli."""
    ...

def stream_response(session_id: str, prompt: str) -> str:
    """Blocking call: send prompt to gemini-cli, stream token back."""
    ...
```

`connect()` is invoked once per session by the platform harness inside the container. `stream_response()` is called for each agent turn.

### `system-prompt.md`

Injected at container startup into the gemini-cli prompt stack. This is the canonical place to set the agent's persona, guardrails, and tool whitelist. gemini-cli concatenates it before its default system message.

```markdown
# System Prompt — Molecule AI gemini-cli Agent

You are a research agent running inside a Molecule AI workspace.
You have access to the following tools: file-search, web-fetch.
Do not call tools outside this list without explicit user approval.
...
```

### `requirements.txt`

Pinned Python dependencies for the adapter and any skill loaders.

```
gemini-cli>=1.0.0
molecule-ai-adapter>=2.1.0
httpx>=0.27.0
pydantic>=2.0.0
```

### `Dockerfile`

Builds the workspace image. Key stages:

```dockerfile
FROM python:3.11-slim

WORKDIR /workspace
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p /workspace/skills

ENV GEMINI_API_KEY=""
ENV WORKSPACE_ID="local-dev"

CMD ["python", "-m", "adapter"]
```

The `CMD` invokes the adapter module, which bootstraps gemini-cli and connects to the platform. To override the startup command locally:

```bash
docker build -t molecule-gemini-cli:dev .
docker run --rm \
  -e GEMINI_API_KEY="$(cat ~/.gemini-api-key)" \
  -e WORKSPACE_ID="dev-001" \
  molecule-gemini-cli:dev
```

## Runtime Config Conventions

### Gemini Model Selection

Set `runtime.model` in `config.yaml`. gemini-cli resolves this to a Vertex AI / AI Studio model name at startup. If the model string does not match a known alias, gemini-cli exits with:

```
ValueError: Unknown model 'gemini-99-pro'. Did you mean 'gemini-2.0-pro'?
```

### API Key Handling

The Gemini API key is injected via the `GEMINI_API_KEY` env var. The platform sets this before `docker run`. Never bake API keys into the image. In local dev, pass it with `--build-arg` or `-e`.

```bash
# Build-time secret (buildkit needed for --build-arg secrecy)
docker build --build-arg GEMINI_API_KEY -t molecule-gemini-cli:dev .

# Runtime secret (recommended for local dev)
docker run --rm -e GEMINI_API_KEY="$GEMINI_API_KEY" molecule-gemini-cli:dev
```

### Skill Loading from config.yaml

gemini-cli loads skills listed under `skills.list` in `config.yaml` at startup. Each entry requires `name` and `path`. If the `path` does not exist, gemini-cli logs a warning and skips the skill:

```
WARN: skill 'file-search' path /workspace/skills/file-search not found, skipping
```

The skill directories must be volume-mounted or present in the image.

## Dev Setup

```bash
# 1. Clone
git clone https://git.moleculesai.app/molecule-ai/molecule-ai-workspace-template-gemini-cli.git
cd molecule-ai-workspace-template-gemini-cli

# 2. Install dependencies
pip install -r requirements.txt

# 3. Build image
docker build -t molecule-gemini-cli:dev .

# 4. Config override for local dev
# Edit config.yaml or set environment variables:
export GEMINI_API_KEY="$(cat ~/.gemini-api-key)"    # not in the repo
export WORKSPACE_ID="dev-local"

# 5. Smoke test
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="$WORKSPACE_ID" \
  molecule-gemini-cli:dev python -c "
from adapter import connect, stream_response
connect('http://localhost:8080', 'dev-local')
print(stream_response('test-session', 'ping'))
"

# 6. Verify adapter connects to platform
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="$WORKSPACE_ID" \
  -e ADAPTER_PLATFORM_URL="https://platform.molecule.ai" \
  molecule-gemini-cli:dev python -c "from adapter import connect; connect()"
```

## Testing

```bash
# Smoke test — runs adapter.connect() and exits 0 on success
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="smoke-test" \
  molecule-gemini-cli:dev python -c "
import sys, os
from adapter import connect
try:
    connect(os.environ['ADAPTER_PLATFORM_URL'], os.environ['WORKSPACE_ID'])
    print('OK')
    sys.exit(0)
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
"
```

## Release Process

1. **Schema version bump** — increment `schema_version` in `config.yaml` following the platform's compatibility matrix. Breaking changes require a major version bump.
2. **Tag** — tag the commit with the new version:

   ```bash
   git tag -a v1.2.0 -m "release: schema v1.2, add skill hot-reload"
   git push origin main --tags
   ```

3. The CI pipeline builds and pushes the image to the registry on tags matching `v*`.
4. Update the platform workspace registry entry to point at the new tag.

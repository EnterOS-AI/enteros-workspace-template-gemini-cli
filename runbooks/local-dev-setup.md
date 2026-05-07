# Local Dev Setup Runbook

This runbook covers setting up the gemini-cli workspace template on a local machine for development and testing. Follow each step in order.

---

## Prerequisites

- Python 3.11+
- Docker 24.0+
- A valid Gemini API key (from Google AI Studio or Google Cloud)
- Git

---

## Step 1: Clone the Repository

```bash
git clone https://git.moleculesai.app/molecule-ai/molecule-ai-workspace-template-gemini-cli.git
cd molecule-ai-workspace-template-gemini-cli
```

---

## Step 2: Install Python Dependencies

Create a virtual environment and install the pinned dependencies:

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

Expected output:

```
Collecting gemini-cli>=1.0.0
  Downloading gemini_cli-1.2.1-py3-none-any.whl (2.1 MB)
Collecting molecule-ai-adapter>=2.1.0
  Downloading molecule_ai_adapter-2.3.0-py3-none-any.whl (650 kB)
...
Installing collected packages: gemini-cli, molecule-ai-adapter, httpx, pydantic
Successfully installed gemini-cli-1.2.1 molecule-ai-adapter-2.3.0 httpx-0.27.2 pydantic-2.9.2
```

---

## Step 3: Set Your API Key

Store your Gemini API key in a local file (never commit this file):

```bash
# Replace with your actual key from https://aistudio.google.com/apikey
echo "AIzaSy..." > ~/.gemini-api-key
chmod 600 ~/.gemini-api-key
```

Set the env var for the current session:

```bash
export GEMINI_API_KEY="$(cat ~/.gemini-api-key)"
```

---

## Step 4: Build the Docker Image

```bash
docker build -t molecule-gemini-cli:dev .
```

To include the API key at build time (buildkit only — do not do this in CI or shared machines):

```bash
DOCKER_BUILDKIT=1 docker build \
  --build-arg GEMINI_API_KEY="$GEMINI_API_KEY" \
  -t molecule-gemini-cli:dev \
  .
```

Standard build without build-time secret:

```bash
docker build -t molecule-gemini-cli:dev .
```

---

## Step 5: Config Override for Local Dev

The template reads `config.yaml` for runtime settings. For local dev, override settings via environment variables or by editing a local copy.

**Option A — environment variables (recommended for dev):**

```bash
export WORKSPACE_ID="dev-local"
export ADAPTER_PLATFORM_URL="https://platform.molecule.ai"
export GEMINI_API_KEY="$(cat ~/.gemini-api-key)"
```

**Option B — local config file override:**

```bash
# Work on a copy, never modify config.yaml directly
cp config.yaml config.yaml.local
$EDITOR config.yaml.local
```

Then run the container with the local config mounted:

```bash
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="dev-local" \
  -v "$(pwd)/config.yaml.local:/workspace/config.yaml:ro" \
  molecule-gemini-cli:dev
```

---

## Step 6: Docker Run Smoke Test

Verify the container starts and the adapter connects successfully:

```bash
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="smoke-test" \
  molecule-gemini-cli:dev python -c "
import sys, os
from adapter import connect
try:
    connect(
        os.environ.get('ADAPTER_PLATFORM_URL', 'https://platform.molecule.ai'),
        os.environ['WORKSPACE_ID']
    )
    print('OK — adapter connected successfully')
    sys.exit(0)
except Exception as e:
    print(f'FAIL: {e}', file=sys.stderr)
    sys.exit(1)
"
```

Expected output:

```
OK — adapter connected successfully
```

If the exit code is non-zero, see [Common Issues](#common-issues) below.

---

## Step 7: Verify Adapter Connects to Platform

Run a full agent round-trip test using the platform endpoint:

```bash
docker run --rm \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e WORKSPACE_ID="dev-local" \
  -e ADAPTER_PLATFORM_URL="https://platform.molecule.ai" \
  molecule-gemini-cli:dev python -c "
from adapter import connect, stream_response
connect('https://platform.molecule.ai', 'dev-local')
reply = stream_response('test-session', 'Say hello in one sentence.')
print(reply)
"
```

Expected output (or similar):

```
Hello! I'm ready to assist you.
```

If the connection is refused:

```
ConnectionRefusedError: [Errno 111] Connection refused
```

See issue `adapter connection refused` in the table below.

---

## Common Issues

| # | Issue | Symptom | Resolution |
|---|-------|---------|------------|
| 1 | `GEMINI_API_KEY` is not set | Container starts but the agent produces no response; `stream_response()` hangs then times out with `AuthenticationError: Invalid API key` or silent hang | Confirm the env var is set: `echo $GEMINI_API_KEY`. If empty, obtain a key from https://aistudio.google.com/apikey and export it before `docker run` |
| 2 | Model not found | gemini-cli exits with `ValueError: Unknown model 'gemini-99-pro'. Did you mean 'gemini-2.0-flash'?` | Check `config.yaml` for the `runtime.model` value. Valid models: `gemini-2.0-flash`, `gemini-2.5-flash`, `gemini-2.5-pro`. Do not use preview or alias names |
| 3 | Docker networking | `ConnectionRefusedError` or `HTTPConnectError` when adapter tries to reach `platform.molecule.ai` inside the container | Ensure the host network is reachable from inside the container. Try `--network=host` on Linux, or map port explicitly: `-p 8080:8080`. Verify the platform URL is correct and the host machine is not behind a VPN blocking Docker's bridge network |
| 4 | Skill not loading | gemini-cli starts but reports `WARN: skill 'file-search' path /workspace/skills/file-search not found, skipping` for each skill | Verify skill directories exist in the image. Add them with a volume mount: `-v "$(pwd)/skills:/workspace/skills:ro"`. Ensure the skill paths in `config.yaml` match the mounted paths exactly |
| 5 | Adapter connection refused | `ConnectionRefusedError: [Errno 111] Connection refused` on `adapter.connect()` call | The adapter is trying to reach the platform at `ADAPTER_PLATFORM_URL` but nothing is listening there. If running against a local platform mock, start it first: `python -m local_platform_mock`. If running against the real platform, check that `ADAPTER_PLATFORM_URL` is set to the correct public endpoint and that the host machine can reach it |

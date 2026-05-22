"""Phase 1 file-only message support (a1ea2200 archaeology).

chloe-dong canary 2026-05-20 01:04:27Z local time: PDF-only message
returned the opaque "Error: message contained no text content." reply
from this CLI executor's empty-text guard at cli_executor.py:276-281.

The fix relaxes that guard so a file-only message synthesizes a prompt
naming the attached file paths (CLI agents like gemini-cli / ollama
read by path through their own tools) instead of short-circuiting, and
the truly-empty case surfaces an actionable reason per
feedback_surface_actionable_failure_reason_to_user.

Phase 2 (separate follow-up) will wire actual file-content forwarding
to each CLI's native attachment flag where supported.
"""

from __future__ import annotations

# Make cli_executor.py (which lives at the repo root, not under a
# package directory) importable as a flat module. Done in the test
# file rather than tests/conftest.py because adding tests/__init__.py
# triggers pytest's package-boundary walk, which lands on the repo-root
# ``__init__.py`` ("from .adapter import GeminiCLIAdapter as Adapter")
# and 500s on the relative import.
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

import pytest

pytest.importorskip("a2a.helpers")
pytest.importorskip("molecule_runtime.executor_helpers")

from cli_executor import CLIAgentExecutor  # noqa: E402
from molecule_runtime.config import RuntimeConfig  # noqa: E402


def _ctx_with_parts(parts: list) -> SimpleNamespace:
    msg = SimpleNamespace(parts=parts, task_id=None, context_id=None)
    return SimpleNamespace(
        message=msg, task_id=None, session_id=None, context_id=None
    )


def _text_part(text: str) -> SimpleNamespace:
    return SimpleNamespace(kind="text", text=text)


def _file_part(*, name: str, mime_type: str, path: str) -> SimpleNamespace:
    file_obj = SimpleNamespace(uri=f"file://{path}", name=name, mimeType=mime_type)
    return SimpleNamespace(kind="file", file=file_obj)


class _CapturingQueue:
    def __init__(self) -> None:
        self.events: list[Any] = []

    async def enqueue_event(self, event: Any) -> None:
        self.events.append(event)


def _make_executor() -> CLIAgentExecutor:
    # Use the "custom" presets path so we don't depend on a real CLI
    # binary being installed in the test env.
    cfg = RuntimeConfig(
        command="/usr/bin/true",
        model="test-model",
        args=[],
    )
    return CLIAgentExecutor(runtime="custom", runtime_config=cfg)


@pytest.mark.asyncio
async def test_execute_file_only_no_longer_returns_opaque_empty(
    tmp_path, monkeypatch
) -> None:
    """File-only message must not short-circuit with the opaque
    'Error: message contained no text content.' string."""
    import molecule_runtime.executor_helpers as _helpers
    monkeypatch.setattr(_helpers, "WORKSPACE_MOUNT", str(tmp_path))

    pdf = tmp_path / "chloe.pdf"
    pdf.write_bytes(b"%PDF-1.4 stub\n")

    ex = _make_executor()
    ctx = _ctx_with_parts([
        _file_part(name="chloe.pdf", mime_type="application/pdf", path=str(pdf)),
    ])
    queue = _CapturingQueue()

    captured_inputs: list[str] = []

    async def fake_run_cli(user_input: str, event_queue: Any) -> None:
        captured_inputs.append(user_input)

    # Disable the side-channel helpers the real execute() touches so
    # the test only exercises the guard path.
    with patch.object(ex, "_run_cli", side_effect=fake_run_cli), \
         patch("cli_executor.set_current_task", return_value=None), \
         patch("cli_executor.read_delegation_results", return_value=""), \
         patch("cli_executor.recall_memories", return_value=""), \
         patch("cli_executor.brief_summary", side_effect=lambda s: s[:60]):
        await ex.execute(ctx, queue)

    blob = repr(queue.events) + repr(captured_inputs)
    assert "Error: message contained no text content" not in blob
    assert any("chloe.pdf" in u for u in captured_inputs), (
        f"_run_cli never saw the file manifest; captured={captured_inputs!r}"
    )


@pytest.mark.asyncio
async def test_execute_truly_empty_surfaces_actionable_reason() -> None:
    """Empty text AND no files → actionable user-facing reason, NOT
    the old opaque error string."""
    ex = _make_executor()
    ctx = _ctx_with_parts([_text_part("   ")])
    queue = _CapturingQueue()

    await ex.execute(ctx, queue)

    assert len(queue.events) == 1
    rendered = repr(queue.events[0])
    assert "Your message was empty" in rendered
    assert "send text or a file" in rendered
    assert "Error: message contained no text content" not in rendered


@pytest.mark.asyncio
async def test_execute_text_only_still_passes_input_unchanged() -> None:
    """Regression-pin: text-only messages keep the user_input path
    unchanged — the file-aware branch must not perturb the text path."""
    ex = _make_executor()
    ctx = _ctx_with_parts([_text_part("write a haiku")])
    queue = _CapturingQueue()

    captured_inputs: list[str] = []

    async def fake_run_cli(user_input: str, event_queue: Any) -> None:
        captured_inputs.append(user_input)

    with patch.object(ex, "_run_cli", side_effect=fake_run_cli), \
         patch("cli_executor.set_current_task", return_value=None), \
         patch("cli_executor.read_delegation_results", return_value=""), \
         patch("cli_executor.recall_memories", return_value=""), \
         patch("cli_executor.brief_summary", side_effect=lambda s: s[:60]):
        await ex.execute(ctx, queue)

    assert captured_inputs == ["write a haiku"]

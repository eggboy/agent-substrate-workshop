"""Tools for the workspace agent.

`publish_report` is deliberately gated behind a human confirmation (see agent.py): it is the
"risky action" of the workshop, the one whose approval can arrive hours after the agent asked
while the actor sits suspended.
"""

from __future__ import annotations

import logging
import os
import shutil
from datetime import UTC, datetime
from pathlib import Path

from google.adk.tools import ToolContext

logger = logging.getLogger(__name__)

WORKSPACE_DIR = Path(os.environ.get("AGENT_WORKSPACE_DIR", "/workspace"))
PUBLISHED_DIR_NAME = "published"


class PublishError(ValueError):
    """Raised when a report cannot be published from the given path."""


def resolve_workspace_path(path: str, workspace: Path = WORKSPACE_DIR) -> Path:
    """Return `path` as an absolute path inside `workspace`.

    Relative paths are taken from the workspace root. A path that escapes the workspace is refused,
    so a prompt-injected "publish /etc/passwd" fails before touching the filesystem.

    Raises:
        PublishError: if the path lies outside the workspace or does not exist.

    """
    candidate = (workspace / path).resolve() if not Path(path).is_absolute() else Path(path).resolve()
    root = workspace.resolve()
    if candidate != root and root not in candidate.parents:
        raise PublishError(f"{path} is outside the workspace {workspace}")
    if not candidate.is_file():
        raise PublishError(f"{path} is not a file in the workspace")
    return candidate


def publish_report(path: str, tool_context: ToolContext) -> dict[str, str]:
    """Publish a finished report from the workspace.

    Copies the file into the workspace's `published/` directory with a UTC timestamp in its name
    and records the publication in session state. Publication is irreversible from the agent's point
    of view, which is why it needs human confirmation.

    Args:
        path: Path of the report inside the workspace, relative to the workspace root.
        tool_context: ADK tool context; the publication is recorded in its session state.

    Returns:
        A dict with `status` and, on success, `published_path` and `published_at`.

    """
    try:
        source = resolve_workspace_path(path)
    except PublishError as exc:
        return {"status": "error", "error": str(exc)}
    published_at = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    target_dir = WORKSPACE_DIR / PUBLISHED_DIR_NAME
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{published_at}-{source.name}"
    shutil.copy2(source, target)
    tool_context.state["last_published"] = str(target)
    logger.info("Published %s to %s", source, target)
    return {"status": "success", "published_path": str(target), "published_at": published_at}

"""Tests for the pure parts of the workspace tools."""

from pathlib import Path

import pytest
from agents.workspace.tools import PublishError, resolve_workspace_path


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
    (tmp_path / "reports").mkdir()
    (tmp_path / "reports" / "q3.md").write_text("# Q3\n")
    return tmp_path


@pytest.mark.parametrize("path", ["reports/q3.md", "./reports/q3.md", "reports/../reports/q3.md"])
def test_resolves_relative_paths_inside_workspace(workspace: Path, path: str) -> None:
    assert resolve_workspace_path(path, workspace) == (workspace / "reports" / "q3.md").resolve()


def test_accepts_absolute_path_inside_workspace(workspace: Path) -> None:
    absolute = str(workspace / "reports" / "q3.md")
    assert resolve_workspace_path(absolute, workspace) == Path(absolute).resolve()


@pytest.mark.parametrize("path", ["../outside.md", "/etc/passwd", "reports/../../x"])
def test_refuses_paths_outside_workspace(workspace: Path, path: str) -> None:
    with pytest.raises(PublishError, match="outside the workspace"):
        resolve_workspace_path(path, workspace)


def test_refuses_missing_or_directory_paths(workspace: Path) -> None:
    with pytest.raises(PublishError, match="not a file"):
        resolve_workspace_path("reports", workspace)
    with pytest.raises(PublishError, match="not a file"):
        resolve_workspace_path("reports/missing.md", workspace)

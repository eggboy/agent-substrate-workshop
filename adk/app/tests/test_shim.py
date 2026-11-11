"""Tests for the PID 1 shim's pure functions and SIGTERM policy."""

import http.server
import signal
import threading
from pathlib import Path

import pytest
from shim.entrypoint import (
    ActorIdentity,
    Supervisor,
    adk_command,
    build_suspend_url,
    read_identity,
    request_suspend,
)


@pytest.fixture
def identity_dir(tmp_path: Path) -> Path:
    (tmp_path / "atespace").write_text("workshop\n")
    (tmp_path / "actor-name").write_text("ws-01")
    (tmp_path / "actor-uid").write_text("0f1e2d3c-0000-4000-8000-000000000001\n")
    return tmp_path


def test_read_identity_strips_whitespace(identity_dir: Path) -> None:
    assert read_identity(identity_dir) == ActorIdentity("workshop", "ws-01", "0f1e2d3c-0000-4000-8000-000000000001")


def test_read_identity_is_none_outside_an_actor(tmp_path: Path) -> None:
    assert read_identity(tmp_path / "absent") is None


def test_build_suspend_url_fills_placeholders() -> None:
    url = build_suspend_url("http://gw.svc/actors/{atespace}/{actor}/suspend", ActorIdentity("workshop", "ws-01", "u"))
    assert url == "http://gw.svc/actors/workshop/ws-01/suspend"


def test_adk_command_binds_all_interfaces() -> None:
    assert adk_command("/app/agents", "80") == ["adk", "api_server", "--host", "0.0.0.0", "--port", "80", "/app/agents"]


def test_adk_command_appends_extra_args_before_agents_dir() -> None:
    command = adk_command("/app/agents", "80", "--session_service_uri=memory:// --auto_create_session")
    assert command[-3:] == ["--session_service_uri=memory://", "--auto_create_session", "/app/agents"]


class _Gateway(http.server.BaseHTTPRequestHandler):
    calls: list[str] = []
    statuses: list[int] = []

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        _Gateway.calls.append(self.path)
        status = _Gateway.statuses.pop(0) if _Gateway.statuses else 200
        self.send_response(status)
        self.end_headers()

    def log_message(self, *_args: object) -> None:
        return


@pytest.fixture
def gateway() -> str:
    _Gateway.calls = []
    _Gateway.statuses = []
    server = http.server.HTTPServer(("127.0.0.1", 0), _Gateway)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def test_request_suspend_retries_until_accepted(gateway: str) -> None:
    _Gateway.statuses = [503, 503]
    assert request_suspend(f"{gateway}/actors/workshop/ws-01/suspend", attempts=5, retry_seconds=0.01)
    assert _Gateway.calls == ["/actors/workshop/ws-01/suspend"] * 3


def test_request_suspend_gives_up(gateway: str) -> None:
    _Gateway.statuses = [500, 500]
    assert not request_suspend(f"{gateway}/actors/workshop/ws-01/suspend", attempts=2, retry_seconds=0.01)


def test_sigterm_does_not_exit_by_default(monkeypatch: pytest.MonkeyPatch, identity_dir: Path, gateway: str) -> None:
    monkeypatch.setenv("ATE_METADATA_DIR", str(identity_dir))
    monkeypatch.setenv("ACTOR_SUSPEND_URL", f"{gateway}/actors/{{atespace}}/{{actor}}/suspend")
    monkeypatch.setenv("SHIM_SUSPEND_ATTEMPTS", "1")
    supervisor = Supervisor()
    supervisor.on_sigterm(signal.SIGTERM, None)
    for thread in threading.enumerate():
        if thread.name == "suspend-request":
            thread.join(timeout=5)
    assert _Gateway.calls == ["/actors/workshop/ws-01/suspend"]
    assert supervisor.child is None  # nothing was signalled or stopped


def test_sigterm_forwards_when_exit_requested(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SHIM_EXIT_ON_SIGTERM", "1")
    supervisor = Supervisor()
    received: list[int] = []

    class _Child:
        def send_signal(self, signum: int) -> None:
            received.append(signum)

    supervisor.child = _Child()  # type: ignore[assignment]
    supervisor.on_sigterm(signal.SIGTERM, None)
    assert received == [signal.SIGTERM]

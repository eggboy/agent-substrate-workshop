"""PID 1 for the actor: run the ADK API server and survive SIGTERM.

Agent Substrate forwards SIGTERM to the actor's main process when the worker pod that hosts it is
going away (upgrade, scale-down, node drain). The actor then has a window (30 minutes on a normal
worker, far less on Spot) to be suspended by something outside the sandbox. A process that exits on
SIGTERM cannot be suspended and the actor crashes. uvicorn exits on SIGTERM, so it must not be PID 1.

This shim is PID 1 instead. It starts `adk api_server` as a child, keeps running when SIGTERM
arrives, reads the actor's own identity from the files Substrate projects into the sandbox, and asks
the gateway to suspend the actor synchronously. The child keeps serving until the checkpoint freezes
it. See docs/reference/api-guide.md "Eviction" in the Substrate repository.

Configuration (environment):
    ADK_AGENTS_DIR          Directory `adk api_server` serves. Default /app/agents.
    ADK_PORT                Port the ADK server listens on. Default 80.
    ADK_EXTRA_ARGS          Extra `adk api_server` flags, shell-split (e.g. "--session_service_uri=memory://").
    ATE_METADATA_DIR        Where Substrate's `actorMetadata` systemInfo volume is mounted. Default /run/ate.
    ACTOR_SUSPEND_URL       Template of the gateway endpoint that suspends this actor, with
                            `{atespace}` and `{actor}` placeholders. Unset: SIGTERM is logged and ignored.
    SHIM_EXIT_ON_SIGTERM    "1" forwards SIGTERM to the child and exits (plain uvicorn behaviour, for
                            local runs and for the workshop's crash drill). Default "0".
    SHIM_SUSPEND_ATTEMPTS   Retries for the suspend request. Default 60, five seconds apart.
"""

from __future__ import annotations

import logging
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger("shim")

DEFAULT_AGENTS_DIR = "/app/agents"
DEFAULT_PORT = "80"
DEFAULT_METADATA_DIR = "/run/ate"
DEFAULT_SUSPEND_ATTEMPTS = 60
SUSPEND_RETRY_SECONDS = 5.0
SUSPEND_REQUEST_TIMEOUT_SECONDS = 120.0


@dataclass(frozen=True)
class ActorIdentity:
    """The identity Substrate projects into the sandbox through an `actorMetadata` volume."""

    atespace: str
    name: str
    uid: str


def read_identity(metadata_dir: Path) -> ActorIdentity | None:
    """Read the actor's atespace, name and UID from `metadata_dir`, or None when not running as an actor."""
    try:
        return ActorIdentity(
            atespace=(metadata_dir / "atespace").read_text().strip(),
            name=(metadata_dir / "actor-name").read_text().strip(),
            uid=(metadata_dir / "actor-uid").read_text().strip(),
        )
    except OSError:
        return None


def identity_pair(identity: ActorIdentity) -> tuple[str, str]:
    """Return the (atespace, name) pair that addresses an actor."""
    return identity.atespace, identity.name


def build_suspend_url(template: str, identity: ActorIdentity) -> str:
    """Fill the `{atespace}` and `{actor}` placeholders of the gateway's suspend endpoint."""
    return template.format(atespace=identity.atespace, actor=identity.name)


def request_suspend(url: str, attempts: int, retry_seconds: float = SUSPEND_RETRY_SECONDS) -> bool:
    """POST to the gateway until it accepts the suspend or the attempts run out.

    A 2xx means the gateway took the request; the checkpoint that follows freezes this process, so
    returning True is the last thing that happens before the actor is suspended.
    """
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(url, method="POST", data=b"")
        try:
            with urllib.request.urlopen(request, timeout=SUSPEND_REQUEST_TIMEOUT_SECONDS) as response:
                logger.info("Suspend request accepted (HTTP %s) on attempt %d", response.status, attempt)
                return True
        except urllib.error.HTTPError as exc:
            logger.warning("Suspend request attempt %d refused: HTTP %s", attempt, exc.code)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            logger.warning("Suspend request attempt %d failed: %s", attempt, exc)
        time.sleep(retry_seconds)
    logger.error("Giving up on the suspend request after %d attempts", attempts)
    return False


def adk_command(agents_dir: str, port: str, extra_args: str = "") -> list[str]:
    """Build the ADK API server command line for this actor.

    `extra_args` is split like a shell would and inserted before the agents directory, so an
    ActorTemplate can pick the session backend (`--session_service_uri=memory://`) or any other
    `adk api_server` flag without a new image.
    """
    return ["adk", "api_server", "--host", "0.0.0.0", "--port", port, *shlex.split(extra_args), agents_dir]


class Supervisor:
    """Runs the ADK server as a child and owns the SIGTERM policy."""

    def __init__(self) -> None:
        """Read configuration from the environment and start with no child."""
        self.child: subprocess.Popen[bytes] | None = None
        self.exit_on_sigterm = os.environ.get("SHIM_EXIT_ON_SIGTERM", "0") == "1"
        self.suspend_template = os.environ.get("ACTOR_SUSPEND_URL")
        self.metadata_dir = Path(os.environ.get("ATE_METADATA_DIR", DEFAULT_METADATA_DIR))
        self.attempts = int(os.environ.get("SHIM_SUSPEND_ATTEMPTS", str(DEFAULT_SUSPEND_ATTEMPTS)))
        self._suspend_thread: threading.Thread | None = None

    def start_child(self) -> subprocess.Popen[bytes]:
        """Start `adk api_server` with the configured agents directory and port."""
        agents_dir = os.environ.get("ADK_AGENTS_DIR", DEFAULT_AGENTS_DIR)
        command = adk_command(
            agents_dir, os.environ.get("ADK_PORT", DEFAULT_PORT), os.environ.get("ADK_EXTRA_ARGS", "")
        )
        logger.info("Starting %s", " ".join(command))
        self.child = subprocess.Popen(command)  # noqa: S603 - fixed argv, no shell
        return self.child

    def suspend_in_flight(self) -> bool:
        """Report whether a suspend request thread is still running.

        Liveness, not a flag: this process is checkpointed and later restored with its memory
        intact, so a "SIGTERM already seen" boolean set before the suspend would still be set in
        the next incarnation, on another worker, and the next eviction would be ignored (that is
        how the first mid-turn drill left an actor RUNNING on a terminating pod). A thread that
        ended with the accepted request carries nothing into the next incarnation.
        """
        return self._suspend_thread is not None and self._suspend_thread.is_alive()

    def on_sigterm(self, signum: int, _frame: object) -> None:
        """Keep running, and ask the gateway to suspend this actor on a background thread."""
        if self.exit_on_sigterm:
            logger.info("SIGTERM: SHIM_EXIT_ON_SIGTERM=1, forwarding to the child and exiting")
            if self.child is not None:
                self.child.send_signal(signum)
            return
        if self.suspend_in_flight():
            logger.info("SIGTERM again: suspend request still in flight")
            return
        logger.info("SIGTERM: the worker is going away; staying alive and asking the gateway to suspend this actor")
        self._suspend_thread = threading.Thread(target=self._ask_for_suspend, name="suspend-request", daemon=True)
        self._suspend_thread.start()

    def _ask_for_suspend(self) -> None:
        identity = read_identity(self.metadata_dir)
        if identity is None:
            logger.error("No actor identity under %s; waiting to be checkpointed or killed", self.metadata_dir)
            return
        if not self.suspend_template:
            logger.error("ACTOR_SUSPEND_URL is unset; %s/%s waits for an external suspend", *identity_pair(identity))
            return
        request_suspend(build_suspend_url(self.suspend_template, identity), self.attempts)

    def run(self) -> int:
        """Supervise the child until it exits; reap any orphan that lands on PID 1 meanwhile."""
        child = self.start_child()
        signal.signal(signal.SIGTERM, self.on_sigterm)
        signal.signal(signal.SIGINT, self.on_sigterm)
        while True:
            try:
                pid, status = os.waitpid(-1, 0)
            except ChildProcessError:
                return 0
            if pid == child.pid:
                code = os.waitstatus_to_exitcode(status)
                logger.info("ADK server exited with %d", code)
                return code if code >= 0 else 128 - code


def main() -> int:
    """Entry point: configure logging, supervise the ADK server, return its exit code."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s shim %(levelname)s %(message)s", stream=sys.stdout)
    return Supervisor().run()


if __name__ == "__main__":
    sys.exit(main())

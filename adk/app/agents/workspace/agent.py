"""The workspace agent: a personal coding assistant that keeps files and a long session.

Nothing here knows about Agent Substrate. The agent is written as if it ran on one developer's
machine: it reads, writes and runs code in `/workspace`, remembers the conversation in process
memory (ADK's default session service), and pauses for a human before publishing. Substrate turns
that process into a durable, suspendable actor from the outside.
"""

from __future__ import annotations

import os

from google.adk.agents import Agent
from google.adk.apps import App, ResumabilityConfig
from google.adk.environment import LocalEnvironment
from google.adk.tools import FunctionTool
from google.adk.tools.environment import EnvironmentToolset

from .tools import WORKSPACE_DIR, publish_report

# The App name must match this package directory (`agents/workspace`), or `adk api_server`
# answers "Session not found" for every request.
APP_NAME = "workspace"
MODEL = os.environ.get("AGENT_MODEL", "gemini-3.8-flash")
MAX_TOOL_OUTPUT_CHARS = 20_000

INSTRUCTION = f"""You are a personal workspace agent for one software engineer.

Your workspace is {WORKSPACE_DIR}. Everything you create lives there and survives between
conversations. Use the environment tools to read, write, edit and run code; prefer small, verifiable
steps and show the command output that proves a step worked.

Rules:
- Work only inside {WORKSPACE_DIR}. Never write outside it.
- When asked to publish a report, call `publish_report`. It needs human approval; wait for it.
- Answer briefly. Lead with what you did and what changed on disk.
"""

root_agent = Agent(
    name="workspace_agent",
    model=MODEL,
    description="Writes and runs code in a persistent personal workspace.",
    instruction=INSTRUCTION,
    tools=[
        EnvironmentToolset(
            environment=LocalEnvironment(working_dir=str(WORKSPACE_DIR)),
            max_output_chars=MAX_TOOL_OUTPUT_CHARS,
        ),
        FunctionTool(publish_report, require_confirmation=True),
    ],
)

app = App(
    name=APP_NAME,
    root_agent=root_agent,
    resumability_config=ResumabilityConfig(is_resumable=True),
)

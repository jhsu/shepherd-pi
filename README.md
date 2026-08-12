# Shepherd

A pi configuration that turns your coding agent into a **Herdr orchestrator** — managing fleets of AI coding agents inside a [Herdr](https://herdr.app) terminal workspace.

Shepherd provides the system prompt, CLI tools, pi extensions, and subagent definitions you need to coordinate multiple agents (pi, codex, claude, gemini, cursor, etc.) from a single orchestrator pane: spawn workers, dispatch tasks, monitor progress, handle approvals, and tear down when you're done.

## What's included

| Path | Description |
|------|-------------|
| `AGENTS.md` | Orchestrator system prompt — the full set of instructions, CLI references, dispatch protocols, and recipes that pi follows when running as the Herdr orchestrator. |
| `bin/herdr-summary` | CLI script that summarizes what each running agent is actually working on — reads pi session transcripts and prints last request, last reply, tools used, and a condensed conversation tail. |
| `.pi/extensions/herdr-agents.ts` | Pi extension providing the `/agents` (alias `/herdr-status`) command — a fleet dashboard with live lifecycle states and `@herdr:` mention insertion for dispatching. |
| `.pi/agents/prompt-refiner.md` | Subagent definition for the prompt-refiner — reads a target agent's transcript and rewrites a raw user instruction into a grounded, self-contained prompt before dispatch. |

## Prerequisites

- **[Herdr](https://herdr.app)** — terminal multiplexer that recognizes coding agents in panes (`HERDR_ENV=1` when inside a session)
- **[pi](https://github.com/earendil-works/pi-coding-agent)** — the coding agent that runs as the orchestrator
- **Python 3** — for `herdr-summary`
- **Node.js** — for the pi extension (pi loads it via its extension system)

## Setup

### 1. Clone into your working directory

```bash
git clone https://github.com/<you>/shepherd.git ~/code/shepherd
cd ~/code/shepherd
```

### 2. Start the orchestrator

Open a Herdr workspace, then in a pane start pi with the shepherd `AGENTS.md` as its project context:

```bash
cd ~/code/shepherd
pi
```

Pi reads `AGENTS.md` from the current directory and assumes the orchestrator role. `herdr-summary` is available as `./bin/herdr-summary` from within the project. Verify it's working by asking for a status check — pi should confirm `HERDR_ENV=1` and list any running agents.

### 3. (Optional) Install the extension globally

The `/agents` extension ships project-locally in `.pi/extensions/`. To use it across projects without cloning shepherd into each one, copy or symlink it into the global extension directory:

```bash
ln -s "$(pwd)/.pi/extensions/herdr-agents.ts" ~/.pi/agent/extensions/herdr-agents.ts
```

Then reload pi with `/reload`.

## Usage

### Fleet status

From the orchestrator pane, run the `/agents` command (or `/herdr-status`) to see a picker of all running worker agents with their lifecycle state and last dispatched task. Selecting an agent inserts an `@herdr:` mention tag into the input bar — type your instruction after it and send.

### Dispatching to an agent

Any message starting with `@herdr:` is treated as a dispatch to the tagged agent. The orchestrator:

1. **Rewrites** the instruction via the `prompt-refiner` subagent, grounding it in the target agent's conversation history
2. **Dispatches** the refined prompt asynchronously — fire-and-forget, does not block
3. **Reports** a one-line summary back to you

Example:

```
@herdr: pi#w14:p1 [working] Add a retry wrapper around the network call.
```

### Fleet summaries

```bash
herdr-summary               # all agents
herdr-summary w13           # filter by workspace, cwd substring, or pane id
herdr-summary --json        # machine-readable
herdr-summary --list-only   # just agent locations, no conversation
herdr-summary --max-events 10  # shorter tail (default 40)
```

### Common recipes

The `AGENTS.md` includes detailed recipes for common orchestration patterns:

- **A — Parallel fan-out**: dispatch review / test / audit tasks to multiple workers simultaneously
- **B — Status roll call**: quick snapshot of the fleet, drill into busy/stuck agents
- **C — Review / refine loop**: fan out, collect, synthesize, re-dispatch
- **D — Sequential hand-off**: pipeline stages with dependency waits
- **E — Unblock an agent**: inspect `blocked` agents and approve via prompt
- **F — Cleanup**: close only the panes/tabs/workspaces you created
- **G — Notify on milestones**: surface notifications when agents finish
- **H — Spawn N workers**: loop to stand up named workers in sibling panes

## Agent lifecycle states

| State | Meaning |
|-------|---------|
| `idle` | Ready for input |
| `done` | Idle after background work finished |
| `working` | Actively doing something |
| `blocked` | Waiting for approval / user input |
| `unknown` | Present but unclassified |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  User (you)                                         │
│    │                                                │
│    ▼                                                │
│  Orchestrator (pi + AGENTS.md)                      │
│    │                                                │
│    ├── @herdr: dispatch ──► prompt-refiner ──► agent│
│    ├── /agents ───────────► herdr-agents extension │
│    └── herdr-summary ────► bin/herdr-summary       │
│                                                     │
│  Herdr (terminal multiplexer)                       │
│    ├── workspace ──── tab ──── pane (agent)        │
│    ├── workspace ──── tab ──── pane (agent)        │
│    └── ...                                          │
└─────────────────────────────────────────────────────┘
```

The orchestrator never touches another agent's pane directly — all control goes through the `herdr` CLI agent surface (`herdr agent prompt`, `herdr agent get`, `herdr agent read`). Dispatches are async by design; the orchestrator polls for results rather than blocking.

## License

MIT

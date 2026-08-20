# Shepherd

A pi configuration that turns your coding agent into a **Herdr orchestrator** — managing fleets of AI coding agents inside a [Herdr](https://herdr.app) terminal workspace.

Shepherd provides the system prompt, CLI tools, pi extensions, and subagent definitions you need to coordinate multiple agents (pi, codex, claude, gemini, cursor, etc.) from a single orchestrator pane: spawn workers, dispatch tasks, monitor progress, handle approvals, and tear down when you're done.

## What's included

| Path | Description |
|------|-------------|
| `AGENTS.md` | Orchestrator system prompt — the full set of instructions, CLI references, dispatch protocols, and recipes that pi follows when running as the Herdr orchestrator. |
| `bin/herdr-summary` | CLI script that summarizes what each running agent is actually working on — reads pi session transcripts and prints last request, last reply, tools used, and a condensed conversation tail. |
| `bin/shepherd-doctor` | Shell-only environment diagnostics invoked by `shepherd-pi doctor`. Checks project layout, required commands, Herdr env, and the fleet-ledger directory; exits nonzero only on hard failures. |
| `.pi/extensions/herdr-agents.ts` | Pi extension providing the `/agents` (alias `/herdr-status`) command — a fleet dashboard with live lifecycle states and `@herdr:` mention insertion for dispatching. |
| `.pi/extensions/fleet-activity.ts` | Pi extension that surfaces live fleet state in the orchestrator's working indicator during a turn (inspired by mitsuhiko's `whimsical.ts`), e.g. `fleet: reviewer, perf · 1 blocked`. |
| `.pi/extensions/fleet-ledger.ts` | Pi extension providing a shared, durable dispatch ledger (`ledger` tool + `/ledger`/`/tasks` commands) — one file per dispatched task under `~/.herdr-ledger`, which the `/agents` dashboard consults as the deterministic source of what each worker is tasked to do. |
| `.pi/agents/prompt-refiner.md` | Subagent definition for the prompt-refiner — reads a target agent's transcript and rewrites a raw user instruction into a grounded, self-contained prompt before dispatch. |

## Prerequisites

- **[Herdr](https://herdr.app)** — terminal multiplexer that recognizes coding agents in panes (`HERDR_ENV=1` when inside a session)
- **[pi](https://github.com/earendil-works/pi-coding-agent)** — the coding agent that runs as the orchestrator
- **Python 3** — for `herdr-summary`
- **Node.js** — for the pi extension (pi loads it via its extension system)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jhsu/shepherd-pi/main/install.sh | bash
```

This clones shepherd into `~/.shepherd`, installs both `shepherd-pi` and the `shepherd-doctor` diagnostics script into `~/.local/bin` (side by side), and installs the `/agents` pi extension globally. Re-run to update.

The `shepherd-pi doctor` subcommand resolves its own installation directory at runtime (following symlinks) and dispatches to the sibling `shepherd-doctor`, so it works regardless of how `PATH`/`HOME` are set later — falling back to `$SHEPHERD_DIR/bin/shepherd-doctor` and then `PATH` only if the sibling is missing. If the clone's `bin/shepherd-doctor` is ever absent, the installer fails clearly instead of producing a half-install.

### Start the orchestrator

Open a Herdr workspace, then run:

```bash
shepherd-pi
```

This starts pi in the shepherd project directory where it reads `AGENTS.md` and assumes the orchestrator role. `herdr-summary` is available on PATH within the session. Verify it's working by asking for a status check — pi should confirm `HERDR_ENV=1` and list any running agents.

### Diagnostics: `shepherd-pi doctor`

Run environment diagnostics without launching pi:

```bash
shepherd-pi doctor           # run all checks
shepherd-pi doctor --no-color # disable ANSI colours
```

The doctor is a shell-only, dependency-free script (installed to `~/.local/bin/shepherd-doctor`, sourced from `bin/shepherd-doctor`) that reports `PASS` / `WARN` / `FAIL` lines and a summary. It checks:

- **Environment** — whether `HERDR_ENV=1` (a warning when outside Herdr, not a failure)
- **Shepherd project** — the shepherd directory and `AGENTS.md`
- **Required commands** — `git` and `pi` (hard failures if missing), `python3`, `node`, and `herdr` (warnings)
- **Project-local extensions / agents** — `bin/herdr-summary`, `.pi/extensions/{herdr-agents,fleet-activity,fleet-ledger}.ts`, `.pi/agents/prompt-refiner.md`
- **Fleet ledger** — whether the ledger directory (`HERDR_LEDGER_DIR` or `~/.herdr-ledger`) is creatable/writable, probing with a temp file and cleaning up without touching existing data

Exit code is nonzero only when one or more **hard failures** are found; contextual warnings (e.g. running doctor outside Herdr, missing optional commands) exit `0`. You can also run it directly from a checkout:

```bash
./bin/shepherd-doctor
```

## Usage

### Aggregate status in the orchestrator

When inside a herdr session, the `fleet-activity` extension swaps a one-line fleet status into the orchestrator's streaming working indicator on each turn — so the orchestrator pane itself signals what the fleet is doing while it works (dispatches are async, but you can see at a glance that workers are churning):

```
fleet: reviewer, perf · 1 blocked      # working/blocked workers named
fleet idle — 2 agents ready            # all workers idle
```

The message clears when the turn settles. It excludes the orchestrator's own pane, so it reflects *other* agents only. Outside herdr (or when there's no interactive UI) it's a silent no-op.

### Fleet dispatch ledger

The `fleet-ledger` extension keeps a **durable, file-backed dispatch ledger** at `~/.herdr-ledger` (override with `HERDR_LEDGER_DIR`) — one markdown file per dispatched task, JSON front-matter + notes. It is the deterministic source of "what is each worker tasked to do" for the `/agents` dashboard, replacing the transcript-guess and the legacy `~/.herdr-tasks.jsonl` log.

Each task tracks a dispatch lifecycle: `open → assigned → working → done | failed`, plus `blocked` / `cancelled`.

Drive it from the orchestrator with the `ledger` tool (native LLM tool call):

```
ledger create title="Add retry wrapper" body="wrap the network call" worker="w14:p1" kind="pi"
ledger assign id=TODO-a5c82cf5 worker="w14:p1" force=true      # reassign an already-held task
ledger set-state id=TODO-a5c82cf5 state=working
ledger set-state id=TODO-a5c82cf5 state=done
ledger list                                     # active tasks
ledger append id=TODO-a5c82cf5 body="also handle timeouts"
ledger delete id=TODO-a5c82cf5
```

Or from the `/ledger` command (alias `/tasks`):
- **non-interactive**: prints a plain-text board (active then closed)
- **interactive**: pick a task to see its detail and drop a `work on ledger task TODO-… "…"` prompt into the editor

Task IDs are shown as `TODO-<hex>`; mutations accept `TODO-<hex>` or the raw hex. Locks (`.lock` file, 30-min TTL) prevent two sessions editing one task; stale locks require an interactive steal. The `/agents` dashboard resolves each worker's current task from the ledger (pane-id match, else agent-kind), falling back to the transcript tail when no entry exists.

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
│    ├── fleet-activity ────► working indicator      │
│    ├── ledger ────────────► ~/.herdr-ledger board  │
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

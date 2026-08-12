/**
 * Herdr Agent Status extension
 *
 * Provides `/agents` (alias `/herdr-status`) — a dashboard for the herdr
 * orchestrator's worker fleet. It shows each agent's live lifecycle state and
 * *what the orchestrator tasked it to do*, then lets you drill into a single
 * agent's recent transcript.
 *
 * Requires: the `herdr` CLI on PATH and `HERDR_ENV=1` (you are inside a
 * herdr-managed pane).
 *
 * Placement: project-local `.pi/extensions/` or global `~/.pi/agent/extensions/`.
 * Reload with /reload after adding or editing.
 *
 * Task tracking:
 *   By default the "tasked to do" line is guessed from the tail of each agent's
 *   recent transcript. For a deterministic task record, have the orchestrator
 *   append one JSON object per line to a task log:
 *
 *     { "at": <epoch ms>, "target": "reviewer", "task": "Review the current diff" }
 *
 *   Default log path: ~/.herdr-tasks.jsonl   (override with HERDR_TASK_LOG)
 */

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionCommandContext, ThemeColor } from "@earendil-works/pi-coding-agent";

type HerdrAgent = {
	agent: string; // kind, e.g. "pi", "codex"
	agent_status: string; // idle | working | blocked | done | unknown
	cwd: string;
	focused: boolean;
	foreground_cwd: string;
	pane_id: string;
	revision: number;
	state_change_seq: number;
	tab_id: string;
	terminal_id: string;
	terminal_title: string;
	workspace_id: string;
};

type TaskRecord = { at?: number; target?: string; pane_id?: string; task?: string };

function runHerdr(args: string[]): Promise<string> {
	return new Promise((resolve, reject) => {
		execFile("herdr", args, { maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
			if (err) {
				reject(new Error((stderr || err.message).trim() || err.message));
				return;
			}
			resolve(stdout);
		});
	});
}

/** Project root for whichever repo hosts this extension (the shepherd orchestrator). */
function shepherdRoot(): string {
	const here = fileURLToPath(import.meta.url);
	if (here.includes(`${sep}.pi${sep}extensions${sep}`)) {
		return here.split(`${sep}.pi${sep}extensions`)[0];
	}
	return process.cwd();
}

/** True when an agent lives inside the shepherd orchestrator repo (i.e. is another \"self\"). */
function isWithinShepherd(cwd: string, root: string): boolean {
	if (!cwd || !root) return false;
	const r = root.replace(/[\/]+$/, "");
	return cwd === r || cwd.startsWith(r + sep);
}

async function listAgents(): Promise<HerdrAgent[]> {
	const out = await runHerdr(["agent", "list"]);
	const parsed = JSON.parse(out);
	const agents = parsed?.result?.agents ?? [];
	return agents as HerdrAgent[];
}

async function readTranscript(target: string, lines: number): Promise<string> {
	try {
		const out = await runHerdr(["agent", "read", target, "--source", "recent-unwrapped", "--lines", String(lines), "--format", "text"]);
		return out.trim();
	} catch {
		return "(could not read transcript)";
	}
}

/** Best guess of the latest instruction/directive handed to an agent. */
function extractTask(transcript: string): string {
	if (!transcript) return "(no recent activity captured)";

	const lines = transcript
		.split("\n")
		.map((l) => l.trim())
		.filter((l) => l.length > 0 && l.length < 400);

	for (let i = lines.length - 1; i >= 0; i--) {
		const l = lines[i];
		// Skip terminal chrome and tracking noise.
		if (/^(Elapsed |Took |\$ |─|╭|╰|│)/.test(l)) continue;
		if (/^(Working|Asking|Searching|editing|running)/.test(l)) continue;
		if (l.length > 20) return l;
	}
	return lines[lines.length - 1] ?? "(—)";
}

async function readTaskLog(): Promise<TaskRecord[]> {
	const log = process.env.HERDR_TASK_LOG || join(homedir(), ".herdr-tasks.jsonl");
	try {
		const raw = await readFile(log, "utf8");
		const records: TaskRecord[] = [];
		for (const line of raw.split("\n")) {
			const trimmed = line.trim();
			if (!trimmed) continue;
			try {
				records.push(JSON.parse(trimmed) as TaskRecord);
			} catch {
				// ignore unparseable lines
			}
		}
		return records;
	} catch {
		return [];
	}
}

/** Latest logged task for a target (matches pane_id or agent name). */
function latestTaskFor(records: TaskRecord[], agent: HerdrAgent, target: string): TaskRecord | undefined {
	const relevant = records
		.filter((r) => (r.target && r.target === target) || (r.pane_id && r.pane_id === agent.pane_id))
		.sort((a, b) => (b.at ?? 0) - (a.at ?? 0));
	return relevant[0];
}

function friendlyLabel(agent: HerdrAgent, target: string): string {
	// target is the pane_id; if it differs from kind, it's a unique agent name.
	const base = agent.cwd.split("/").filter(Boolean).pop() ?? agent.pane_id;
	return `${base} [${target}]`;
}

function stateColor(state: string): ThemeColor {
	switch (state) {
		case "idle":
		case "done":
			return "success";
		case "working":
			return "muted";
		case "blocked":
			return "warning";
		default:
			return "dim";
	}
}

async function buildView(ctx: ExtensionCommandContext): Promise<{
	rows: Array<{ target: string; label: string; state: string; task: string }>;
	agentByTarget: Record<string, HerdrAgent>;
	records: TaskRecord[];
}> {
	if (process.env.HERDR_ENV !== "1") {
		throw new Error("Not running inside Herdr (HERDR_ENV != 1). Start this session from a herdr pane.");
	}

	const agents = await listAgents();
	if (agents.length === 0) throw new Error("No agents detected in the current herdr session.");

	const records = await readTaskLog();
	const selfPane = process.env.HERDR_PANE_ID;
	const selfDir = shepherdRoot(); // exclude the shepherd orchestrator's own repo so we never dispatch to "shepherd-pi"

	const rows: Array<{ target: string; label: string; state: string; task: string }> = [];
	const agentByTarget: Record<string, HerdrAgent> = {};

	for (const agent of agents) {
		if (selfPane && agent.pane_id === selfPane) continue; // skip the orchestrator's own pane
		if (isWithinShepherd(agent.cwd, selfDir)) continue; // skip shepherd-pi agents (the orchestrator itself / its clones)
		const target = agent.pane_id; // unique, always usable as a prompt target
		const logged = latestTaskFor(records, agent, target);

		let task = logged?.task;
		if (!task) {
			task = extractTask(await readTranscript(target, 120));
		}

		agentByTarget[target] = agent;
		rows.push({ target, label: friendlyLabel(agent, target), state: agent.agent_status, task });
	}

	rows.sort((a, b) => a.state.localeCompare(b.state) || a.label.localeCompare(b.label));
	return { rows, agentByTarget, records };
}

export default function herdrAgentsExtension(pi: ExtensionAPI) {
	const handler = async (args: string, ctx: ExtensionCommandContext): Promise<void> => {
		void args;
		try {
			const { rows, agentByTarget } = await buildView(ctx);

			if (rows.length === 0) {
				ctx.ui.notify("No worker agents found (excluding the orchestrator itself).", "info");
				return;
			}

			if (!ctx.hasUI) {
				for (const r of rows) {
					process.stdout.write(`${r.label}\t[${r.state}]\t${r.task}\n`);
				}
				return;
			}

			const pickLabels = rows.map((r) => {
				const color = stateColor(r.state);
				const task = r.task.length > 90 ? r.task.slice(0, 90) + "…" : r.task;
				return `${ctx.ui.theme.fg(color, r.state.padEnd(8))} ${r.label} :: ${task}`;
			});

			const selected = await ctx.ui.select("Herdr agents (state :: name :: last tasked instruction)", pickLabels);
			if (!selected) return;

			const idx = pickLabels.indexOf(selected);
			if (idx === -1) return;
			const row = rows[idx];

			const agent = agentByTarget[row.target];
			// Insert the single-line mention tag into the normal pi editor so the user can
			// append their instruction right after it. Any previous text in the input bar is
			// preserved, and the tag is separated so the orchestrator sees it as a dispatchable
			// "@herdr: <kind>#<pane> [state] <instruction>" message (see AGENTS.md §4a).
			const tag = `@herdr: ${agent?.agent ?? "?"}#${row.target} [${row.state}]`;
			const existing = ctx.ui.getEditorText();
			ctx.ui.setEditorText(existing ? existing + " " + tag : tag);
			ctx.ui.notify("Agent tag inserted into input; append your instruction and send.", "info");
		} catch (err) {
			const msg = err instanceof Error ? err.message : String(err);
			ctx.ui.notify(`Herdr status error: ${msg}`, "error");
		}
	};

	pi.registerCommand("agents", {
		description: "Show herdr agent fleet status and what each agent was tasked to do",
		handler,
	});

	pi.registerCommand("herdr-status", {
		description: "Show herdr agent fleet status and what each agent was tasked to do",
		handler,
	});
}

/**
 * Fleet Activity working-message extension
 *
 * Inspired by mitsuhiko's `whimsical.ts` extension
 * (https://github.com/mitsuhiko/agent-stuff/blob/main/extensions/whimsical.ts),
 * which swaps a playful string into the streaming working indicator on every
 * `turn_start` and clears it on `turn_end`.
 *
 * Shepherd ports that lifecycle pattern but replaces the jokes with real fleet
 * state: on `turn_start` we ask the `herdr` CLI how many worker agents are
 * busy / blocked / idle and surface a one-line status in the orchestrator's own
 * working indicator, e.g.:
 *
 *     Working — fleet: 3 agents (reviewer, perf, sec) · 1 blocked
 *
 * This closes the UX gap where a dispatch to a worker agent returns immediately
 * (by design, async) and the orchestrator pane looks idle while the fleet churns
 * in the background.
 *
 * Requires: `herdr` CLI on PATH and `HERDR_ENV=1` (you are inside a herdr pane).
 * Outside herdr, or when there is no interactive UI, this is a no-op.
 *
 * Placement: project-local `.pi/extensions/` or global `~/.pi/agent/extensions/`.
 * Reload with /reload after adding or editing.
 *
 * The `setFleetWorkingMessage` export is a convenience for code in the same
 * loader (e.g. other extensions) that wants to publish fleet state between
 * turns — call it fire-and-forget after a dispatch, no need to await.
 */

import { execFile } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type HerdrAgent = {
	agent: string; // kind, e.g. "pi", "codex"
	agent_status: string; // idle | working | blocked | done | unknown
	cwd: string;
	foreground_cwd: string;
	pane_id: string;
};

function runHerdr(args: string[]): Promise<string> {
	return new Promise((resolve, reject) => {
		execFile("herdr", args, { maxBuffer: 16 * 1024 * 1024, timeout: 4000 }, (err, stdout, stderr) => {
			if (err) {
				reject(new Error((stderr || err.message).trim() || err.message));
				return;
			}
			resolve(stdout);
		});
	});
}

async function listWorkerAgents(): Promise<HerdrAgent[]> {
	const out = await runHerdr(["agent", "list"]);
	const parsed = JSON.parse(out);
	const agents = (parsed?.result?.agents ?? []) as HerdrAgent[];
	// Exclude the orchestrator's own pane so "the fleet" means other agents.
	const selfPane = process.env.HERDR_PANE_ID;
	return agents.filter((a) => !selfPane || a.pane_id !== selfPane);
}

/** Best-effort short label for an agent from its cwd's basename. */
function labelFor(a: HerdrAgent): string {
	const base = a.cwd.split(/[\\/]/).filter(Boolean).pop();
	return base && base.length > 0 ? base : a.pane_id;
}

/**
 * Build a one-line fleet status string. Returns undefined when no usable state
 * is available (e.g. outside herdr, no agents, or herdr errors out).
 */
export async function buildFleetWorkingMessage(): Promise<string | undefined> {
	if (process.env.HERDR_ENV !== "1") return undefined;
	let agents: HerdrAgent[];
	try {
		agents = await listWorkerAgents();
	} catch {
		return undefined; // herdr unavailable / transient error — stay quiet
	}

	const isInteresting = (s: string) => s === "working" || s === "blocked";
	const busy = agents.filter((a) => isInteresting(a.agent_status));
	const blocked = agents.filter((a) => a.agent_status === "blocked");

	if (busy.length === 0) {
		if (agents.length === 0) return undefined;
		const idleCount = agents.length;
		return `fleet idle — ${idleCount} agent${idleCount === 1 ? "" : "s"} ready`;
	}

	const names = busy.map((a) => labelFor(a)).join(", ");
	const blockedNote = blocked.length > 0 ? ` · ${blocked.length} blocked` : "";
	return `fleet: ${names}${blockedNote}`;
}

/**
 * Publish the current fleet status into the streaming working indicator.
 * No-op when there is no interactive UI. Safe to call without awaiting.
 */
export function setFleetWorkingMessage(ctx: ExtensionContext): void {
	void (async () => {
		if (!ctx.hasUI) return;
		const msg = await buildFleetWorkingMessage();
		if (msg) ctx.ui.setWorkingMessage(msg);
	})();
}

export default function fleetActivityExtension(pi: ExtensionAPI) {
	// Show real fleet state while the orchestrator is "working"; clear it when
	// the turn settles, matching the whimsical.ts lifecycle discipline.
	pi.on("turn_start", async (_event, ctx) => {
		setFleetWorkingMessage(ctx);
	});

	pi.on("turn_end", async (_event, ctx) => {
		if (ctx.hasUI) ctx.ui.setWorkingMessage(); // restore default
	});
}

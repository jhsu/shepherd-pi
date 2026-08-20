/**
 * Fleet Ledger extension — a durable, shared dispatch ledger for the shepherd
 * orchestrator.
 *
 * Modeled after mitsuhiko's `todos.ts` extension
 * (https://github.com/mitsuhiko/agent-stuff/blob/main/extensions/todos.ts), which
 * stores todo items as files under `<dir>` with JSON front-matter and per-item
 * lock files. Shepherd adapts that file-based model into a *fleet dispatch
 * ledger*: one file per dispatched task, readable and crash-proof, which the
 * `/agents` dashboard consults as the deterministic source of "what is each
 * worker tasked to do" (instead of guessing from transcript tails).
 *
 * Storage: each task is `<ledger-dir>/<id>.md`. Default ledger dir is
 * `~/.herdr-ledger` (override with HERDR_LEDGER_DIR). An optional `<id>.lock`
 * file is used while a session is editing a task (TTL 30 min).
 *
 * File format:
 *   - The file starts with a JSON object: { id, title, state, worker, tags,
 *     created_at, assigned_at }
 *   - After the JSON block comes optional markdown body text after a blank line.
 *
 * Dispatch lifecycle (state):
 *   open --> assigned (worker set) --> working --> done | failed
 *                                          \-> blocked
 *   closed / cancelled
 *
 * Registration: `ledger` LLM tool (for the orchestrator to drive during a turn)
 * and `/ledger` (alias `/tasks`) command for an interactive/plain board view.
 *
 * Requires: pi extension loader (this file is project-local or global). Does NOT
 * require HERDR_ENV; it degrades to a plain file-backed task list outside herdr.
 */

import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile, readdir, unlink, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type, StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, ThemeColor } from "@earendil-works/pi-coding-agent";

const DEFAULT_LEDGER_DIR = join(homedir(), ".herdr-ledger");
const LOCK_TTL_MS = 30 * 60 * 1000;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface LedgerEntry {
	id: string; // 8 hex chars
	title: string;
	state: "open" | "assigned" | "working" | "blocked" | "done" | "failed" | "cancelled";
	worker: string | null; // pane id or agent name (prompt target)
	kind: string | null; // agent kind, e.g. "pi"
	tags: string[];
	created_at: string;
	assigned_at?: string; // set when first assigned to a worker
	closed_at?: string;
	body?: string;
}

interface LockInfo {
	id: string;
	pid: number;
	session?: string | null;
	created_at: string;
}

type LedgerAction =
	| "list"
	| "list-all"
	| "get"
	| "create"
	| "assign"
	| "set-state"
	| "update"
	| "append"
	| "close"
	| "reopen"
	| "delete";

// ---------------------------------------------------------------------------
// Paths / helpers
// ---------------------------------------------------------------------------

export function ledgerDir(): string {
	return process.env.HERDR_LEDGER_DIR || process.env.HERDR_TASK_LOG?.replace(/\.jsonl$/, "") || DEFAULT_LEDGER_DIR;
}

function entryPath(dir: string, id: string): string {
	return join(dir, `${id}.md`);
}
function lockPath(dir: string, id: string): string {
	return join(dir, `${id}.lock`);
}
function displayId(id: string): string {
	return `TODO-${id}`;
}
function normId(input: string): string {
	return input.replace(/^TODO-/, "").toLowerCase();
}
function newId(): string {
	return randomUUID().replace(/-/g, "").slice(0, 8);
}
function isClosed(state: string): boolean {
	return state === "done" || state === "failed" || state === "cancelled";
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

function serializeEntry(e: LedgerEntry): string {
	const front = JSON.stringify(
		{
			id: e.id,
			title: e.title,
			state: e.state,
			worker: e.worker || undefined,
			kind: e.kind || undefined,
			tags: e.tags ?? [],
			created_at: e.created_at,
			assigned_at: e.assigned_at || undefined,
			closed_at: e.closed_at || undefined,
		},
		null,
		2,
	);
	const body = (e.body ?? "").replace(/^\n+/, "").replace(/\s+$/, "");
	if (!body) return `${front}\n`;
	return `${front}\n\n${body}\n`;
}

function parseEntryContent(content: string, idFallback: string): LedgerEntry {
	const [frontRaw, ...bodyParts] = content.split(/\n\n/);
	let front: Partial<LedgerEntry> = {};
	try {
		front = JSON.parse(frontRaw) as LedgerEntry;
	} catch {
		// unparseable front matter — tolerate; keys default below
	}
	const body = bodyParts.join("\n\n").trim();
	return {
		id: front.id || idFallback,
		title: front.title || "(untitled)",
		state: (front.state as LedgerEntry["state"]) || "open",
		worker: front.worker || null,
		kind: front.kind || null,
		tags: front.tags ?? [],
		created_at: front.created_at || new Date().toISOString(),
		assigned_at: front.assigned_at,
		closed_at: front.closed_at,
		body: body || undefined,
	};
}

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

async function ensureDir(dir: string): Promise<void> {
	await mkdir(dir, { recursive: true });
}

async function listEntries(dir: string): Promise<LedgerEntry[]> {
	const out: LedgerEntry[] = [];
	let names: string[] = [];
	try {
		names = await readdir(dir);
	} catch {
		return out;
	}
	for (const name of names) {
		if (!name.endsWith(".md")) continue;
		const id = name.slice(0, -3);
		if (!/^[0-9a-f]{8}$/i.test(id)) continue;
		try {
			out.push(parseEntryContent(await readFile(join(dir, name), "utf8"), id));
		} catch {
			// ignore unreadable
		}
	}
	return out.sort((a, b) => a.created_at.localeCompare(b.created_at));
}

async function readEntry(dir: string, id: string): Promise<LedgerEntry | null> {
	try {
		return parseEntryContent(await readFile(entryPath(dir, id), "utf8"), id);
	} catch {
		return null;
	}
}

async function writeEntry(dir: string, e: LedgerEntry): Promise<void> {
	await writeFile(entryPath(dir, e.id), serializeEntry(e), "utf8");
}

// ---------------------------------------------------------------------------
// Locking (port of todos.ts withTodoLock)
// ---------------------------------------------------------------------------

function readLockInfo(lockPathStr: string): Promise<LockInfo | null> {
	return readFile(lockPathStr, "utf8")
		.then((raw) => {
			try {
				return JSON.parse(raw) as LockInfo;
			} catch {
				return null;
			}
		})
		.catch(() => null);
}

async function acquireLock(
	dir: string,
	id: string,
	ctx: ExtensionContext | undefined,
): Promise<(() => Promise<void>) | { error: string }> {
	const lockPathStr = lockPath(dir, id);
	const info: LockInfo = {
		id,
		pid: process.pid,
		session: ctx?.sessionManager.getSessionId?.() ?? null,
		created_at: new Date().toISOString(),
	};
	try {
		await writeFile(lockPathStr, JSON.stringify(info, null, 2), { flag: "wx" });
		return async () => {
			try {
				await unlink(lockPathStr);
			} catch {
				// ignore
			}
		};
	} catch (err: any) {
		if (err?.code !== "EEXIST") {
			return { error: `Failed to acquire lock: ${err?.message ?? "unknown error"}` };
		}
		const now = Date.now();
		const s = await stat(lockPathStr).catch(() => null);
		const lockAge = s ? now - s.mtimeMs : LOCK_TTL_MS + 1;
		if (lockAge <= LOCK_TTL_MS) {
			const owner = await readLockInfo(lockPathStr);
			const who = owner?.session ? ` (session ${owner.session})` : "";
			return { error: `Task ${displayId(id)} is locked${who}. Try again later.` };
		}
		if (!ctx?.hasUI) {
			return { error: `Task ${displayId(id)} lock is stale; rerun in interactive mode to steal it.` };
		}
		const ok = await ctx.ui.confirm("Task locked", `Task ${displayId(id)} appears locked. Steal the lock?`);
		if (!ok) return { error: `Task ${displayId(id)} remains locked.` };
		await unlink(lockPathStr).catch(() => undefined);
		// retry acquire once
		try {
			await writeFile(lockPathStr, JSON.stringify(info, null, 2), { flag: "wx" });
			return async () => {
				try {
					await unlink(lockPathStr);
				} catch {
					// ignore
				}
			};
		} catch {
			return { error: `Failed to acquire lock for task ${displayId(id)}.` };
		}
	}
}

async function withLedgerLock<T>(
	dir: string,
	id: string,
	ctx: ExtensionContext | undefined,
	fn: () => Promise<T>,
): Promise<T | { error: string }> {
	const lock = await acquireLock(dir, id, ctx);
	if (typeof lock === "object" && "error" in lock) return lock;
	try {
		return await fn();
	} finally {
		await lock();
	}
}

// ---------------------------------------------------------------------------
// Board formatting
// ---------------------------------------------------------------------------

function stateColor(state: string): ThemeColor {
	switch (state) {
		case "done":
		case "cancelled":
			return "dim";
		case "failed":
			return "error";
		case "blocked":
			return "warning";
		case "working":
			return "muted";
		default:
			return "success";
	}
}

function heading(e: LedgerEntry): string {
	const who = e.worker ? ` → ${e.worker}${e.kind ? ` (${e.kind})` : ""}` : "";
	const tags = e.tags.length ? ` [${e.tags.join(", ")}]` : "";
	return `${displayId(e.id)} ${e.title}${tags}${who}`;
}

function serializeForAgent(e: LedgerEntry): string {
	return JSON.stringify({ ...e, id: displayId(e.id) }, null, 2);
}

/** Plain-text board: active then closed sections. */
function formatBoard(entries: LedgerEntry[]): string {
	const active = entries.filter((e) => !isClosed(e.state));
	const closed = entries.filter((e) => isClosed(e.state));
	const lines: string[] = [];
	const push = (label: string, list: LedgerEntry[]) => {
		lines.push(`${label} (${list.length}):`);
		if (!list.length) {
			lines.push("  none");
		} else {
			for (const e of list) lines.push(`  ${heading(e)}`);
		}
	};
	push("Active tasks", active);
	push("Closed tasks", closed);
	return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Tool + command handlers
// ---------------------------------------------------------------------------

type LedgerParams = {
	action: LedgerAction;
	id?: string;
	title?: string;
	state?: string;
	worker?: string;
	kind?: string;
	tags?: string[];
	body?: string;
	force?: boolean;
};

export async function runAction(params: LedgerParams, ctx: ExtensionContext | undefined): Promise<string | { error: string; text: string }> {
	const dir = ledgerDir();
	await ensureDir(dir);
	const { action } = params;

	if (action === "list" || action === "list-all") {
		const all = await listEntries(dir);
		const shown = action === "list-all" ? all : all.filter((e) => !isClosed(e.state));
		return JSON.stringify(
			shown.map((e) => ({ ...e, id: displayId(e.id) })),
			null,
			2,
		);
	}

	if (action === "get") {
		if (!params.id) return { error: "id required", text: "Error: id required" };
		const e = await readEntry(dir, normId(params.id));
		if (!e) return { error: "not found", text: `Task ${params.id} not found` };
		return serializeForAgent(e);
	}

	if (action === "create") {
		if (!params.title) return { error: "title required", text: "Error: title required" };
		const id = newId();
		const entry: LedgerEntry = {
			id,
			title: params.title,
			state: params.worker ? "assigned" : "open",
			worker: params.worker || null,
			kind: params.kind || null,
			tags: params.tags ?? [],
			created_at: new Date().toISOString(),
			assigned_at: params.worker ? new Date().toISOString() : undefined,
			body: params.body,
		};
		await writeEntry(dir, entry);
		return serializeForAgent(entry);
	}

	// All remaining actions need an id and mutate under lock.
	if (!params.id) return { error: "id required", text: "Error: id required" };
	const id = normId(params.id);

	const result = await withLedgerLock(dir, id, ctx, async () => {
		const existing = await readEntry(dir, id);
		if (!existing) return { error: "not found", text: `Task ${params.id} not found` };

		// Assignment guard: refuse to reassign an actively-held task unless force.

		switch (action) {
			case "assign": {
				if (existing.worker && existing.worker !== params.worker && !params.force) {
					return {
						error: "assigned",
						text: `Task ${displayId(id)} is already assigned to ${existing.worker}. Pass force:true to override.`,
					};
				}
				existing.worker = params.worker ?? null;
				if (existing.worker) {
					existing.state = existing.state === "open" ? "assigned" : existing.state;
					existing.kind = params.kind || existing.kind;
					existing.assigned_at = existing.assigned_at ?? new Date().toISOString();
				}
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "set-state": {
				const allowed = ["open", "assigned", "working", "blocked", "done", "failed", "cancelled"] as const;
				if (!params.state || !(allowed as readonly string[]).includes(params.state)) {
					return { error: "bad state", text: `Invalid state: ${params.state}. Use ${allowed.join("|")}.` };
				}
				existing.state = params.state as LedgerEntry["state"];
				if (isClosed(existing.state)) existing.closed_at = existing.closed_at ?? new Date().toISOString();
				else existing.closed_at = undefined;
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "update": {
				existing.title = params.title ?? existing.title;
				if (params.tags) existing.tags = params.tags;
				existing.body = params.body ?? existing.body;
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "append": {
				if (!params.body) return { error: "body required", text: "Error: body required for append" };
				const spacer = (existing.body ?? "").trim().length ? "\n\n" : "";
				existing.body = `${(existing.body ?? "").replace(/\s+$/, "")}${spacer}${params.body.trim()}\n`;
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "close": {
				existing.state = "done";
				existing.closed_at = existing.closed_at ?? new Date().toISOString();
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "reopen": {
				if (isClosed(existing.state)) {
					existing.state = existing.worker ? "assigned" : "open";
					existing.closed_at = undefined;
				}
				await writeEntry(dir, existing);
				return serializeForAgent(existing);
			}

			case "delete": {
				await unlink(entryPath(dir, id)).catch(() => undefined);
				return `Deleted ${displayId(id)}`;
			}

			default:
				return { error: "unsupported", text: `Unknown action: ${action}` };
		}
	});

	// Normalize lock-failure ({error} only) and callback errors ({error,text}) into one shape.
	if (typeof result !== "string" && result && "error" in result) {
		return "text" in result ? result : { error: result.error, text: result.error };
	}
	return result as string;
}

export default function fleetLedgerExtension(pi: ExtensionAPI) {
	const ledgerParams = Type.Object({
		action: StringEnum(
			["list", "list-all", "get", "create", "assign", "set-state", "update", "append", "close", "reopen", "delete"] as const,
			{ description: "Ledger action" },
		),
		id: Type.Optional(Type.String({ description: "Task id (TODO-<hex> or raw hex)" })),
		title: Type.Optional(Type.String({ description: "Short summary shown in lists; required for create" })),
		state: Type.Optional(
			Type.String({ description: "Dispatch state: open|assigned|working|blocked|done|failed|cancelled" }),
		),
		worker: Type.Optional(Type.String({ description: "Pane id or agent name to assign (prompt target)" })),
		kind: Type.Optional(Type.String({ description: "Agent kind, e.g. pi|codex" })),
		tags: Type.Optional(Type.Array(Type.String({ description: "Tag" }))),
		body: Type.Optional(Type.String({ description: "Task details (markdown); update replaces, append adds" })),
		force: Type.Optional(Type.Boolean({ description: "Override another worker's assignment/lock" })),
	});

	pi.registerTool({
		name: "ledger",
		label: "Fleet Ledger",
		description:
			"Manage the shared fleet dispatch ledger (one file per task under ~/.herdr-ledger). " +
			"Actions: list (active), list-all, get, create (title required), assign (set worker/pane id), " +
			"set-state (open|assigned|working|blocked|done|failed|cancelled), update (replace), append (add body), " +
			"close, reopen, delete. Use as the durable record when dispatching work: create a task, assign it to a " +
			"worker, set-state working when it starts and done/failed when it reports. Assign ID prefix TODO-<hex>.",
		promptSnippet: "Track fleet dispatch tasks in the shared ~/.herdr-ledger board",
		promptGuidelines: [
			"Create a ledger entry for each dispatched task and keep its state current (assigned→working→done/failed).",
			"Use force:true only to override an assignment/lock you intentionally own.",
		],
		parameters: ledgerParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const res = await runAction(params, ctx);
			if (typeof res === "string") {
				return { content: [{ type: "text", text: res }], details: { action: params.action } };
			}
			return {
				content: [{ type: "text", text: res.text }],
				details: { action: params.action, error: res.error },
			};
		},
	});

	const boardHandler = async (args: string, ctx: ExtensionContext): Promise<void> => {
		void args;
		const dir = ledgerDir();
		await ensureDir(dir);
		const entries = await listEntries(dir);

		// Non-interactive: print plain board.
		if (!ctx.hasUI) {
			process.stdout.write(formatBoard(entries) + "\n");
			return;
		}

		if (entries.length === 0) {
			ctx.ui.notify("Ledger is empty. Use the `ledger` tool to create tasks.", "info");
			return;
		}

		const labels = entries.map((e) => {
			const color = stateColor(e.state);
			return `${ctx.ui.theme.fg(color, e.state.padEnd(9))} ${heading(e)}`;
		});
		const selected = await ctx.ui.select(`Fleet ledger (${dir})`, labels);
		if (!selected) return;

		const idx = labels.indexOf(selected);
		if (idx === -1) return;
		const entry = entries[idx];
		const detail = await readEntry(dir, entry.id);
		ctx.ui.notify(
			`${displayId(entry.id)} [${entry.state}] ${entry.title}${entry.worker ? ` assigned ${entry.worker}` : ""}`,
			"info",
		);
		if (detail?.body) {
			// surface the task body via a follow-up editor insert so the orchestrator can act on it
			const existing = ctx.ui.getEditorText();
			const insert = existing ? existing + " " : "";
			ctx.ui.setEditorText(`${insert}work on ledger task ${displayId(entry.id)} "${entry.title}"`);
		}
	};

	pi.registerCommand("ledger", {
		description: "Show the shared fleet dispatch ledger (last tasked to each worker)",
		handler: boardHandler,
	});
	pi.registerCommand("tasks", {
		description: "Show the shared fleet dispatch ledger (last tasked to each worker)",
		handler: boardHandler,
	});
}

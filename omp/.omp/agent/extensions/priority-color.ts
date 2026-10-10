/**
 * priority-color — traffic-light priority for every omp session, mirrored onto
 * the cmux workspace it runs in.
 *
 *   green  = high priority
 *   yellow = medium priority
 *   red    = low priority
 *
 * Hotkeys (one chord per colour, one to cycle, one to clear):
 *
 *   alt+1  green      alt+2  yellow      alt+3  red
 *   alt+c  cycle green → yellow → red → green
 *   alt+0  clear
 *
 * `/priority [green|yellow|red|high|medium|low|cycle|clear]` does the same
 * from the prompt; with no argument it opens a picker.
 *
 * Priority belongs to the omp *session*: it is stored in the session file (a
 * `custom` entry), so it survives `/resume`, branching and tree navigation,
 * and a coloured `● HIGH` / `● MEDIUM` / `● LOW` segment is published to
 * `status-line.ts`, which renders the shared row just above the footer.
 * Enable that host for the UI; cmux colouring works independently.
 *
 * The cmux workspace colour is derived, not stored: it is the highest
 * priority among the live omp sessions in that workspace (red, red, yellow →
 * yellow). Each omp process records its session's colour in
 * `$XDG_STATE_HOME/omp-priority/<workspace-id>/<pid>.json`; every change
 * recomputes the maximum over records whose process is still alive and paints
 * it with `cmux workspace-action set-color`. When no live session has a colour
 * the workspace colour is cleared — but only by a process that has itself
 * painted it, so a colour picked by hand in cmux is left alone. Outside
 * cmux only the shared-line segment applies. Subagent sessions are ignored.
 */

import { execFile } from "node:child_process";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import {
	STATUS_LINE_REMOVE,
	STATUS_LINE_REQUEST,
	STATUS_LINE_SET,
	type StatusLineRemoval,
	type StatusLineSegment,
} from "./.lib/status-line-protocol";

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

/** Namespaced: the `custom` entry type space is global. */
const ENTRY_TYPE = "com.brannon.priority-color";

/** cmux must never hang the UI. */
const CMUX_TIMEOUT_MS = 5_000;

type Priority = "green" | "yellow" | "red";

/** Highest priority first: cycle order, and "highest" is the lowest index. */
const ORDER: readonly Priority[] = ["green", "yellow", "red"];

const SHORTCUTS: Record<Priority, string> = { green: "alt+1", yellow: "alt+2", red: "alt+3" };
const CYCLE_SHORTCUT = "alt+c";
const CLEAR_SHORTCUT = "alt+0";

interface Meta {
	/** cmux `set-color` accepts `#RRGGBB`; the named palette has no yellow. */
	hex: string;
	label: string;
	themeColor: "success" | "warning" | "error";
	hint: string;
}

const META: Record<Priority, Meta> = {
	green: { hex: "#2ECC71", label: "HIGH", themeColor: "success", hint: "high priority" },
	yellow: { hex: "#F1C40F", label: "MEDIUM", themeColor: "warning", hint: "medium priority" },
	red: { hex: "#E74C3C", label: "LOW", themeColor: "error", hint: "low priority" },
};

const ALIASES: Record<string, Priority | "cycle" | "clear"> = {
	green: "green",
	high: "green",
	yellow: "yellow",
	medium: "yellow",
	med: "yellow",
	red: "red",
	low: "red",
	cycle: "cycle",
	next: "cycle",
	clear: "clear",
	none: "clear",
	off: "clear",
};

function isPriority(value: unknown): value is Priority {
	return typeof value === "string" && (ORDER as readonly string[]).includes(value);
}

function nextPriority(current: Priority | undefined): Priority {
	if (!current) return ORDER[0];
	return ORDER[(ORDER.indexOf(current) + 1) % ORDER.length];
}

// ---------------------------------------------------------------------------
// Per-workspace registry of live sessions' colours
// ---------------------------------------------------------------------------

interface SessionRecord {
	pid: number;
	sessionId: string;
	color: Priority;
}

function registryDir(workspace: string): string {
	const state = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
	return join(state, "omp-priority", workspace);
}

function processAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		// EPERM: exists but owned by someone else — still alive.
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/** Publish (or, with `undefined`, withdraw) this process's session colour. */
function writeRecord(workspace: string, sessionId: string, color: Priority | undefined): void {
	const dir = registryDir(workspace);
	const file = join(dir, `${process.pid}.json`);
	if (!color) {
		rmSync(file, { force: true });
		return;
	}
	mkdirSync(dir, { recursive: true });
	const record: SessionRecord = { pid: process.pid, sessionId, color };
	writeFileSync(file, JSON.stringify(record));
}

/** Highest colour among live sessions in the workspace; prunes records of dead processes. */
function highestInWorkspace(workspace: string): Priority | undefined {
	const dir = registryDir(workspace);
	let names: string[];
	try {
		names = readdirSync(dir);
	} catch {
		return undefined;
	}
	let best = ORDER.length;
	for (const name of names) {
		const file = join(dir, name);
		try {
			const record = JSON.parse(readFileSync(file, "utf8")) as Partial<SessionRecord>;
			if (!record.pid || !processAlive(record.pid) || !isPriority(record.color)) {
				rmSync(file, { force: true });
				continue;
			}
			best = Math.min(best, ORDER.indexOf(record.color));
		} catch {
			rmSync(file, { force: true });
		}
	}
	return ORDER[best];
}

// ---------------------------------------------------------------------------
// cmux
// ---------------------------------------------------------------------------

/** Resolves to an error message, or undefined on success. */
async function cmuxWorkspaceAction(workspace: string, args: string[]): Promise<string | undefined> {
	const { promise, resolve } = Promise.withResolvers<string | undefined>();
	execFile(
		process.env.CMUX_BUNDLED_CLI_PATH || "cmux",
		["workspace-action", "--workspace", workspace, ...args],
		{ timeout: CMUX_TIMEOUT_MS, env: { ...process.env, CMUX_QUIET: "1" } },
		(error, _stdout, stderr) => {
			resolve(error ? String(stderr || error.message).trim().split("\n")[0] : undefined);
		},
	);
	return promise;
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function priorityColorExtension(pi: ExtensionAPI): void {
	const workspace = process.env.CMUX_WORKSPACE_ID;
	let current: Priority | undefined;
	let latestContext: ExtensionContext | undefined;
	/** This process has held a colour, so clearing the workspace when none remain is ours to do. */
	let owned = false;

	/** Latest colour entry on the active branch. `data.color === null` is an explicit clear. */
	function restore(ctx: ExtensionContext): Priority | undefined {
		let found: Priority | undefined;
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom" || entry.customType !== ENTRY_TYPE) continue;
			const color = (entry.data as { color?: unknown } | undefined)?.color;
			found = isPriority(color) ? color : undefined;
		}
		return found;
	}

	function publishSegment(ctx: ExtensionContext): void {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!current) {
			pi.events.emit(STATUS_LINE_REMOVE, { sessionId, id: "priority" } satisfies StatusLineRemoval);
			return;
		}
		const { label, themeColor } = META[current];
		pi.events.emit(STATUS_LINE_SET, {
			sessionId,
			id: "priority",
			order: 10,
			text: `● ${label}`,
			tone: themeColor,
		} satisfies StatusLineSegment);
	}

	pi.events.on(STATUS_LINE_REQUEST, (request: unknown) => {
		if (
			!latestContext ||
			typeof request !== "object" ||
			request === null ||
			!("sessionId" in request) ||
			typeof request.sessionId !== "string"
		) return;
		if (request.sessionId === latestContext.sessionManager.getSessionId()) publishSegment(latestContext);
	});

	/** Publish this session's colour, then paint the workspace with the highest live one. */
	async function publish(ctx: ExtensionContext): Promise<void> {
		if (!workspace) return;
		let failure: string | undefined;
		try {
			writeRecord(workspace, ctx.sessionManager.getSessionId(), current);
			const highest = highestInWorkspace(workspace);
			if (highest) {
				failure = await cmuxWorkspaceAction(workspace, ["--action", "set-color", "--color", META[highest].hex]);
				owned = true;
			} else if (owned) {
				failure = await cmuxWorkspaceAction(workspace, ["--action", "clear-color"]);
				if (!failure) owned = false;
			}
		} catch (error) {
			failure = (error as Error).message;
		}
		if (failure && ctx.hasUI) ctx.ui.notify(`cmux workspace colour not updated: ${failure}`, "error");
	}

	/** Reload after the session (or branch) changed underneath us. */
	async function load(ctx: ExtensionContext): Promise<void> {
		if (ctx.agent?.kind === "sub") return;
		latestContext = ctx;
		current = restore(ctx);
		publishSegment(ctx);
		await publish(ctx);
	}

	async function assign(ctx: ExtensionContext, next: Priority | undefined): Promise<void> {
		if (ctx.agent?.kind === "sub") return;
		latestContext = ctx;
		if (next === current) return;
		current = next;
		pi.appendEntry(ENTRY_TYPE, { color: next ?? null });
		publishSegment(ctx);
		await publish(ctx);
	}

	const reload = async (_event: unknown, ctx: ExtensionContext) => load(ctx);
	pi.on("session_start", reload);
	pi.on("session_switch", reload);
	pi.on("session_branch", reload);
	pi.on("session_tree", reload);
	pi.on("session_shutdown", async (_event, ctx) => {
		if (ctx.agent?.kind === "sub") return;
		current = undefined;
		publishSegment(ctx);
		latestContext = undefined;
		await publish(ctx);
	});

	for (const color of ORDER) {
		pi.registerShortcut(SHORTCUTS[color] as never, {
			description: `Priority ${color}: ${META[color].hint}`,
			handler: (ctx) => assign(ctx, color),
		});
	}
	pi.registerShortcut(CYCLE_SHORTCUT as never, {
		description: "Priority: cycle green → yellow → red",
		handler: (ctx) => assign(ctx, nextPriority(current)),
	});
	pi.registerShortcut(CLEAR_SHORTCUT as never, {
		description: "Priority: clear colour",
		handler: (ctx) => assign(ctx, undefined),
	});

	pi.registerCommand("priority", {
		description: "Set session priority colour: green|yellow|red (high|medium|low), cycle, clear",
		handler: async (args, ctx) => {
			const word = args.trim().toLowerCase();
			let action = ALIASES[word];
			if (word && !action) {
				ctx.ui.notify(`Unknown priority '${word}'. Use green, yellow, red, cycle, or clear.`, "error");
				return;
			}
			if (!word) {
				const options = [...ORDER.map((c) => `${c} — ${META[c].hint}`), "cycle", "clear"];
				const picked = await ctx.ui.select("Session priority", options);
				if (!picked) return;
				action = ALIASES[picked.split(" ")[0]];
			}
			if (action === "cycle") await assign(ctx, nextPriority(current));
			else if (action === "clear") await assign(ctx, undefined);
			else if (action) await assign(ctx, action);
		},
	});
}

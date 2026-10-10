/**
 * fork-tab — tab-opening variants of omp's `/fork` and `/branch`: the new
 * session runs in a *second* omp, in a new terminal tab, leaving this one
 * running and untouched.
 *
 *   /fork-tab     no picker → new tab holding the whole conversation as it
 *                 stands, empty editor, ready to continue (stock `/fork`)
 *   /branch-tab   picker → new tab holding the conversation up to just before
 *                 the prompt you picked, that prompt waiting unsent in its
 *                 editor (stock `/branch`, alias `/rewind`)
 *
 *   The stock commands are left alone; these are separate commands beside
 *   them.
 *
 * WHY THIS EXISTS
 *   omp's branching primitives cover three of four quadrants:
 *
 *                      │ stay in this session  │ move to the new one
 *     ─────────────────┼───────────────────────┼─────────────────────
 *      same file       │ /tree                 │ /branch, /rewind
 *      new file        │ /fork-tab /branch-tab │ /fork
 *
 *   Stock `/fork` duplicates the session into a new file and *switches this
 *   process to it*; stock `/branch` rewinds this session in place, keeping the
 *   old path as a sibling branch. Either way the conversation you were in is no
 *   longer the one on screen. One omp process is one session, and there is no
 *   daemon to attach a second client to, so "branch, but keep both alive" has
 *   to mean a second process. That is all this is — omp's own fork with the
 *   replacement half removed and a terminal spawn bolted on.
 *
 * WHY SEPARATE COMMANDS
 *   Extension commands cannot shadow built-ins ("Command name conflicts with
 *   built-ins are skipped"), and the other ways in are worse: cancelling
 *   `/fork` from `session_before_switch` makes omp report "Fork failed", and
 *   `/branch` only emits `session_before_tree`, which `/tree` shares. Explicit
 *   `-tab` commands keep the stock ones predictable.
 *
 * HOW THE FILES ARE PRODUCED
 *   Nothing here touches the live session. `ctx.sessionManager` is read-only
 *   by type, and `SessionManager.createBranchedSession(leafId)` *mutates the
 *   manager it is called on* — repointing it at the copy is precisely how omp
 *   moves you to a branch. So every copy is written by a second, detached
 *   `SessionManager` built from the file on disk, which absorbs the mutation
 *   and is closed straight after:
 *
 *     /fork-tab     `SessionManager.forkFrom()` — the same whole-file copy
 *                   stock `/fork` produces: every branch, a `parentSession`
 *                   link, the inherited prompt-cache key, and the artifacts.
 *     /branch-tab   `SessionManager.open()` + `createBranchedSession()` —
 *                   root→target only, as stock `/branch`-to-new-session does.
 *
 *   Both run with `suppressBreadcrumb`. A manager records the session it last
 *   opened as this terminal's `--continue` breadcrumb, and the throwaway copy
 *   must not claim this terminal: `omp --continue` here should still land on
 *   the session that is actually running here. The new tab's omp writes its
 *   own breadcrumb for its own terminal when it opens the copy.
 *
 * WHY READING FROM DISK IS SAFE
 *   Entries are appended synchronously as they are committed, so the file is
 *   current except for an assistant message still streaming. `/branch-tab`
 *   targets the parent of a committed prompt, so it works mid-turn. `/fork-tab`
 *   copies the leaf, which mid-turn is an unanswered prompt, so — like stock
 *   `/fork` — it refuses until the response finishes.
 *
 *   One thing the file does not carry is *where you are*. The leaf lives in
 *   memory, and reopening a file lands on its last entry. After an in-place
 *   `/tree` or `/branch` with nothing sent since, those differ, and a
 *   whole-file copy would open the new tab on the path you just left. In that
 *   case `/fork-tab` copies root→leaf instead, so the tab opens where you are.
 *
 * THE UNSENT PROMPT
 *   Stock `/branch` restores the selected prompt into the editor. We cannot
 *   reach into another process's editor, so the text travels as a private temp
 *   file named by `OMP_FORK_TAB_DRAFT` in the spawned command's environment;
 *   the `session_start` handler below picks it up, once, and deletes it.
 *   Deliberately *not* a session entry: the draft is not part of the
 *   conversation, and a session that has been opened once should not still be
 *   carrying it. Text only — images attached to the picked prompt stay behind.
 *
 * TERMINALS
 *   cmux and tmux are driven directly. Anywhere else the commands print the
 *   command line to paste, which is the honest fallback — there is no portable
 *   "open a tab".
 *
 *   Getting cmux to *run* something in a new tab took three attempts, so the
 *   dead ends are recorded here rather than rediscovered:
 *
 *     - `new-surface --command` and its socket form (`surface.create` with
 *       `initialInput`) are documented on main but silently ignored by the
 *       shipped build (0.64.22) — the tab opens at a bare shell. Only
 *       `workspace.create` honours an initial command, and that makes a
 *       workspace, not a tab.
 *     - `cmux send` types into the shell, so it works only once that shell is
 *       at a prompt. Here that is ~5s (a heavy zshrc), and anything sent
 *       earlier is dropped silently. Polling for readiness means guessing at
 *       prompt glyphs, and guessing wrong means the fork vanishes.
 *     - `respawn-pane --command` hands the command to the app as the surface's
 *       program. No shell, no typing, no race: it can be issued in the same
 *       breath as `new-surface`.
 *
 *   `respawn-pane` launches through `login -flp … /bin/sh -c`, whose PATH is
 *   the bare system one — `omp` is not on it. Hence the absolute binary path,
 *   and hence re-entering the user's login shell so the forked omp gets the
 *   same environment every other tab has.
 */

import {
	SessionManager,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type ReadonlySessionManager,
	copySessionArtifacts,
} from "@oh-my-pi/pi-coding-agent";
import { execFileSync } from "node:child_process";
import {
	accessSync,
	constants,
	existsSync,
	mkdtempSync,
	readFileSync,
	rmdirSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

/** Carries the unsent prompt to the spawned omp. Path, not content. */
const DRAFT_ENV = "OMP_FORK_TAB_DRAFT";

/** No terminal control call should ever hang a slash command. */
const SPAWN_TIMEOUT_MS = 10_000;

/** Picker labels are one line; the full prompt still travels as the draft. */
const LABEL_MAX_CHARS = 100;

/**
 * Absolute path to the omp that should run in the new tab.
 *
 * Resolved from *this* process's PATH — the one the shell handed to the
 * session you are forking — because the spawned command does not inherit it.
 * `OMP_FORK_TAB_BIN` overrides for a build that is not on PATH. The running
 * binary is the last resort, and only when it really is omp: under a source
 * checkout `process.execPath` is bun, which would not know what to do with
 * `--session`.
 */
function resolveOmpBinary(): string {
	const override = process.env.OMP_FORK_TAB_BIN?.trim();
	if (override) return override;
	for (const dir of (process.env.PATH ?? "").split(":")) {
		if (!dir) continue;
		const candidate = join(dir, "omp");
		try {
			accessSync(candidate, constants.X_OK);
			return candidate;
		} catch {
			// Next PATH entry.
		}
	}
	if (basename(process.execPath) === "omp") return process.execPath;
	return "omp";
}

// ---------------------------------------------------------------------------
// Session plumbing
// ---------------------------------------------------------------------------

type ContentBlock = { type: string; text?: string };

/** Same shape as omp's `textContent(content)`: text blocks, concatenated. */
function extractUserText(content: string | readonly ContentBlock[] | undefined): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block) => block.type === "text")
		.map((block) => block.text ?? "")
		.join("");
}

interface BranchCandidate {
	/** Entry the new session ends at: the prompt's parent. */
	parentId: string | null;
	/** The prompt itself, restored unsent in the new tab. */
	text: string;
}

/**
 * User prompts on the *current* branch, oldest first — the same scope stock
 * `/branch` offers, since it rewinds along the path you are on.
 */
function branchCandidates(sm: ReadonlySessionManager): BranchCandidate[] {
	const candidates: BranchCandidate[] = [];
	for (const entry of sm.getBranch()) {
		if (entry.type !== "message" || entry.message.role !== "user") continue;
		const text = extractUserText(entry.message.content);
		if (text.trim()) candidates.push({ parentId: entry.parentId, text });
	}
	return candidates;
}

/** The session file on disk, or a user-facing reason there is none. */
function persistedSessionFile(sm: ReadonlySessionManager): string {
	const file = sm.getSessionFile();
	if (!file) throw new Error("This session is not saved (--no-session), so there is nothing to copy");
	if (!existsSync(file)) {
		throw new Error("This session has not been saved yet. Wait for the first response to finish.");
	}
	return file;
}

/**
 * Write root→`leafId` of `sourceFile` to a new session file and return its path.
 *
 * The detached manager absorbs `createBranchedSession()`'s repointing; closing
 * it surfaces a failed write, which `createBranchedSession()` itself only
 * records rather than throws.
 */
async function branchToNewFile(sm: ReadonlySessionManager, sourceFile: string, leafId: string): Promise<string> {
	const detached = await SessionManager.open(sourceFile, sm.getSessionDir(), undefined, {
		suppressBreadcrumb: true,
	});
	let branched: string | undefined;
	try {
		branched = detached.createBranchedSession(leafId);
	} finally {
		await detached.close();
	}
	if (!branched || !existsSync(branched)) throw new Error("omp did not write the branched session");
	return branched;
}

/**
 * Copy the conversation as it stands to a new session file.
 *
 * Whole-file `forkFrom()` whenever reopening the copy lands where this session
 * is; root→leaf plus artifacts when it would not (see the header).
 */
async function forkToNewFile(sm: ReadonlySessionManager): Promise<string> {
	const sourceFile = persistedSessionFile(sm);
	const leafId = sm.getLeafId();
	if (!leafId) throw new Error("Nothing to fork yet");

	if (sm.getEntries().at(-1)?.id !== leafId) {
		const branched = await branchToNewFile(sm, sourceFile, leafId);
		await copySessionArtifacts(sourceFile, branched);
		return branched;
	}

	const forked = await SessionManager.forkFrom(sourceFile, sm.getCwd(), sm.getSessionDir(), undefined, {
		suppressBreadcrumb: true,
	});
	const forkedFile = forked.getSessionFile();
	await forked.close();
	if (!forkedFile || !existsSync(forkedFile)) throw new Error("omp did not write the forked session");
	return forkedFile;
}

/** Private, short-lived carrier for the unsent prompt. */
function stashDraft(text: string): string {
	const dir = mkdtempSync(join(tmpdir(), "omp-fork-tab-"));
	const file = join(dir, "draft.txt");
	writeFileSync(file, text, { encoding: "utf8", mode: 0o600 });
	return file;
}

/**
 * Remove a stashed draft and its directory.
 *
 * `rmdirSync`, not a recursive `rm`: the path may have come from the
 * environment, and this must never delete more than the one file we made.
 */
function discardDraft(file: string): void {
	rmSync(file, { force: true });
	try {
		rmdirSync(dirname(file));
	} catch {
		// Not ours, not empty, or already gone.
	}
}

// ---------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------

function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * The omp invocation itself — what you would have typed.
 *
 * `env` rather than a bare `VAR=… cmd` prefix so the assignment is also valid
 * under fish, and so the draft cannot be mistaken for a persistent export.
 */
function ompCommand(sessionFile: string | undefined, draftFile: string | undefined): string {
	const parts: string[] = [];
	if (draftFile) parts.push("env", `${DRAFT_ENV}=${shellQuote(draftFile)}`);
	parts.push(shellQuote(resolveOmpBinary()));
	if (sessionFile) parts.push("--session", shellQuote(sessionFile));
	return parts.join(" ");
}

/**
 * Same command, re-entered through the user's login shell.
 *
 * The spawned process starts from a bare system environment, so without this
 * the forked omp would run with a different PATH — and therefore different
 * tools — than the session it was forked from. `-l` for the profile, `-i` for
 * the rc file, since PATH is routinely set in either.
 */
function loginShellCommand(inner: string): string {
	const shell = process.env.SHELL?.trim();
	if (!shell) return inner;
	return `exec ${shell} -lic ${shellQuote(inner)}`;
}

function run(bin: string, args: string[]): string {
	return execFileSync(bin, args, {
		encoding: "utf8",
		timeout: SPAWN_TIMEOUT_MS,
		stdio: ["ignore", "pipe", "pipe"],
	});
}

/**
 * The pane *this* omp is in, as a UUID.
 *
 * `cmux identify` resolves `caller` from the inherited `CMUX_*` environment,
 * so it names our own pane even when the focus is elsewhere — which it can be,
 * since a command may be triggered while this tab is in the background. UUIDs,
 * never refs: refs are positional (`surface:9`) and shift as tabs open and
 * close, so a ref captured a moment ago can address someone else's tab.
 */
function cmuxCallerPane(): string | undefined {
	try {
		const identity = JSON.parse(run("cmux", ["identify", "--json", "--id-format", "both"]));
		const paneId = identity?.caller?.pane_id;
		return typeof paneId === "string" && paneId.length > 0 ? paneId : undefined;
	} catch {
		// Fall through: new-surface targets the current workspace's focused pane.
		return undefined;
	}
}

type Opened = { ok: true; where: string } | { ok: false; reason: string };

/** `new-surface` prints `OK <surface> <pane> <workspace>` under --id-format uuids. */
function parseSurfaceId(output: string): string | undefined {
	const id = output.trim().split(/\s+/)[1];
	return id && /^[0-9A-Fa-f-]{36}$/.test(id) ? id : undefined;
}

function openInCmux(command: string, cwd: string): Opened {
	const args = ["new-surface", "--type", "terminal", "--id-format", "uuids"];
	const pane = cmuxCallerPane();
	if (pane) args.push("--pane", pane);
	args.push("--working-directory", cwd, "--focus", "true");

	let surface: string | undefined;
	try {
		surface = parseSurfaceId(run("cmux", args));
	} catch (error) {
		return { ok: false, reason: describe(error) };
	}
	if (!surface) return { ok: false, reason: "cmux did not report the new tab's id" };

	try {
		run("cmux", ["respawn-pane", "--surface", surface, "--command", command]);
		return { ok: true, where: "new tab" };
	} catch (error) {
		// The tab exists but has nothing useful in it. Take it back rather than
		// leaving a stray shell behind; the surface id came from cmux itself, so
		// this can only close the tab we just made.
		try {
			run("cmux", ["close-surface", "--surface", surface]);
		} catch {
			// Best effort.
		}
		return { ok: false, reason: describe(error) };
	}
}

function openTab(command: string, cwd: string): Opened {
	if (process.env.CMUX_SURFACE_ID) return openInCmux(command, cwd);

	if (process.env.TMUX) {
		try {
			run("tmux", ["new-window", "-c", cwd, command]);
			return { ok: true, where: "new tmux window" };
		} catch (error) {
			return { ok: false, reason: describe(error) };
		}
	}

	return { ok: false, reason: "no supported terminal detected (cmux or tmux)" };
}

function describe(error: unknown): string {
	if (error && typeof error === "object" && "stderr" in error) {
		const stderr = String((error as { stderr?: unknown }).stderr ?? "").trim();
		if (stderr) return stderr.split("\n")[0]!;
	}
	return error instanceof Error ? error.message : String(error);
}

// ---------------------------------------------------------------------------
// The shared half of both commands
// ---------------------------------------------------------------------------

interface TabRequest {
	/** Session file to open. `undefined` starts a fresh omp. */
	sessionFile: string | undefined;
	/** Prompt to restore, unsent, in the new tab's editor. */
	draft?: string;
	/** Confirmation notice once the tab is open, completed with its kind. */
	success: (where: string) => string;
}

function launchInTab(ctx: ExtensionCommandContext, request: TabRequest): void {
	const draftFile = request.draft ? stashDraft(request.draft) : undefined;
	const command = ompCommand(request.sessionFile, draftFile);
	const result = openTab(loginShellCommand(command), ctx.sessionManager.getCwd());

	if (result.ok) {
		ctx.ui.notify(request.success(result.where), "info");
		return;
	}

	// The session file is already on disk, so the fork is not lost — say
	// exactly how to pick it up rather than silently discarding the work.
	if (draftFile) discardDraft(draftFile);
	ctx.ui.notify(
		`Could not open a tab (${result.reason}). Run this yourself:  ${ompCommand(request.sessionFile, undefined)}`,
		"error",
	);
}

// ---------------------------------------------------------------------------
// Picker
// ---------------------------------------------------------------------------

/** One line, capped — the picker is for recognising a prompt, not reading it. */
function labelFor(text: string, ordinal: number): string {
	const line = text.replace(/\s+/g, " ").trim();
	const clipped = line.length > LABEL_MAX_CHARS ? `${line.slice(0, LABEL_MAX_CHARS - 1)}…` : line;
	// `select` answers with the label, so the ordinal also keeps repeats apart.
	return `${ordinal}. ${clipped}`;
}

/** Newest first, as the most recent prompt is the usual do-over. */
async function pickPrompt(
	ctx: ExtensionCommandContext,
	candidates: BranchCandidate[],
): Promise<BranchCandidate | undefined> {
	const byLabel = new Map<string, BranchCandidate>();
	for (let i = candidates.length - 1; i >= 0; i--) {
		byLabel.set(labelFor(candidates[i]!.text, i + 1), candidates[i]!);
	}
	const choice = await ctx.ui.select("Branch into a new tab from before…", [...byLabel.keys()]);
	return choice === undefined ? undefined : byLabel.get(choice);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

export default function forkTabExtension(pi: ExtensionAPI): void {
	pi.registerCommand("fork-tab", {
		description: "Fork this conversation into a new terminal tab, keeping this session running",
		handler: async (_args, ctx) => {
			if (!ctx.hasUI) {
				ctx.ui.notify("/fork-tab needs interactive mode", "error");
				return;
			}
			// Mid-turn the leaf is a prompt whose answer is still streaming; a copy
			// taken now would open on a question nobody is going to answer.
			if (!ctx.isIdle()) {
				ctx.ui.notify("Wait for the current response to finish or abort it before forking.", "warning");
				return;
			}

			let sessionFile: string;
			try {
				sessionFile = await forkToNewFile(ctx.sessionManager);
			} catch (error) {
				ctx.ui.notify(describe(error), "error");
				return;
			}

			launchInTab(ctx, {
				sessionFile,
				success: (where) => `Forked into a ${where} — this session is unchanged`,
			});
		},
	});

	pi.registerCommand("branch-tab", {
		description: "Branch from before an earlier prompt into a new terminal tab, keeping this session running",
		handler: async (_args, ctx) => {
			if (!ctx.hasUI) {
				ctx.ui.notify("/branch-tab needs interactive mode", "error");
				return;
			}

			const sm = ctx.sessionManager;
			const candidates = branchCandidates(sm);
			if (candidates.length === 0) {
				ctx.ui.notify("No messages to branch from", "warning");
				return;
			}

			const picked = await pickPrompt(ctx, candidates);
			if (!picked) return;

			// "Before" semantics: the new session stops short of the selected
			// prompt, which comes back as editable text — a do-over, not a copy.
			// Before the first prompt there is at most startup metadata, and
			// possibly no file yet (it is written lazily), so that do-over is
			// simply a fresh omp.
			const parentId = picked.parentId;
			if (parentId === null || !sm.getBranch(parentId).some((entry) => entry.type === "message")) {
				launchInTab(ctx, {
					sessionFile: undefined,
					draft: picked.text,
					success: (where) => `Branched into a ${where} — it starts empty with your prompt restored`,
				});
				return;
			}

			let sessionFile: string;
			try {
				sessionFile = await branchToNewFile(sm, persistedSessionFile(sm), parentId);
			} catch (error) {
				ctx.ui.notify(describe(error), "error");
				return;
			}

			launchInTab(ctx, {
				sessionFile,
				draft: picked.text,
				success: (where) => `Branched into a ${where} — this session is unchanged`,
			});
		},
	});

	/**
	 * Receiving side: restore the prompt the fork was taken from.
	 *
	 * Consumed exactly once, on the first `session_start`. omp's event carries
	 * no reason, but it fires at startup before anything else could have
	 * reached the editor; clearing the variable then means a later re-emit
	 * (e.g. `/reload`) cannot prefill again over whatever you have typed, and
	 * the prompt does not leak into the environment of tools this omp spawns.
	 */
	pi.on("session_start", (_event, ctx) => {
		const draftFile = process.env[DRAFT_ENV];
		if (!draftFile) return;
		delete process.env[DRAFT_ENV];

		let draft = "";
		try {
			draft = readFileSync(draftFile, "utf8");
		} catch {
			// Already consumed, or never written. Nothing to restore.
		}
		discardDraft(draftFile);

		if (!draft || !ctx.hasUI) return;
		ctx.ui.setEditorText(draft);
	});
}

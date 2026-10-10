/** Passive cache-retention confidence on the status row; observations in /cache-status. */
import type { ExtensionAPI, ExtensionContext, SessionEntry } from "@oh-my-pi/pi-coding-agent";
import {
	cacheBranchAnchor,
	cacheBranchObservation,
	cacheModelIdentity,
	cacheRequestEvidence,
	formatCacheEstimate,
	matchesCacheModel,
	type CacheRequestEvidence,
	type LiveCacheResponse,
} from "./.lib/cache-estimate";
import { CacheCalibration, formatCacheDetails } from "./.lib/cache-calibration";
import {
	STATUS_LINE_REMOVE,
	STATUS_LINE_REQUEST,
	STATUS_LINE_SET,
	type StatusLineRemoval,
	type StatusLineSegment,
} from "./.lib/status-line-protocol";

interface BranchSnapshot {
	id: string;
	message?: unknown;
	content?: unknown;
	blocks?: { block: unknown; text?: string }[];
}
interface PendingRequest {
	at: number;
	parentId: string | null;
	evidence?: CacheRequestEvidence;
	key: string;
}

interface CompletedCacheRequest {
	key: string;
	at: number;
	cacheRead: number;
	branchLength: number;
}

export default function cacheStatus(pi: ExtensionAPI) {
	let current: ExtensionContext | undefined;
	let sessionId = "";
	let identity = "";
	let interval: Timer | undefined;
	let debounce: Timer | undefined;
	let unsubscribeInput: (() => void) | undefined;
	let live: LiveCacheResponse | undefined;
	let pendingRequest: PendingRequest | undefined;
	let completedRequest: CompletedCacheRequest | undefined;
	let activeEvidence: CacheRequestEvidence | undefined;
	let previousBranch: BranchSnapshot[] = [];
	let invalidatedAt = -Infinity;
	let lastText = "";
	let lastTone = "";
	const requests = new Map<number, CacheRequestEvidence>();
	const excluded = new Set<string>();
	const calibration = new CacheCalibration();

	function detach() {
		unsubscribeInput?.();
		unsubscribeInput = undefined;
		if (current && interval !== undefined) current.clearTimer(interval);
		if (current && debounce !== undefined) current.clearTimer(debounce);
		interval = undefined;
		debounce = undefined;
	}

	function remove() {
		if (sessionId) pi.events.emit(STATUS_LINE_REMOVE, { sessionId, id: "cache" } satisfies StatusLineRemoval);
		lastText = "";
		lastTone = "";
	}

	function invalidate(entries: readonly SessionEntry[]) {
		live = undefined;
		pendingRequest = undefined;
		completedRequest = undefined;
		requests.clear();
		excluded.clear();
		for (const entry of entries) excluded.add(entry.id);
		invalidatedAt = Date.now();
	}

	function refresh(force = false) {
		const ctx = current;
		if (!ctx) return;
		const model = ctx.model;
		const nextIdentity = cacheModelIdentity(model);
		const branch = ctx.sessionManager.getBranch();
		const entries = ctx.sessionManager.getEntries();
		const previousRequest = completedRequest;
		if (previousRequest && branch.some((entry, index) => index >= previousRequest.branchLength
			&& (entry.type === "compaction" || entry.type === "reset_boundary" || entry.type === "branch_summary"
				|| (entry.type === "model_change" && (!entry.role || entry.role === "default"))))) completedRequest = undefined;
		if (model && previousRequest && entries.some(entry => entry.type === "model_usage"
			&& (entry.purpose === "cache-warm" || entry.purpose === "cache-warm:extension-override")
			&& entry.stopReason !== "error" && entry.stopReason !== "aborted" && matchesCacheModel(model, entry)
			&& (entry.usage.cacheRead > 0 || entry.usage.cacheWrite > 0)
			&& Date.parse(entry.timestamp) >= previousRequest.at)) completedRequest = undefined;
		// Native /shake keeps text-block identity but mutates block.text. Keep
		// primitive strings/references, not copies or hashes of the full history.
		let rewritten = previousBranch.length > branch.length;
		const snapshots = branch.map((entry, index): BranchSnapshot => {
			const message = entry.type === "message" ? entry.message : entry.type === "custom_message" ? entry : undefined;
			const content = message && "content" in message ? message.content : undefined;
			const previous = previousBranch[index];
			const unchanged = previous !== undefined && previous.id === entry.id && previous.message === message && previous.content === content && (!Array.isArray(content) || (previous.blocks?.length === content.length && content.every((block: unknown, blockIndex: number) => {
				const before = previous.blocks?.[blockIndex];
				const text = typeof block === "object" && block !== null && "text" in block && typeof block.text === "string" ? block.text : undefined;
				return before !== undefined && before.block === block && before.text === text;
			})));
			if (unchanged && previous) return previous;
			if (previous) rewritten = true;
			return {
				id: entry.id,
				message,
				content,
				blocks: Array.isArray(content) ? content.map((block: unknown) => ({
					block,
					text: typeof block === "object" && block !== null && "text" in block && typeof block.text === "string" ? block.text : undefined,
				})) : undefined,
			};
		});
		if (nextIdentity !== identity) activeEvidence = undefined;
		if (nextIdentity !== identity || rewritten) invalidate(entries);
		identity = nextIdentity;
		previousBranch = snapshots;
		const response = live;
		if (response) {
			const persisted = branch.some(entry => entry.type === "message" && entry.message.role === "assistant" && entry.message.timestamp === response.message.timestamp && entry.message.model === response.message.model && entry.message.provider === response.message.provider && entry.message.api === response.message.api);
			const parentExists = response.parentId === null ? branch.length === 0 : branch.some(entry => entry.id === response.parentId);
			if (persisted || !parentExists) live = undefined;
		}
		const retention = process.env.PI_CACHE_RETENTION;
		const anchor = model ? cacheBranchAnchor(model, branch, entries, live, requests, excluded, retention) : undefined;
		const observation = retention !== "none" && model && (!anchor || anchor.heuristic)
			? cacheBranchObservation(model, branch, entries, live, excluded) : undefined;
		const estimate = formatCacheEstimate(anchor, Date.now(), retention, observation);
		if (!force && estimate.text === lastText && estimate.tone === lastTone) return;
		lastText = estimate.text;
		lastTone = estimate.tone;
		pi.events.emit(STATUS_LINE_SET, {
			sessionId,
			id: "cache",
			order: 20,
			...estimate,
		} satisfies StatusLineSegment);
	}

	function bind(ctx: ExtensionContext, invalidateHistory = false) {
		const previousIdentity = identity;
		const previousEvidence = activeEvidence;
		detach();
		remove();
		current = undefined;
		live = undefined;
		pendingRequest = undefined;
		completedRequest = undefined;
		activeEvidence = cacheModelIdentity(ctx.model) === previousIdentity ? previousEvidence : undefined;
		requests.clear();
		excluded.clear();
		previousBranch = [];
		invalidatedAt = -Infinity;
		sessionId = "";
		identity = "";
		if (!ctx.hasUI || ctx.agent.kind === "sub") return;
		current = ctx;
		sessionId = ctx.sessionManager.getSessionId();
		identity = cacheModelIdentity(ctx.model);
		if (invalidateHistory) invalidate(ctx.sessionManager.getEntries());
		interval = ctx.setInterval(() => refresh(), 15_000);
		unsubscribeInput = ctx.ui.onTerminalInput(() => {
			if (debounce !== undefined) ctx.clearTimer(debounce);
			debounce = ctx.setTimeout(() => {
				debounce = undefined;
				refresh();
			}, 1000);
			// Never consume, replace, retain, or log typed/pasted terminal bytes.
			return undefined;
		});
		refresh(true);
	}

	function adopt(ctx: ExtensionContext): boolean {
		if (!ctx.hasUI || ctx.agent.kind === "sub") return false;
		// Native handlers wrap ui in a fresh proxy; proxy identity is not a
		// surface replacement. Lifecycle events explicitly reattach listeners.
		if (!current || ctx.sessionManager.getSessionId() !== sessionId || current.sessionManager !== ctx.sessionManager) bind(ctx);
		else current = ctx;
		return current !== undefined;
	}

	pi.events.on(STATUS_LINE_REQUEST, (payload: unknown) => {
		if (typeof payload !== "object" || payload === null || !("sessionId" in payload) || payload.sessionId !== sessionId || !current) return;
		refresh(true);
	});
	pi.on("session_start", (_event, ctx) => bind(ctx));
	pi.on("session_switch", (_event, ctx) => bind(ctx));
	pi.on("session_branch", (_event, ctx) => bind(ctx, true));
	pi.on("session_tree", (_event, ctx) => bind(ctx, true));
	pi.on("session_compact", (_event, ctx) => bind(ctx, true));
	pi.on("before_provider_request", (event, ctx) => {
		if (!current || !ctx.hasUI || ctx.agent.kind === "sub" || ctx.sessionManager.getSessionId() !== sessionId) return;
		// A provider hook's ctx.model can be a tiny/ephemeral call override;
		// never retain it as the current chat model or replace local context.
		refresh();
		const model = current.model;
		const payload = event.payload;
		if (!model || typeof payload !== "object" || payload === null || !("model" in payload) || typeof payload.model !== "string" || (payload.model !== model.id && payload.model !== model.requestModelId)) return;
		// Overlapping/retried provider requests cannot establish one idle interval.
		if (pendingRequest) completedRequest = undefined;
		const evidence = cacheRequestEvidence(payload, model);
		pendingRequest = {
			at: Date.now(),
			parentId: ctx.sessionManager.getLeafId(),
			evidence,
			key: JSON.stringify([identity, process.env.PI_CACHE_RETENTION ?? null, evidence?.tier ?? null, evidence?.seconds ?? null]),
		};
	});
	pi.on("message_end", (event, ctx) => {
		if (!adopt(ctx)) return;
		refresh();
		const message = event.message;
		if (!ctx.model || message.role !== "assistant" || !matchesCacheModel(ctx.model, message)) return;
		if (message.stopReason === "error" || message.stopReason === "aborted" || !Number.isFinite(message.timestamp) || message.timestamp <= 0) {
			pendingRequest = undefined;
			completedRequest = undefined;
			return;
		}
		const branch = ctx.sessionManager.getBranch();
		const parentId = ctx.sessionManager.getLeafId();
		const requestParentIndex = pendingRequest?.parentId === null ? -1 : branch.findIndex(entry => entry.id === pendingRequest?.parentId);
		// refresh() above rejects rewritten prefixes. On the remaining append-only
		// branch, shortcuts and an already-persisted response may advance the leaf
		// without changing the request's prompt; new cache boundaries may not.
		const applicableRequest = pendingRequest
			&& (pendingRequest.parentId === null || requestParentIndex >= 0)
			&& !branch.some((entry, index) => index > requestParentIndex && (entry.type === "compaction" || entry.type === "reset_boundary" || entry.type === "branch_summary" || (entry.type === "model_change" && (!entry.role || entry.role === "default"))))
			&& pendingRequest.at >= message.timestamp
			&& pendingRequest.at >= invalidatedAt ? pendingRequest : undefined;
		if (message.timestamp < invalidatedAt && !applicableRequest) return;
		// Even an empty evidence object proves that this extension observed a
		// matching request on the current route; restored usage alone cannot.
		const request = applicableRequest ? applicableRequest.evidence ?? {} : undefined;
		activeEvidence = applicableRequest?.evidence;
		const read = message.usage.cacheRead;
		const previous = completedRequest;
		if (applicableRequest && previous && previous.key === applicableRequest.key
			&& Number.isFinite(read) && read > 0 && previous.cacheRead > 0 && read >= previous.cacheRead
			&& process.env.PI_CACHE_RETENTION !== "none") {
			calibration.record(applicableRequest.key, applicableRequest.at - previous.at, Date.now());
		}
		// Completion-to-next-request gaps exclude streaming time. A miss breaks
		// the sequence; it neither refreshes a confirmed hit nor proves expiry.
		completedRequest = applicableRequest
			? { key: applicableRequest.key, at: Date.now(), cacheRead: Number.isFinite(read) ? read : 0, branchLength: branch.length }
			: undefined;
		if (request) requests.set(message.timestamp, request);
		// Detached responses attach to the actual leaf, including streaming appends.
		live = { message, parentId, request };
		pendingRequest = undefined;
		refresh();
	});
	pi.registerCommand("cache-status", {
		description: "Show cache-retention evidence, observed reuse, and calibration storage details",
		handler: (_args, ctx) => {
			if (!adopt(ctx)) return;
			refresh();
			const model = current?.model;
			const branch = ctx.sessionManager.getBranch();
			const entries = ctx.sessionManager.getEntries();
			const retention = process.env.PI_CACHE_RETENTION;
			const key = JSON.stringify([identity, retention ?? null, activeEvidence?.tier ?? null, activeEvidence?.seconds ?? null]);
			let summary = retention === "none" ? undefined : calibration.summary(key);
			let historicTier: "short" | "long" | undefined;
			if (!activeEvidence && retention !== "none") {
				for (const tier of ["short", "long"] as const) {
					const candidate = calibration.summary(JSON.stringify([identity, retention ?? null, tier, null]));
					if (candidate && (!summary || candidate.lastAt > summary.lastAt)) {
						summary = candidate;
						historicTier = tier;
					}
				}
			}
			const anchor = model ? cacheBranchAnchor(model, branch, entries, live, requests, excluded, retention) : undefined;
			const observation = model ? cacheBranchObservation(model, branch, entries, live, excluded) : undefined;
			const basis = anchor?.minimum
				? "documented OpenAI public-API minimum"
				: anchor && !anchor.heuristic ? "explicit provider/catalog retention estimate" : "no endpoint-specific retention bound";
			ctx.ui.notify([
				"Cache details",
				lastText,
				`Model: ${model?.id ?? "not selected"}`,
				`Lifetime basis: ${basis}`,
				...formatCacheDetails(observation, summary, Date.now(), historicTier, calibration.persistent),
			].join("\n"), "info");
		},
	});
	pi.on("turn_end", (_event, ctx) => {
		if (adopt(ctx)) refresh();
	});
	pi.on("session_shutdown", (_event, ctx) => {
		if (ctx.agent.kind === "sub" || ctx.sessionManager.getSessionId() !== sessionId) return;
		detach();
		remove();
		current = undefined;
		live = undefined;
		pendingRequest = undefined;
		completedRequest = undefined;
		activeEvidence = undefined;
		previousBranch = [];
		requests.clear();
		excluded.clear();
		sessionId = "";
		identity = "";
		// Keep the factory's snapshot subscription for a reused native runtime.
	});
}

import type { SessionEntry } from "@oh-my-pi/pi-coding-agent";
import type { AssistantMessage, Model, Usage } from "@oh-my-pi/pi-ai";
import type { StatusLineTone } from "./status-line-protocol";

export type CacheTier = "short" | "long";
export interface CacheRequestEvidence {
	tier?: CacheTier;
	seconds?: number;
	heuristic?: true;
	minimum?: true;
}
export interface CacheAnchor {
	at: number;
	seconds: number;
	heuristic?: true;
	minimum?: true;
}
export interface CacheEstimate {
	text: string;
	tone: StatusLineTone;
}
export interface CacheObservation {
	at: number;
	kind: "hit" | "write";
}

function record(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function cacheModelIdentity(model: Model | undefined): string {
	return model ? JSON.stringify([model.provider, model.api, model.id, model.requestModelId, model.baseUrl]) : "";
}

export function matchesCacheModel(model: Model, response: Pick<AssistantMessage, "provider" | "api" | "model">): boolean {
	return response.provider === model.provider && response.api === model.api && response.model === model.id;
}

function officialEndpoint(model: Model): "anthropic" | "openai" | "codex" | undefined {
	let url: URL;
	try {
		url = new URL(model.baseUrl);
	} catch {
		return undefined;
	}
	if (url.protocol !== "https:" || url.port || url.username || url.password || url.search || url.hash) return undefined;
	const path = url.pathname.replace(/\/$/, "");
	if (model.provider === "anthropic" && model.api === "anthropic-messages" && url.hostname === "api.anthropic.com" && (path === "" || path === "/v1")) return "anthropic";
	if (model.provider === "openai" && (model.api === "openai-responses" || model.api === "openai-completions") && url.hostname === "api.openai.com" && path === "/v1") return "openai";
	if (model.provider === "openai-codex" && model.api === "openai-codex-responses" && url.hostname === "chatgpt.com" && (path === "/backend-api" || path === "/backend-api/codex")) return "codex";
	return undefined;
}

/** Inspect only recognized wire fields, never credentials, headers, or prompt text. */
export function cacheRequestEvidence(payload: unknown, model: Model): CacheRequestEvidence | undefined {
	if (!record(payload) || typeof payload.model !== "string" || (payload.model !== model.id && payload.model !== model.requestModelId)) return undefined;
	const endpoint = officialEndpoint(model);
	if (endpoint === "openai") {
		if (payload.prompt_cache_retention === "in_memory") return { tier: "short" };
		if (payload.prompt_cache_retention === "24h") return { tier: "long" };
		return undefined;
	}
	if (endpoint !== "anthropic") return undefined;
	let short = false;
	let long = false;
	const inspect = (value: unknown): void => {
		if (!record(value)) return;
		const control = value.cache_control;
		if (record(control) && control.type === "ephemeral") {
			if (control.ttl === "1h") long = true;
			else if (control.ttl === undefined || control.ttl === "5m") short = true;
		}
		if (Array.isArray(value.content)) for (const block of value.content) inspect(block);
	};
	for (const field of [payload.system, payload.messages, payload.tools]) {
		if (Array.isArray(field)) for (const block of field) inspect(block);
	}
	// Mixed tiers only promise the shorter lifetime for the complete cached prefix.
	return short ? { tier: "short", seconds: 300 } : long ? { tier: "long", seconds: 3600 } : undefined;
}

export function cacheLifetime(
	model: Model,
	usage: Usage,
	request: CacheRequestEvidence | undefined,
	previous: CacheRequestEvidence | undefined,
	retention: string | undefined,
): CacheRequestEvidence | undefined {
	const endpoint = officialEndpoint(model);
	if (!endpoint || retention === "none") return undefined;
	let evidence: CacheRequestEvidence | undefined;
	if (endpoint === "anthropic") {
		if ((usage.cttl?.ephemeral5m ?? 0) > 0) evidence = { tier: "short", seconds: 300 };
		else if ((usage.cttl?.ephemeral1h ?? 0) > 0) evidence = { tier: "long", seconds: 3600 };
	}
	// Empty evidence confirms a local request, not a retention policy.
	if (request?.tier !== undefined || request?.seconds !== undefined) evidence ??= request;
	let inheritedMinimum = false;
	if (!evidence && (usage.cacheRead > 0 || usage.cacheWrite > 0)) {
		evidence = previous;
		inheritedMinimum = previous?.minimum === true;
	}
	if (!evidence && (retention === "short" || retention === "long")) evidence = { tier: retention };
	if (evidence?.seconds !== undefined && !inheritedMinimum && !evidence.heuristic) {
		return evidence.minimum ? { ...evidence, minimum: undefined } : evidence;
	}
	const declared = evidence?.tier === undefined ? undefined : model.promptCache?.[evidence.tier];
	if (declared !== undefined && Number.isFinite(declared) && declared > 0) return { tier: evidence?.tier, seconds: declared };
	if (endpoint === "anthropic") {
		return evidence?.tier === undefined ? undefined : { tier: evidence.tier, seconds: evidence.tier === "long" ? 3600 : 300 };
	}
	if (endpoint === "codex") {
		const tier = evidence?.tier ?? "short";
		const metadata = model.promptCache?.[tier];
		if (metadata !== undefined && Number.isFinite(metadata) && metadata > 0) return { tier, seconds: metadata };
		// First-party Codex PR #11190: a 60-minute idle-expiry HEURISTIC,
		// not model metadata or a promise that a particular prefix is resident.
		return { ...evidence, seconds: 3600, heuristic: true };
	}
	const tier = evidence?.tier ?? "short";
	const metadata = model.promptCache?.[tier];
	if (metadata !== undefined && Number.isFinite(metadata) && metadata > 0) return { tier, seconds: metadata };
	const version = /^gpt-(\d+)(?:\.(\d+))?(?:-|$)/.exec(model.requestModelId ?? model.id);
	const newer = version !== null && (Number(version[1]) > 5 || (Number(version[1]) === 5 && Number(version[2] ?? 0) >= 6));
	// Historical usage lacks endpoint/alias provenance. A public-API minimum
	// requires a locally matched current request plus confirmed cache use.
	if (newer && request !== undefined && (usage.cacheRead > 0 || usage.cacheWrite > 0)) return { tier, seconds: 1800, minimum: true };
	// Older retention and unverified historical routes have no supported timer.
	return { tier, seconds: newer || tier === "long" ? 1800 : 300, heuristic: true };
}

export function formatCacheEstimate(anchor: CacheAnchor | undefined, now: number, retention: string | undefined, observation?: CacheObservation): CacheEstimate {
	if (retention === "none") return { text: "cache tracking off", tone: "dim" };
	if (!anchor || anchor.heuristic || !Number.isFinite(anchor.at) || anchor.at <= 0 || !Number.isFinite(anchor.seconds) || anchor.seconds <= 0 || !Number.isFinite(now)) {
		if (observation && Number.isFinite(observation.at) && observation.at > 0 && Number.isFinite(now) && observation.at <= now) {
			const elapsed = now - observation.at;
			const age = elapsed >= 60_000 ? `${Math.floor(elapsed / 60_000)}m` : `${Math.floor(elapsed / 1000)}s`;
			return { text: `cache ${observation.kind} ${age} ago · time left unknown · low confidence`, tone: "dim" };
		}
		return { text: "cache time left unknown · low confidence", tone: "dim" };
	}
	const remaining = anchor.at + anchor.seconds * 1000 - now;
	if (remaining <= 0) return { text: "cache window elapsed · expiry uncertain", tone: "warning" };
	const time = remaining >= 60_000 ? `${Math.floor(remaining / 60_000)}m` : `${Math.floor(remaining / 1000)}s`;
	return anchor.minimum
		? { text: `cache ≥${time} left · high confidence`, tone: "success" }
		: { text: `cache ~${time} left · medium confidence`, tone: "warning" };
}

export interface LiveCacheResponse {
	message: AssistantMessage;
	parentId: string | null;
	request?: CacheRequestEvidence;
}

function cacheBranchBoundary(branch: readonly SessionEntry[]): number {
	let boundary = -1;
	for (let index = 0; index < branch.length; index++) {
		const entry = branch[index];
		if (entry.type === "compaction" || entry.type === "reset_boundary" || entry.type === "branch_summary" || (entry.type === "model_change" && (!entry.role || entry.role === "default"))) boundary = index;
	}
	return boundary;
}

function eligibleLiveCacheResponse(
	model: Model,
	branch: readonly SessionEntry[],
	live: LiveCacheResponse | undefined,
	boundary: number,
	latestRealTimestamp: number,
): live is LiveCacheResponse {
	const parentIndex = live?.parentId === null ? -1 : branch.findIndex(entry => entry.id === live?.parentId);
	return live !== undefined && live.message.stopReason !== "error" && live.message.stopReason !== "aborted" && Number.isFinite(live.message.timestamp) && live.message.timestamp > 0 && matchesCacheModel(model, live.message) && parentIndex >= boundary && (live.parentId === null ? branch.length === 0 : parentIndex >= 0) && live.message.timestamp >= latestRealTimestamp;
}

function cacheUsageObservation(usage: Usage, at: number): CacheObservation | undefined {
	if (usage.cacheRead > 0) return { at, kind: "hit" };
	if (usage.cacheWrite > 0) return { at, kind: "write" };
	return undefined;
}

/** Rebuild from the active prefix, never from a sibling response or old rewrite. */
export function cacheBranchAnchor(
	model: Model,
	branch: readonly SessionEntry[],
	entries: readonly SessionEntry[],
	live: LiveCacheResponse | undefined,
	requests: ReadonlyMap<number, CacheRequestEvidence>,
	excluded: ReadonlySet<string>,
	retention: string | undefined,
): CacheAnchor | undefined {
	const boundary = cacheBranchBoundary(branch);
	let evidence: CacheRequestEvidence | undefined;
	let anchor: CacheAnchor | undefined;
	let latestRealIndex = -1;
	let latestRealTimestamp = -Infinity;
	let foregroundFloorIndex = -1;
	let foregroundFloorTimestamp = -Infinity;
	const foregroundResponses: { index: number; at: number; request?: CacheRequestEvidence; evidence?: CacheRequestEvidence }[] = [];
	for (let index = boundary + 1; index < branch.length; index++) {
		const entry = branch[index];
		if (excluded.has(entry.id) || entry.type !== "message" || entry.message.role !== "assistant") continue;
		const message = entry.message;
		if (message.stopReason === "error" || message.stopReason === "aborted") continue;
		if (!matchesCacheModel(model, message)) {
			evidence = undefined;
			anchor = undefined;
			latestRealIndex = -1;
			foregroundFloorIndex = -1;
			foregroundFloorTimestamp = -Infinity;
			foregroundResponses.length = 0;
			continue;
		}
		if (!Number.isFinite(message.timestamp) || message.timestamp <= 0) continue;
		const request = requests.get(message.timestamp);
		const confirmed = cacheUsageObservation(message.usage, message.timestamp);
		if (confirmed || foregroundFloorIndex < 0) {
			foregroundFloorIndex = index;
			foregroundFloorTimestamp = message.timestamp;
		}
		if (confirmed) {
			evidence = cacheLifetime(model, message.usage, request, evidence, retention);
			anchor = evidence?.seconds === undefined ? undefined : { at: message.timestamp, seconds: evidence.seconds, heuristic: evidence.heuristic, minimum: evidence.minimum };
		}
		foregroundResponses.push({ index, at: message.timestamp, request, evidence });
		latestRealIndex = index;
		latestRealTimestamp = message.timestamp;
	}
	if (eligibleLiveCacheResponse(model, branch, live, boundary, latestRealTimestamp)) {
		const confirmed = cacheUsageObservation(live.message.usage, live.message.timestamp);
		if (confirmed || foregroundFloorIndex < 0) {
			foregroundFloorIndex = branch.length;
			foregroundFloorTimestamp = live.message.timestamp;
		}
		if (confirmed) {
			evidence = cacheLifetime(model, live.message.usage, live.request, evidence, retention);
			anchor = evidence?.seconds === undefined ? undefined : { at: live.message.timestamp, seconds: evidence.seconds, heuristic: evidence.heuristic, minimum: evidence.minimum };
		}
		foregroundResponses.push({ index: branch.length, at: live.message.timestamp, request: live.request, evidence });
		latestRealIndex = branch.length;
		latestRealTimestamp = live.message.timestamp;
	}
	if (latestRealIndex < 0) return anchor;
	const activeIndexes = new Map(branch.map((entry, index) => [entry.id, index]));
	for (const entry of entries) {
		if (excluded.has(entry.id) || entry.type !== "model_usage" || (entry.purpose !== "cache-warm" && entry.purpose !== "cache-warm:extension-override") || entry.stopReason === "error" || entry.stopReason === "aborted") continue;
		if (!matchesCacheModel(model, entry) || !(entry.usage.cacheRead > 0 || entry.usage.cacheWrite > 0)) continue;
		const parentIndex = entry.parentId === null ? undefined : activeIndexes.get(entry.parentId);
		if (parentIndex === undefined || parentIndex < foregroundFloorIndex || parentIndex <= boundary) continue;
		const at = Date.parse(entry.timestamp);
		if (!Number.isFinite(at) || at <= foregroundFloorTimestamp || (anchor !== undefined && at <= anchor.at)) continue;
		// A later zero-use response preserves a completed warm, not a warm
		// that finished later without including that response's active prefix.
		let foreground: (typeof foregroundResponses)[number] | undefined;
		let prefixMismatch = false;
		for (const response of foregroundResponses) {
			if (response.at > at) continue;
			if (response.index > parentIndex) {
				prefixMismatch = true;
				break;
			}
			foreground = response;
		}
		if (prefixMismatch) continue;
		// Reuse only evidence available before this warm. A proven foreground
		// minimum is explicit evidence here, downgraded to a completion estimate.
		const warmRequest = foreground?.request ?? (foreground?.evidence?.minimum ? foreground.evidence : undefined);
		const warmEvidence = cacheLifetime(model, entry.usage, warmRequest, foreground?.evidence, retention);
		if (warmEvidence?.seconds === undefined) continue;
		// Native model_usage records completion, not request-start, so omit
		// the minimum marker: this timestamp supports only an estimate.
		anchor = { at, seconds: warmEvidence.seconds, heuristic: warmEvidence.heuristic };
	}
	return anchor;
}

/** Confirm actual cache use without assigning an expiry to unknown or heuristic routes. */
export function cacheBranchObservation(
	model: Model,
	branch: readonly SessionEntry[],
	entries: readonly SessionEntry[],
	live: LiveCacheResponse | undefined,
	excluded: ReadonlySet<string>,
): CacheObservation | undefined {
	const boundary = cacheBranchBoundary(branch);
	let observation: CacheObservation | undefined;
	let latestRealIndex = -1;
	let latestRealTimestamp = -Infinity;
	let foregroundFloorIndex = -1;
	let foregroundFloorTimestamp = -Infinity;
	const foregroundResponses: { index: number; at: number }[] = [];
	for (let index = boundary + 1; index < branch.length; index++) {
		const entry = branch[index];
		if (excluded.has(entry.id) || entry.type !== "message" || entry.message.role !== "assistant") continue;
		const message = entry.message;
		if (message.stopReason === "error" || message.stopReason === "aborted") continue;
		if (!matchesCacheModel(model, message)) {
			observation = undefined;
			latestRealIndex = -1;
			foregroundFloorIndex = -1;
			foregroundFloorTimestamp = -Infinity;
			foregroundResponses.length = 0;
			continue;
		}
		if (!Number.isFinite(message.timestamp) || message.timestamp <= 0) continue;
		const confirmed = cacheUsageObservation(message.usage, message.timestamp);
		if (confirmed || foregroundFloorIndex < 0) {
			foregroundFloorIndex = index;
			foregroundFloorTimestamp = message.timestamp;
		}
		observation = confirmed ?? observation;
		foregroundResponses.push({ index, at: message.timestamp });
		latestRealIndex = index;
		latestRealTimestamp = message.timestamp;
	}
	if (eligibleLiveCacheResponse(model, branch, live, boundary, latestRealTimestamp)) {
		const confirmed = cacheUsageObservation(live.message.usage, live.message.timestamp);
		if (confirmed || foregroundFloorIndex < 0) {
			foregroundFloorIndex = branch.length;
			foregroundFloorTimestamp = live.message.timestamp;
		}
		observation = confirmed ?? observation;
		foregroundResponses.push({ index: branch.length, at: live.message.timestamp });
		latestRealIndex = branch.length;
		latestRealTimestamp = live.message.timestamp;
	}
	if (latestRealIndex < 0) return observation;
	const activeIndexes = new Map(branch.map((entry, index) => [entry.id, index]));
	for (const entry of entries) {
		if (excluded.has(entry.id) || entry.type !== "model_usage" || (entry.purpose !== "cache-warm" && entry.purpose !== "cache-warm:extension-override") || entry.stopReason === "error" || entry.stopReason === "aborted") continue;
		if (!matchesCacheModel(model, entry) || (entry.usage.cacheRead <= 0 && entry.usage.cacheWrite <= 0)) continue;
		const parentIndex = entry.parentId === null ? undefined : activeIndexes.get(entry.parentId);
		if (parentIndex === undefined || parentIndex < foregroundFloorIndex || parentIndex <= boundary) continue;
		const at = Date.parse(entry.timestamp);
		if (!Number.isFinite(at) || at <= foregroundFloorTimestamp || (observation !== undefined && at <= observation.at)) continue;
		// A later zero-use response preserves historical warming, but a warm
		// completed after that response must include its active prefix.
		if (foregroundResponses.some(response => response.index > parentIndex && response.at <= at)) continue;
		observation = cacheUsageObservation(entry.usage, at) ?? observation;
	}
	return observation;
}

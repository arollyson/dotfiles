/** One theme-aware below-editor row for independently enabled status contributors. */
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { truncateToWidth } from "@oh-my-pi/pi-tui";
import {
	STATUS_LINE_REMOVE,
	STATUS_LINE_REQUEST,
	STATUS_LINE_SET,
	type StatusLineRemoval,
	type StatusLineRequest,
	type StatusLineSegment,
	type StatusLineTone,
} from "./.lib/status-line-protocol";

const WIDGET_KEY = "com.brannon.status-line";
const CONTROL_TEXT = /[\p{Cc}\p{Cf}\u2028\u2029]/u;

function isIdentifier(value: unknown): value is string {
	return typeof value === "string" && value.length > 0 && !CONTROL_TEXT.test(value);
}

function isTone(value: unknown): value is StatusLineTone {
	return value === "success" || value === "warning" || value === "error" || value === "dim";
}

function isRemoval(value: unknown): value is StatusLineRemoval {
	return (
		typeof value === "object" &&
		value !== null &&
		"sessionId" in value &&
		isIdentifier(value.sessionId) &&
		"id" in value &&
		isIdentifier(value.id)
	);
}

function isSegment(value: unknown): value is StatusLineSegment {
	return (
		isRemoval(value) &&
		"order" in value &&
		typeof value.order === "number" &&
		Number.isFinite(value.order) &&
		"text" in value &&
		typeof value.text === "string" &&
		!CONTROL_TEXT.test(value.text) &&
		"tone" in value &&
		isTone(value.tone)
	);
}

export default function statusLineExtension(pi: ExtensionAPI): void {
	const segments = new Map<string, StatusLineSegment>();
	let context: ExtensionContext | undefined;
	let sessionId: string | undefined;
	let cancelSnapshot: (() => void) | undefined;

	function render(): void {
		if (!context) return;
		if (segments.size === 0) {
			context.ui.setWidget(WIDGET_KEY, undefined);
			return;
		}
		const ordered = [...segments.values()].sort(
			(a, b) => a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
		);
		const widgetContext = context;
		context.ui.setWidget(
			WIDGET_KEY,
			() => ({
				render: (width) => {
					const theme = widgetContext.ui.theme;
					const row = ordered.map((segment) => theme.fg(segment.tone, segment.text)).join(theme.fg("dim", " · "));
					return [width > 0 ? truncateToWidth(row, width) : ""];
				},
				invalidate() {},
			}),
			{ placement: "belowEditor" },
		);
	}

	function clear(): void {
		if (context) {
			cancelSnapshot?.();
			context.ui.setWidget(WIDGET_KEY, undefined);
		}
		cancelSnapshot = undefined;
		segments.clear();
		context = undefined;
		sessionId = undefined;
	}

	// Keep bus subscriptions alive: a shutdown may be followed by a new session
	// in the same extension runtime. Until then, there is no active recipient.
	pi.events.on(STATUS_LINE_SET, (value: unknown) => {
		if (!context || !isSegment(value) || value.sessionId !== sessionId) return;
		const previous = segments.get(value.id);
		if (previous && previous.order === value.order && previous.text === value.text && previous.tone === value.tone) {
			return;
		}
		// Own the accepted snapshot; contributors cannot mutate it after emitting.
		segments.set(value.id, {
			sessionId: value.sessionId,
			id: value.id,
			order: value.order,
			text: value.text,
			tone: value.tone,
		});
		render();
	});
	pi.events.on(STATUS_LINE_REMOVE, (value: unknown) => {
		if (!context || !isRemoval(value) || value.sessionId !== sessionId) return;
		if (segments.delete(value.id)) render();
	});

	function load(_event: unknown, ctx: ExtensionContext): void {
		if (ctx.agent?.kind === "sub") return;
		clear();
		if (!ctx.hasUI) return;
		context = ctx;
		sessionId = ctx.sessionManager.getSessionId();
		const requestedSession = sessionId;
		// Lifecycle handlers restore peers independently of extension load order.
		// Ask after those handlers, including peers which emitted before our reset.
		const timer = ctx.setTimeout(() => {
			if (context !== ctx || sessionId !== requestedSession) return;
			cancelSnapshot = undefined;
			pi.events.emit(STATUS_LINE_REQUEST, { sessionId: requestedSession } satisfies StatusLineRequest);
		}, 0);
		cancelSnapshot = () => ctx.clearTimer(timer);
	}

	pi.on("session_start", load);
	pi.on("session_switch", load);
	pi.on("session_branch", load);
	pi.on("session_tree", load);
	pi.on("session_compact", load);
	pi.on("session_shutdown", (_event, ctx) => {
		if (ctx.agent?.kind === "sub") return;
		clear();
	});
}

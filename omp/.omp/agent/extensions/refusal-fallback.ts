/**
 * refusal-fallback — retry cyber-safety blocks on the `security` model role.
 *
 * Fallback chains don't know why a request failed, so a cyber block on Opus or
 * Sol walks the ordinary chain, whose models block the same request again.
 * This extension recognises the two cyber blocks omp's own retry acts on:
 *
 *   Anthropic  stopDetails { type: "refusal", category: "cyber" }
 *   OpenAI     `cyber_policy` / "Trusted Access for Cyber" errors
 *
 * For that one retry it points the failing model's fallback chain at
 * `modelRoles.security` (GLM), so omp switches straight to it. Other refusal
 * categories, plain content filters, and ordinary failures keep the normal
 * chains. Nothing changes when the security role is unset or has no configured credential.
 *
 * The override lives only in the runtime settings layer, keyed by the exact
 * failing model. It is released once the retry picks its model, when the retry
 * ends, when the run ends without a retry (retries disabled, or omp can't
 * replay the turn safely), and on the next user input.
 */

import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { lookup } from "@oh-my-pi/pi-coding-agent/config/registry";

const TARGET_ROLE = "security";

/** Same pattern omp uses to classify OpenAI cyber-policy denials. */
const OPENAI_CYBER_POLICY = /\bcyber_policy\b|trusted access for cyber/i;

const THINKING_SUFFIX = /:(?:off|minimal|low|medium|high|xhigh|max|auto|inherit)$/;

interface FailedAssistant {
	provider: string;
	model: string;
	stopDetails?: { type?: unknown; category?: unknown } | null;
	errorMessage?: unknown;
}

function asFailedAssistant(message: unknown): FailedAssistant | undefined {
	if (!message || typeof message !== "object") return undefined;
	if (!("role" in message) || message.role !== "assistant") return undefined;
	if (!("stopReason" in message) || message.stopReason !== "error") return undefined;
	if (!("provider" in message) || typeof message.provider !== "string") return undefined;
	if (!("model" in message) || typeof message.model !== "string") return undefined;
	// Remaining fields are optional and type-checked where they are read.
	return message as FailedAssistant;
}

function isCyberBlock(message: FailedAssistant): boolean {
	const type = message.stopDetails?.type;
	if (type === "refusal" || type === "sensitive") return message.stopDetails?.category === "cyber";
	const error = message.errorMessage;
	return typeof error === "string" && OPENAI_CYBER_POLICY.test(error);
}

/** The security role's selector, if it names one model with a configured credential. */
function usableTarget(pi: ExtensionAPI, ctx: ExtensionContext): string | undefined {
	const roles = lookup("modelRoles")?.get(pi.pi.settings);
	const selector = roles && typeof roles === "object" ? Reflect.get(roles, TARGET_ROLE) : undefined;
	if (typeof selector !== "string" || selector.includes(",") || selector.startsWith("@")) {
		return undefined;
	}
	const slash = selector.indexOf("/");
	if (slash <= 0) return undefined;
	const provider = selector.slice(0, slash);
	const id = selector.slice(slash + 1).replace(THINKING_SUFFIX, "");
	const available = ctx.modelRegistry.getAvailable();
	const found = available.some((model) => model.provider === provider && model.id === id);
	return found ? selector : undefined;
}

export default function refusalFallbackExtension(pi: ExtensionAPI): void {
	const chains = lookup("retry.fallbackChains");
	if (!chains) throw new Error("refusal-fallback: omp has no retry.fallbackChains setting");
	let state: "idle" | "pending" | "retrying" = "idle";
	let warned = false;

	const release = () => {
		if (state === "idle") return;
		chains.clearOverride(pi.pi.settings);
		state = "idle";
	};

	// Must stay synchronous: omp picks the retry model without awaiting this
	// handler, so an override set after an `await` arrives too late.
	pi.on("message_end", (event, ctx) => {
		const message = asFailedAssistant(event.message);
		if (!message || !isCyberBlock(message)) return;
		const failing = `${message.provider}/${message.model}`;
		const target = usableTarget(pi, ctx);
		if (!target) {
			if (!warned && ctx.hasUI) {
				const why = `modelRoles.${TARGET_ROLE} is unset or has no credential`;
				ctx.ui.notify(`Cyber block on ${failing}: ${why}; using normal fallbacks.`, "warning");
			}
			warned = true;
			return;
		}
		if (target.replace(THINKING_SUFFIX, "") === failing) return;
		const current = chains.get(pi.pi.settings);
		const base = current && typeof current === "object" ? current : {};
		chains.override(pi.pi.settings, { ...base, [failing]: [target] });
		state = "pending";
	});

	pi.on("auto_retry_start", () => {
		if (state === "pending") state = "retrying";
	});
	pi.on("retry_fallback_applied", release);
	pi.on("auto_retry_end", release);
	pi.on("agent_end", () => {
		if (state === "pending") release();
	});
	pi.on("input", release);
}

import { complete, type Api, type Model, type UserMessage } from "@oh-my-pi/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

interface Question {
	question: string;
	context?: string;
}

const EXTRACTION_PROMPT = `Extract only questions in the assistant message that require an answer from the user. Return exactly one JSON object: {"questions":[{"question":"...","context":"optional short context"}]}. Preserve original order. Rewrite each question as one short, plain-language sentence a reader can answer at a glance: lead with the actual choice or ask, resolve pronouns so it stands alone, keep the options and any names that distinguish them, and drop background, justification, and qualifiers. Put only the background needed to answer into "context", as one short sentence, or omit it. Do not include rhetorical questions or questions already answered in the message. If none remain, return {"questions":[]}. Do not include commentary.`;

function textParts(content: unknown): string[] {
	if (!Array.isArray(content)) return [];
	return content.flatMap((part) =>
		part && typeof part === "object" && "type" in part && part.type === "text" && "text" in part && typeof part.text === "string"
			? [part.text]
			: [],
	);
}

function lastCompletedAssistant(ctx: ExtensionContext): { text?: string; skippedIncomplete: boolean } {
	const branch = ctx.sessionManager.getBranch();
	let skippedIncomplete = false;
	for (let i = branch.length - 1; i >= 0; i--) {
		const entry = branch[i]!;
		if (entry.type !== "message") continue;
		const message = entry.message;
		if (!("role" in message) || message.role !== "assistant") continue;
		const text = textParts(message.content).join("\n").trim();
		if (message.stopReason !== "stop") {
			skippedIncomplete = true;
			continue;
		}
		if (text) return { text, skippedIncomplete };
	}
	return { skippedIncomplete };
}

function fallbackQuestions(text: string): Question[] {
	const matches = text.replace(/\r\n?/g, "\n").match(/[^\n.!?]*\?+(?:[\"')\]]+)?/g) ?? [];
	const seen = new Set<string>();
	return matches
		.map((question) => question.replace(/^[\s>*-]+/, "").trim())
		.filter((question) => {
			const key = question.toLowerCase();
			if (!question || seen.has(key)) return false;
			seen.add(key);
			return true;
		})
		.map((question) => ({ question }));
}

function parseQuestions(response: string): Question[] | undefined {
	const candidates = [response.trim()];
	for (const match of response.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)) {
		if (match[1]?.trim()) candidates.push(match[1].trim());
	}
	const start = response.indexOf("{");
	const end = response.lastIndexOf("}");
	if (start >= 0 && end > start) candidates.push(response.slice(start, end + 1));
	for (const candidate of candidates) {
		try {
			const parsed: unknown = JSON.parse(candidate);
			if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as { questions?: unknown }).questions)) continue;
			const seen = new Set<string>();
			return (parsed as { questions: unknown[] }).questions.flatMap((item) => {
				if (!item || typeof item !== "object" || typeof (item as { question?: unknown }).question !== "string") return [];
				const question = (item as { question: string }).question.trim();
				const context = typeof (item as { context?: unknown }).context === "string" ? (item as { context: string }).context.trim() : "";
				const key = question.toLowerCase();
				if (!question || seen.has(key)) return [];
				seen.add(key);
				return [{ question, ...(context ? { context } : {}) }];
			});
		} catch {
			// Try the next representation before using the text fallback.
		}
	}
	return undefined;
}

async function extractQuestions(text: string, model: Model<Api>, ctx: ExtensionContext): Promise<Question[]> {
	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) throw new Error(`No authentication available for ${model.provider}/${model.id}: ${auth.error}`);
	const message: UserMessage = { role: "user", content: [{ type: "text", text }], timestamp: Date.now() };
	const response = await complete(
		model,
		{ systemPrompt: [EXTRACTION_PROMPT], messages: [message] },
		{ ...(auth.apiKey !== undefined ? { apiKey: auth.apiKey } : {}), ...(auth.headers ? { headers: auth.headers } : {}), reasoning: "low", maxTokens: 2048 },
	);
	const responseText = textParts(response.content).join("\n").trim();
	return parseQuestions(responseText) ?? fallbackQuestions(text);
}

function formatAnswers(questions: Question[], answers: string[]): string {
	const lines = ["Here are my answers to your questions:", ""];
	questions.forEach((question, i) => {
		lines.push(`Q: ${question.question}`);
		if (question.context) lines.push(`Context: ${question.context}`);
		lines.push(`A: ${answers[i]?.trim() || "(no answer)"}`);
		if (i < questions.length - 1) lines.push("");
	});
	return lines.join("\n");
}

async function answer(ctx: ExtensionContext, pi: ExtensionAPI): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify("/answer requires interactive mode", "error");
		return;
	}
	const model = ctx.models.resolve("@smol");
	if (!model) {
		ctx.ui.notify("Could not resolve the configured @smol model", "error");
		return;
	}
	const latest = lastCompletedAssistant(ctx);
	if (!latest.text) {
		ctx.ui.notify(latest.skippedIncomplete ? "No completed assistant message found" : "No assistant messages found", "error");
		return;
	}
	if (latest.skippedIncomplete) ctx.ui.notify("Using the last completed assistant message", "warning");

	let questions: Question[];
	try {
		questions = await extractQuestions(latest.text, model, ctx);
	} catch (error) {
		ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
		return;
	}
	if (questions.length === 0) {
		ctx.ui.notify("No questions found in the selected assistant message", "info");
		return;
	}

	const answers: string[] = [];
	for (const [index, question] of questions.entries()) {
		// Only the first title line is rendered in the border (single-row, truncated); later lines wrap in full.
		const prompt = [`Question ${index + 1}/${questions.length}`, question.question, ...(question.context ? ["", `Context: ${question.context}`] : [])].join("\n");
		const value = await ctx.ui.editor(prompt, "", undefined, { promptStyle: true });
		if (value === undefined) {
			ctx.ui.notify("Cancelled", "info");
			return;
		}
		answers.push(value);
	}

	const unanswered = answers.filter((value) => !value.trim()).length;
	const confirmation = unanswered
		? `Submit answers? ${unanswered} unanswered ${unanswered === 1 ? "item" : "items"} will be sent as '(no answer)'.`
		: "Submit all answers?";
	if (!(await ctx.ui.confirm("Confirm answers", confirmation))) return;

	const message = formatAnswers(questions, answers);
	if (ctx.isIdle()) {
		pi.sendUserMessage(message);
	} else {
		pi.sendUserMessage(message, { deliverAs: "followUp" });
		ctx.ui.notify("Answers queued as a follow-up message", "info");
	}
}

export default function answerExtension(pi: ExtensionAPI): void {
	pi.registerCommand("answer", {
		description: "Extract questions from the last completed assistant message and answer them",
		handler: async (_args, ctx) => answer(ctx, pi),
	});
	pi.registerShortcut("ctrl+.", {
		description: "Extract and answer questions",
		handler: async (ctx) => answer(ctx, pi),
	});
}

// Offline stand-in for the Anthropic Messages and OpenAI Responses streams that
// refusal-fallback reacts to. Prints its port on the first stdout line.
import { createServer } from "node:http";

const CYBER_POLICY =
	"This content was flagged for possible cybersecurity risk. If this seems wrong, try " +
	"rephrasing your request. To get authorized for security work, join the Trusted Access " +
	"for Cyber program: https://chatgpt.com/cyber";
const REFUSAL_CATEGORY = { cyber: "cyber", bio: "bio" };
const ANSWERS = { generic: "GENERIC", target: "TARGET", "target-slow": "TARGET" };
const requestsByModel = {};

function sse(res, events) {
	res.writeHead(200, { "content-type": "text/event-stream" });
	res.end(events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(""));
}

function anthropic(res, model) {
	const seen = (requestsByModel[model] = (requestsByModel[model] ?? 0) + 1);
	// `flaky-*`: a cyber block first, then ordinary rate limits. The wait is far
	// past retry.maxDelayMs, so omp falls back at once instead of backing off.
	if (model.startsWith("flaky-") && seen > 1) {
		res.writeHead(429, { "content-type": "application/json", "retry-after": "3600", "x-should-retry": "false" });
		res.end(JSON.stringify({ type: "error", error: { type: "rate_limit_error", message: "Rate limited" } }));
		return;
	}
	const category = model.startsWith("flaky-") ? "cyber" : REFUSAL_CATEGORY[model];
	const start = { type: "message_start", message: { id: `msg_${seen}`, type: "message", role: "assistant", model, content: [], stop_reason: null, usage: { input_tokens: 1, output_tokens: 0 } } };
	if (category) {
		const stopDetails = { type: "refusal", category, explanation: "fixture block" };
		sse(res, [
			["message_start", start],
			["message_delta", { type: "message_delta", delta: { stop_reason: "refusal", stop_details: stopDetails }, usage: { output_tokens: 0 } }],
			["message_stop", { type: "message_stop" }],
		]);
		return;
	}
	sse(res, [
		["message_start", start],
		["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
		["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: ANSWERS[model] ?? `UNKNOWN:${model}` } }],
		["content_block_stop", { type: "content_block_stop", index: 0 }],
		["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } }],
		["message_stop", { type: "message_stop" }],
	]);
}

function responses(res, model) {
	const id = `resp_${model}`;
	const error = model === "sol-cyber"
		? { code: "cyber_policy", message: CYBER_POLICY }
		: { code: "content_filter", message: "blocked by content filter" };
	sse(res, [
		["response.created", { type: "response.created", response: { id, object: "response", status: "in_progress", model, output: [] } }],
		["response.failed", { type: "response.failed", response: { id, object: "response", status: "failed", model, output: [], error } }],
	]);
}

const server = createServer((req, res) => {
	let raw = "";
	req.on("data", (chunk) => (raw += chunk));
	req.on("end", () => {
		const { model } = JSON.parse(raw || "{}");
		const respond = () => (req.url?.includes("/responses") ? responses(res, model) : anthropic(res, model));
		// Slow enough for the RPC case to abort while the fallback answer is in flight.
		setTimeout(respond, model === "target-slow" ? 3000 : 0);
	});
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));

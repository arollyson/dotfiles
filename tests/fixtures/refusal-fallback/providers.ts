// Registers the fixture server's models. The `security` target lives in the
// scratch models.yml instead, so its key resolves through a slow command.
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const baseUrl = `http://127.0.0.1:${process.env.REFUSAL_FIXTURE_PORT}`;

function models(api: "anthropic-messages" | "openai-responses", ids: string[]) {
	return ids.map((id) => ({
		id,
		name: id,
		api,
		reasoning: true,
		input: ["text" as const],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 200_000,
		maxTokens: 4096,
	}));
}

export default function (pi: ExtensionAPI) {
	pi.registerProvider("mock", {
		baseUrl,
		apiKey: "fixture-key",
		models: models("anthropic-messages", ["cyber", "bio", "generic", "flaky-disabled", "flaky-abort"]),
	});
	pi.registerProvider("mockoai", {
		baseUrl: `${baseUrl}/v1`,
		apiKey: "fixture-key",
		models: models("openai-responses", ["sol-cyber", "sol-filter"]),
	});
}

// Drives two prompts through one `omp --mode rpc` session and prints the final
// assistant text (or error) of each, one per line.
//
// Usage: node rpc.mjs <disabled|abort> <omp args...>
//   disabled: prompt 1 with auto-retry off, prompt 2 with it back on.
//   abort:    abort prompt 1 while its retry runs, then prompt 2 on the same model.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [scenario, ...ompArgs] = process.argv.slice(2);
const flakyModel = scenario === "abort" ? "flaky-abort" : "flaky-disabled";
const child = spawn("omp", ["--mode", "rpc", "--no-ui", ...ompArgs], { stdio: ["pipe", "pipe", "inherit"] });
const deadline = setTimeout(() => {
	console.error(`rpc fixture timed out (${scenario})`);
	child.kill();
	process.exit(2);
}, 60_000);

let lastResult = "none";
let waiter;
let onRetryStart;
createInterface({ input: child.stdout }).on("line", (line) => {
	let event;
	try {
		event = JSON.parse(line);
	} catch {
		return;
	}
	if (event.type === "message_end" && event.message?.role === "assistant") {
		const text = (event.message.content ?? []).filter((block) => block.type === "text").map((block) => block.text).join("");
		lastResult = event.message.stopReason === "error" ? `error:${event.message.errorMessage}` : text;
	}
	if (event.type === "auto_retry_start") onRetryStart?.();
	if (event.type === "response" && event.success === false) {
		console.error(`rpc command failed: ${line}`);
		process.exit(2);
	}
	if (event.type === "prompt_result") waiter?.(event.status);
});

const send = (command) => child.stdin.write(`${JSON.stringify(command)}\n`);
const prompt = (message) =>
	new Promise((resolve) => {
		lastResult = "none";
		waiter = (status) => resolve(`${status} ${lastResult}`);
		send({ type: "prompt", message });
	});

if (scenario === "disabled") {
	send({ type: "set_auto_retry", enabled: false });
	console.log(await prompt("one"));
	send({ type: "set_auto_retry", enabled: true });
} else {
	onRetryStart = () => setTimeout(() => send({ type: "abort" }), 300);
	console.log(await prompt("one"));
	onRetryStart = undefined;
	send({ type: "set_model", provider: "mock", modelId: flakyModel });
}
console.log(await prompt("two"));
clearTimeout(deadline);
child.kill();

---
name: no-sleep-wait
description: "Forbid the main agent from sleeping to wait; hand waits to background jobs, services, or subagents."
condition:
  - '(?:(?<![\w.-])|(?<=\\[nt]))sleep\s+(?:\d|\.\d|\$)'
  - '(?:(?<![\w.])|(?<=\\[nt]))(?:time|asyncio|trio|anyio)\.sleep\s*\('
  - '(?:(?<![\w.])|(?<=\\[nt]))Bun\.sleep(?:Sync)?\s*\('
  - 'new\s+Promise\s*(?:<[^>]*>\s*)?\(\s*(?:\(\s*\w+[^)]*\)|\w+)\s*=>\s*\{?\s*setTimeout\s*\('
  - '(?:(?<![\w.])|(?<=\\[nt]))await\s+(?:\w+\.)?setTimeout\s*\('
scope: "tool:bash, tool:eval"
agents: main
---

## Never sleep to wait in the main session

The main session must stay responsive. Do not wait by sleeping: no shell `sleep`, `time.sleep`, `asyncio.sleep`, `Bun.sleep`, or `setTimeout` promises in `bash` or `eval`, including inside poll loops (`until …; do sleep …; done`) and async jobs.

Hand the wait to something that runs in the background and delivers its result:

- Process, CI run, or job with a native blocking waiter (`gh run watch`, `gh pr checks --watch`, `docker wait`, `kubectl wait`, `wait <pid>`): run it with `bash` and `async: true`, keep working, and let the result arrive.
- Server or watcher readiness: start a named `bash` service with `ready.log` and/or `ready.port`.
- Anything that needs polling (deploys, external APIs, flaky endpoints): spawn a `task` subagent to watch it and report back; subagents may poll, the main session may not.
- Nothing else to do until a background job or agent finishes: call `wait`; never poll `proc://` or `agent://`.

This guidance interrupts matching tool calls but its matching is incomplete; it does not catch every waiting idiom.

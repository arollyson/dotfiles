# Picking the right models for workflows and subagents

Rankings, higher = better. Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.

| model         | cost | intelligence | taste |
|---------------|------|--------------|-------|
| gpt-5.6-sol   | 7    | 9            | 8     |
| sonnet-5      | 5    | 5            | 7     |
| opus-5        | 4    | 9            | 8     |
| fable-5       | 2    | 10           | 9     |

How to apply:
- These are defaults, not limits. You have standing permission to override them: if a cheaper model's output doesn't meet the bar, rerun or redo the work with a smarter model without asking. Judge the output, not the price tag. Escalating costs less than shipping mediocre work.
- Subagent spawns default to sonnet-5. Explicitly set the model on every spawn and state a one-line justification when choosing anything above sonnet-5 — inheriting the main-loop model is a decision, not a default. (This overrides any harness-level "omit the model param" guidance.)
- Operationalizing "mechanical": verbatim code moves, dead-code removal, dependency bumps, search/inventory sweeps, and clear-spec migrations are mechanical (gpt-5.6-sol, sonnet-5, or even Opus 5 if we need something slightly heavier weight) even inside a high-stakes project. "Parity-critical" or "intelligence-heavy" means the change itself requires judgment calls — not that the surrounding project matters. When claiming the escalation permission, name the judgment the task requires.
- Cost is a tie-breaker only; when axes conflict for anything that ships, intelligence > taste > cost.
- Bulk/mechanical work (clear-spec implementation, data analysis, migrations): gpt-5.6-sol - it's very cheap and token efficient.
- Anything user-facing (UI, copy, API design) needs taste ≥ 7.
- Reviews of plans/implementations: opus-5 or fable-5, optionally gpt-5.6-sol as an extra independent perspective. Cross model reviews are preferred in complex situations however i.e. Codex reviewing Claude or vice versa
- Never use Haiku.
- Mechanics: gpt-5.6-sol is handled natively via the `openai/codex-plugin-cc` plugin inside Claude Code, automatically adopting the user-level configurations from `~/.codex/config.toml`. Avoid writing custom bash scripts; instead, utilize the plugin's built-in tools and skills
  - `/codex:review` - Run non-destructive, read-only code quality assessments. Supports `--base <ref>` for branch analysis.
  - `/codex:adversarial-review` - Perform a skeptical design review to pressure-test tradeoffs, auth, and reliability. Append custom focus text at the end of the command to steer the focus.
  - `/codex:rescue` - Subcontract active debugging, multi-file refactoring, or implementation loops to Codex when a second pass is required.
  - `/codex:status` / `/codex:result` / `/codex:cancel` - Use these to check, fetch, or abort asynchronous jobs when using the `--background` flag on heavy tasks.
  - If a Codex background run dies silently (output frozen, no error), retry once with a tighter brief before falling back to a Claude-side agent — one dead run is not a reason to abandon the routing.
- Claude models (sonnet-5, opus-5, fable-5) run via the Agent/Workflow model parameter.

Using gpt-5.6 sol inside workflows and subagents:
- Subagents and automated workflows should call the plugin's native slash commands or its exposed `codex-cli-runtime` skills to delegate tasks directly, omitting the need for raw terminal wrappers.
- For closed-loop quality assurance, keep the review gate turned on via `/codex:setup --enable-review-gate`. This ensures a stop hook automatically challenges Claude's outputs using Codex before finalizing, preventing broken code or weak design assumptions from reaching the main session unvetted.

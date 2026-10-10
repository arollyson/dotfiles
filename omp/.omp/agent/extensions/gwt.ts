import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const GWT_PROMPT = `Run the requested work in a new, isolated Git worktree. Assume unrelated work may be in progress in the invoking checkout. Keep this initiative isolated.

## Requested work

{{work}}

When no task was supplied, or the only request is to create a worktree, this is a create-only request: create an otherwise empty worktree for the user to move into. Do not ask what to build or continue with implementation, commits, pushes, or a pull request in this mode. Report the absolute worktree path clearly so the user can use /move to enter it, then stop.

## 1. Resolve the repository and base

From the invoking checkout, inspect the repository root and origin URL. Fetch origin with prune, then resolve origin's default branch from its symbolic ref. If that ref is absent, set origin's default branch from the remote and retry. A base branch explicitly named in the request overrides the default. Derive the organization and repository from the origin URL, stripping a .git suffix. Stop if this is not a Git repository, has no origin, or the required remote refs cannot be resolved.

Use only the remote base ref (origin/<base>) as the starting point, never a potentially stale local branch.

## 2. Choose a branch and worktree path

For a create-only request, use the branch name worktree-<UTC timestamp> (YYYYMMDD-HHmmss). Otherwise, infer a concise descriptive kebab-case branch name from the request, following the repository's established branch prefix only if one is clearly in use. Tell the user the branch name before making changes. Use:

<PROJECT_HOME>/worktrees/<org>/<repo>/<branch>

Resolve PROJECT_HOME from the invoking environment; when unset, use ~/dev. Expand it to an absolute path before creating the worktree.

If the branch already exists locally or remotely, or that worktree path already exists, stop and ask the user how to proceed. Never reuse, overwrite, or silently suffix an existing branch or path.

## 3. Create and use the worktree

Create the parent directories as needed, then create a new worktree and branch from origin/<base>. Do not modify files in the invoking checkout: after worktree creation, perform every read, edit, build, and check inside the new worktree. Read and follow that repository's own instructions and normal verification workflow.

If worktree creation fails, stop and report the actual error; do not fall back to editing the invoking checkout.

## 4. Implement and verify

For a create-only request, creating the worktree is the complete task; do not modify files or run implementation checks. Otherwise, complete the requested work, including relevant tests and checks. Do not silently narrow scope. Before publishing, inspect the final changes and ensure only deliberate task files are included. Never use git add -A. Do not stage credentials, runtime state, caches, generated output, or unrelated changes.

## 5. Commit, push, and open the PR

Skip this entire section for a create-only request. Otherwise, stage only the deliberate changed paths, commit with an imperative one-line subject, and push the branch to origin. Open a ready-for-review PR against <base>; use a draft only if requested. The PR body should briefly state what changed, why, and how it was verified. If GitHub CLI is unavailable or unauthenticated, do not claim a PR was opened; provide the compare URL and explain the blocker. Do not merge the PR.

If a commit, push, or PR action fails, preserve the worktree and report the exact state reached. Do not claim completion for steps that did not succeed.

## 6. Report

For a create-only request, report the absolute worktree path, branch name, and this cleanup command; do not report a PR or verification. Otherwise, finish with the worktree path, branch name, PR URL (or the reason it could not be created and compare URL), verification performed, and this cleanup command:

git worktree remove <worktree-path>

Also note that git worktree prune removes stale worktree metadata. Report any remaining user decision or blocker.`;

export default function gwtExtension(pi: ExtensionAPI): void {
	pi.registerCommand("gwt", {
		description: "Create an isolated worktree, optionally with a task and pull request",
		handler: async (args, ctx) => {
			if (!ctx.isIdle()) {
				ctx.ui.notify("Wait for the current response to finish before starting /gwt.", "warning");
				return;
			}

			const work = args.trim();
			pi.sendUserMessage(GWT_PROMPT.replace("{{work}}", work || "(No additional work requested; create-only mode.)"));
		},
	});
}

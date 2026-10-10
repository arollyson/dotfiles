---
name: no-direct-main-push
description: "Require explicit repository-specific user permission before pushing directly to main or another default branch."
condition: ["\\bgit\\s+push\\s+(?:[\\w.-]+\\s+)?HEAD(?=\\s*(?:[\";]|&&|$))", "\\bgit\\s+push\\s+(?:[\\w.-]+\\s+)?(?:HEAD:)?(?:refs/heads/)?(?:main|master)(?=\\s|[\";]|$)"]
scope: "tool"
---

## Check publication authorization before pushing

This rule is advisory guidance for the assistant, not authorization enforcement. Its command matching is incomplete; repository permissions and branch protection remain the enforcement boundary.

Never push directly to `main`, `master`, or a repository’s default branch unless the user explicitly authorizes direct pushes for that repository. A request to make changes, generic “commit and push” instructions, or credentials capable of bypassing branch protection do not constitute that permission.

Before pushing `HEAD`, resolve the current branch and destination. Without explicit default-branch authorization, publish through a non-default branch and pull request. If branch creation is forbidden or unavailable, ask how to publish rather than pushing the default branch. Do not discover or disclose a branch-protection bypass only after the push.

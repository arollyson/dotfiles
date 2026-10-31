---
name: no-aws-admin
description: "Forbid running anything with admin-level AWS credentials: admin profiles, admin role ARNs."
condition:
  - '--profile(?:=|\s+)(?:\\?["''])?[\w.-]*admin[\w.-]*(?![\w.-])'
  - 'AWS_(?:DEFAULT_)?PROFILE(?:\\?["''\]])*\s*[=:]\s*(?:\\?["''])?[\w.-]*admin[\w.-]*(?![\w.-])'
  - '\bprofile(?:_name|Name)?(?:\\?["''\]])*\s*[=:]\s*\\?["''][\w.-]*admin[\w.-]*(?![\w.-])'
  - '(?:assume-role|--role-arn|role_arn|RoleArn)[^\n]{0,200}?:role/(?:[\w+=,.@-]+/)*[\w+=,.@-]*Admin'
scope: "tool:bash, tool:eval"
interruptMode: always
---

## Never use admin-level AWS credentials

Do not run anything with admin-level AWS permissions: no `*admin*` profiles and no assuming `*Admin*` roles. This includes read-only calls such as `sts get-caller-identity`, and it applies to `--profile`, `AWS_PROFILE`/`AWS_DEFAULT_PROFILE`, and SDK `profile`/`profile_name` options alike.

Use the least-privileged credentials that can do the job. If only admin credentials would work, stop and tell the user what needs running and why; do not run it yourself or look for another way to obtain admin access.

The patterns match the command text, not the credentials a process ends up with, so they miss indirection such as a profile name held in a shell variable. Treat that as a gap to avoid, not a way around this rule.

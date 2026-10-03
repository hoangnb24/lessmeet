# LessMeet agent instructions

Read the shared workspace protocol and `docs/WORKSPACE_PROTOCOL.md` before
project work. Preserve existing role authority, ownership and safety boundaries.

When diagnosing visible app behavior, checking native UI changes or accepting
user-facing app flows, you must use `$lessmeet-app-check` at
`.agents/skills/lessmeet-app-check/SKILL.md`. Read it directly if it is not listed
in the current skill catalog. Act proactively within the authorized scope.
Do not claim UI verification without runtime evidence; report blockers as
UNVERIFIED. Code-only and backend-only tasks do not activate this requirement.

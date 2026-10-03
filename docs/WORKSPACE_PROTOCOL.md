# LessMeet workspace

Follow the shared Codex Room protocol. Lead owns integration and acceptance.
Each writable scope has one owner; research peers are read-only. No Peer commits
or pushes. Lead records ownership, decisions and verification in `docs/STATUS.md`.
Keep this a small native Swift app, not a framework. Do not read unrelated keys,
recordings or credentials. Do not upload audio or incur API charges for tests.

Follow the required app-verification rule in the root `AGENTS.md` whenever
diagnosing visible behavior, checking native UI changes or accepting app flows.
Lead must require observed runtime evidence or an explicit UNVERIFIED blocker
before the affected handoff. Supervisor checks this distinction; Peers include it
in their responses. Do not substitute passing builds/tests for UI evidence.
Use `.agents/skills/lessmeet-app-check/SKILL.md` for the procedure.
One agent owns the live UI at a time; record that owner in `docs/STATUS.md`.
Read-only reviewers must not operate the shared UI. Existing Human-approved
limitations and all production/destructive-action boundaries remain in force.

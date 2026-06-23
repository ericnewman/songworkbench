# Repository instructions

Keep responses succinct and technical. Ask when an unresolved choice would
materially change behavior. Record durable project facts in `memory.md`.

## Workflow

1. Plan non-trivial work in `tasks/todo.md` with checkable acceptance criteria.
2. Confirm the plan before runtime implementation when requirements are unclear.
3. Keep the plan current and add a review section with verification evidence.
4. After a user correction, add a preventative rule to `tasks/lessons.md`.
5. Preserve existing work and make the smallest coherent change that solves the
   root problem.
6. Do not call work complete without tests, builds, logs, or representative UI
   evidence appropriate to the change.

Prefer deep, testable service modules behind narrow interfaces. Long-running
audio/ML work must support progress, cancellation, persistence, and recovery.
Do not reduce corpus coverage to make performance or quality checks pass.

## Agent skills

### Issue tracker

Issues and PRDs are local Markdown files under `.scratch/`. See
`docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical local status vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

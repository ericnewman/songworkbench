# Issue tracker: Local Markdown

Issues and PRDs for this repository live as Markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`.
- The PRD is `.scratch/<feature-slug>/PRD.md`.
- Implementation issues are
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
- Triage state is recorded as a `Status:` line near the top of each issue.
- Comments and decision history append under a `## Comments` heading.

When a skill says to publish to the issue tracker, create or update the relevant
file under `.scratch/`. When a remote tracker is adopted, update this document
and the `Agent skills` block in `AGENTS.md` together.

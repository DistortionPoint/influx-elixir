---
name: design-doc-workflow
description: Author, review, and update design documents and fidelity sweep reports in docs/design/ following InfluxElixir's Document-Driven Development (DDD) workflow. Use when planning significant changes, conducting fidelity reviews, or updating design doc status.
---

# Document-Driven Development (DDD) & Fidelity Review Skill

All significant changes, architecture additions, and `Client.Local` fidelity reviews in `influx_elixir` follow the Document-Driven Development workflow in [`docs/design/`](file:///Volumes/Dev/development/influx-elixir/docs/design/README.md).

## 1. Design Document Conventions

- **Location**: `docs/design/YYYY-MM-DD_<descriptive-kebab-slug>.md`
  - Check today's date and existing files in `docs/design/` before naming.
- **Template**: Always structure new design documents using [`docs/design/templates/design-document-template.md`](file:///Volumes/Dev/development/influx-elixir/docs/design/templates/design-document-template.md).
- **Index**: Every new design document must be added to the table in [`docs/design/README.md`](file:///Volumes/Dev/development/influx-elixir/docs/design/README.md), and its status updated there as it progresses.
- **Standing Rules Boundary**: Never link individual design documents or single work items from `CLAUDE.md`, `AGENTS.md`, or `.agents/rules/*.md`.

## 2. Lifecycle Phases

1. **Research & Verification**:
   - Before starting a sweep, run `git fetch` and `git log HEAD..origin/main` to check if CI published a `Release v...` commit and reconcile `(unreleased)` markers in `CHANGELOG.md`.
   - Read the target source modules (`lib/influx_elixir/...`) and contract suites (`test/support/...`).
   - Verify real InfluxDB behavior against running endpoints via `curl` using the `influx-verification` skill (never run `docker` commands directly).
2. **Design Document (`DRAFT`)**:
   - Document specific findings with exact file paths, line numbers, verified engine behavior (`curl` reproducers and outputs), root causes, and concrete fix plans.
   - Include an implementation checklist with verifiable acceptance criteria.
3. **Implementation & Contract Pinning**:
   - Fix every bug found during the pass immediately in the same pass — never defer findings.
   - Implement fixes in `lib/`.
   - Add or update contract test cases in `test/support/` and unit tests in `test/influx_elixir/`.
   - Update [`usage-rules.md`](file:///Volumes/Dev/development/influx-elixir/usage-rules.md), [`usage-rules/`](file:///Volumes/Dev/development/influx-elixir/usage-rules/testing.md), `README.md`, and `CHANGELOG.md` if any documented `Client.Local` limitation or capability changed.
   - Update test count floors in [`test/influx_elixir/contract_tags_test.exs`](file:///Volumes/Dev/development/influx-elixir/test/influx_elixir/contract_tags_test.exs) if contract test counts grew significantly.
4. **Completion (`IMPLEMENTED` / `COMPLETE`)**:
   - Check off completed items in the design doc.
   - Update the document's **Status** header and its row in [`docs/design/README.md`](file:///Volumes/Dev/development/influx-elixir/docs/design/README.md).
   - Run the full quality and test suite (`code-quality-sweep` skill), one test run at a time.

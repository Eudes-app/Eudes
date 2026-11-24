---
name: eudes-development-cycle
description: Report verified Eudes development, optional iPhone validation, and final delivery stages when working on Eudes. GitHub Actions owns workflow execution and Kanban transitions.
---

# Eudes development cycle

Use this skill to report progress during Eudes development. It provides development conventions and a display format, not an automation engine. The repository's [delivery workflow documentation](https://github.com/Eudes-app/Eudes/blob/main/docs/DELIVERY_WORKFLOWS.md), `.github/workflows/` and their scripts define execution and transition rules. Read the relevant current sources when interpreting a result.

## Development conventions

Identify the relevant checkout and preserve unrelated work. Use an issue with acceptance criteria, a dedicated issue-linked branch and a linked pull request; avoid duplicates. Present a new issue's title and content for agreement before creation unless that agreement is already given. Link the PR with a GitHub closing reference such as `Closes #123`. Review the changes and make the necessary corrections, or state that Corrections is not needed.

The repository is public: never write a real name, e-mail, postal address, phone number, device identifier, Apple Team ID, private network address, token or key in code, docs, commits, issues, pull requests, review comments, screenshots or artifacts. See [AGENTS.md](../../../AGENTS.md#never-publish-personal-data) for the neutral labels and example values to use instead.

## Separation from GitHub Actions

GitHub Actions owns automatic tests, delivery versioning, compilation, signing, merge, validation invalidation and Kanban transitions. Installation on a device is manual and no workflow reaches an iPhone. This skill does not add/remove labels, dispatch/retry workflows, run a duplicate local delivery pipeline, add/move project cards or repair their statuses automatically. Do not perform those actions merely to advance the displayed workflow.

An explicit user request to operate GitHub is a separate authorized task, handled through the repository's existing workflows and their documentation. Do not duplicate their orchestration in this skill. Targeted local checks for development or diagnosis remain possible; do not repeat the complete XCTest suite locally as a routine CI prerequisite.

Review approval and final validation are human decisions, associated with the relevant PR and commit. Report them from explicit user approval or verified GitHub evidence. A successful check is not approval. The final approval authorizes Actions to compile and then merge; it is not a second automatic approval supplied by this skill. The iPhone path and final delivery can share the same manual validation; do not invent a second approval requirement.

## Read and interpret progress

Verify the issue, current PR SHA, Actions runs and actual project values before reporting success. A column position alone is not proof that its operation succeeded. Ignore evidence for an obsolete revision. Distinguish queued, running, skipped, failed and successful jobs; a skipped job is not a completed operation.

The **Développement** view uses `Workflow développement`. **Validation iPhone** uses the field of the same name. `Livraison finale` records manual validation, compilation and fusion. **Historique livraison** and the legacy `Status` preserve older tracking. Read and explain discrepancies; this skill does not move or delete their cards.

Installation on a device is manual (`tools/build-device.sh`, then `tools/install-iphone.py`); it produces no CI evidence, and final validation is satisfied by a human approval of the pull request at the exact commit. Neither an unsigned Release build nor a merge proves installation, and installation itself does not prove launch, gestures, Siri, microphone, VoiceOver or acceptance of a feature. If `iphone-requis` is present, report iPhone validation as required. Otherwise, state when the iPhone path was not requested or is unnecessary; do not present it as an automatic blocker.

When code changes or a defect is reported, reflect the current Corrections/review/validation state and evidence. Changing the displayed circles does not change GitHub labels, approvals or project fields. Leave enforcement of invalidations and transitions to Actions.

## Display format

When reporting the state of an issue or PR in chat, identify/link it and show one compact Markdown line in this exact shape:

🟢 Issue #N ──► 🟢 Branche + PR ──► 🟢 CI n/n ──► 🟢 Review ──► 🔘 Merge main ──► 🔘 Build IPA

Each stage carries a short annotation underneath (branch name, checks passed, label name, merge mode, workflow name). Legend: 🟢 completed, 🔘 pending, 🔵 in progress, 🔴 blocked/failed. Base statuses on verified evidence for the relevant revision; do not invent completed actions. Show regression or invalidated evidence in the displayed statuses, without triggering corrective automation from this skill.

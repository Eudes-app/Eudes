# Instructions for assistants working on Eudes

Before modifying this repository or reporting its delivery status, read and apply
[the Eudes workflow reporting skill](.agents/skills/eudes-development-cycle/SKILL.md).
If your tool does not discover skills automatically, open that file explicitly.

The skill in the current checkout is the canonical version for this revision.
Use it instead of an independently maintained personal copy. It defines the
three progress displays and the evidence needed to mark stages complete.

GitHub Actions owns execution and Kanban transitions. Reading this skill does
not authorize labels, workflow dispatches, installations, merges or project
changes. For execution details, consult [the delivery workflow documentation](docs/DELIVERY_WORKFLOWS.md)
and the current `.github/workflows/` files.

## Never publish personal data

This repository is public. Everything written here is readable by anyone and
stays readable after deletion. An assistant must never write a real person's
name, first name, e-mail address, postal address, phone number, Apple ID,
Apple Team ID, device identifier (UDID, serial), real private network address,
token or API key — not in code, documentation, comments, commit messages,
branch names, issue titles or bodies, pull request titles or bodies, review
comments, discussions, labels, screenshots or build artifacts.

- Refer to people and devices by neutral labels: "the maintainer", "the test
  iPhone", "a private LAN address". Use documented example values only, such as
  `192.168.1.20`.
- Identifiers read by automation come from GitHub Actions secrets or variables
  (`secrets.*`, `vars.APPLE_TEAM_ID`), never from a literal in a tracked file.
- Commit identity matters as much as content: use the GitHub noreply address,
  never a real mailbox. Author metadata is part of the published history.
- A screenshot is published content. Look at it before attaching it and remove
  anything identifying: names in the status bar, conversation content, server
  addresses, notches of account screens.
- If a real value has already been posted, rewrite the text so the value
  disappears and say so; apologising without replacing it leaves the leak in
  place. Deleting a comment is not enough when the value reached a commit.
- When a report needs to mention a defect involving such data, describe it
  ("the UDID of the test iPhone") instead of quoting it. Quoting it in a bug
  report reopens the leak the report is supposed to close.

## Language

User-facing text is French. `README.md` and `docs/` are French. This file and
the skill are English so that assistants read them consistently. Keep commit
messages short and factual, in French.

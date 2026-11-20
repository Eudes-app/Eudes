#!/bin/bash
# Ensure this run still tests the exact PR revision validated by the user.
set -euo pipefail
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${PR_NUMBER:?}" "${REVIEWED_SHA:?}"
gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '
  if .state == "open" and .draft == false and .head.sha == env.REVIEWED_SHA
     and any(.labels[]; .name == "review-validée")
  then "Review label and commit verified"
  else error("Review invalidated: PR is closed, draft, changed, or missing the validation label") end'

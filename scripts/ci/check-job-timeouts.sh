#!/bin/bash
# Fails if any GitHub Actions job lacks `timeout-minutes` or sets it
# above MAX_MINUTES. A hung job otherwise burns runner time until
# GitHub's 6-hour default kills it.
set -uo pipefail

MAX_MINUTES="${MAX_MINUTES:-10}"
status=0

for workflow in .github/workflows/*.yml; do
    # Jobs are the 2-space-indented keys under the top-level `jobs:`;
    # their `timeout-minutes` sits at 4 spaces.
    report="$(awk -v max="$MAX_MINUTES" '
        /^[^ #]/ { in_jobs = ($0 ~ /^jobs:/) ; next }
        !in_jobs { next }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (job != "" && !limit) print job ": no timeout-minutes"
            job = $1; sub(/:$/, "", job); limit = 0; next
        }
        /^    timeout-minutes:/ {
            limit = 1
            if ($2 + 0 > max) print job ": timeout-minutes " $2 " > " max
        }
        END { if (job != "" && !limit) print job ": no timeout-minutes" }
    ' "$workflow")"
    if [[ -n "$report" ]]; then
        while IFS= read -r line; do
            echo "::error file=$workflow::$line"
        done <<<"$report"
        status=1
    fi
done

[[ $status -eq 0 ]] && echo "Every job is capped at ${MAX_MINUTES} minutes or less."
exit $status

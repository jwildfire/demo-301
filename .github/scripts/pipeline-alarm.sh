#!/usr/bin/env bash
#
# pipeline-alarm.sh — turn a pipeline outcome into a signal somebody receives.
#
# `Run Pipeline` failed on 2026-08-03, 08-10 and 08-17 and told nobody. A red
# check on a scheduled run is not a signal: nobody opens the Actions tab of a
# demo repository on a Monday morning. This raises a GitHub issue instead —
# assigned, so it emails — and closes it again when the pipeline recovers.
#
# One issue per ref, deduplicated by a marker in the body, so a run of red
# Mondays adds comments to one thread instead of filing a new issue each week.
#
# Modes (MODE):
#   failure   the run failed          -> open, or comment on, the alarm issue
#   success   the run passed          -> comment and close any open alarm issue
#   stale     no run in the window    -> open, or comment on, the alarm issue
#
# The script never exits non-zero for lack of something to do; it exits
# non-zero only when it could not deliver the signal it was asked to deliver.
# That distinction matters — an alarm that fails quietly is the bug it exists
# to fix.
#
# Environment:
#   GH_TOKEN     token with issues:write and actions:read
#   REPO         owner/name
#   MODE         failure | success | stale
#   ALARM_REF    the ref the alarm is about (e.g. refs/heads/main)
#   RUN_ID       the run this is reporting on          (failure/success)
#   RUN_URL      its html_url                          (failure/success)
#   STALE_NOTE   one line saying what went unnoticed   (stale)
#   ASSIGNEE     who should receive it (default jwildfire)
#   ALARM_LABEL  label used for deduplication (default pipeline-alarm)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${MODE:?MODE is required}"
: "${ALARM_REF:?ALARM_REF is required}"
ASSIGNEE="${ASSIGNEE:-jwildfire}"
ALARM_LABEL="${ALARM_LABEL:-pipeline-alarm}"
MARKER="<!-- pipeline-alarm ref=${ALARM_REF} -->"
SHORT_REF="${ALARM_REF#refs/heads/}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

# --- the label the dedup key hangs off --------------------------------------
# Created before any list, because `gh issue list --label` errors outright on a
# label the repository does not have.
ensure_label() {
  if gh label list -R "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null | grep -qx "$ALARM_LABEL"; then
    return 0
  fi
  gh label create "$ALARM_LABEL" -R "$REPO" \
    --color B60205 \
    --description 'The scheduled pipeline is failing, or has stopped running' \
    >/dev/null 2>&1 || note "note: could not create the $ALARM_LABEL label"
}

# --- the open alarm issue for this ref, if there is one ---------------------
find_open_alarm() {
  gh issue list -R "$REPO" --label "$ALARM_LABEL" --state open --limit 50 \
    --json number,body \
    --jq "[.[] | select(.body | contains(\"$MARKER\"))] | .[0].number // empty" \
    2>/dev/null || true
}

# --- what actually broke, read from the run rather than guessed -------------
failure_detail() {
  local run_id="${1:-}" step job_id
  [ -n "$run_id" ] || return 0
  gh api "repos/$REPO/actions/runs/$run_id/jobs" > "$WORK/jobs.json" 2>/dev/null || return 0

  step="$(jq -r '[.jobs // [] | .[] | .steps // [] | .[] | select(.conclusion == "failure") | .name] | .[0] // empty' "$WORK/jobs.json" 2>/dev/null || true)"
  job_id="$(jq -r '[.jobs // [] | .[] | select(.conclusion == "failure") | .id] | .[0] // empty' "$WORK/jobs.json" 2>/dev/null || true)"

  if [ -n "$step" ]; then
    say "**Failing step:** \`$step\`"
    say ""
  fi
  [ -n "$job_id" ] || return 0

  # The archived log is not always there the instant the job ends — the first
  # alarm this script ever raised (issue #5) carried the failing step's name and
  # no log, because the fetch came back empty seconds after the job finished.
  # Retry, and if it still cannot be read, say so rather than leaving a silent
  # gap: an alarm that drops the error without mentioning it is a smaller
  # version of the problem this file exists to fix.
  local attempt
  for attempt in 1 2 3 4; do
    if gh api "repos/$REPO/actions/jobs/$job_id/logs" > "$WORK/job.log" 2>/dev/null \
       && [ -s "$WORK/job.log" ]; then
      break
    fi
    : > "$WORK/job.log"
    # Not `[ ... ] && sleep`: as the last command in the loop body a false test
    # returns non-zero, and `set -e` would take the function down with it.
    if [ "$attempt" -lt 4 ]; then sleep $(( attempt * 5 )); fi
  done

  if [ ! -s "$WORK/job.log" ]; then
    say "_The failing job's log could not be read back from the API (job \`$job_id\`) — open the run to see it._"
    say ""
    return 0
  fi

  # Strip the ISO timestamp Actions prefixes every line with, drop blanks, and
  # keep the tail — where the error is.
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$WORK/job.log" \
    | grep -v '^[[:space:]]*$' | tail -n 30 > "$WORK/tail.log" || true
  [ -s "$WORK/tail.log" ] || return 0

  say "<details><summary>Last 30 lines of the failing job</summary>"
  say ""
  say '```'
  cat "$WORK/tail.log"
  say '```'
  say ""
  say "</details>"
}

body_failure() {
  say "$MARKER"
  say ""
  say "\`Run Pipeline\` failed on \`$SHORT_REF\`. Nothing was published."
  say ""
  say "- Run: ${RUN_URL:-unknown}"
  say "- Ref: \`$ALARM_REF\`"
  say ""
  failure_detail "${RUN_ID:-}"
  say ""
  say "This issue is the pipeline's alarm for \`$SHORT_REF\`. Later failures comment here rather than filing again, and a green run closes it automatically."
  say ""
  say "---"
  say ""
  say "Raised by the \`Run Pipeline\` alarm (\`.github/scripts/pipeline-alarm.sh\`)."
}

body_stale() {
  say "$MARKER"
  say ""
  say "\`Run Pipeline\` has stopped running on \`$SHORT_REF\`."
  say ""
  say "${STALE_NOTE:-No completed run was found in the expected window.}"
  say ""
  say "A weekly job that stops firing is as invisible as one that fails quietly. GitHub disables scheduled workflows in repositories with no activity for 60 days, and a workflow file that will not parse produces no run at all — and so no red check for anyone to notice."
  say ""
  say "---"
  say ""
  say "Raised by the pipeline watchdog (\`.github/scripts/pipeline-alarm.sh\`)."
}

comment_failure() {
  say "\`Run Pipeline\` failed again on \`$SHORT_REF\`."
  say ""
  say "- Run: ${RUN_URL:-unknown}"
  say ""
  failure_detail "${RUN_ID:-}"
}

comment_stale() {
  say "\`Run Pipeline\` is still not running on \`$SHORT_REF\`."
  say ""
  say "${STALE_NOTE:-No completed run was found in the expected window.}"
}

emit_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
}

ensure_label

case "$MODE" in
  failure|stale)
    existing="$(find_open_alarm)"
    if [ -n "$existing" ]; then
      if [ "$MODE" = failure ]; then comment_failure > "$WORK/comment.md"
      else comment_stale > "$WORK/comment.md"; fi
      gh issue comment "$existing" -R "$REPO" --body-file "$WORK/comment.md" >/dev/null
      issue="$existing"
    else
      if [ "$MODE" = failure ]; then
        title="🚨 Run Pipeline is failing on $SHORT_REF"
        body_failure > "$WORK/body.md"
      else
        title="🚨 Run Pipeline has stopped running on $SHORT_REF"
        body_stale > "$WORK/body.md"
      fi
      # Assignment is what makes this arrive as email rather than as a row in a
      # tab. If the assignee cannot be set, still file the issue — but say so,
      # because a quiet alarm is the defect this exists to fix.
      if ! url="$(gh issue create -R "$REPO" --title "$title" --body-file "$WORK/body.md" \
                    --label "$ALARM_LABEL" --assignee "$ASSIGNEE" 2>"$WORK/err")"; then
        note "::warning::could not assign $ASSIGNEE ($(tr '\n' ' ' < "$WORK/err")); filing unassigned"
        url="$(gh issue create -R "$REPO" --title "$title" --body-file "$WORK/body.md" \
                 --label "$ALARM_LABEL")"
      fi
      issue="${url##*/}"
    fi
    emit_output "alarm_issue=$issue"
    say "::error::Run Pipeline is not healthy on $SHORT_REF — see $REPO issue #$issue"
    say "Alarm delivered: https://github.com/$REPO/issues/$issue"
    ;;

  success)
    existing="$(find_open_alarm)"
    if [ -z "$existing" ]; then
      say "Pipeline green on $SHORT_REF; no open alarm to close."
      exit 0
    fi
    {
      say "\`Run Pipeline\` is green again on \`$SHORT_REF\`."
      say ""
      say "- Run: ${RUN_URL:-unknown}"
      say ""
      say "Closing this alarm. It reopens by itself the next time a run fails."
    } > "$WORK/comment.md"
    gh issue comment "$existing" -R "$REPO" --body-file "$WORK/comment.md" >/dev/null
    gh issue close "$existing" -R "$REPO" --reason completed
    emit_output "alarm_issue=$existing"
    say "Closed alarm issue #$existing."
    ;;

  *)
    note "unknown MODE: $MODE"
    exit 2
    ;;
esac

#!/usr/bin/env bash
# agenda.sh — what DevLead plans to work on today in this repo, and the
# human's adjustments to it.
#
# Usage:
#   agenda.sh publish        store today's queue (stdin: `envelope.sh plan` output)
#   agenda.sh show           the effective agenda: adjusted order, then what is skipped
#   agenda.sh first <N>      work on issue #N before everything else
#   agenda.sh skip <N>       do not work on issue #N today
#   agenda.sh reset          drop every adjustment
#   agenda.sh apply          stdin: issue numbers, one per line (a live queue)
#                            stdout: that queue with the adjustments applied
#
# The loop this supports: the morning sweep publishes the queue the envelope
# policy produces and tells the human; the run that executes later derives
# its queue again (state is never cached, A2) and passes it through `apply`.
# Nothing waits for an approval: with no adjustment `apply` is the identity.
#
# What an adjustment is NOT: authority. `first` and `skip` can only reorder
# or drop issues of a queue the envelope policy already produced. `apply`
# never emits a number that was not on its stdin, so nothing stored here can
# put an issue in front of an unattended run (A1, A3). A test pins that.
# open-pr.sh, merge.sh, envelope.sh, the gates and the forbidden zones never
# read this script or its files.
#
# Adjustments belong to one published agenda: publishing the agenda of a new
# day discards them. Until then they stay in force, also past midnight, so a
# run that starts late still honours what the human asked for.
#
# State (local only, nothing leaves the machine):
#   ~/.devlead/agenda/<repo-key>/agenda.tsv
#       <date> TAB <issue number> TAB <title>          one line per issue, queue order
#   ~/.devlead/agenda/<repo-key>/adjust.tsv
#       <utc timestamp> TAB <first|skip> TAB <issue number>
#   ~/.devlead/agenda/<repo-key>/date    the day of the published agenda
#   ~/.devlead/agenda/<repo-key>/repo    the repository path the key stands for
#
# Exit codes: 0 ok · 1 misuse, input that is not a plan, an issue that is not
# on the agenda, or a local write that failed.
#
# Environment:
#   DEVLEAD_AGENDA_DIR    state root (default: ~/.devlead/agenda)
#   DEVLEAD_AGENDA_DATE   the day `publish` stamps (default: today, local
#                         time). Tests set it to cross a day boundary.

# shellcheck disable=SC2016 # awk programs are single-quoted on purpose
set -uo pipefail

AGENDA_ROOT="${DEVLEAD_AGENDA_DIR:-$HOME/.devlead/agenda}"
TITLE_MAX_CHARS=200

_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$_root" ]]; then
  echo "STATUS: not-a-repo"
  exit 1
fi
# Same key sweep.sh uses for outcomes: a hash, so no two paths can collide.
_key="$(printf '%s' "$_root" | sha256sum | cut -c1-20)"
STATE_DIR="$AGENDA_ROOT/$_key"
AGENDA="$STATE_DIR/agenda.tsv"
ADJUST="$STATE_DIR/adjust.tsv"
DATE_FILE="$STATE_DIR/date"

_ensure_state() {
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "agenda: cannot create $STATE_DIR" >&2
    return 1
  fi
  [[ -f "$STATE_DIR/repo" ]] || printf '%s\n' "$_root" > "$STATE_DIR/repo" 2>/dev/null
  return 0
}

# _replace <target> — stdin becomes the new content of <target>, atomically.
_replace() {
  local target="$1" tmp
  tmp="$(mktemp "$STATE_DIR/.tmp-XXXXXX" 2>/dev/null)" || return 1
  if cat > "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# _issue_number <arg> — echoes the bare number of `12` or `#12`; fails otherwise.
_issue_number() {
  local n="${1#\#}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$((10#$n))"
}

# _adjusted — stdin: issue numbers in queue order. stdout: `Q <n>` for every
# issue that stays, in effective order, then `S <n>` for every skipped one.
# The latest adjustment of an issue wins; the latest `first` goes to the top.
# Only numbers read from stdin are ever printed.
_adjusted() {
  ADJUST_FILE="$ADJUST" awk '
    BEGIN {
      file = ENVIRON["ADJUST_FILE"]
      while ((getline line < file) > 0) {
        split(line, f, "\t")
        # Anything that is not a well-formed adjustment is ignored, so a
        # damaged line can neither add an issue nor make one disappear.
        if (f[3] ~ /^[0-9]+$/ && (f[2] == "first" || f[2] == "skip")) {
          verb[f[3]] = f[2]; seq[f[3]] = ++lines
        }
      }
    }
    $1 ~ /^[0-9]+$/ && !($1 in seen) { seen[$1] = 1; queue[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) if (verb[queue[i]] == "first") top[++t] = queue[i]
      for (i = 2; i <= t; i++) {
        cur = top[i]
        for (j = i - 1; j >= 1 && seq[top[j]] < seq[cur]; j--) top[j + 1] = top[j]
        top[j + 1] = cur
      }
      for (i = 1; i <= t; i++) print "Q " top[i]
      for (i = 1; i <= n; i++) if (verb[queue[i]] == "") print "Q " queue[i]
      for (i = 1; i <= n; i++) if (verb[queue[i]] == "skip") print "S " queue[i]
    }
  '
}

_publish() {
  local plan today tmp_rows count
  plan="$(cat)"
  if ! grep -q '^=== DEVLEAD ENVELOPE PLAN' <<<"$plan" \
     || ! grep -q '^--- INCLUDED (queue order) ---' <<<"$plan"; then
    echo "STATUS: no-plan"
    echo "agenda: stdin is not an \`envelope.sh plan\` result — nothing changed" >&2
    return 1
  fi
  _ensure_state || return 1
  today="${DEVLEAD_AGENDA_DATE:-$(date +%F)}"

  # Queue lines look like `1. #12  Title` (envelope.sh quotes a title holding
  # a colon). Only the INCLUDED section is read.
  tmp_rows="$(DAY="$today" MAX="$TITLE_MAX_CHARS" awk '
    /^--- INCLUDED \(queue order\) ---/ { on = 1; next }
    /^--- / || /^=== END PLAN/ { on = 0 }
    on && match($0, /^[0-9]+\. #[0-9]+  /) {
      head = substr($0, 1, RLENGTH); title = substr($0, RLENGTH + 1)
      sub(/^[0-9]+\. #/, "", head); sub(/ +$/, "", head)
      if (title ~ /^".*"$/) title = substr(title, 2, length(title) - 2)
      gsub(/[\t\r]/, " ", title)
      print ENVIRON["DAY"] "\t" head "\t" substr(title, 1, ENVIRON["MAX"] + 0)
    }' <<<"$plan")"

  if ! { [[ -z "$tmp_rows" ]] || printf '%s\n' "$tmp_rows"; } | _replace "$AGENDA"; then
    echo "agenda: could not write $AGENDA" >&2
    return 1
  fi
  # Adjustments belong to the agenda they were made against.
  if [[ "$(cat "$DATE_FILE" 2>/dev/null)" != "$today" ]]; then
    rm -f "$ADJUST"
    if ! printf '%s\n' "$today" | _replace "$DATE_FILE"; then
      echo "agenda: could not write $DATE_FILE" >&2
      return 1
    fi
  fi
  count="$(grep -c . "$AGENDA" || true)"
  if [[ "$count" -eq 0 ]]; then echo "STATUS: empty"; else echo "STATUS: published"; fi
  echo "DATE: $today"
  echo "COUNT: $count"
}

_show() {
  if [[ ! -f "$AGENDA" ]]; then
    echo "STATUS: none"
    return 0
  fi
  if [[ ! -s "$AGENDA" ]]; then
    echo "STATUS: empty"
    echo "DATE: $(cat "$DATE_FILE" 2>/dev/null)"
    return 0
  fi
  local kind num pos=0
  echo "STATUS: ok"
  echo "DATE: $(cat "$DATE_FILE" 2>/dev/null)"
  while read -r kind num; do
    if [[ "$kind" == "Q" ]]; then
      pos=$((pos + 1))
      printf '%d. #%s  %s\n' "$pos" "$num" "$(_title_of "$num")"
    else
      printf 'SKIPPED: #%s  %s\n' "$num" "$(_title_of "$num")"
    fi
  done < <(cut -f2 "$AGENDA" | _adjusted)
}

_title_of() {
  NUM="$1" awk -F'\t' '$2 == ENVIRON["NUM"] { print $3; exit }' "$AGENDA"
}

# _adjust <first|skip> <N> — record one adjustment.
_adjust() {
  local verb="$1" num
  if ! num="$(_issue_number "${2:-}")"; then
    echo "agenda: usage: agenda.sh $verb <issue number>" >&2
    return 1
  fi
  # Refusing an issue the agenda does not hold keeps a typo from sitting in
  # the file until some later queue happens to contain that number.
  if [[ ! -f "$AGENDA" ]] || ! cut -f2 "$AGENDA" | grep -qx "$num"; then
    echo "STATUS: not-on-agenda"
    echo "agenda: #$num is not on the published agenda — nothing changed" >&2
    return 1
  fi
  _ensure_state || return 1
  if ! printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$verb" "$num" >> "$ADJUST" 2>/dev/null; then
    echo "agenda: could not write $ADJUST" >&2
    return 1
  fi
  echo "STATUS: recorded"
  echo "ISSUE: $num"
  echo "ADJUSTMENT: $verb"
}

_reset() {
  if ! rm -f "$ADJUST" 2>/dev/null; then
    echo "agenda: could not remove $ADJUST" >&2
    return 1
  fi
  echo "STATUS: reset"
}

_apply() {
  local input out queue skipped
  input="$(cat)"
  out="$(_adjusted <<<"$input")"
  queue="$(sed -n 's/^Q //p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
  skipped="$(sed -n 's/^S //p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
  # `unchanged` means the caller's queue came back exactly as it went in.
  if [[ -z "$skipped" && "$queue" == "$(ADJUST=/dev/null _adjusted <<<"$input" | sed -n 's/^Q //p' | tr '\n' ' ' | sed 's/ $//')" ]]; then
    echo "STATUS: unchanged"
  else
    echo "STATUS: adjusted"
  fi
  echo "QUEUE: $queue"
  echo "SKIPPED: $skipped"
}

case "${1:-}" in
  publish) _publish ;;
  show)    _show ;;
  first)   _adjust first "${2:-}" ;;
  skip)    _adjust skip "${2:-}" ;;
  reset)   _reset ;;
  apply)   _apply ;;
  *)
    echo "Usage: agenda.sh publish | show | first <N> | skip <N> | reset | apply" >&2
    exit 1 ;;
esac

#!/usr/bin/env bash
#
# adapt-report.sh <report.json>
#
# Normalizes the real cursor-agent report schema to the few fields the rest of the glue
# cares about. The raw report is UNTRUSTED — this only extracts the executor's CLAIM and
# its token usage (for §3). It never touches ground truth.
#
#   real schema in:  {type, subtype, is_error, result, usage:{inputTokens,...}}
#   normalized out:  {report_present, claimed_success, summary, tokens:{in,out,cache_read,cache_write,total}}
#
# Missing/invalid report (timeout, garbage) -> report_present:false, claimed_success:false.
#
set -uo pipefail
REPORT="${1:-}"

if [[ -z "$REPORT" || ! -f "$REPORT" ]] || ! jq -e . "$REPORT" >/dev/null 2>&1; then
  jq -cn '{report_present:false, claimed_success:false, summary:null,
           tokens:{in:0, out:0, cache_read:0, cache_write:0, total:0}}'
  exit 0
fi

jq -c '
  (.usage // {}) as $u
  | ($u.inputTokens // 0)      as $in
  | ($u.outputTokens // 0)     as $out
  | ($u.cacheReadTokens // 0)  as $cr
  | ($u.cacheWriteTokens // 0) as $cw
  | {
      report_present: true,
      # the executor claims success unless it explicitly flags an error
      claimed_success: ((.is_error // false) | not),
      summary: (.result // null),
      tokens: { in:$in, out:$out, cache_read:$cr, cache_write:$cw,
                total: ($in + $out) }
    }
' "$REPORT"

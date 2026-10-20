#!/usr/bin/env bash
# php-memory-diagnose.sh
# Read-only report of what drives a WordPress site on Kinsta to the PHP memory limit.
# Changes nothing on the site.
#
# Usage:  bash php-memory-diagnose.sh [/www/sitename_123]
#         TOP=25 bash php-memory-diagnose.sh        # show more rows per section

set -uo pipefail

SITE="${1:-$(ls -d /www/*/ 2>/dev/null | head -1)}"
SITE="${SITE%/}"
LOGS="$SITE/logs"
PUB="$SITE/public"
PROFILE_LOG="$SITE/private/kinsta-mem-profile.log"
TOP="${TOP:-15}"

hr()  { printf '\n==================== %s ====================\n' "$1"; }
sub() { printf '\n-- %s\n' "$1"; }

[ -d "$LOGS" ] || { echo "Logs directory not found: $LOGS"; exit 1; }

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
# Current + rotated (.gz) error logs
zgrep -h "Allowed memory size" "$LOGS"/*error*.log* 2>/dev/null > "$TMP"
TOTAL=$(wc -l < "$TMP" | tr -d ' ')

echo "Site: $SITE"
echo "Logs: $LOGS"

# ------------------------------------------------------------------
hr "1. Memory limits"
if command -v wp >/dev/null 2>&1 && [ -d "$PUB" ]; then
  ( cd "$PUB" && wp eval --skip-plugins --skip-themes '
      printf("WP_MEMORY_LIMIT (front end)  = %s\n", WP_MEMORY_LIMIT);
      printf("WP_MAX_MEMORY_LIMIT (admin)  = %s\n", WP_MAX_MEMORY_LIMIT);
      printf("CLI memory_limit (not FPM)   = %s\n", ini_get("memory_limit"));
    ' 2>/dev/null | grep -v -i "warning" )
fi
sub "Limit enforced by PHP-FPM, as reported in the fatal errors"
if [ "$TOTAL" -gt 0 ]; then
  sed -nE 's/.*Allowed memory size of ([0-9]+) bytes.*/\1/p' "$TMP" \
    | sort | uniq -c | awk '{printf "  %6d fatals at %d MB\n", $1, $2/1048576}'
else
  echo "  (no memory fatals in logs)"
fi

# ------------------------------------------------------------------
hr "2. Memory fatals in logs: $TOTAL"
if [ "$TOTAL" -gt 0 ]; then
  sub "Per day"
  sed -nE 's#^([0-9]{4}/[0-9]{2}/[0-9]{2}).*#\1#p' "$TMP" | sort | uniq -c

  sub "Per hour (busiest $TOP)"
  sed -nE 's#^([0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}).*#\1:00#p' "$TMP" | sort | uniq -c | sort -rn | head -n "$TOP"

  sub "Component where the allocation failed"
  sed -nE 's/.*exhausted \(tried to allocate [0-9]+ bytes\) in ([^ ]+) on line [0-9]+.*/\1/p' "$TMP" \
    | awk '{
        f=$0
        if (match(f, /wp-content\/mu-plugins\/[^\/]+/))   c="mu-plugin: " substr(f, RSTART+22, RLENGTH-22)
        else if (match(f, /wp-content\/plugins\/[^\/]+/)) c="plugin:    " substr(f, RSTART+19, RLENGTH-19)
        else if (match(f, /wp-content\/themes\/[^\/]+/))  c="theme:     " substr(f, RSTART+18, RLENGTH-18)
        else if (f ~ /wp-(includes|admin)\//)             { sub(/.*\/public\//, "", f); c="core:      " f }
        else c="other:     " f
        print c }' \
    | sort | uniq -c | sort -rn | head -n "$TOP"

  sub "Exact file:line (top $TOP)"
  sed -nE 's/.*exhausted \(tried to allocate [0-9]+ bytes\) in ([^ ]+) on line ([0-9]+).*/\1:\2/p' "$TMP" \
    | sed "s#^$PUB/##" | sort | uniq -c | sort -rn | head -n "$TOP"

  sub "Size of the failed allocation"
  sed -nE 's/.*tried to allocate ([0-9]+) bytes.*/\1/p' "$TMP" \
    | awk '{ if ($1 >= 1048576) b="1) >= 1 MB      -> one huge value (big query result, option, API response, file)";
             else if ($1 >= 65536) b="2) 64 KB - 1 MB -> large arrays/strings being built";
             else b="3) < 64 KB      -> gradual growth (loops, many objects, leak)";
             print b }' | sort | uniq -c

  sub "Requests that hit the limit (query strings stripped, top $TOP)"
  sed -nE 's/.*request: "([A-Z]+) ([^ ?"]*)[^"]*".*/\1 \2/p' "$TMP" | sort | uniq -c | sort -rn | head -n "$TOP"

  sub "Referrers of failing admin-ajax / wp-json / wp-cron requests (top $TOP)"
  grep -E 'request: "[A-Z]+ /(wp-admin/admin-ajax\.php|wp-json|wp-cron\.php)' "$TMP" \
    | sed -nE 's/.*referrer: "([^"?]*)[^"]*".*/\1/p' | sort | uniq -c | sort -rn | head -n "$TOP"

  sub "Client IPs behind the failing requests (top $TOP)"
  sed -nE 's/.*client: ([0-9a-fA-F.:]+),.*/\1/p' "$TMP" | sort | uniq -c | sort -rn | head -n "$TOP"
fi

# ------------------------------------------------------------------
hr "3. Database data loaded into memory"
if command -v wp >/dev/null 2>&1 && [ -d "$PUB" ]; then
  cd "$PUB" || exit 1
  P="$(wp db prefix 2>/dev/null | tail -1)"
  AUTO="autoload IN ('yes','on','auto-on','auto')"

  sub "Autoloaded options (loaded on EVERY request)"
  wp db query "SELECT COUNT(*) AS options, ROUND(SUM(LENGTH(option_value))/1048576,2) AS autoload_MB FROM ${P}options WHERE $AUTO;" 2>/dev/null

  sub "Largest autoloaded options"
  wp db query "SELECT option_name, ROUND(LENGTH(option_value)/1024,1) AS KB FROM ${P}options WHERE $AUTO ORDER BY LENGTH(option_value) DESC LIMIT $TOP;" 2>/dev/null

  sub "Largest options overall (incl. non-autoloaded)"
  wp db query "SELECT option_name, autoload, ROUND(LENGTH(option_value)/1024,1) AS KB FROM ${P}options ORDER BY LENGTH(option_value) DESC LIMIT 10;" 2>/dev/null

  sub "Transients stored in the options table"
  wp db query "SELECT COUNT(*) AS transients, ROUND(SUM(LENGTH(option_value))/1048576,2) AS MB FROM ${P}options WHERE option_name LIKE '\_transient\_%' OR option_name LIKE '\_site\_transient\_%';" 2>/dev/null

  sub "Largest single postmeta values"
  wp db query "SELECT post_id, meta_key, ROUND(LENGTH(meta_value)/1024,1) AS KB FROM ${P}postmeta ORDER BY LENGTH(meta_value) DESC LIMIT 10;" 2>/dev/null

  sub "Largest tables"
  wp db query "SELECT table_name, ROUND((data_length+index_length)/1048576,1) AS MB, table_rows FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY (data_length+index_length) DESC LIMIT 10;" 2>/dev/null

  sub "Persistent object cache in use?"
  wp eval 'echo wp_using_ext_object_cache() ? "yes\n" : "no\n";' 2>/dev/null | tail -1

  sub "Active plugins"
  echo "  $(wp plugin list --status=active --format=count 2>/dev/null | tail -1) active"
else
  echo "  WP-CLI not available, skipping database checks."
fi

# ------------------------------------------------------------------
hr "4. Optional profiler results ($PROFILE_LOG)"
if [ -f "$PROFILE_LOG" ]; then
  echo "  $(wc -l < "$PROFILE_LOG" | tr -d ' ') requests logged above the threshold"
  sub "Heaviest endpoints (count, then peak MB seen)"
  awk -F'\t' '{ key=$3 ($4 != "" ? " [action=" $4 "]" : ""); split($2, m, "MB"); n[key]++; if (m[1] > mx[key]) mx[key]=m[1] }
              END { for (k in n) printf "%6d  peak %4d MB  %s\n", n[k], mx[k], k }' "$PROFILE_LOG" \
    | sort -rn | head -n "$TOP"
else
  echo "  Not installed. See kinsta-mem-profiler.php (temporary, needs customer approval)."
fi

echo
echo "Done. Nothing was changed."

#!/usr/bin/env bash
# Shell-level tests for the loader's download handling. No database and no
# Docker: every tool the scripts reach for -- wget, psql, tiger-prefetch,
# shp2pgsql, unzip -- is a fake on PATH that records what it was asked and
# answers according to the URL or the SQL it was given. What is under test is
# the classification and control flow the scripts wrap around those tools:
# which failures are routine, which stop the run, and what a stopped run leaves
# behind. Needs zip and unzip on the host (unzip is what tiger-prefetch uses to
# checksum a download).
set -euo pipefail

repo=${TIGER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
bin=$repo/docker/bin
work=$(mktemp --directory)
trap 'rm --recursive --force "$work"' EXIT

fakes=$work/bin
export TIGER_STAGING=$work/staging
export FAKE_LOG=$work/log
export FAKE_ZIP=$work/good.zip
export FAKE_STATE=$work/state
mkdir --parents "$fakes" "$TIGER_STAGING" "$FAKE_STATE"
export PATH=$fakes:$PATH

passed=0
failed=0

ok()   { printf 'ok       %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL     %s (%s)\n' "$1" "$2"; failed=$((failed + 1)); }

expect_eq() { # name expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1" "expected $(printf %q "$2"), got $(printf %q "$3")"; fi
}
expect_grep() { # name pattern file
  if grep --quiet --extended-regexp -- "$2" "$3"; then ok "$1"; else fail "$1" "no match for $2"; fi
}
expect_no_grep() { # name pattern file
  if grep --quiet --extended-regexp -- "$2" "$3"; then fail "$1" "unexpected match for $2"; else ok "$1"; fi
}
expect_file() { # name path
  if [[ -s $2 ]]; then ok "$1"; else fail "$1" "$2 missing or empty"; fi
}
expect_no_file() { # name path
  if [[ -e $2 ]]; then fail "$1" "$2 exists"; else ok "$1"; fi
}

# A real zip whose member CRC unzip -t can check. This is what "verified" means.
echo payload >"$work/member.txt"
(cd "$work" && zip --quiet good.zip member.txt)

# --- fakes -------------------------------------------------------------------

# Behaviour is keyed on the file name in the URL. Every call is logged, one
# line of arguments each, so tests can assert on what was and was not asked.
cat >"$fakes/wget" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LOG}/wget"
url=
for arg in "$@"; do [[ $arg == *://* ]] && { url=$arg; break; }; done
path=${url#*://}
case ${url##*/} in
  *404*)     printf 'HTTP request sent, awaiting response... 404 Not Found\nERROR 404: Not Found.\n' >&2; exit 8 ;;
  *nofile*)  printf "No such file '%s'.\n" "${url##*/}" >&2; exit 8 ;;
  *429*)     printf '  HTTP/1.1 429 Too Many Requests\n  Retry-After: 3600\nERROR 429: Too Many Requests.\n' >&2; exit 8 ;;
  *403*)     printf '  HTTP/1.1 403 Forbidden\nERROR 403: Forbidden.\n' >&2; exit 8 ;;
  *503*)     printf '  HTTP/1.1 503 Service Unavailable\nERROR 503: Service Unavailable.\n' >&2; exit 8 ;;
  *reset*)   printf 'Read error (Connection reset by peer) in headers.\nGiving up.\n' >&2; exit 4 ;;
  *diskfull*) printf 'Cannot write to %q (No space left on device).\n' "$path" >&2; exit 3 ;;
  *corrupt*) mkdir --parents "$(dirname "$path")"; echo garbage >"$path"; exit 0 ;;
  *)         mkdir --parents "$(dirname "$path")"; cp "$FAKE_ZIP" "$path"; exit 0 ;;
esac
FAKE

# Answers the handful of queries tiger-load makes. Loaded states live in
# ${FAKE_STATE}/loadlog; ${FAKE_STATE}/verify/<ST> holds t or f for the
# completeness check; ${FAKE_STATE}/script/<name> is what "generate" returns.
cat >"$fakes/psql" <<'FAKE'
#!/usr/bin/env bash
sql=
while [[ $# -gt 0 ]]; do
  case $1 in
    --command|-c) sql=$2; shift ;;
    --command=*)  sql=${1#--command=} ;;
  esac
  shift
done
[[ -n $sql ]] || sql=$(cat)
printf '%s\n' "$sql" | tr --squeeze-repeats '[:space:]' ' ' >>"${FAKE_LOG}/psql"
loadlog=${FAKE_STATE}/loadlog
touch "$loadlog"
case $sql in
  *"INSERT INTO api.load_log"*)
    st=${sql#*SELECT \'}; st=${st%%\'*}
    echo "$st" >>"$loadlog" ;;
  *"to_regclass('tiger_data.state_all')"*) echo t ;;
  *"tiger_year FROM tiger.loader_variables"*) echo 2025 ;;
  *"FROM api.load_log WHERE state = '"*)
    st=${sql#*state = \'}; st=${st%%\'*}
    if grep --quiet --line-regexp "$st" "$loadlog"; then echo t; else echo f; fi ;;
  *"SELECT state FROM api.load_log"*) cat "$loadlog" ;;
  *"loader_generate_nation_script"*) cat "${FAKE_STATE}/script/nation" ;;
  *"loader_generate_script(ARRAY['"*)
    st=${sql#*ARRAY[\'}; st=${st%%\'*}
    cat "${FAKE_STATE}/script/${st}" ;;
  *"api.state_is_complete('"*)
    st=${sql#*state_is_complete(\'}; st=${st%%\'*}
    cat "${FAKE_STATE}/verify/${st}" 2>/dev/null || echo t ;;
esac
exit 0
FAKE

# The real one is under test on its own below; here it is a stand-in so that
# tiger-load's control flow can be driven. Exit code comes from
# ${FAKE_STATE}/prefetch_rc/<script basename>, default 0.
cat >"$fakes/tiger-prefetch" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$1")" >>"${FAKE_LOG}/prefetch"
rc=0
[[ -r ${FAKE_STATE}/prefetch_rc/$(basename "$1") ]] && rc=$(<"${FAKE_STATE}/prefetch_rc/$(basename "$1")")
exit "$rc"
FAKE

printf '#!/usr/bin/env bash\nexit 0\n' >"$fakes/shp2pgsql"
chmod +x "$fakes"/*

# tiger-prefetch calls unzip for real; tiger-load only needs it to exist.
# tiger-prefetch on PATH must be the fake for tiger-load's tests and the real
# one for its own, so the real one is invoked by path.
real_prefetch=$bin/tiger-prefetch

# The wget wrapper is the header tiger-load writes into every generated script.
# Lift it verbatim rather than copying it here, so the test follows the code.
sed --quiet "/cat <<-'HEADER'/,/^\tHEADER\$/p" "$bin/tiger-load" \
  | sed '1d;$d' | sed 's/^\t//' >"$work/header.bash"

reset() {
  rm --recursive --force "$FAKE_LOG" "$FAKE_STATE" "$TIGER_STAGING"
  mkdir --parents "$FAKE_LOG" "$FAKE_STATE/verify" "$FAKE_STATE/script" \
    "$FAKE_STATE/prefetch_rc" "$TIGER_STAGING"
  : >"$FAKE_LOG/wget"; : >"$FAKE_LOG/psql"; : >"$FAKE_LOG/prefetch"
}

# Run the wrapper as the generated script would: header, then one wget line.
wrapped_wget() { # url -> prints rc, stderr to $work/err
  local rc=0
  (cd "$TIGER_STAGING" && bash -c "$(cat "$work/header.bash"); rc=0; wget --mirror \"\$1\" || rc=\$?; echo \"rc=\$rc\"" _ "$1") \
    2>"$work/err" || rc=$?
  [[ $rc -eq 0 ]] || echo "exit=$rc"
}

echo "-- wget wrapper (generated script header)"

reset
expect_eq "a published file downloads and returns 0" \
  "rc=0" "$(wrapped_wget https://h.test/geo/tl_2025_11001_edges.zip)"
expect_grep "the wrapper resumes by size, not mtime, and keeps one cookie jar" \
  "--continue --no-if-modified-since --keep-session-cookies --save-cookies=${TIGER_STAGING}/cookies.txt --load-cookies=${TIGER_STAGING}/cookies.txt" "$FAKE_LOG/wget"

reset
expect_eq "a 404 is not published: skipped, exit 0" \
  "rc=0" "$(wrapped_wget https://h.test/geo/tl_2025_11001_404.zip)"
expect_grep "the skip is logged as not published" "not published, skipping" "$work/err"
expect_grep "and the file is listed for the verifier" "^tl_2025_11001_404\.zip$" "$TIGER_STAGING/not-published.txt"

reset
expect_eq "an FTP 'No such file' is skipped too" \
  "rc=0" "$(wrapped_wget ftp://h.test/geo/tl_2025_11001_nofile.zip)"
expect_grep "and listed for the verifier as well" "^tl_2025_11001_nofile\.zip$" "$TIGER_STAGING/not-published.txt"

for code in 429 403 503; do
  reset
  expect_eq "a ${code} stops the script with 75" \
    "exit=75" "$(wrapped_wget "https://h.test/geo/tl_2025_11001_${code}.zip")"
  expect_grep "the ${code} stop says the server is refusing" "refusing requests" "$work/err"
done

reset
expect_eq "a write error (exit 3) stays fatal with its own code" \
  "rc=3" "$(wrapped_wget https://h.test/geo/tl_2025_11001_diskfull.zip)"

reset
expect_eq "a connection reset that survives every retry stops the run" \
  "exit=75" "$(wrapped_wget https://h.test/geo/tl_2025_11001_reset.zip)"

reset
mkdir --parents "$TIGER_STAGING/h.test/geo"
cp "$FAKE_ZIP" "$TIGER_STAGING/h.test/geo/cached.zip"
echo abc >"$TIGER_STAGING/h.test/geo/cached.zip.sha256"
expect_eq "a checksummed cache hit returns 0" \
  "rc=0" "$(wrapped_wget https://h.test/geo/cached.zip)"
expect_eq "a checksummed cache hit makes no request" "" "$(cat "$FAKE_LOG/wget")"

reset
mkdir --parents "$TIGER_STAGING/h.test/geo"
cp "$FAKE_ZIP" "$TIGER_STAGING/h.test/geo/unverified.zip"
wrapped_wget https://h.test/geo/unverified.zip >/dev/null
expect_eq "a cached file without a sidecar is still requested" \
  "1" "$(wc --lines <"$FAKE_LOG/wget")"

echo "-- tiger-prefetch"

prefetch() { # script-body... -> prints exit code, stderr to $work/err
  printf '%s\n' "$@" >"$work/gen.sh"
  local rc=0
  "$real_prefetch" "$work/gen.sh" 2>"$work/err" || rc=$?
  echo "$rc"
}

reset
expect_eq "a script with no URLs exits 0" "0" "$(prefetch 'echo nothing to fetch')"
expect_eq "and makes no request" "" "$(cat "$FAKE_LOG/wget")"

reset
rc=$(prefetch \
  'wget --mirror https://h.test/geo/a.zip' \
  'wget --mirror https://h.test/geo/a.zip' \
  'wget --mirror https://h.test/geo/b_404.zip' \
  'wget --mirror ftp://h.test/geo/c_nofile.zip' \
  'wget --mirror https://h.test/geo/d_corrupt.zip' \
  'wget --mirror https://h.test/geo/e_reset.zip' \
  'wget --mirror https://h.test/geo/f.zip')
expect_eq "soft failures do not change the exit code" "0" "$rc"
expect_eq "a URL repeated in the script is fetched once" \
  "6" "$(wc --lines <"$FAKE_LOG/wget")"
expect_grep "every soft failure is counted" "4 file\(s\) not fetched" "$work/err"
expect_grep "a 404 is reported as not published" "not published" "$work/err"
expect_grep "a reset is reported as a download failure" "download failed" "$work/err"
expect_file "a good download gets a sha256 sidecar" "$TIGER_STAGING/census-cache/../h.test/geo/a.zip.sha256"
expect_no_file "a corrupt download is discarded" "$TIGER_STAGING/h.test/geo/d_corrupt.zip"
expect_grep "the corrupt one is named" "corrupt or truncated, discarding" "$work/err"
expect_grep "every request retries 5xx, resumes by size, paces, and shares the cookie jar" \
  "--retry-on-http-error=500,502,503,504,520,521,522,523,524 --continue --no-if-modified-since --keep-session-cookies --save-cookies=${TIGER_STAGING}/cookies.txt --load-cookies=${TIGER_STAGING}/cookies.txt --wait=1 --random-wait" "$FAKE_LOG/wget"

reset
rc=$(prefetch \
  'wget --mirror https://h.test/geo/a.zip' \
  'wget --mirror https://h.test/geo/b_429.zip' \
  'wget --mirror https://h.test/geo/c.zip')
expect_eq "a 429 exits 75" "75" "$rc"
expect_eq "and nothing after it is requested" "2" "$(wc --lines <"$FAKE_LOG/wget")"
expect_grep "the Retry-After is surfaced" "Retry-After: 3600 seconds \(~60 minutes\)" "$work/err"
expect_file "what was fetched before the stop is kept" "$TIGER_STAGING/h.test/geo/a.zip.sha256"

for code in 403 503; do
  reset
  rc=$(prefetch "wget --mirror https://h.test/geo/a_${code}.zip" 'wget --mirror https://h.test/geo/b.zip')
  expect_eq "a ${code} is a refusal: exit 75" "75" "$rc"
  expect_eq "a ${code} stops the run" "1" "$(wc --lines <"$FAKE_LOG/wget")"
done
expect_no_grep "no Retry-After is invented when the server sent none" "Retry-After" "$work/err"

reset
prefetch 'wget --mirror https://h.test/geo/a.zip' >/dev/null
: >"$FAKE_LOG/wget"
rc=$(prefetch 'wget --mirror https://h.test/geo/a.zip')
expect_eq "a verified file is not requested again" "" "$(cat "$FAKE_LOG/wget")"
expect_eq "and the run still exits 0" "0" "$rc"

reset
prefetch 'wget --mirror https://h.test/geo/a.zip' >/dev/null
: >"$FAKE_LOG/wget"
TIGER_DOWNLOAD_REVALIDATE=true prefetch 'wget --mirror https://h.test/geo/a.zip' >/dev/null
expect_eq "TIGER_DOWNLOAD_REVALIDATE=true revalidates a verified file" "1" "$(wc --lines <"$FAKE_LOG/wget")"

reset
mkdir --parents "$TIGER_STAGING/h.test/geo"
cp "$FAKE_ZIP" "$TIGER_STAGING/h.test/geo/serial.zip"
prefetch 'wget --mirror https://h.test/geo/serial.zip' >/dev/null
expect_eq "a file the serial pass left behind is checked locally, not fetched" "" "$(cat "$FAKE_LOG/wget")"
expect_file "and gains a sidecar once it passes" "$TIGER_STAGING/h.test/geo/serial.zip.sha256"

reset
mkdir --parents "$TIGER_STAGING/h.test/geo"
echo garbage >"$TIGER_STAGING/h.test/geo/torn.zip"
prefetch 'wget --mirror https://h.test/geo/torn.zip' >/dev/null
expect_eq "a truncated leftover is discarded and fetched again" "1" "$(wc --lines <"$FAKE_LOG/wget")"
expect_eq "and the refetched copy is verified" \
  "$(sha256sum "$FAKE_ZIP" | cut --delimiter=' ' --fields=1)" "$(cat "$TIGER_STAGING/h.test/geo/torn.zip.sha256")"

reset
mkdir --parents "$TIGER_STAGING/www2.census.gov/geo/tiger" "$TIGER_STAGING/census-cache"
cp "$FAKE_ZIP" "$TIGER_STAGING/www2.census.gov/geo/tiger/old.zip"
# A cache from before the links were relative.
ln --symbolic --no-target-directory "$TIGER_STAGING/census-cache" "$TIGER_STAGING/ftp.census.gov"
prefetch 'wget --mirror ftp://ftp2.census.gov/geo/tiger/new.zip' >/dev/null
for host in www2.census.gov ftp2.census.gov ftp.census.gov; do
  expect_eq "unify_cache: ${host} is a relative symlink to census-cache" \
    "census-cache" "$(readlink "$TIGER_STAGING/$host")"
done
expect_file "unify_cache: the https download moved into the shared cache" "$TIGER_STAGING/census-cache/geo/tiger/old.zip"
expect_file "unify_cache: the ftp download lands in the shared cache" "$TIGER_STAGING/census-cache/geo/tiger/new.zip"
prefetch 'wget --mirror https://www2.census.gov/geo/tiger/old.zip' >/dev/null
expect_eq "unify_cache: the same file over https is a cache hit" "1" "$(wc --lines <"$FAKE_LOG/wget")"
rc=$(prefetch 'echo re-run')
expect_eq "unify_cache: a second run over the symlinks is a no-op" "0" "$rc"

echo "-- tiger-load: states"

load() { # args... -> prints exit code; stderr to $work/err
  local rc=0
  "$bin/tiger-load" "$@" 2>"$work/err" >/dev/null || rc=$?
  echo "$rc"
}
plan() { # state url... : the "generated" body for that state
  local st=$1; shift
  # shellcheck disable=SC2016  # expanded by the generated script, not here
  { echo 'cd "${TIGER_STAGING}"'; printf 'wget --mirror %s\n' "$@"; } >"$FAKE_STATE/script/$st"
}

reset
plan AA https://h.test/geo/aa.zip; plan BB https://h.test/geo/bb.zip; plan CC https://h.test/geo/cc.zip
echo f >"$FAKE_STATE/verify/BB"
rc=$(load states AA BB CC)
expect_eq "a state failing verification costs the run exit 65" "65" "$rc"
expect_eq "the states around it still load and are recorded" $'AA\nCC' "$(cat "$FAKE_STATE/loadlog")"
expect_grep "the failed state is named" "1 state\(s\) failed: BB" "$work/err"
expect_grep "and told how to retry" "re-run to retry BB" "$work/err"
expect_grep "the failing state's tables are dropped first" "DROP TABLE IF EXISTS tiger_data.%I" "$FAKE_LOG/psql"

reset
plan AA https://h.test/geo/aa.zip https://h.test/geo/tl_2025_01001_nofile.zip
rc=$(load states AA)
expect_eq "a state with a file the Census does not publish still loads" "0" "$rc"
expect_grep "and the file is handed to the verifier" \
  "record_not_published\('AA', '\{tl_2025_01001_nofile\.zip\}'::text\[\]\)" "$FAKE_LOG/psql"
expect_grep "before the state is verified" \
  "record_not_published.*state_is_complete\('AA'" <(tr '\n' ' ' <"$FAKE_LOG/psql")

reset
plan AA https://h.test/geo/aa.zip
rc=$(load states AA)
expect_grep "a state with nothing unpublished still clears its list" \
  "record_not_published\('AA', '\{\}'::text\[\]\)" "$FAKE_LOG/psql"

reset
plan AA https://h.test/geo/aa.zip; plan BB https://h.test/geo/bb.zip; plan CC https://h.test/geo/cc.zip
echo 75 >"$FAKE_STATE/prefetch_rc/state_bb.sh"
rc=$(load states AA BB CC)
expect_eq "a rate-limited prefetch stops the run with 75" "75" "$rc"
expect_eq "states before it are kept" "AA" "$(cat "$FAKE_STATE/loadlog")"
expect_eq "states after it are never started" $'state_aa.sh\nstate_bb.sh' "$(cat "$FAKE_LOG/prefetch")"
expect_no_grep "CC is not generated after the stop" "generating state_cc" "$work/err"
expect_grep "the stop is logged" "prefetch rate limited; not starting the load" "$work/err"

reset
plan AA https://h.test/geo/aa.zip; plan BB https://h.test/geo/bb_429.zip; plan CC https://h.test/geo/cc.zip
rc=$(load states AA BB CC)
expect_eq "a refusal inside the serial pass stops the run with 75" "75" "$rc"
expect_eq "the refused state is not recorded" "AA" "$(cat "$FAKE_STATE/loadlog")"
expect_no_grep "and later states are not attempted" "generating state_cc" "$work/err"

reset
plan AA https://h.test/geo/aa_404.zip https://h.test/geo/aa.zip
rc=$(load states AA)
expect_eq "a file the Census does not publish does not fail the state" "0" "$rc"
expect_eq "and the state is recorded once verification passes" "AA" "$(cat "$FAKE_STATE/loadlog")"

reset
plan AA https://h.test/geo/aa_diskfull.zip
rc=$(load states AA)
expect_eq "a write error in the serial pass fails the state" "65" "$rc"
expect_eq "and leaves it out of the load log" "" "$(cat "$FAKE_STATE/loadlog")"

reset
plan AA https://h.test/geo/aa.zip; plan BB https://h.test/geo/bb.zip
echo AA >"$FAKE_STATE/loadlog"
rc=$(load states AA BB)
expect_eq "an already-loaded state is skipped" "0" "$rc"
expect_grep "and says so" "AA already loaded; skipping" "$work/err"
expect_eq "without being prefetched" "state_bb.sh" "$(cat "$FAKE_LOG/prefetch")"

reset
plan AA https://h.test/geo/aa.zip
echo AA >"$FAKE_STATE/loadlog"
rc=$(TIGER_RELOAD_STATES=1 load states AA)
expect_eq "TIGER_RELOAD_STATES=1 reloads a loaded state" "state_aa.sh" "$(cat "$FAKE_LOG/prefetch")"

reset
plan AA https://h.test/geo/aa.zip; plan BB https://h.test/geo/bb.zip
echo f >"$FAKE_STATE/verify/BB"
rc=$(load all AA BB)
expect_eq "all: a failed state still exits 65" "65" "$rc"
expect_grep "all: indexes are built regardless" "install_missing_indexes" "$FAKE_LOG/psql"
expect_grep "all: the vacuum freeze runs regardless" "VACUUM \(FREEZE, ANALYZE\) tiger.addr" "$FAKE_LOG/psql"

reset
plan AA https://h.test/geo/aa.zip
rc=$(TIGER_STATES=aa load states)
expect_eq "states come from TIGER_STATES when no arguments are given" "AA" "$(cat "$FAKE_STATE/loadlog")"

reset
rc=$(load states)
expect_eq "no states at all is a usage error" "64" "$rc"

reset
rc=$(TIGER_STATES=AA load verify)
expect_grep "verify ignores TIGER_STATES" "no states loaded" "$work/err"
expect_no_grep "verify does not check TIGER_STATES's state" "state_is_complete\('AA'" "$FAKE_LOG/psql"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]

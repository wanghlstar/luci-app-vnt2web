#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKER="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/version-worker"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

stop_worker() {
	if [ -f "$1/pid" ]; then
		kill "$(cat "$1/pid")" 2>/dev/null || true
		wait "$(cat "$1/pid")" 2>/dev/null || true
	fi
}

wait_for_count() {
	file="$1"
	wanted="$2"
	remaining="${3:-10}"

	while [ "$remaining" -gt 0 ]; do
		count="$(cat "$file" 2>/dev/null || printf '0')"
		[ "$count" -ge "$wanted" ] && return 0
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

log_count() {
	file="$1"
	pattern="$2"

	if [ ! -f "$file" ]; then
		printf '0\n'
		return 0
	fi
	count="$(grep -c "$pattern" "$file" 2>/dev/null)" || count=0
	printf '%s\n' "$count"
}

# A fixed sleep cannot tell a slow machine from a machine that never logs the
# line, so wait until the pattern appears the expected number of times and then
# keep observing it for a while: the count has to stay stable.
wait_for_log_count() {
	file="$1"
	pattern="$2"
	wanted="$3"
	remaining="${4:-20}"
	stable="${5:-3}"
	observed=0

	while [ "$remaining" -gt 0 ]; do
		count="$(log_count "$file" "$pattern")"
		if [ "$count" -ge "$wanted" ]; then
			observed=$((observed + 1))
			if [ "$observed" -ge "$stable" ]; then
				return 0
			fi
		else
			observed=0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

make_mock_check() {
	dir="$1"
	body="$2"

	cat >"$dir/mock-check" <<EOF
#!/bin/sh
$body
EOF
	chmod 0755 "$dir/mock-check"
}

start_worker() {
	dir="$1"
	check_delay="$2"
	debounce_delay="$3"
	shift 3

	MOCK_STATE_DIR="$dir" \
	MOCK_CHECK_DELAY="$check_delay" \
	VNT2_VERSION_PENDING_FILE="$dir/pending" \
	VNT2_VERSION_CLAIMED_FILE="$dir/claimed" \
	VNT2_VERSION_LOG_FILE="$dir/log" \
	VNT2_VERSION_CHECK_COMMAND="$dir/mock-check" \
	VNT2_VERSION_DELAY="$debounce_delay" \
	VNT2_VERSION_POLL_INTERVAL=1 \
		env "$@" sh "$WORKER" &
	echo "$!" >"$dir/pid"
}

test_repeated_requests_merge() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	make_mock_check "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
touch "$MOCK_STATE_DIR/entered"
sleep "${MOCK_CHECK_DELAY:-0}"
'
	start_worker "$dir" 0 2

	date +%s >"$dir/pending"
	sleep 1
	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 1 20 3 ||
		fail "merged version check did not run"

	[ "$(cat "$dir/count")" -eq 1 ] || fail "repeated page loads started more than one version check"
	[ ! -e "$dir/pending" ] || fail "merged check left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "merged check left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: repeated page-load requests were merged\n'
}

test_request_during_check_is_retained() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	make_mock_check "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
touch "$MOCK_STATE_DIR/entered"
sleep "${MOCK_CHECK_DELAY:-0}"
'
	start_worker "$dir" 2 1

	date +%s >"$dir/pending"
	remaining=10
	while [ ! -f "$dir/entered" ] && [ "$remaining" -gt 0 ]; do
		sleep 1
		remaining=$((remaining - 1))
	done
	[ -f "$dir/entered" ] || fail "first version check did not begin"

	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 15 || fail "request received during version check was lost"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 2 20 3 ||
		fail "second version check did not complete"

	[ "$(cat "$dir/count")" -eq 2 ] || fail "expected exactly two version checks"
	[ ! -e "$dir/pending" ] || fail "second check left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "second check left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: request received during a version check was retained\n'
}

# A marker written with leading zeros used to abort the whole worker loop,
# because dash evaluates "08" as an invalid octal number inside $(( )).
test_leading_zero_timestamp_marker() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	make_mock_check "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
sleep "${MOCK_CHECK_DELAY:-0}"
'
	start_worker "$dir" 0 1

	printf '%016d\n' "$(date +%s)" >"$dir/pending"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 1 20 3 ||
		fail "zero padded timestamp marker was not processed"
	[ ! -e "$dir/claimed" ] || fail "zero padded marker left a claimed marker"

	# The worker must still be alive and serve the next request.
	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 20 || fail "worker did not survive a zero padded timestamp marker"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 2 20 3 ||
		fail "second request after a zero padded marker did not complete"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: zero padded timestamp marker is handled without crashing\n'
}

# A failing check must not silently drop the request: the claimed marker
# survives and the command is retried with a growing backoff.
test_failed_check_is_retried() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	make_mock_check "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
[ "$count" -ge 2 ] || exit 1
'
	start_worker "$dir" 0 1 \
		VNT2_VERSION_RETRY_BACKOFF="1 1 1" \
		VNT2_VERSION_RETRY_LIMIT=3

	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 20 || fail "failed version check was not retried"
	wait_for_log_count "$dir/log" 'version worker latest release check retry 1 scheduled in 1s' 1 20 3 ||
		fail "failed version check did not schedule a retry"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 1 20 3 ||
		fail "retried version check did not complete"
	[ ! -e "$dir/claimed" ] || fail "retried version check left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a failed version check is retried before it is abandoned\n'
}

# Non numeric tuning values must not break the loop or turn it into a busy loop.
test_non_numeric_tuning_is_sanitized() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	make_mock_check "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
sleep "${MOCK_CHECK_DELAY:-0}"
'
	start_worker "$dir" 0 1 \
		VNT2_VERSION_DELAY=later \
		VNT2_VERSION_POLL_INTERVAL=0x2 \
		VNT2_VERSION_RETRY_LIMIT=all

	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'version worker completed latest release check' 1 20 3 ||
		fail "worker did not run with sanitized tuning values"
	[ -s "$dir/log" ] || fail "worker produced no log output"
	case "$(sed -n '1p' "$dir/log")" in
		*'version : '*) ;;
		*) fail "worker log prefix is not 'version :'" ;;
	esac

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: non numeric tuning values fall back to defaults\n'
}

test_repeated_requests_merge
test_request_during_check_is_retained
test_leading_zero_timestamp_marker
test_failed_check_is_retried
test_non_numeric_tuning_is_sanitized
printf 'version-worker tests passed\n'

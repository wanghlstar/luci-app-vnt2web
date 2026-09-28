#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKER="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/restart-worker"

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

make_mock_restart() {
	dir="$1"
	body="$2"

	cat >"$dir/mock-restart" <<EOF
#!/bin/sh
$body
EOF
	chmod 0755 "$dir/mock-restart"
}

test_debounce() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=2 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	sleep 1
	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 20 3 ||
		fail "debounced restart did not complete"

	starts="$(log_count "$dir/log" 'worker starts queued restart')"
	[ "$starts" -eq 1 ] || fail "debounce started $starts restarts"
	[ ! -e "$dir/pending" ] || fail "debounce left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "debounce left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: repeated requests were merged\n'
}

test_request_during_restart() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	make_mock_restart "$dir" '
printf "%s\n" "${VNT2_RESTART_MODE:-}" >"$MOCK_STATE_DIR/mode"
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
touch "$MOCK_STATE_DIR/entered"
sleep 2
'

	MOCK_STATE_DIR="$dir" \
	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND="$dir/mock-restart" \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	remaining=10
	while [ ! -f "$dir/entered" ] && [ "$remaining" -gt 0 ]; do
		sleep 1
		remaining=$((remaining - 1))
	done
	[ -f "$dir/entered" ] || fail "first restart did not begin"
	mode="$(cat "$dir/mode" 2>/dev/null || true)"
	[ "$mode" = "apply" ] || fail "restart mode was not isolated from normal stop cleanup"

	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 12 || fail "request received during restart was lost"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 2 20 3 ||
		fail "second restart did not complete"

	starts="$(log_count "$dir/log" 'worker starts queued restart')"
	completed="$(log_count "$dir/log" 'worker completed queued restart')"
	[ "$starts" -eq 2 ] || fail "expected 2 starts, got $starts"
	[ "$completed" -eq 2 ] || fail "expected 2 completions, got $completed"
	[ ! -e "$dir/pending" ] || fail "second run left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "second run left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a request received during restart was retained\n'
}

# A marker written with leading zeros used to abort the whole worker loop,
# because dash evaluates "08" as an invalid octal number inside $(( )).
test_leading_zero_timestamp_marker() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	printf '%016d\n' "$(date +%s)" >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 20 3 ||
		fail "zero padded timestamp marker was not processed"
	[ ! -e "$dir/claimed" ] || fail "zero padded marker left a claimed marker"

	# The worker must still be alive and serve the next request.
	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 2 20 3 ||
		fail "worker did not survive a zero padded timestamp marker"
	[ ! -e "$dir/pending" ] || fail "second request left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "second request left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: zero padded timestamp marker is handled without crashing\n'
}

# A worker that dies mid-request leaves the claimed marker behind. The
# replacement process has to finish that request instead of dropping it.
test_recovers_pre_existing_claimed_marker() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	printf '%s\n' "$(date +%s)" >"$dir/claimed"

	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 20 3 ||
		fail "pre-existing claimed marker was not recovered"
	[ ! -e "$dir/claimed" ] || fail "recovered request left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a pre-existing claimed marker is recovered after a crash\n'
}

# A failing restart command must not silently drop the request: the claimed
# marker survives and the command is retried with a growing backoff.
test_failed_restart_is_retried() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	make_mock_restart "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
[ "$count" -ge 2 ] || exit 1
'

	MOCK_STATE_DIR="$dir" \
	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND="$dir/mock-restart" \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
	VNT2_RESTART_RETRY_BACKOFF="1 1 1" \
	VNT2_RESTART_RETRY_LIMIT=3 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 20 || fail "failed restart was not retried"
	wait_for_log_count "$dir/log" 'worker restart retry 1 scheduled in 1s' 1 20 3 ||
		fail "failed restart did not schedule a retry"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 20 3 ||
		fail "retried restart did not complete"
	[ ! -e "$dir/claimed" ] || fail "retried restart left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a failed restart is retried before it is abandoned\n'
}

# When every retry fails the request is abandoned with an explicit log entry
# and the claimed marker is removed so the worker can serve the next request.
test_restart_is_abandoned_after_retries() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	make_mock_restart "$dir" '
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '"'"'0'"'"')"
count=$((count + 1))
printf "%s\n" "$count" >"$MOCK_STATE_DIR/count"
exit 1
'

	MOCK_STATE_DIR="$dir" \
	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND="$dir/mock-restart" \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
	VNT2_RESTART_RETRY_BACKOFF="1 1 1" \
	VNT2_RESTART_RETRY_LIMIT=2 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker restart abandoned after 2 retries' 1 30 3 ||
		fail "failing restart was never abandoned"
	[ ! -e "$dir/claimed" ] || fail "abandoned request left a claimed marker"
	[ "$(cat "$dir/count")" -eq 3 ] || fail "expected 3 attempts, got $(cat "$dir/count")"

	# The worker must keep serving requests after an abandoned one.
	make_mock_restart "$dir" 'exit 0'
	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 30 3 ||
		fail "worker did not recover after an abandoned request"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a restart that keeps failing is abandoned and logged\n'
}

# Non numeric tuning values must not break the loop or turn it into a busy loop.
test_non_numeric_tuning_is_sanitized() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=soon \
	VNT2_RESTART_POLL_INTERVAL=-1 \
	VNT2_RESTART_RETRY_LIMIT=many \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	wait_for_log_count "$dir/log" 'worker completed queued restart' 1 20 3 ||
		fail "worker did not run with sanitized tuning values"
	[ -s "$dir/log" ] || fail "worker produced no log output"
	case "$(sed -n '1p' "$dir/log")" in
		*'restart : '*) ;;
		*) fail "worker log prefix is not 'restart :'" ;;
	esac

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: non numeric tuning values fall back to defaults\n'
}

test_debounce
test_request_during_restart
test_leading_zero_timestamp_marker
test_recovers_pre_existing_claimed_marker
test_failed_restart_is_retried
test_restart_is_abandoned_after_retries
test_non_numeric_tuning_is_sanitized
printf 'restart-worker tests passed\n'

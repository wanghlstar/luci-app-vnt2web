#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKER="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/upload-worker"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# GNU tar rewrites archived member names with --transform, while bsdtar uses -s
# and takes the substitution delimiter as the first character of the pattern.
# Developers run these tests on macOS and CI runs on Ubuntu, so both dialects
# have to work; a silently skipped tar command would drop the whole check.
tar_rewrite_args() {
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then
		TAR_REWRITE_ARGS="--transform=s|$1|$2|"
	else
		TAR_REWRITE_ARGS="-s |$1|$2|"
	fi
}

# e_machine values for the architectures the worker can identify, written as
# printf escapes so the NUL bytes never have to pass through a variable.
host_elf_machine() {
	case "$(uname -m 2>/dev/null)" in
		x86_64|amd64) printf '%s' '\076\000' ;;
		i386|i486|i586|i686) printf '%s' '\003\000' ;;
		aarch64|arm64) printf '%s' '\267\000' ;;
		armv7*|armv6*|arm*) printf '%s' '\050\000' ;;
		mips*) printf '%s' '\010\000' ;;
		riscv64*|riscv*) printf '%s' '\363\000' ;;
		*) return 1 ;;
	esac
}

foreign_elf_machine() {
	case "$(uname -m 2>/dev/null)" in
		x86_64|amd64|i386|i486|i586|i686) printf '%s' '\267\000' ;;
		*) printf '%s' '\076\000' ;;
	esac
}

# Writes a minimal but complete 20 byte ELF header. The worker validates the
# e_machine field against the router architecture, so a magic-only fixture is
# no longer enough.
make_elf() {
	path="$1"
	machine="${2:-}"

	if [ -z "$machine" ]; then
		machine="$(host_elf_machine)" || return 1
	fi
	printf '\177ELF\002\001\001\000' >"$path"
	printf '\000\000\000\000\000\000\000\000' >>"$path"
	printf '\002\000' >>"$path"
	printf '%b' "$machine" >>"$path"
}

stop_worker() {
	if [ -f "$1/pid" ]; then
		kill "$(cat "$1/pid")" 2>/dev/null || true
		wait "$(cat "$1/pid")" 2>/dev/null || true
	fi
}

start_worker() {
	dir="$1"
	VNT2_UPLOAD_PENDING_FILE="$dir/upload.pending" \
	VNT2_UPLOAD_CLAIMED_FILE="$dir/upload.claimed" \
	VNT2_UPLOAD_DIR="$dir/upload" \
	VNT2_UPLOAD_LOG_FILE="$dir/download.log" \
	VNT2_UPLOAD_STATE_FILE="$dir/web.state" \
	VNT2_VERSION_STATE_FILE="$dir/web.version" \
	VNT2_INSTALL_BIN_DIR="$dir/bin" \
	VNT2_RESTART_PENDING_FILE="$dir/restart.pending" \
	VNT2_UPLOAD_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"
}

queue_file() {
	dir="$1"
	src="$2"
	name="$3"

	# Wait until the worker has finished any previous request. The worker writes
	# one shared state file, so queuing too early could make this request observe
	# the previous request's terminal state.
	remaining=10
	while [ "$remaining" -gt 0 ]; do
		if [ ! -e "$dir/upload.pending" ] && [ ! -e "$dir/upload.claimed" ]; then
			break
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	[ ! -e "$dir/upload.claimed" ] || fail "worker did not become idle before the next upload"

	counter="$(cat "$dir/counter" 2>/dev/null || printf '0')"
	counter=$((counter + 1))
	printf '%s\n' "$counter" >"$dir/counter"
	staged="$dir/upload/incoming.$counter"
	mkdir -p "$dir/upload"
	cp "$src" "$staged"
	# LuCI queues uploads with an atomic rename, so mirror that here. Writing the
	# pending marker in place could let the worker claim a half-written file.
	cat >"$dir/upload.pending.tmp" <<EOF
time=$(date +%s)
path=$staged
name=$name
size=$(wc -c <"$src" | tr -d '[:space:]')
EOF
	mv -f "$dir/upload.pending.tmp" "$dir/upload.pending"
	rm -f "$dir/web.state"
}

wait_for_state() {
	file="$1"
	wanted="$2"
	remaining="${3:-10}"

	while [ "$remaining" -gt 0 ]; do
		if [ -f "$file" ] && [ "$(sed -n 's/^state=//p' "$file" | head -n1)" = "$wanted" ]; then
			return 0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

state_message() {
	sed -n 's/^message=//p' "$1" 2>/dev/null | head -n1
}

test_worker_installs_only_valid_uploads() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	mkdir -p "$dir/upload/work.stale" "$dir/bin"
	printf 'stale\n' >"$dir/upload/work.stale/leftover"
	printf 'stale\n' >"$dir/web.version"

	make_elf "$dir/vnt2_web"
	start_worker "$dir"

	# The worker clears abandoned extraction directories on startup.
	remaining=10
	while [ -d "$dir/upload/work.stale" ] && [ "$remaining" -gt 0 ]; do
		sleep 1
		remaining=$((remaining - 1))
	done
	[ ! -d "$dir/upload/work.stale" ] || fail "stale work directory was not cleaned up"

	# A marker that points outside the staging directory must be rejected.
	# LuCI writes the marker with an atomic rename, so mirror that here.
	cat >"$dir/upload.pending.tmp" <<EOF
time=$(date +%s)
path=/tmp/evil-vnt2_web
name=vnt2_web
size=7
EOF
	mv -f "$dir/upload.pending.tmp" "$dir/upload.pending"
	rm -f "$dir/web.state"
	wait_for_state "$dir/web.state" failed 10 || fail "out-of-directory upload was not rejected"
	case "$(state_message "$dir/web.state")" in
		*'invalid staged path'*) ;;
		*) fail "out-of-directory upload produced an unexpected message" ;;
	esac

	# A staged path that walks out of the staging directory is rejected even
	# though it still carries the incoming prefix.
	cat >"$dir/upload.pending.tmp" <<EOF
time=$(date +%s)
path=${dir}/upload/incoming.1/../../evil
name=vnt2_web
size=7
EOF
	mv -f "$dir/upload.pending.tmp" "$dir/upload.pending"
	rm -f "$dir/web.state"
	wait_for_state "$dir/web.state" failed 10 || fail "parent traversal staged path was not rejected"
	case "$(state_message "$dir/web.state")" in
		*'invalid staged path'*) ;;
		*) fail "parent traversal staged path produced an unexpected message" ;;
	esac

	# Directory traversal, Windows drive paths and absolute paths are rejected.
	tar_rewrite_args '^' '../'
	tar -czf "$dir/traversal.tar.gz" -C "$dir" $TAR_REWRITE_ARGS vnt2_web ||
		fail "could not build the traversal archive"
	queue_file "$dir" "$dir/traversal.tar.gz" "traversal.tar.gz"
	wait_for_state "$dir/web.state" failed 10 || fail "traversal archive was accepted"

	tar_rewrite_args '^vnt2_web$' 'C:/evil'
	tar -czf "$dir/windows.tar.gz" -C "$dir" $TAR_REWRITE_ARGS vnt2_web ||
		fail "could not build the Windows drive archive"
	queue_file "$dir" "$dir/windows.tar.gz" "windows.tar.gz"
	wait_for_state "$dir/web.state" failed 10 || fail "Windows drive archive was accepted"

	tar_rewrite_args '^vnt2_web$' '/etc/vnt2_web'
	tar -czPf "$dir/absolute.tar.gz" -C "$dir" $TAR_REWRITE_ARGS vnt2_web ||
		fail "could not build the absolute path archive"
	queue_file "$dir" "$dir/absolute.tar.gz" "absolute.tar.gz"
	wait_for_state "$dir/web.state" failed 10 || fail "absolute path archive was accepted"

	# A binary built for another architecture must be refused before install.
	make_elf "$dir/foreign_arch_vnt2_web" "$(foreign_elf_machine)"
	queue_file "$dir" "$dir/foreign_arch_vnt2_web" "vnt2_web"
	wait_for_state "$dir/web.state" failed 10 || fail "foreign architecture upload was accepted"
	case "$(state_message "$dir/web.state")" in
		*'targets'*'router'*) ;;
		*) fail "foreign architecture upload produced an unexpected message: $(state_message "$dir/web.state")" ;;
	esac

	# Zip uploads cannot be inspected safely, so they must fail with a clear
	# message instead of falling through to the raw binary branch.
	printf 'PK\003\004zip\n' >"$dir/package.zip"
	queue_file "$dir" "$dir/package.zip" "package.zip"
	wait_for_state "$dir/web.state" failed 10 || fail "zip upload was accepted"
	case "$(state_message "$dir/web.state")" in
		*'zip archives are not supported'*) ;;
		*) fail "zip upload produced an unexpected message" ;;
	esac

	# Archives without vnt2_web, non-ELF files and corrupt archives are rejected.
	mkdir -p "$dir/empty"
	printf 'readme\n' >"$dir/empty/readme.txt"
	( cd "$dir/empty" && tar -czf "$dir/missing.tar.gz" readme.txt )
	queue_file "$dir" "$dir/missing.tar.gz" "missing.tar.gz"
	wait_for_state "$dir/web.state" failed 10 || fail "archive without vnt2_web was accepted"

	printf 'not an elf\n' >"$dir/plain.bin"
	queue_file "$dir" "$dir/plain.bin" "vnt2_web"
	wait_for_state "$dir/web.state" failed 10 || fail "non-ELF upload was accepted"

	printf 'not a gzip archive\n' >"$dir/corrupt.tar.gz"
	queue_file "$dir" "$dir/corrupt.tar.gz" "corrupt.tar.gz"
	wait_for_state "$dir/web.state" failed 10 || fail "corrupt archive was accepted"

	[ ! -e "$dir/bin/vnt2_web" ] || fail "rejected uploads must not install a binary"

	# Links and special files must be rejected when the platform can create them.
	mkdir -p "$dir/link_src"
	if ln -s /etc/passwd "$dir/link_src/vnt2_web" 2>/dev/null && [ -L "$dir/link_src/vnt2_web" ]; then
		( cd "$dir/link_src" && tar -czf "$dir/link.tar.gz" vnt2_web )
		queue_file "$dir" "$dir/link.tar.gz" "link.tar.gz"
		wait_for_state "$dir/web.state" failed 10 || fail "symlink archive was accepted"
		printf 'PASS: symlink archive was rejected\n'
	else
		printf 'SKIP: symlink archive case is not supported on this platform\n'
	fi

	if command -v mkfifo >/dev/null 2>&1 && mkfifo "$dir/link_src/vnt2fifo" 2>/dev/null; then
		( cd "$dir/link_src" && tar -czf "$dir/fifo.tar.gz" vnt2fifo )
		queue_file "$dir" "$dir/fifo.tar.gz" "fifo.tar.gz"
		wait_for_state "$dir/web.state" failed 10 || fail "FIFO archive was accepted"
		printf 'PASS: special file archive was rejected\n'
	else
		printf 'SKIP: FIFO archive case is not supported on this platform\n'
	fi

	# A valid single binary is installed atomically and queues a restart.
	queue_file "$dir" "$dir/vnt2_web" "vnt2_web"
	wait_for_state "$dir/web.state" success 10 || fail "valid ELF upload was not installed"
	[ -f "$dir/bin/vnt2_web" ] || fail "valid ELF upload was not copied to the install directory"
	if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
		[ "$(stat -c '%a' "$dir/bin/vnt2_web")" = "755" ] || \
			fail "installed binary does not have mode 0755"
		[ -x "$dir/bin/vnt2_web" ] || fail "installed binary is not executable"
	else
		cmp -s "$dir/vnt2_web" "$dir/bin/vnt2_web" || \
			fail "installed binary content does not match the uploaded file"
	fi
	[ ! -e "$dir/web.version" ] || fail "stale version sidecar was not cleared after an upload"
	[ -s "$dir/restart.pending" ] || fail "successful install did not queue a restart"
	case "$(sed -n '1p' "$dir/restart.pending")" in
		''|*[!0-9]*) fail "restart marker does not contain a timestamp" ;;
	esac
	[ ! -e "$dir/upload/incoming.1" ] || fail "staged upload was not removed after install"
	[ ! -e "$dir/upload.pending" ] || fail "pending marker was not claimed"
	[ ! -e "$dir/upload.claimed" ] || fail "claimed marker was not removed"

	# A nested archive is accepted and its vnt2_web entry is installed.
	mkdir -p "$dir/nested/pkg"
	make_elf "$dir/nested/pkg/vnt2_web"
	( cd "$dir/nested" && tar -czf "$dir/nested.tar.gz" pkg )
	queue_file "$dir" "$dir/nested.tar.gz" "nested.tar.gz"
	wait_for_state "$dir/web.state" success 10 || fail "nested archive was not installed"
	[ -f "$dir/bin/vnt2_web" ] || fail "nested archive did not install vnt2_web"

	# Archive detection must not depend on lower-case extensions.
	queue_file "$dir" "$dir/nested.tar.gz" "NESTED.TAR.GZ"
	wait_for_state "$dir/web.state" success 10 || fail "upper-case archive extension was not treated as an archive"
	[ -f "$dir/bin/vnt2_web" ] || fail "upper-case archive did not install vnt2_web"

	# tar.xz archives are validated and installed like tar.gz archives. bsdtar
	# has liblzma built in while GNU tar shells out to xz, so probe first.
	if tar -cJf "$dir/probe.tar.xz" -C "$dir" vnt2_web >/dev/null 2>&1 && [ -s "$dir/probe.tar.xz" ]; then
		queue_file "$dir" "$dir/probe.tar.xz" "nested.tar.xz"
		wait_for_state "$dir/web.state" success 10 || fail "tar.xz archive was not installed"
		[ -f "$dir/bin/vnt2_web" ] || fail "tar.xz archive did not install vnt2_web"
		printf 'PASS: tar.xz archive was installed\n'

		# A tar.xz archive that escapes the staging directory is rejected too.
		tar_rewrite_args '^' '../'
		tar -cJf "$dir/traversal.tar.xz" -C "$dir" $TAR_REWRITE_ARGS vnt2_web ||
			fail "could not build the tar.xz traversal archive"
		queue_file "$dir" "$dir/traversal.tar.xz" "traversal.tar.xz"
		wait_for_state "$dir/web.state" failed 10 || fail "tar.xz traversal archive was accepted"
		case "$(state_message "$dir/web.state")" in
			*'invalid tar.xz archive'*) ;;
			*) fail "tar.xz traversal archive produced an unexpected message" ;;
		esac
		printf 'PASS: unsafe tar.xz archive was rejected\n'
	else
		printf 'SKIP: tar.xz is not available on this platform\n'
	fi

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: uploads are validated, installed and queued for restart\n'
}

test_worker_installs_only_valid_uploads
printf 'upload-worker tests passed\n'

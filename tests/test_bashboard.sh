#!/usr/bin/env bash
# Mock callbacks below are invoked indirectly by the sourced application.
# shellcheck disable=SC2329
# shellcheck source-path=SCRIPTDIR
set -u
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app="$root/bashboard.sh"
# shellcheck source=../bashboard.sh
source "$app"
tmp_root=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$tmp_root/bashboard-tests.XXXXXXXX")
passed=0
finish_tests() {
    cleanup
    case "$test_dir" in "$tmp_root"/bashboard-tests.*) rm -rf -- "$test_dir" ;; esac
}
trap finish_tests EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3: expected <$1>, got <$2>"; }
check_rc() {
    local expected="$1" actual
    shift
    if "$@" > "$test_dir/stdout" 2> "$test_dir/stderr"; then actual=0; else actual=$?; fi
    equal "$expected" "$actual" "exit code: $*"
}
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
new_runtime() { runtime_dir=$(mktemp -d "$test_dir/run.XXXXXXXX"); }

check_rc 0 bash -n "$app"
check_rc 0 bash "$app" --help
grep -Fq -- '--jobs' "$test_dir/stdout" || fail 'help does not explain jobs'
check_rc 0 bash "$app" --version
grep -Fq 'BashBoard 1.0' "$test_dir/stdout" || fail 'version missing'
pass 'syntax, help, and version'

for arguments in '--jobs 0' '--jobs 33' '--jobs abc' '--jobs' '--timeout 31' '--interval 0' '--unknown'; do
    read -r -a bad_args <<< "$arguments"
    check_rc 2 bash "$app" "${bad_args[@]}"
done
pass 'invalid CLI arguments fail before probing'

printf '%s' $'# example configuration\r\nname\thost\tport\tprotocol\r\nAPI % service\t127.0.0.1\t0080\thttp\r\nSSH server\t127.0.0.1\t22\tssh' > "$test_dir/valid.tsv"
check_rc 0 parse_config_file "$test_dir/valid.tsv"
equal 2 "${#service_names[@]}" 'row count'
equal 80 "${service_ports[0]}" 'decimal port'
equal 'API % service' "${service_names[0]}" 'name preserved'
check_rc 0 parse_config_file "$test_dir/valid.tsv"
equal 2 "${#service_names[@]}" 'reparse did not duplicate rows'
check_rc 0 bash "$app" --check-config "$test_dir/valid.tsv"
pass 'CRLF, comments, spaces, percent signs, leading zero, final line, repeated parsing'

for row in \
    $'Bad\t\t80\ttcp' $'Bad\tbad host\t80\ttcp' $'Bad\t-host\t80\ttcp' \
    $'Bad\t127.0.0.1\t0\ttcp' $'Bad\t127.0.0.1\t99999\ttcp' \
    $'Bad\t127.0.0.1\tabc\ttcp' $'Bad\t127.0.0.1\t80\tbogus' \
    $'Bad\t127.0.0.1\t80\ttcp\textra' $'Bad\033[31m\t127.0.0.1\t80\ttcp' \
    $'Bad\thttp://localhost\t80\thttp' $'   \t127.0.0.1\t80\thttp'; do
    printf '%s\n' "$row" > "$test_dir/bad.tsv"
    check_rc 1 parse_config_file "$test_dir/bad.tsv"
    equal 2 "${#service_names[@]}" 'failed parse preserved previous configuration'
done
printf 'name\thost\tport\tprotocol\n' > "$test_dir/empty.tsv"
check_rc 1 parse_config_file "$test_dir/empty.tsv"
check_rc 2 bash "$app" --check-config "$test_dir/missing.tsv"
pass 'invalid configuration is rejected without publishing partial arrays'

original_probe_row=$(declare -f probe_row)
probe_row() {
    local index="$1" host_rc=0 state_rc=0
    printf 'start\n' >> "$test_dir/events"
    # Different durations deliberately complete rows out of order.
    if (( index % 2 )); then sleep 0.12; else sleep 0.3; fi
    case "$index" in 1) host_rc=1 ;; 2) state_rc=1 ;; 3) state_rc=2 ;; esac
    printf '%s\t%s\t200\trow%s\n' "$host_rc" "$state_rc" "$index" > "$runtime_dir/$index.result"
    printf 'end\n' >> "$test_dir/events"
}
service_names=(); service_hosts=(); service_ports=(); service_protocols=()
for ((i=0; i<8; i++)); do
    service_names+=("Service $i"); service_hosts+=(127.0.0.1); service_ports+=(80); service_protocols+=(http)
done
new_runtime
: > "$test_dir/events"
jobs_limit=3
check_rc 0 collect_snapshot
[[ ! -s "$test_dir/stdout" ]] || fail 'collector rendered output'
equal 8 "${#snapshot_status[@]}" 'complete snapshot'
equal No "${snapshot_reachable[1]}" 'blocked ICMP'
equal UP "${snapshot_status[1]}" 'service works even when ICMP does not'
equal DOWN "${snapshot_status[2]}" 'down state'
equal ERROR "${snapshot_status[3]}" 'error state'
for ((i=0; i<8; i++)); do equal "row$i" "${snapshot_detail[$i]}" 'stable result order'; done
peak=$(awk '$1=="start" { n++; if(n>m)m=n } $1=="end" { n-- } END { print m+0 }' "$test_dir/events")
(( peak > 1 && peak <= 3 )) || fail "worker cap broken: peak=$peak"
equal 0 "${#active_workers[@]}" 'all workers reaped'
check_rc 2 snapshot_exit_code
pass 'bounded concurrency, out-of-order completion, stable rows, independent ICMP/service status'

probe_row() {
    (( $1 == 2 )) && return 19
    printf '0\t0\t1\tfast%s\n' "$1" > "$runtime_dir/$1.result"
}
snapshot_status[99]=stale
jobs_limit=32
check_rc 0 collect_snapshot
equal 8 "${#snapshot_status[@]}" 'stale entries removed'
equal ERROR "${snapshot_status[2]}" 'crashed worker is not stale UP'
equal 'Worker failed' "${snapshot_detail[2]}" 'crashed worker diagnostic'
pass 'fast jobs, worker failures, and stale snapshot removal'

probe_row() { sleep 0.3; printf '0\t0\t300\tbenchmark\n' > "$runtime_dir/$1.result"; }
jobs_limit=1
check_rc 0 collect_snapshot
serial_ms=$scan_ms
jobs_limit=4
check_rc 0 collect_snapshot
parallel_ms=$scan_ms
(( parallel_ms * 100 < serial_ms * 85 )) || fail "parallel scan did not improve: $serial_ms -> $parallel_ms ms"
printf 'BENCHMARK: 8 simulated services: serial=%s ms, 4 workers=%s ms\n' "$serial_ms" "$parallel_ms"
pass 'parallel collection improves measured scan time'
eval "$original_probe_row"

no_color=1; LAVENDER='' MUTED='' GREEN='' RED='' YELLOW='' RESET=''
terminal_active=0
check_rc 0 render_dashboard
grep -Fq 'Service 7' "$test_dir/stdout" || fail 'plain output lost rows'
grep -Fq $'\033' "$test_dir/stdout" && fail 'plain output contains ANSI codes'
tput() { if [[ "$1" == cols ]]; then printf '80\n'; else printf '10\n'; fi; }
terminal_active=1
check_rc 0 render_dashboard
grep -Fq 'Showing 4/8' "$test_dir/stdout" || fail 'small-terminal row limit missing'
tput() { if [[ "$1" == cols ]]; then printf '60\n'; else printf '10\n'; fi; }
check_rc 0 render_dashboard
grep -Fq 'Resize to at least 70 columns' "$test_dir/stdout" || fail 'narrow-terminal guidance missing'
terminal_active=0
unset -f tput
pass 'plain output, viewport limit, and narrow-terminal handling'

original_run_tool=$(declare -f run_tool)
worker_prefix="$runtime_dir/decoder"
fake_tool_rc=0 fake_response=200
run_tool() { printf '%s\n' "$fake_response" > "$worker_prefix.out"; return "$fake_tool_rc"; }
check_rc 0 probe_service 127.0.0.1 80 http
equal 'HTTP 200' "$check_detail" 'HTTP response detail'
fake_response=503; fake_tool_rc=22
check_rc 1 probe_service 127.0.0.1 80 http
equal 'HTTP 503' "$check_detail" 'failed HTTP detail'
fake_tool_rc=60
check_rc 1 probe_service 127.0.0.1 443 https
equal 'TLS check failed' "$check_detail" 'TLS detail'
fake_tool_rc=0; fake_response=203.0.113.1
check_rc 0 probe_service 127.0.0.1 53 dns
fake_response=NXDOMAIN
check_rc 1 probe_service 127.0.0.1 53 dns
fake_response='127.0.0.1 ssh-ed25519 FAKE_KEY'
check_rc 0 probe_service 127.0.0.1 22 ssh
os=MINGW64_NT; fake_response='Reply from 127.0.0.1: bytes=32 time<1ms TTL=128'
check_rc 0 probe_host 127.0.0.1
fake_response='Reply from 192.0.2.1: Destination host unreachable.'
check_rc 1 probe_host 192.0.2.2
eval "$original_run_tool"
pass 'protocol responses and Windows unreachable messages are classified correctly'

worker_prefix="$runtime_dir/deadline"; probe_timeout=1
check_rc 2 run_tool this-bashboard-command-does-not-exist
equal 'Missing this-bashboard-command-does-not-exist' "$check_detail" 'missing tool diagnostic'
start=$(now_ms)
check_rc 1 run_tool bash -c 'sleep 30'
elapsed=$(( $(now_ms) - start ))
equal 'Timed out' "$check_detail" 'deadline diagnostic'
(( elapsed < 5000 )) || fail "deadline took too long: ${elapsed}ms"
pass 'missing dependencies and hard tool deadlines'
cleanup

# A separate process tests cleanup while a real worker is waiting on a local tool.
cat > "$test_dir/interrupt.sh" <<'INTERRUPT'
#!/usr/bin/env bash
source "$1"
runtime_dir=$(mktemp -d "$2/interrupt.XXXXXXXX")
printf '%s\n' "$runtime_dir" > "$2/runtime-path"
probe_timeout=30
service_names=(Hanging); service_hosts=(127.0.0.1); service_ports=(80); service_protocols=(http)
probe_host() { return 0; }
fixture_dir="$2"
probe_service() { run_tool bash -c 'printf "%s\n" "$BASHPID" > "$1"; exec sleep 30' _ "$fixture_dir/hanging-pid"; }
trap cleanup EXIT
trap 'exit 143' TERM
collect_snapshot
INTERRUPT
bash "$test_dir/interrupt.sh" "$app" "$test_dir" > "$test_dir/interrupt.out" 2> "$test_dir/interrupt.err" &
interrupted_pid=$!
for ((attempt=0; attempt<100; attempt++)); do [[ -s "$test_dir/hanging-pid" ]] && break; sleep 0.05; done
[[ -s "$test_dir/hanging-pid" ]] || fail 'interrupt fixture did not start'
kill -TERM "$interrupted_pid"
if wait "$interrupted_pid"; then fail 'interrupted app returned success'; fi
hanging_pid=$(< "$test_dir/hanging-pid")
if kill -0 "$hanging_pid" 2> /dev/null; then fail 'probe process survived cleanup'; fi
interrupted_dir=$(< "$test_dir/runtime-path")
[[ ! -d "$interrupted_dir" ]] || fail 'runtime directory survived cleanup'
pass 'interruption stops workers/tools and removes temporary files'

printf '\nAll %s test groups passed. No external services were contacted.\n' "$passed"

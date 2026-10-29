# Running BashBoard v1.0

BashBoard checks network services in parallel, collects a complete snapshot, and draws it in your terminal. The previous frame stays visible while the next scan runs.

## Requirements

- Bash **5.1 or newer** on Linux or Git Bash for Windows. The worker pool uses `wait -n -p`.
- Coreutils-compatible utilities, including `timeout` with `--kill-after`, `mktemp`, `rm`, and `rmdir`. GNU coreutils and Ubuntu's compatible coreutils are supported.
- A terminal supporting ANSI control sequences for the full-screen dashboard. `--plain` works without them.
- The tools needed by your configured checks:

| Check | Linux | Git Bash on Windows |
| --- | --- | --- |
| ICMP | `ping` | Windows `ping.exe` |
| TCP | `nc` with `-z -w` support | Nmap `ncat.exe` |
| HTTP / HTTPS | `curl` | `curl` |
| DNS | BIND-compatible `dig` | BIND-compatible `dig` |
| SSH | `ssh-keyscan` | `ssh-keyscan` |

Git Bash includes Bash, coreutils, curl, and OpenSSH utilities. Install Nmap/Ncat separately and make `ncat.exe` available in `PATH`. If `dig` is unavailable, DNS checks show `ERROR: Missing dig`; other services can still be checked.

For example, on Ubuntu/Debian:

```bash
sudo apt update
sudo apt install bash coreutils curl iputils-ping netcat-openbsd dnsutils openssh-client
```

macOS, BusyBox tools, and older Bash versions are not supported in this release.

## First run

```bash
git clone https://github.com/fistoook/BashBoard.git
cd BashBoard
cp config.tsv inventory.tsv
```

Edit `inventory.tsv` to describe your homelab. This filename is already ignored by Git, so your personal inventory stays out of normal commits. The bundled `config.tsv` is a public demonstration inventory and includes intentionally failing checks.

Validate without contacting any services:

```bash
bash bashboard.sh --check-config inventory.tsv
```

Start the dashboard:

```bash
bash bashboard.sh --config inventory.tsv --jobs 4 --timeout 3 --interval 2
```

The small `bashboard` launcher also supports the README's `./bashboard` spelling after `chmod +x bashboard`. Both entry points accept the same arguments. A supplied relative config path is relative to your current directory; the default `config.tsv` is resolved beside the script.

## Configuration

Use real tabs, with these four required columns:

```text
name<TAB>host<TAB>port<TAB>protocol
Plex<TAB>192.168.1.20<TAB>32400<TAB>http
NAS SSH<TAB>192.168.1.30<TAB>22<TAB>ssh
AdGuard DNS<TAB>192.168.1.40<TAB>53<TAB>dns
```

`<TAB>` above describes a tab character. To create a tiny example with actual tabs:

```bash
printf 'name\thost\tport\tprotocol\nPlex\t192.168.1.20\t32400\thttp\n' > inventory.tsv
```

- Supported protocols: `tcp`, `http`, `https`, `dns`, `ssh`.
- Ports are decimal integers from 1 to 65535. Leading zeroes are normalized.
- Host is an IP address or hostname, without a URL scheme, path, or whitespace.
- Blank lines and lines beginning with `#` are skipped. The exact header is optional.
- Windows CRLF files and a final line without a newline are accepted.
- A bad row reports its line number and stops startup. A failed parse does not publish partial configuration arrays.

## Options

| Option | Meaning |
| --- | --- |
| `--config FILE`, `-c FILE`, or positional `FILE` | Choose a TSV file |
| `--jobs N`, `-j N` | At most 1-32 concurrent service workers; default 4 |
| `--timeout SEC`, `-t SEC` | 1-30 seconds per ICMP/service probe; default 3 |
| `--interval SEC`, `-i SEC` | Pause 1-3600 seconds after a completed scan; default 2 |
| `--once` | Print one complete snapshot and exit |
| `--plain` | Plain text without colors or full-screen control |
| `--no-color` | Keep the dashboard but disable colors |
| `--check-config` | Validate only, without network checks |
| `--help`, `-h` | Show help |
| `--version` | Show the version |

Redirected output automatically uses one plain snapshot:

```bash
bash bashboard.sh --once --plain inventory.tsv > snapshot.txt
```

The default interactive dashboard uses an alternate screen and hides the cursor. Ctrl+C stops workers, cleans temporary results, restores the cursor, and returns to your previous terminal screen. Small windows show the rows that fit; `--once` includes all rows without truncating their names or details.

## Reading the results

- **ICMP Yes / No / Error** describes the host's Echo check. Windows uses IPv4 Echo replies to avoid treating an unreachable message as a successful ping.
- **UP / DOWN / ERROR** describes the service. Blocked ICMP does not prevent a service from being UP.
- **MS** is the elapsed time for that service's ICMP and protocol checks together.
- **DETAIL** explains a result, such as `HTTP 200`, `HTTP 503`, `Timed out`, `TLS check failed`, or `Missing dig`.
- The header timestamp and scan duration describe the most recently completed snapshot.

Each worker checks ICMP and then the service. The `timeout` utility bounds each entire tool invocation, including name resolution, with up to one additional second for forced termination. Four workers can check four services at once. The refresh interval is a pause after collection, not a promise to finish a scan every two seconds.

HTTP/S checks request `/`. A 2xx or 3xx response is UP; redirects are not followed. HTTPS certificate verification remains enabled. For an internal CA, configure curl's trust store, for example through `CURL_CA_BUNDLE`.

DNS checks request an `example.com` A record from the configured server and port. A resolver that intentionally blocks this query will show DOWN. SSH checks require a returned host key; they do not log in. TCP UP means a connection can be opened, not that application-level work is healthy.

## Exit codes

For `--once`:

- `0`: every service is UP, with no probe errors. ICMP No alone does not make an otherwise working service fail.
- `1`: at least one service is DOWN, with no probe errors.
- `2`: invalid arguments/configuration, an unsupported environment, or any service/ICMP probe ERROR.
- `130` / `143`: interrupted by SIGINT / SIGTERM respectively.

## Development checks

The app stays in Bash. The regression suite uses local fake probes, and the integration suite uses Python's standard library to host local HTTP endpoints:

```bash
bash tests/test_bashboard.sh
python3 tests/integration_http.py
```

On Windows, use `python` if `python3` is not available. The interactive Ctrl+C test runs on Linux; the remaining integration checks run on both supported platforms. No public servers or homelab devices are contacted by these tests.

## How the snapshot works

Configuration arrays share a service index. The parent starts at most `--jobs` child processes using `&`, reaps them with `wait -n -p`, and reads their result files in configuration order. Children cannot update the parent's arrays directly: Bash runs them with separate shell state. Only the parent publishes a new snapshot and renders it. This keeps rows stable even when checks finish in a different order.

Private temporary directories hold worker results and tool output. Cleanup stops active tools before removing those files. The terminal frame is assembled in memory and printed after collection; moving the cursor home avoids clearing the screen between every refresh.

## License

MIT, copyright 2026 fistook. See [LICENSE](../LICENSE).

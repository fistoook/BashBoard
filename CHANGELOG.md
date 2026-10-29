# Changelog

## v1.0

- Bounded parallel service workers, configurable with `--jobs`, with stable row order.
- Complete snapshots with scan time, per-service duration, and useful result details.
- A buffered full-screen dashboard with cursor restoration, terminal-size handling, and plain output.
- Deadlines for entire probe commands, plus cleanup of active workers and tools on interruption.
- `--help`, `--version`, `--config`, `--once`, `--check-config`, interval, timeout, and color options.
- Clear distinction between unhealthy services and checks that could not run.
- Transactional TSV validation, normalized decimal ports, comments, CRLF support, and paths relative to the script by default.
- A `bashboard` launcher, LF line-ending rules, setup documentation, and automated regression/integration checks.

## v0.4

- Separated configuration parsing, snapshot collection, and rendering.
- Collected all service results before replacing the dashboard.
- Added MIT licensing and README formatting.

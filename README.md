# CensorCheck by winq

`censorcheck.sh` is a live DNS, TLS, HTTP, and DPI reachability probe for Debian and Ubuntu.

The script is built to:

- check censorship-related reachability across a curated domain list;
- keep terminal output readable with progress feedback;
- send structured JSON results to a backend API;
- collect runtime and system metrics so the script can be improved and debugged more accurately over time.

## What gets reported

Each run can send:

- scan status and elapsed time;
- source IP and public IP;
- host name and kernel;
- result counts for `OK`, `BLOCKED`, `PARTIAL`, and total checks;
- full debug log;
- a system snapshot with:
  - CPU model and core count;
  - RAM usage and availability;
  - disk usage;
  - load average;
  - process count.

These metrics are meant for diagnostics and future tuning, not just for raw logging.

## Quick start

```bash
chmod +x censorcheck.sh
./censorcheck.sh
```

## Backend

The script sends JSON to the configured backend endpoint. Override the default with
`BACKEND_URL` if needed.

Example:

```bash
BACKEND_URL="http://185.17.0.25:25444/api/logs" ./censorcheck.sh
```

## Notes

- Optimized for Debian and Ubuntu.
- Includes a centered terminal banner and animated scan output.
- Each run gets its own `run_id`, so backend records stay separate.

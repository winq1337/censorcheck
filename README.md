# CensorCheck by winq

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![OS](https://img.shields.io/badge/Target-Debian%20%7C%20Ubuntu-2B4C7E?style=for-the-badge)
![Status](https://img.shields.io/badge/Release-stable-0F766E?style=for-the-badge)

`censorcheck.sh` is a live DNS, TLS, HTTP, and DPI reachability probe for Debian and Ubuntu.

It is built to stay practical:

- scan a curated censorship-oriented domain list;
- keep terminal output readable and animated;
- keep each run isolated with its own `run_id`.

## Highlights

- Clean centered banner and structured terminal output.
- Handles repeated runs without mixing logs.
- Captures machine context for better troubleshooting.
- Designed for Debian and Ubuntu out of the box.

## Quick Start

```bash
chmod +x censorcheck.sh
./censorcheck.sh
```

## What you get

- scan status and elapsed time;
- source IP and public IP;
- host name and kernel;
- counts for `OK`, `BLOCKED`, `PARTIAL`, and total checks;
- full debug log and preview output.

## Options

| Flag | Description |
| --- | --- |
| `-v`, `--verbose` | extra diagnostics |
| `-d`, `--debug` | print and log debug info |
| `--source-ip IPV4` | scan from a specific local IPv4 |
| `--proxy ADDR` | `http://host:port` or SOCKS5 `host:port` |
| `--install-deps` | install missing dependencies (root/sudo, apt/dnf/yum/pacman) |
| `--send-report URL` | opt-in: POST the run report to URL |
| `-h`, `--help` | usage |

Requires Bash 4+ and GNU `date`. Missing tools are no longer installed automatically.

## Privacy

Nothing leaves your machine by default. Reporting is opt-in:

```
./censorcheck.sh --send-report https://your-server/api/logs
```

With `--send-report`, the script POSTs the run logs, public/source IP, ASN, hostname, kernel and basic system stats (CPU, memory, disk, load) to the URL you give. Use HTTPS.

## Notes

- Optimized for Debian and Ubuntu.
- The output is intentionally compact, readable, and terminal-friendly.
- Each run gets its own `run_id`, so logs stay separate and traceable.

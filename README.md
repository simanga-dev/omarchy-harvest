# Harvest for Omarchy

An Omarchy shell bar widget for [Harvest](https://www.getharvest.com/) time tracking.
Start and stop timers, resume today's entries, and see your tracked time without
leaving the desktop. The panel follows your Omarchy theme.

## Install

```bash
omarchy plugin add https://github.com/simanga-dev/omarchy-harvest.git --enable
```

## Setup

1. Create a personal access token at <https://id.getharvest.com/developers>.
2. Open the Harvest widget on the bar and enter your account ID and token.

Credentials are stored locally in `~/.config/omarchy/harvest/credentials.json`
with owner-only permissions (`chmod 600`). They never leave your machine except
to authenticate with the Harvest API.

## Features

- Running timer and elapsed hours in the bar
- Start a timer from your assigned projects and tasks, with notes
- Stop the running timer, or resume any of today's entries
- Today's total, entry count and a connection indicator
- Optional background sync every 60 seconds (off by default)

## Requirements

- Omarchy with the Quickshell-based shell
- `python3` (standard library only)

## Tests

```bash
python3 -m unittest test_harvest
```

## License

MIT

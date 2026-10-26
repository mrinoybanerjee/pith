# Changelog

Notable changes to Pith, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-25

The first release. Pith is built from source; there is no download.

### Added

- A menu-bar dot: an outline when calm, amber when memory, CPU or storage is tight, and red when
  memory or storage is critical. It shows no numbers, and it changes only when the state changes.
- A panel that opens on a click: a status sentence; Memory, CPU and Storage tiles; the top 8 apps
  by Memory, CPU or Disk; and a "macOS system" row, always last.
- App grouping: each app's helper processes count toward that app, found through the responsible
  process, the app bundle or the parent chain.
- Opened rows: the app's processes grouped by role, each with its count and memory, and a plain
  explanation.
- "macOS system": the memory and CPU that your own processes leave unexplained. Opening it runs
  Apple's `top` once and names the 4 largest parts.
- Quit, with a confirm. Force Quit after 5 s, with a second confirm. Never for macOS processes,
  other users' apps or command-line processes.
- Pin: a floating panel on every Space, saved where you put it.
- Three settings: Launch at login, Refresh while open (2 s by default, or 1 s), and Dot turns
  amber on. Pith saves a setting only when you change it.
- A built-in guide of 187 checked entries. Each of its 103 macOS entries cites a source.
- Keyboard control, a VoiceOver sentence for each row and tile, and Reduce Motion support.
- Release gates: `scripts/perf.sh` for speed, `scripts/accuracy.sh` for accuracy against `top`,
  and `scripts/soak.sh` for 24 hours of running.
- Install from source with `scripts/build-app.sh` and `scripts/install.sh`, with the Command Line
  Tools only.

### Measured

Speed, with `scripts/perf.sh`. CPU is the mean share of one core, as `top` shows it. "Open" is the
default 2 s refresh. The Mac mini and the MacBook Air have 16 GB of memory; the MacBook Pro has
128 GB.

| Measure | Budget | Mac mini M4 | MacBook Air M4 | MacBook Pro M5 Max |
|---|---|---|---|---|
| CPU, panel closed | ≤ 0.1% | 0.03% | <!-- fill: air --> | <!-- fill: pro --> |
| CPU, panel closed, worst 60 s | ≤ 1% | 0.07% | <!-- fill: air --> | <!-- fill: pro --> |
| CPU, panel open | ≤ 1.5% | 1.09% | <!-- fill: air --> | <!-- fill: pro --> |
| CPU, panel open, worst 60 s | ≤ 5% | 1.48% | <!-- fill: air --> | <!-- fill: pro --> |
| Memory, panel closed | ≤ 30 MB | 21 MB | <!-- fill: air --> | <!-- fill: pro --> |
| Memory, panel open | ≤ 45 MB | 25 MB | <!-- fill: air --> | <!-- fill: pro --> |
| Wakeups per second, closed | ≤ 0.5 | 0.10 | <!-- fill: air --> | <!-- fill: pro --> |
| Wakeups per second, open | ≤ 2 | 0.52 | <!-- fill: air --> | <!-- fill: pro --> |
| Tools started | 0 | 0 | <!-- fill: air --> | <!-- fill: pro --> |
| One reading of all processes, mean of 200 | ≤ 3 ms | 0.87 ms | <!-- fill: air --> | <!-- fill: pro --> |
| Launch to first reading | ≤ 300 ms | 125 ms | <!-- fill: air --> | <!-- fill: pro --> |
| Click to panel on screen, slowest of 10 | ≤ 100 ms | 55 ms | <!-- fill: air --> | <!-- fill: pro --> |
| macOS | 15 or later | 26.6.2 | <!-- fill: air --> | <!-- fill: pro --> |

Accuracy, with `scripts/accuracy.sh`: Pith against `top`, for the same processes at the same
moment, for every app of 50 MB or more. CPU points are shares of the whole Mac.

| Check | Pass rule | Mac mini M4 | MacBook Air M4 | MacBook Pro M5 Max |
|---|---|---|---|---|
| Memory per app | within ±3% | pass, 2 of 2 runs | <!-- fill: air --> | <!-- fill: pro --> |
| CPU per app, over 10 s | within ±2 points | pass, largest gap 0.16 | <!-- fill: air --> | <!-- fill: pro --> |
| "macOS system" | never below zero | 100 of 100 readings | <!-- fill: air --> | <!-- fill: pro --> |

[0.1.0]: https://github.com/mrinoybanerjee/pith/releases/tag/v0.1.0

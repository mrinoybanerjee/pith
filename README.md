# Pith

What is using my Mac right now?

<p align="center">
  <img src="docs/images/panel-calm-light.png" width="440" alt="Pith's panel in light mode. The title says All calm. Tiles show 9.8 of 16 GB memory, 14% CPU and 112 GB free storage. Below, Google Chrome, Claude, Mail, Music and Finder are listed by memory, then macOS system.">
</p>

Pith is a free, open-source menu-bar app for Apple Silicon Macs. A calm dot sits in the menu
bar. Click it, and one small panel shows memory, CPU and storage, and the apps that use the most.
Each app's helper processes count toward that app, in one row. Pith is light enough to leave
running all day, and its numbers are checked against `top`.

## What it shows

- **The dot.** An outline when all is calm. Amber when memory, CPU or storage is tight. Red when
  memory or storage is critical. No numbers in the menu bar.
- **One sentence** that says what matters now, for example "Google Chrome uses the most: 6.4 GB
  across 41 processes."
- **Three tiles:** memory in use and memory pressure, CPU load, and free space on the startup disk.
- **The apps that use the most**, by Memory, CPU or Disk. Open a row to see its helper processes
  grouped by role, a short explanation, and Quit.
- **macOS system**, always last: what macOS itself uses. Open it to see its largest parts.
- **Plain words** from a built-in guide of 187 checked entries. No AI.
- **Pin** keeps the panel floating while you work.
- **Keep awake** at the bottom of the panel stops the Mac from sleeping while idle, for 1 hour,
  4 hours or until you end it. On a MacBook, tick **Lid closed** to keep it awake with the lid
  closed too. A thin ring around the dot shows that it is on.

<p align="center">
  <img src="docs/images/panel-tight-dark.png" width="440" alt="Pith's panel in dark mode. The title says Memory is tight, with an amber dot. The memory tile shows 15.1 of 16 GB, Tight and 2.1 GB swap. Google Chrome, Safari, Claude, Mail and Music are listed by memory, then macOS system.">
</p>

<sub>Both images use Pith's synthetic demo data.</sub>

## Install

You need an Apple Silicon Mac with macOS 15 or later, and the Command Line Tools with Swift 6.
Xcode is not needed.

```bash
xcode-select --install        # only if the Command Line Tools are missing
git clone https://github.com/mrinoybanerjee/pith.git
cd pith
./scripts/build-app.sh        # builds and signs dist/Pith.app
mv dist/Pith.app /Applications/
open /Applications/Pith.app
```

To update, or when Pith is already in `/Applications`, run `git pull`, then
`./scripts/install.sh local`. It builds Pith, quits the running copy, replaces the app in
`/Applications` and opens it.

- Always open Pith from `/Applications`.
- On its first launch, Pith adds itself as a login item. Turn this off in Pith's Settings or in
  System Settings.
- The build signs Pith ad hoc. [docs/BUILDING.md](docs/BUILDING.md) explains a stable local
  signing identity, the tests and the install script.

## Privacy and safety

Pith reads:

- memory, memory pressure, swap, CPU load and free disk space, from macOS;
- for your own processes: the name, parent, path, memory footprint, CPU time and disk bytes read
  and written;
- app names and icons, from each app's bundle.

Of other users' processes, including macOS's own, Pith reads only the process IDs. macOS refuses
Pith the rest. Only Apple's `top` lists them, when you open "macOS system".

Pith never:

- **connects to the network.** No analytics, no accounts, no update checks;
- **installs a root helper** or asks for your password;
- **asks for a privacy permission;**
- **runs tools in the background.** It runs Apple's `/usr/bin/top` once when you open "macOS
  system", at most once every 10 s, and, only while **Lid closed** is ticked, one copy of itself
  that holds the lid;
- **quits an app without asking.** Quit always asks first, and Pith never offers to quit part of
  macOS.

Pith keeps the Mac awake only when you ask, without root. Quitting Pith, or a crash, ends it, and
a closed lid then sleeps the Mac within seconds. With the lid closed, it also lets the Mac sleep
when macOS warns of low battery or the Mac gets hot. macOS has one closed-lid switch for all apps:
if another app also keeps a closed lid awake, Pith's end ends that app's hold too, and the reverse.

Pith saves only the settings you change, the Memory · CPU · Disk choice, the pinned panel's
position, and a note that it added its login item.

## Speed

Each line is a release gate, measured with `scripts/perf.sh`.

| Measure | Budget | Mac mini M4 | MacBook Air M4 | MacBook Pro M5 Max |
|---|---|---|---|---|
| CPU, panel closed | ≤ 0.1% | 0.03% | 0.03% | 0.02% |
| CPU, panel open | ≤ 1.5% | 0.98% | 1.15% | 0.95% |
| Memory, panel closed | ≤ 30 MB | 27 MB | 27 MB | 28 MB |
| Memory, panel open | ≤ 45 MB | 26 MB | 25 MB | 33 MB |
| Wakeups per second, closed | ≤ 0.5 | 0.03 | 0.10 | 0.00 |
| Wakeups per second, open | ≤ 2 | 0.13 | 0.30 | 0.00 |
| Tools started | 0 | 0 | 0 | 0 |
| One reading of all processes | ≤ 3 ms | 1.27 ms | 1.15 ms | 2.02 ms |
| Launch to first reading | ≤ 300 ms | 182 ms | 117 ms | 108 ms |
| Click to panel on screen: first open / slowest of the others | ≤ 100 ms | 81 / 68 ms | 59 / 64 ms | 230 ms* |
| macOS | 15 or later | 26.6.2 | 26.6.2 | 26.6 |

CPU is the mean share of one core, as `top` shows it. "Open" is the default 2 s refresh. "Tools
started" leaves out the on-demand `top`. The Mac mini and the MacBook Air have 16 GB of memory;
the MacBook Pro has 128 GB.

\* The MacBook Pro's numbers are from build `a68ea3c`; the Mac mini's and the MacBook Air's are from
the release build. The Pro locks its screen 3 minutes after the last input and Pith pauses while the
screen is locked, so its gates cannot run unattended. Its closed-panel numbers may include time
when Pith was paused by the lock. Its gate's first open ran behind a locked
screen under heavy disk load; a later probe measured 43–85 ms for 15 first opens after launch.
No 24-hour soak was run for 0.1.0.

## Accuracy

`scripts/accuracy.sh` compares Pith with `top`, for the same processes at the same moment, for
every app of 50 MB or more. CPU points are shares of the whole Mac.

| Check | Pass rule | Mac mini M4 | MacBook Air M4 | MacBook Pro M5 Max |
|---|---|---|---|---|
| Memory per app | within ±3% of the range of 2 `top` samples, in at least 5 counted runs; at most 1 run outside, none beyond ±10%; a range over 6% wide does not count | pass, 2 of 2 runs | pass, 19 apps | pass, 2 of 2 runs |
| CPU per app, over 10 s | within ±2 points | pass, 2 of 2 runs | pass, largest gap 0.12 | pass, largest gap 0.22 |
| "macOS system" | never below zero | 100 of 100 readings | 100 of 100 readings | 100 of 100 readings |

## More

- [docs/DESIGN.md](docs/DESIGN.md): what you see and how it behaves.
- [docs/BUILDING.md](docs/BUILDING.md): build, sign, test and install.
- [CHANGELOG.md](CHANGELOG.md): what changed in each version.

## Credits

Pith adapts a few system readers from [Stats](https://github.com/exelban/stats) by Serhiy
Mytrovtsiy, under the MIT License. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists each
adapted file and keeps the Stats license.

## License

MIT. Copyright (c) 2026 Mrinoy Banerjee. See [LICENSE](LICENSE).

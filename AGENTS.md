# Pith agent guide

Pith is a free, open-source macOS menu-bar activity monitor. This repository is public:
use synthetic data only (see Global Constraints). Read the spec,
[docs/specs/2026-10-25-pith-design.md](docs/specs/2026-10-25-pith-design.md), and the
plan, [docs/plans/2026-10-25-pith-plan.md](docs/plans/2026-10-25-pith-plan.md), before
you change behavior.

## Where work happens

All work happens in `~/Codex/Projects/Pith` on the Mac mini. Builds, tests, commits and
pushes run there.

- `./scripts/ci-local.sh` is the local gate: lint, release build, tests.
- `./scripts/test.sh` runs every test. Without Xcode, a focused run needs the Swift
  Testing paths that `test.sh` adds:
  `swift test --filter <name> -Xswiftc -F -Xswiftc "$F" -Xlinker -rpath -Xlinker "$F"`,
  with `F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks`.

## Launch rule

Launch the real app only with `open /Applications/Pith.app`, never a `.build` binary.
On macOS 26, a process started the wrong way can get no visible status item.

## Global Constraints

- **Where work runs:** all work runs on the Mac mini in `~/Codex/Projects/Pith`. Builds, tests and commits run on the mini.
- **Toolchain:** Command Line Tools only, no Xcode. `swift-tools-version: 6.0`, platforms `.macOS(.v15)`, Swift language mode 6, Apple Silicon (`arm64`) only.
- **Identity:** bundle ID `com.mrinoy.pith`, app name `Pith`, `LSUIElement = YES`, `LSMinimumSystemVersion = 15.0`.
- **Dependencies:** zero third-party packages. No widget extension, no XPC service, no helper tool. The lid holder is Pith's own binary (Awake spec 4.2).
- **Resource use:** Pith makes **no network calls**. It launches no child process except the on-demand `/usr/bin/top` (spec 6.7) and, while "Lid closed" is ticked, its own `--hold-lid` copy (Awake spec 4.2). It writes to disk only settings and the pinned panel frame.
- **Unknown values:** a missing reading is `Reading.unavailable(reason)`, shown as "Not available" or "—". It is never shown as 0.
- **UI:**
  - text the user must read is at least 13 pt, in SF Pro, with tabular numerals for all values;
  - color appears only for state: `NSColor.systemOrange` for Tight and `NSColor.systemRed` for Critical;
  - the panel is 360 pt wide.
- **Copy:** UI strings are copied exactly from spec sections 4 and 7.3, and Awake spec section 3.
- **Public repo:** fixtures, screenshots and README images use **synthetic data only**, with no real process lists, paths or user names.
- **Ported Stats code:** each adapted file starts with a header like this:

  ```swift
  // Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
  // Copyright (c) 2020 Serhiy Mytrovtsiy. Source: <path> L<a>-L<b> at v3.0.22 (1282cd5).
  ```

- **Commits:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Run `./scripts/ci-local.sh` (on the mini) before the task's last commit.
- **Code style (Mrinoy's rules):**
  - the fewest lines that solve the problem;
  - no speculative code;
  - no fallbacks or defensive branches that hide errors: fail loudly, and use `assert` for invariants;
  - match the surrounding style.

## Speed budget (spec section 10, release gate)

Measured on each of the three Macs with `scripts/perf.sh`, which samples `top -l 2 -pid <pith>` every 10 s:

| Measure | Closed | Open |
|---|---|---|
| CPU, mean % of one core | ≤ 0.1% | ≤ 1.5% |
| CPU, any 60 s sample | ≤ 1% | ≤ 5% |
| Memory footprint | ≤ 30 MB | ≤ 45 MB |
| Idle wakeups per second | ≤ 0.5 | ≤ 2 |
| Child processes launched | 0 | 0 (on-demand `top` and the lid holder excluded) |
| One full sweep (~500 processes, M4) | — | ≤ 3 ms |
| Click to panel visible | ≤ 100 ms | — |
| Launch to first reading | ≤ 300 ms | — |
| Footprint growth over 24 h | ≤ 2 MB | — |

## Accuracy gate (spec section 11)

`scripts/accuracy.sh`, each Mac, each release:

- Pith's per-app memory must be within ±3% of the sum of `top` MEM for the same PIDs at the same moment.
- Pith's CPU must be within ±2 points over a 10 s window.
- No residual may be negative across 100 samples.

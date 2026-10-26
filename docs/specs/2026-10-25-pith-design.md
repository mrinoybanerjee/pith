# Pith — design spec

- **Date:** 2026-10-25
- **Status:** draft for review
- **Owner:** Mrinoy Banerjee
- **Visual companions:** `pith-design-1-what-you-see.html` (section 1, approved 2026-10-25) and `pith-design-2-how-it-works.html` (sections 2–4, approved 2026-10-25).

## 1. Summary

Pith is a free, open-source macOS menu-bar app. It answers one question at a glance: "what is using my Mac right now?"
- A calm dot sits in the menu bar.
- A click opens a panel with:
  - a one-line status sentence;
  - three tiles (Memory, CPU, Storage);
  - the apps that use the most, with each app's helper processes added into one row.
- The panel can be pinned as a floating side panel.

Pith must be extremely light, fast, robust and accurate. It must also look minimal, native and pristine.

## 2. Goals and non-goals

### Goals

1. Show per-app memory, CPU and disk activity, with helper processes grouped under their app.
2. Use plain words. Explain known apps and macOS processes from a built-in guide.
3. Stay out of the way: a quiet dot, color only when something is tight.
4. Use almost no resources. The budget is in section 10, and it is a release gate.
5. Match Activity Monitor's numbers for the same processes.
6. Run on Mrinoy's three Apple Silicon Macs (MacBook Air M4, Mac mini M4, MacBook Pro) on macOS 26, and keep working on macOS 27.
7. Cost $0 to build, sign and install.

### Non-goals for v1

- Network, GPU, battery, temperatures, fans and power readings.
- Disk *space* per app. v1 shows free space for the startup disk only.
- History graphs, widgets, notifications and AI-written explanations.
- A root helper, Intel Macs, the Mac App Store and notarized public downloads.

## 3. Decisions made with Mrinoy (2026-10-25)

| Topic | Decision |
|---|---|
| Price | Completely free. |
| Scope | Focused v1: CPU, RAM and disk activity per app, memory pressure, free space, plain labels. |
| System processes | On demand: one "macOS system" row is always shown. Its details come from one `top` run only when the row is opened. |
| Opening | Click to open; a pin turns the panel into a floating side panel. No hover. |
| Menu bar | A calm status dot. No numbers. |
| Explanations | A built-in, checked guide plus rule-based hints. No AI. |
| Actions | Quit with confirmation. A normal quit first, Force Quit only if the app doesn't respond. Never for system processes. |
| Approach | A new small app (approach A). Port specific MIT-licensed readers from Stats, with credit. Do not fork Stats. |
| Name and repo | Pith. Public repo `github.com/mrinoybanerjee/pith`, MIT license. |
| CI | A local gate on the Mac mini plus GitHub's free macOS runner. Blacksmith supports organizations only, not personal repos. |

## 4. User experience

### 4.1 Menu bar item

A 16 pt template image: a 9 pt circle.

| State | Look | Enters when | Leaves when |
|---|---|---|---|
| Calm | Outline in the menu bar's own color | No other state applies | — |
| Tight | Filled amber (system orange) | Memory pressure is *warning*; or CPU busy is ≥ 80% for 60 s; or free space is < 10% of the startup disk | All its causes clear. CPU must be < 70% for 60 s before it counts as clear. |
| Critical | Filled red (system red) | Memory pressure is *critical*; or free space is < 5% of the startup disk | All its causes clear |

The setting "Dot turns amber on" can drop CPU from the Tight causes (section 4.6). The image changes only when the state changes; no per-tick redraw.

### 4.2 Panel

- Width 360 pt; height fits content, up to 560 pt. Beyond that, the app list scrolls inside the panel, and the status line and tiles stay fixed.
- Material: `NSVisualEffectView` `.popover`, 14 pt corner radius, light and dark.
- It opens under the status item. It closes on an outside click, Escape, or a second click on the item.

Top to bottom:

1. **Status line.** A colored 10 pt dot, a 17 pt semibold title and a 13 pt secondary sentence (section 7.3). Pin and Settings icon buttons sit on the right.
2. **Three tiles**, each with a caption, a value, a thin meter and a word.
   - **Memory:** "15.1 of 16 GB"; meter = used/total; word = Plenty / Tight / Critical. Swap is added ("Tight · 2.1 GB swap") when pressure is not normal or swap is over 1 GB.
   - **CPU:** "38%"; word = Light (< 30%) / Moderate (30–70%) / Busy (> 70%).
   - **Storage:** "112 GB free"; second line "of 228 GB"; meter = used/total.
3. **"Using the most"** with a segmented control: Memory · CPU · Disk. The default is Memory, and the choice is remembered.
4. **App rows** (top 8 by the selected metric):
   - a 24 pt app icon, the app name, a 3 pt proportional bar and a right-aligned tabular value;
   - "N processes" under the value when N > 1.
5. **"macOS system" row**, always last. It shows a generic chip icon and the residual value (section 6.6).
6. **Footer** (11.5 pt, tertiary): "Updated just now" and "Pith".

Typography: SF Pro, 13 pt minimum for anything the user must read, tabular numerals for all values.

Color: native greys and materials only. Amber and red appear only for Tight and Critical.

### 4.3 Opened app row

Clicking a row expands it in place. The expanded row shows:
- The guide explanation, when the app has an entry.
- **Inside:** the app's helper processes, grouped by role label with count and total. For example "Tabs and sites (34) 5.1 GB", "Graphics 620 MB", "Extensions (5) 480 MB". Role labels come from the guide's helper patterns (for example `Helper (Renderer)` → "Tabs and sites"). An unmatched helper is listed by its own name.
- **Quit** (section 4.5), only for apps with a running `NSRunningApplication` owned by the user.

### 4.4 Opened "macOS system" row

- Pith runs the system-details reader once (section 6.7) and shows "Measuring…" for up to 1.5 s.
- The list shows the top 4 system processes by memory, named by the guide (for example "Spotlight indexing"), plus "Other system work" for the rest.
- A note says the numbers were measured once, just now.
- System entries show their guide explanation and "Part of macOS. Pith never offers to quit it."
- Results are cached for 10 s.

### 4.5 Quit flow

1. **Quit** shows an inline confirm: "Quit {App}? It can ask you to save first." [Cancel] [Quit].
2. **Quit** calls `NSRunningApplication.terminate()`.
3. If the app is still running after 5 s, the row offers **Force Quit**, with a second confirm. That calls `forceTerminate()`.
4. System processes, apps owned by other users and command-line processes never show Quit.

### 4.6 Settings (exactly three)

| Setting | Options | Default |
|---|---|---|
| Launch at login | On / Off (`SMAppService.mainApp`) | On |
| Refresh while open | 1 s / 2 s | 2 s (R134) |
| Dot turns amber on | Memory, CPU or storage / Memory or storage only | Memory, CPU or storage |

### 4.7 Pin

- The pin button detaches the panel into a floating `NSPanel`:
  - level `.floating`, non-activating;
  - joins all Spaces;
  - can be dragged by its background;
  - stays open while the user works in other apps.
- The frame is saved and restored.
- Unpinning re-attaches the panel to the status item and closes it.

### 4.8 Motion and accessibility

- Rows reorder only when the rank really changes, with a 0.25 s ease. A value that moves within 2% never reorders rows.
- Reduce Motion replaces all motion with crossfades.
- VoiceOver: each row reads as "{App}, {value} {metric}, {N} processes". Tiles read as full sentences.
- Keyboard:
  - ↑ / ↓ move between rows;
  - Return opens or closes a row;
  - ⌘1 / ⌘2 / ⌘3 switch Memory / CPU / Disk;
  - Escape closes the panel.

## 5. Architecture

### 5.1 Components

| Component | Target | Responsibility | Depends on |
|---|---|---|---|
| `Clock` | PithCore | Fires ticks at the current speed with leeway. It pauses on sleep, screen lock and display sleep. | `DispatchSourceTimer`, `NSWorkspace` notifications (passed in by the app) |
| `SystemReader` | PithCore | Reads memory totals, pressure (event source), swap, CPU busy and storage | Mach host APIs, sysctl, `DispatchSource`, `URL` resource values |
| `ProcessTableSource` | PithCore | Reads a raw process table for the user's own processes, using one buffer that is reused | libproc |
| `AppGrouper` | PithCore | Maps each process to an app identity (section 6.5) and caches by `ProcessKey` | libproc, `dlsym` for the responsibility call, bundle paths |
| `Aggregator` | PithCore | Takes the previous and current tables plus totals and returns a `Snapshot` (CPU %, rates, per-app sums, residual). It is a pure function. | — |
| `StatusRules` | PithCore | Turns a `Snapshot` and the recent history into a `Status` (dot state + sentence) with hysteresis. It is pure. | — |
| `Guide` | PithCore | Loads `guide.json` and matches names, bundle IDs, path prefixes and helper patterns | Bundle resource |
| `SystemDetails` | PithCore | Runs `/usr/bin/top` once and parses its output | `Process` |
| `Engine` (actor) | PithCore | Owns the readers and the previous table. `tick(mode:)` returns a `Snapshot`. | All of the above |
| `Store` (`@MainActor`, `@Observable`) | Pith | Holds the latest `Snapshot`, the UI state and the settings | `Engine` |
| `StatusItemController` | Pith | Owns the `NSStatusItem`, swaps the dot image on state change, and toggles the panel | AppKit |
| `PanelController` | Pith | Owns the `NSPanel`, attaches or pins it, saves the frame, and dismisses on outside click | AppKit |
| Views | Pith | SwiftUI views hosted in `NSHostingView`. They draw a `Snapshot` and nothing else. | SwiftUI |
| `QuitFlow` | Pith | The confirm, terminate, wait and force-quit state machine | AppKit |

### 5.2 Key types (sketch)

```swift
enum Reading<Value: Sendable>: Sendable { case value(Value), unavailable(String) }

struct ProcessKey: Hashable, Sendable { let pid: pid_t; let startTime: UInt64 }  // start time in µs

struct ProcessSample: Sendable {
  let key: ProcessKey; let parent: pid_t; let name: String; let path: String
  let footprint: UInt64          // ri_phys_footprint, bytes
  let cpuTimeNs: UInt64          // ri_user_time + ri_system_time, converted from Mach ticks
  let diskRead: UInt64; let diskWritten: UInt64
}

enum Pressure: Sendable { case normal, warning, critical }

struct SystemTotals: Sendable {
  let memoryUsed: UInt64; let memoryTotal: UInt64; let pressure: Pressure; let swapUsed: UInt64
  let cpuBusy: Double            // 0...1, whole machine
  let storageFree: Reading<UInt64>; let storageTotal: Reading<UInt64>
}

struct AppUsage: Sendable, Identifiable {
  let id: String                 // bundle ID, else the .app path, else "proc:<name>"
  let name: String; let bundlePath: String?
  let processCount: Int; let memory: UInt64; let cpu: Double; let diskBytesPerSecond: Double
  let inside: [HelperGroup]
}

struct Snapshot: Sendable {
  let takenAt: ContinuousClock.Instant; let mode: Mode
  let totals: SystemTotals; let apps: [AppUsage]     // empty when mode == .closed
  let system: Reading<SystemResidual>; let grouping: GroupingQuality
}
```

### 5.3 Data flow per tick

1. `Clock` fires and calls `engine.tick(mode:)`.
2. `SystemReader` returns `SystemTotals`.
3. In `.open` mode only:
   - `ProcessTableSource` returns the current table;
   - `AppGrouper` assigns app identities;
   - `Aggregator` diffs this table with the previous one.
4. `Aggregator` returns a `Snapshot`. `StatusRules` returns a `Status`.
5. `Store` receives both on the main actor in one assignment.
6. Views redraw. `StatusItemController` changes the image only if the dot state changed.

### 5.4 Concurrency

- Swift 6 strict concurrency.
- `Engine` is an actor on its own executor.
- The UI touches only `Store` on the main actor.
- Snapshots are immutable values. Nothing is shared and mutable across actors.

## 6. Data sources and algorithms

### 6.1 Sources

| Reading | API | Privilege | When |
|---|---|---|---|
| Process list | `proc_listallpids` | none | open, each tick |
| Name, parent, user | `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` | none (all users) | open, each tick (cached by `ProcessKey`) |
| Path | `proc_pidpath` | none | first sight of a `ProcessKey` |
| Footprint, CPU time, disk I/O | `proc_pid_rusage(RUSAGE_INFO_V6)` | same user only (EPERM for others, verified on the Air 2026-10-25) | open, each tick |
| Memory totals | `host_statistics64(HOST_VM_INFO64)`, `hw.memsize` | none | each tick |
| Memory pressure | `DispatchSource.makeMemoryPressureSource` + `kern.memorystatus_vm_pressure_level` read on event | none | event-driven |
| Swap | `sysctl vm.swapusage` | none | each tick |
| CPU busy | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas | none | each tick |
| Storage | `URL.resourceValues` `.volumeAvailableCapacityForImportantUsageKey`, `.volumeTotalCapacityKey` on `/` | none | every 60 s, and on volume mount/unmount |
| App name and icon | `NSRunningApplication`, `Bundle(path:)`, `NSWorkspace.icon(forFile:)` | none | first sight of an app; icons cached |
| System details | `/usr/bin/top -l 2 -s 1 -n 20 -o mem -stats pid,command,cpu,mem,uid` (setuid root on macOS) | none needed by Pith | only when "macOS system" is opened; cached 10 s |

### 6.2 Units

- `ri_user_time` and `ri_system_time` are Mach absolute-time units on Apple Silicon. Convert them with `mach_timebase_info` (numerator/denominator) before any math.
- Memory is shown in binary units (1 GB = 2^30 bytes), labeled "GB"/"MB" as Activity Monitor and `top` do. Storage is shown in decimal units (1 GB = 10^9 bytes), as Finder and System Settings do.
- Accuracy test step 2 confirms both against Activity Monitor.

### 6.3 CPU

- App CPU = Σ over the app's processes of Δ`cpuTimeNs` / (Δwall-clock ns × logical CPU count). This is the share of the whole Mac, 0–100%; it never exceeds 100%.
- Total CPU busy = Δ(user + system + nice ticks) / Δ(all ticks), summed over all cores.
- Opening the panel shows the last snapshot at once and runs one tick immediately. That tick has no previous table, so it fills memory right away and shows "—" for CPU and Disk until the next tick, 1 s later. The first interval after an open is always the 1 s one (doubled in Low Power Mode or a serious thermal state); then the refresh setting's interval applies (R134).

### 6.4 Memory "used"

- Activity Monitor's definition: used = (internal − purgeable + wired + compressor) pages × page size. These come from `vm_statistics64`: `internal_page_count`, `purgeable_count`, `wire_count`, `compressor_page_count`.
- Per-app memory = Σ `ri_phys_footprint` of its processes.

### 6.5 App grouping

For each new `ProcessKey`, Pith tries three methods in order:

1. **Responsible process:**
   - Call `responsibility_get_pid_responsible_for_pid` (resolved once with `dlsym`).
   - If the responsible process differs and has an enclosing `.app`, use that app.
2. **Enclosing bundle:** walk up from `proc_pidpath` to the outermost `*.app` directory. Helpers inside `App.app/Contents/Frameworks/...` resolve to `App.app`.
3. **Parent chain:**
   - Follow parent PIDs (up to 5 levels) until a process with an enclosing `.app` is found.
   - Stop at `launchd` (pid 1).
   - If nothing is found, the process is its own group, `proc:<name>`. Command-line tools (`node`, `python3`) therefore group under their parent app when one exists (for example Terminal or Codex), and otherwise stand alone.

Rules:
- Cache results by `ProcessKey` (pid + start time), so a reused PID never inherits an old group. Evict keys that no longer appear.
- If `dlsym` cannot find the responsibility call, `GroupingQuality` becomes `.limited`. Grouping then continues with methods 2–3, and Settings shows "App grouping is limited on this macOS version." This is a visible degraded mode, not a silent fallback.

### 6.6 "macOS system" residual

- Memory residual = (internal − purgeable + wired + pages stored in the compressor) × page size − Σ footprint of the user's own processes. Footprints count a compressed page at its full size, so the residual uses the compressor's uncompressed count (`total_uncompressed_pages_in_compressor`), not `compressor_page_count` (R133). The Memory tile keeps memory used (6.4).
- CPU residual = total busy − Σ the user's process CPU.
- If a residual is negative, it is shown as "—" with the reason "accounting mismatch". Debug builds log the inputs. The accuracy test (step 2) fails on any negative residual.

### 6.7 System details

- Runs `top` in a child process, at most once per 10 s, only on user request.
- Pith parses the second sample. The first `top` sample is cumulative and is discarded.
- `mem` values can carry `K`/`M`/`G` and trailing `+`/`-`; the parser handles both.
- Keeps rows whose UID is not the user's.
- On a non-zero exit, a timeout (3 s) or a parse failure, the row shows "Couldn't measure system details" with Retry. Raw output is logged in debug builds.

## 7. Built-in guide

### 7.1 Format

`Resources/guide.json` holds an array of entries:

```json
{ "match": { "name": "mds_stores" },
  "title": "Spotlight indexing",
  "explanation": "Builds the search index after files change. Normal for a few minutes after big copies or updates.",
  "kind": "system", "quittable": false,
  "source": "man:mds_stores(8)" }
```

- `match` takes exactly one of `name`, `bundleID`, `pathPrefix` or `helperPattern`.
- `kind` is `app`, `helper` or `system`.

### 7.2 Content

- About 150–300 entries: common macOS daemons, Apple apps, and helper patterns for Chromium, Electron, WebKit and Xcode.
- Each system entry cites an Apple or man-page source.
- An agent drafts the entries. A reviewer checks each one against its source before merge.

### 7.3 Status sentences (rules, in priority order)

| Condition | Title | Sentence |
|---|---|---|
| Pressure critical | Memory is very tight | "{App} uses the most: {mem} across {n} processes." |
| Free space < 5% | Storage is almost full | "{free} free of {total}." |
| Pressure warning | Memory is tight | "{App} uses the most: {mem} across {n} processes." |
| CPU busy ≥ 80% for 60 s | Your Mac is busy | "{App} is using {cpu}% of the CPU." |
| Free space < 10% | Storage is getting full | "{free} free of {total}." |
| Otherwise | All calm | "Plenty of memory and CPU to spare." |

The sentence is visible only while the panel is open, and opening the panel runs one tick at once (section 6.3). Per-app memory is therefore always available for the sentence.

## 8. Error handling

- Every reading that can fail returns `Reading.unavailable(reason)`. Views show "Not available". Values are never shown as 0 when unknown.
- Invariants checked with `assert` in debug builds:
  - CPU values lie in 0…1;
  - timestamps are monotonic.
- A memory accounting mismatch is not asserted. It takes the visible "accounting mismatch" path (section 6.6), and the accuracy gate fails on it.
- No silent fallbacks. Degraded modes are named and visible: grouping `.limited`, residual "accounting mismatch", system details failure.
- Crashes are never caught and hidden. Diagnostic reports are checked in the soak test.

## 9. Performance design

- Two speeds:
  - **closed:** 5 s interval, 1 s leeway, system totals only;
  - **open:** 2 s interval by default (1 s by setting), a tenth of it as leeway, full sweep. The first interval after an open is 1 s, with 0.1 s leeway (R146). At 1 s the panel measured 1.9–2.4% of one core on the mini, over the open budget (R134).
- A pinned panel that is fully covered (`NSWindow.occlusionState`) uses the closed speed.
- The clock stops on sleep, screen lock and display sleep, and resumes on wake.
- Low Power Mode or `ProcessInfo.thermalState` ≥ `.serious` doubles both intervals.
- No tools are launched except the on-demand `top`.
- One reused buffer serves the process list. Paths and names are cached per `ProcessKey`. Strings are formatted only for visible rows.
- Drawing:
  - bars are plain SwiftUI shapes; no `Canvas`, no Swift Charts;
  - no animation runs while the panel is hidden.
- Zero third-party dependencies, no widget extension, no XPC services.
- One timer drives every reader. Stats runs about six unaligned 1 s timers, each on its own queue (teardown).
- No writes to disk during normal running, apart from settings and the pinned frame. Stats writes its last values to LevelDB about every 10 s.
- The status item has a fixed width and changes its image only when the dot state changes. On macOS 26, each status-item layout pass costs WindowServer work; Stats patches a private AppKit method to avoid it.
- Both panel modes are non-activating, so opening Pith never takes focus from the app in front.

## 10. Speed budget (release gate)

Measured on each of the three Macs with `scripts/perf.sh`, which samples `top -l 2 -pid <pith>` every 10 s:

| Measure | Closed | Open |
|---|---|---|
| CPU, mean % of one core | ≤ 0.1% | ≤ 1.5% |
| CPU, any 60 s sample | ≤ 1% | ≤ 5% |
| Memory footprint | ≤ 30 MB | ≤ 45 MB |
| Idle wakeups per second | ≤ 0.5 | ≤ 2 |
| Child processes launched | 0 | 0 (on-demand `top` excluded) |
| One full sweep (~500 processes, M4) | — | ≤ 3 ms |
| Click to panel visible | ≤ 100 ms | — |
| Launch to first reading | ≤ 300 ms | — |
| Footprint growth over 24 h | ≤ 2 MB | — |

## 11. Testing

1. **Unit tests** (`swift test`, every commit). They cover:
   - Mach-tick conversion;
   - CPU and rate math;
   - aggregation and residuals;
   - grouping on recorded process tables (Chrome, an Electron app, Xcode with XPC services, `node` and `python3` under Terminal and under Codex, a reused PID);
   - status rules with hysteresis;
   - the `top` parser on recorded output;
   - guide validation: schema, unique matches, sources on system entries, no quittable system entry.
2. **Accuracy** (`scripts/accuracy.sh`, each Mac, each release):
   - Pith's per-app memory must be within ±3% of the sum of `top` MEM for the same PIDs at the same moment.
   - Pith's CPU must be within ±2 points over a 10 s window.
   - No residual may be negative across 100 samples.
3. **Speed gate** (`scripts/perf.sh`, each Mac, each release): every line of section 10.
4. **Soak** (each release): 24 h running, two sleep/wake cycles, one restart, zero crash reports, footprint growth ≤ 2 MB.
5. **Look and feel** (each UI change):
   - light and dark screenshots checked against the approved mockup;
   - an accessibility audit test that walks the AX tree, modeled on Vani's `AccessibilityAuditTests`;
   - Reduce Motion and keyboard paths.
6. **Review** (every PR): `/cr` on GPT-6.1 Sol, then the council as the final gate before merge. PR bodies follow the "At a glance" template with before/after visuals.

## 12. Build, sign, install, CI

- **Toolchain:** a Swift package (`swift-tools-version: 6.0`) that builds with Command Line Tools only. On 2026-10-25, the Air and the mini had no Xcode, and Vani builds and tests the same way on the mini.
  - Products: library `PithCore`, executable `Pith`.
  - Platform minimum: macOS 15. Tested on macOS 26 and, before any Mac upgrades, macOS 27.
- **App bundle:** `scripts/build-app.sh` assembles `Pith.app` from the release binary, `Info.plist` (`LSUIElement = YES`), `guide.json`, the icon, LICENSE and THIRD_PARTY_NOTICES. It follows Vani's `build-app.sh` pattern.
- **Signing:** a stable local code-signing identity, "Pith Local Development", in the Mac mini's login keychain. It is created once, with Mrinoy's OK.
  - Pith needs no privacy permissions.
  - The stable identity keeps the login item and Gatekeeper trust steady across rebuilds.
  - No Apple Developer Program fee.
- **Install:** `scripts/install.sh` builds on the mini, then copies `Pith.app` with `rsync` over SSH to `/Applications` on each Mac (Air, mini, Pro) and relaunches it. Copied apps carry no quarantine flag. The Air and the mini are reachable over SSH today; the plan confirms the Pro's SSH host before the first install.
- **Login item:** `SMAppService.mainApp.register()` on first launch, controlled by the setting.
- **Launch rule for testing:** final checks always launch the installed bundle through Launch Services (`open /Applications/Pith.app`), never a `.build` executable. On macOS 26, a process started the wrong way can get no visible status item. Local DeID hit this on 2026-10-12, and Vani's troubleshooting guide has the same rule.
- **Local gate:** `scripts/ci-local.sh` = lint + release build + unit tests. It runs on the mini before every push.
- **GitHub CI:** `.github/workflows/ci.yml` on GitHub's `macos-15` runner (free for public repos, as Vani uses). It runs lint, build and unit tests. Accuracy, speed and soak run on real Macs only.

## 13. Repository and licensing

- **Repo:** `github.com/mrinoybanerjee/pith` (public). License: MIT, © 2026 Mrinoy Banerjee.
- **Canonical checkout:** `~/Codex/Projects/Pith/` on the Mac mini (the repository folder is the project folder). Other Macs use git checkouts only.
- **Ported code:** code adapted from Stats (`github.com/exelban/stats`, MIT, © Serhiy Mytrovtsiy) keeps the Stats copyright and permission notice in `THIRD_PARTY_NOTICES.md`. A header comment in each adapted file names its source file and lines at tag `v3.0.22` (commit `1282cd5`).
  - The ported parts total a few hundred lines. They are confirmed in `stats-teardown.md` (2026-10-25):

    | Pith file | Stats source at v3.0.22 | What |
    |---|---|---|
    | `SystemReader.swift` | `Modules/RAM/readers.swift` L37–L103 | `host_statistics64`, pressure sysctl and swap sysctl reads |
    | `SystemReader.swift` | `Modules/CPU/readers.swift` L42–L156 | `host_processor_info` per-core deltas with wrap-safe `UInt32` math |
    | `AppGrouper.swift` | `Modules/RAM/readers.swift` L210–L227 | `responsibility_get_pid_responsible_for_pid` through `dlsym` |
    | `ProcessTableSource.swift` | `Modules/Disk/readers.swift` L448–L457 | The `proc_pid_rusage` disk-I/O read pattern |

  - Not ported:
    - all `ps`, `top`, `nettop` and `uptime` spawning and its regex parsing;
    - the per-reader timers;
    - LevelDB persistence;
    - the updater;
    - the private `CSDiskSpaceGetRecoveryEstimate` free-space path. Pith uses the public important-usage capacity key and checks it against Finder in accuracy step 2.
- **Project docs:** `README.md` (with real screenshots), `AGENTS.md` and `CLAUDE.md` for agents, `DESIGN.md` (from section 4), and this spec under `docs/specs/`.

## 14. Risks and mitigations

| Risk | Mitigation |
|---|---|
| System processes are invisible without root | A residual row that is always shown, plus on-demand `top`. Never a root helper in v1. |
| A private call (`responsibility_get_pid_responsible_for_pid`) disappears | Visible `.limited` grouping mode; bundle-path and parent-chain grouping still run |
| `top` output format changes | Parser tests on recorded output; visible failure with Retry |
| Numbers disagree with Activity Monitor | Unit-correct math; accuracy gate within ±3% on each Mac and release |
| Overhead creeps up | Speed budget as a release gate on three Macs |
| macOS 27 changes behavior | Run the accuracy and speed gates on macOS 27 before any Mac upgrades |
| Scope creep | Section 2 non-goals; any new metric needs its own spec |

## 15. Acceptance for v1

v1 is done when all of these hold:
- Every item in section 4 works as written.
- The section 10 budget passes on all three Macs.
- Accuracy step 2 passes on all three Macs.
- The soak passes once.
- Mrinoy approves the real app against the section 1 mockup.

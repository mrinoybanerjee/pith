# Pith — Awake (v0.2)

- **Date:** 2026-10-28
- **Status:** approved direction (Mrinoy, 2026-10-28: "Pith = Monitor + Awake", keep it minimal)
- **Extends:** [2026-10-25-pith-design.md](2026-10-25-pith-design.md). Where they differ, this file wins.
- **Background:** the Insomnia review and plan in Mrinoy's working files (2026-10-28).

## 1. Summary

Pith keeps the Mac awake when you ask it to, for a time you pick. One bar at the bottom of the
panel starts and ends it. A thin ring around the dot shows that the Mac is being kept awake.
Nothing else changes.

v0.2 covers the lid **open** only. Closing the lid still sleeps the Mac, as it does today.
Lid-closed awake is a later version, if a no-root mechanism proves reliable.

## 2. Behavior

- **Start:** the bar offers three durations: 1 hour, 4 hours, and until you end it.
- **While awake:** the Mac does not sleep from idle. The display can still sleep, and the
  Apple menu, the power button and the lid still sleep the Mac.
- **End:** "End" in the bar, the chosen time passing, or Pith quitting. Quitting or a crash
  ends it at once, because the hold belongs to Pith's process.
- **Across sleep:** if the Mac sleeps during a session (lid or Apple menu) and wakes after the
  end time, the session ends on wake.
- **No settings, no notifications, nothing saved.** A relaunch starts with no session.

## 3. What you see

### 3.1 Menu bar

| State | Look |
|---|---|
| Not awake | The dot as today (section 4.1 of the main spec) |
| Awake | The same dot inside a thin ring: a 14 pt circle, 1.25 pt line, in the menu bar's text color |

- The ring never takes a state color, and the dot keeps its meaning (Calm, Tight, Critical).
- The image changes only when the dot state or the awake state changes: 6 cached images.
- No numbers and no countdown in the menu bar.
- Accessibility label: "Pith: {title}." plus, while awake, "Awake until {time}." or
  "Awake until you end it."

### 3.2 Awake bar

The bar replaces the footer ("Updated just now" and "Pith") at the bottom of the panel, at the
same place and with the same top separator. It is not shown on the Settings page.

| State | Left | Right |
|---|---|---|
| Not awake | "Keep awake" (13 pt, secondary) | Three small buttons: "1 h", "4 h", "∞" |
| Awake, timed | "Awake until 3:40 PM" (13 pt, primary) | "End" |
| Awake, no end | "Awake until you end it" | "End" |

- The time uses the user's short time format. If the end is not today, the weekday comes
  first: "Awake until Thu 9:40 AM".
- No countdown. The text changes only on start and end, so the bar costs nothing while open.
- One click starts or ends. No confirm: both are harmless and undone with one more click. Each
  button acts once it has shown for 0.4 s, as the quit confirm does (R93), so the second click of
  a double-click never lands on the button that replaced the first: a double-click on End does
  not start a session, and one on a duration does not end it.
- VoiceOver: the buttons read "Keep awake for 1 hour", "Keep awake for 4 hours", "Keep awake
  until you end it", and "End keeping awake".
- Colors: native greys only, as everywhere in the panel.

## 4. Design

- **The hold:** one `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
  "Pith: keep awake")` per session, released by `IOPMAssertionRelease`, which must succeed.
  macOS releases it if Pith's process dies, so a crash leaves nothing behind. No powerd
  timeout: after powerd ends a timed assertion, a release call fails (spike, 2026-10-28), and
  one owner is simpler.
- **The end time:** one task that sleeps on the continuous clock until the end time, then ends
  the session. The continuous clock keeps counting while the Mac sleeps, so the end lands on
  wake if the end time passed during sleep. No polling.
- **State:** `Store.awake: Awake?`, with `Awake { until: Date? }`. Start only when not awake; end
  only when awake (assert both).
- **Seam:** a `SleepHold` closure struct with `.main` (the assertion) and `.none` (holds
  nothing), the same pattern as `LoginItem`. Tests, `--demo` and `--render-panel` use `.none`,
  so they never hold the real Mac awake.
- **Monitor unchanged:** sampling still pauses on display sleep and lock during a session.
  Awake needs no sampling.

## 5. Budget

The speed budget (main spec section 10) holds unchanged, closed and open, with or without a
session. A session adds one sleeping task and nothing periodic.

## 6. Testing

- Store: start acquires once; End releases once; the end time ends the session and releases;
  start while awake and End while not awake trap.
- Status item: 6 images; the image changes only when the dot state or the awake state changes;
  the accessibility label carries the awake sentence.
- Native interaction: each button starts the matching session (with `.none`), and End returns
  the bar to "Keep awake".
- `--render-panel` also renders the calm demo with a session running, for screenshots.
- `perf.sh` and `accuracy.sh` run at release, as for every release.

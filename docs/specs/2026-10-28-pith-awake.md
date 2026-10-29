# Pith — Awake (v0.2)

- **Date:** 2026-10-28
- **Status:** approved direction (Mrinoy, 2026-10-28: "Pith = Monitor + Awake", keep it minimal;
  later the same day, after the lid test passed: ship the lid-closed choice in the bar)
- **Extends:** [2026-10-25-pith-design.md](2026-10-25-pith-design.md). Where they differ, this file wins.
- **Background:** the Insomnia review and plan in Mrinoy's working files (2026-10-28).

## 1. Summary

Pith keeps the Mac awake when you ask it to, for a time you pick. One bar at the bottom of the
panel starts and ends it. On a Mac with a lid, one checkbox in the same bar keeps it awake with
the lid closed too. A thin ring around the dot shows that the Mac is being kept awake. Nothing
else changes.

No part needs root or an installer. A Mac without a lid never shows the checkbox.

## 2. Behavior

- **Start:** the bar offers three durations: 1 hour, 4 hours, and until you end it.
- **While awake:** the Mac does not sleep from idle. The display can still sleep, and the
  Apple menu and the power button still sleep the Mac. Closing the lid sleeps it too, unless
  "Lid closed" is ticked.
- **Lid closed:** while a session runs, ticking "Lid closed" keeps the Mac awake with the lid
  closed. It ends with the session, when the box is unticked, when macOS warns of low battery
  (its early warning, below 22%), when the Mac is seriously hot, or when Pith quits or crashes.
  Then a closed lid sleeps the Mac within seconds. If it ends on its own (battery, heat), the
  box unticks and the session goes on with the lid open.
- **End:** "End" in the bar, the chosen time passing, or Pith quitting. Quitting or a crash
  ends it at once.
- **Across sleep:** if the Mac sleeps during a session (lid or Apple menu) and wakes after the
  end time, the session ends on wake.
- **No settings, no notifications, nothing saved.** A relaunch starts with no session, and each
  session starts with "Lid closed" unticked.

## 3. What you see

### 3.1 Menu bar

| State | Look |
|---|---|
| Not awake | The dot as today (section 4.1 of the main spec) |
| Awake | The same dot inside a thin ring: a 14 pt circle, 1.25 pt line, in the menu bar's text color |

- The ring never takes a state color, and the dot keeps its meaning (Calm, Tight, Critical).
  "Lid closed" does not change it.
- The image changes only when the dot state or the awake state changes: 6 cached images.
- No numbers and no countdown in the menu bar.
- Accessibility label: "Pith: {title}." plus, while awake, "Awake until {time}." or
  "Awake until you end it.", plus "Even with the lid closed." while "Lid closed" is ticked.

### 3.2 Awake bar

The bar replaces the footer ("Updated just now" and "Pith") at the bottom of the panel, at the
same place and with the same top separator. It is not shown on the Settings page.

| State | Left | Right |
|---|---|---|
| Not awake | "Keep awake" (13 pt, secondary) | Three small buttons: "1 h", "4 h", "∞" |
| Awake, timed | "Awake until 3:40 PM" (13 pt, primary) | A checkbox "Lid closed" (Macs with a lid only), then "End" |
| Awake, no end | "Awake until you end it" | The same |

- The time uses the user's short time format. If the end is not today, the weekday comes
  first: "Awake until Thu 9:40 AM".
- No countdown. The text changes only on start and end, so the bar costs nothing while open.
- One click starts or ends. No confirm: both are harmless and undone with one more click. Each
  control acts once it has shown for 0.4 s, as the quit confirm does (R93), so the second click
  of a double-click never lands on the control that replaced the first: a double-click on End
  does not start a session, and one on a duration neither ends it nor ticks "Lid closed".
- VoiceOver: the buttons read "Keep awake for 1 hour", "Keep awake for 4 hours", "Keep awake
  until you end it", and "End keeping awake"; the checkbox reads "Stay awake with the lid
  closed".
- Colors: native greys only, as everywhere in the panel. The checkbox is the native one.

## 4. Design

### 4.1 Idle sleep

- **The hold:** one `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
  "Pith: keep awake")` per session, released by `IOPMAssertionRelease`, which must succeed.
  macOS releases it if Pith's process dies, so a crash leaves nothing behind. No powerd
  timeout: after powerd ends a timed assertion, a release call fails (spike, 2026-10-28), and
  one owner is simpler.
- **The end time:** one task that sleeps on the continuous clock until the end time, with 1 s
  of tolerance, then ends the session. The continuous clock keeps counting while the Mac
  sleeps, so the end lands on wake if the end time passed during sleep. No polling.
- **State:** `Store.awake: Awake?`, with `Awake { until: Date?, lidClosed: Bool }`. Start only
  when not awake; end only when awake (assert both).
- **Seam:** a `SleepHold` closure struct with `.main` (the assertion) and `.none` (holds
  nothing), the same pattern as `LoginItem`. Tests, `--demo` and `--render-panel` use `.none`,
  so they never hold the real Mac awake.
- **Monitor unchanged:** sampling still pauses on display sleep and lock during a session.
  Awake needs no sampling.

### 4.2 Lid closed

- **The flag:** `kPMSetClamshellSleepState` (selector 12 of the power root domain's user
  client, `IOPMLibDefs.h`) with 1 keeps a closed lid from sleeping the Mac, and with 0 lets it
  again. It needs no privilege. The lid test (MacBook Air M4, macOS 26.6.2, 2026-10-28) held a
  closed lid awake for 30 minutes on battery, and the Mac slept 5 s after the flag was cleared.
- **The catch:** the flag outlives the process that sets it; the same test killed the setter
  and the Mac stayed awake. So Pith never sets it from its own process.
- **The holder:** ticking the box starts a copy of Pith's own binary with `--hold-lid`, with a
  pipe as its input. The copy sets the flag, then clears it and exits on the first of:
  - end of input: Pith closed the pipe (untick, End, the end time) or Pith's process ended,
    even by a crash or SIGKILL, because the kernel closes a dead process's pipe;
  - SIGTERM, SIGINT or SIGHUP (`pkill -x Pith`, logout), handled from before the flag is set;
  - macOS's low-battery warning (`IOPSGetBatteryWarningLevel`, told by
    `kIOPSNotifyLowBattery`);
  - a thermal state of serious or critical.

  It waits on events only; nothing polls.
- **One copy at a time:** Pith clears the flag each time a copy exits, and starts a new copy
  only once the last one has exited. So a copy that died before it could clear leaves nothing
  set, an untick before the copy set the flag still ends clear, and a quick untick and tick
  never lets the old copy clear the new hold. When the copy ends and Pith did not stop it,
  Pith also unticks the box.
- **At launch:** on a Mac with a lid, Pith clears the flag once, for the case of both processes
  killed at once. The flag is shared with any other app that uses it, as Pith's own clear is.
- **A lid or not:** the power root domain reports `AppleClamshellState` only on a Mac with a
  lid. Without it, the bar shows no checkbox.
- **Seam:** a `LidHold` closure struct, `.main` (the copy) and `.none` (no lid, holds nothing).
  Tests use a stand-in executable, so they never set the real flag.

## 5. Budget

The speed budget (main spec section 10) holds unchanged, closed and open, with or without a
session. A session adds one sleeping task and nothing periodic. "Lid closed" adds the holder:
one more process, which sleeps until an event and draws nothing.

## 6. Testing

- Store: start acquires once; End releases once; the end time ends the session and releases;
  start while awake and End while not awake trap; a late End or duration click does nothing;
  the lid hold starts on tick and stops on untick and on the session's end; a hold that ends
  on its own unticks the box and keeps the session.
- Lid hold: with a stand-in executable, a stop ends it and Pith clears on its exit; a stop and
  a start before it ran start the new copy only after the old one exited; one that dies makes
  Pith clear the flag and untick, once; a child that Pith starts later does not keep the input
  open.
- Status item: 6 images; the image changes only when the dot state or the awake state changes;
  the accessibility label carries the awake sentence and the lid sentence.
- Native interaction: each button starts the matching session (with `.none`), and End returns
  the bar to "Keep awake"; on a Mac with a lid the checkbox waits 0.4 s, then ticks and
  unticks; without a lid it is absent.
- On a laptop, by hand, with the installed app: a closed lid stays awake on battery and on
  power; killing Pith, or the holder, lets a closed lid sleep within seconds.
- `--render-panel` also renders the calm demo with a session running, for screenshots.
- `perf.sh` and `accuracy.sh` run at release, as for every release.

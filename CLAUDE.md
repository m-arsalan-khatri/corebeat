# CoreBeat

Menu-bar-only macOS app that reports which apps have departed from *their own*
normal CPU usage, and offers one-click interventions — pause, throttle, quit —
on the offender.

The distinction from every other system monitor is the baseline. "What is using
the most CPU" has a boring, unchanging answer on a busy Mac. "What is different
from ten minutes ago" is the useful question, and it is the only one this app
tries to answer.

## Open items

Nothing here is broken. These are decisions left open when the app was built,
written down so the next session does not rediscover them or silently decide
them on Arsalan's behalf.

The three that needed a call have all been answered — see *Decisions taken*
below. What is left is genuinely small.

**Loose ends**

- **Nothing is pushed yet.** The README, `install.sh`, the landing page and the
  carousel all point at `github.com/m-arsalan-khatri/corebeat` and
  `m-arsalan-khatri.github.io/corebeat`. Neither exists until the repo is
  created and Pages is switched on for `/docs` on `main`. Every one of those
  URLs is dead until then.
- No `.icns`. Harmless while `LSUIElement` keeps it out of the Dock, but Finder
  and the About panel show a generic icon. The site and the carousel now have a
  mark to derive one from — the pulse trace in `docs/favicon.svg`.
- The migration read of the `com.arsalaniqbal.chipcrawl` defaults domain in
  `Interventions.recoverFromPreviousRun` is one-shot cleanup. It can go once
  nobody is running a build from before the rename.

## Decisions taken

Answered by Arsalan, recorded here so they are not reopened.

- **The name does work now.** `Level` is `steady / elevated / racing`, and the
  tooltip is one word from that same ladder: `CPU 92% · racing`. A known cause
  still displaces the word entirely, because "Time Machine, backing up" beats
  any adjective about the pulse. Note this dropped the old red-state string
  "click to see what changed" — the affordance is gone in exchange for one
  consistent vocabulary.
- **Broad load is stated outright.** When the machine is at 50% or more and no
  app owns a third of it, the headline reads `spread across many apps` instead
  of `nothing unusual`. It is a claim about the current sample only — no
  baseline involved — which is why it is also allowed to speak before
  calibration, where the alternative was telling someone with a pegged Mac that
  we are still learning. Changes still win the headline when there are any.
- **Renamed from ChipCrawl to CoreBeat**, including the bundle id
  (`com.arsalaniqbal.corebeat`).

## Commands

```bash
./build.sh     # universal, ad-hoc signed bundle -> build/CoreBeat.app
./test.sh      # what CI runs: shell lint, Swift 6 warnings-as-errors, behaviour, bundle checks
./install.sh   # build from source and install to /Applications
```

## Layout

```
Sources/Sampling.swift       reading CPU from the system
Sources/Diagnosis.swift      grouping, baselines, change detection
Sources/KnownCauses.swift    explanations for routine background work
Sources/Interventions.swift  pause/throttle/quit, and the safety rules
Sources/StatusBar.swift      the icon and the menu
Sources/main.swift           AppKit wiring and the two timers
tools/verify/                headless behaviour tests
tools/menudump/              prints the live menu to stdout
docs/                        the landing page, served by GitHub Pages
```

## The landing page and the carousel

`docs/` is the site at `m-arsalan-khatri.github.io/corebeat`. Same rules as the
app: one self-contained HTML file, zero dependencies, and a CSP that forbids
loading anything from another origin — so it can never quietly grow an analytics
script. It styles both colour schemes, and the viewer's explicit choice beats the
media query in both directions.

The menu in the hero is a live replica driven by the *same* level rule the app
uses (median of the last 8 samples, 50/80 thresholds), and its remainder row is
computed rather than typed, so the demo cannot drift out of reconciliation the
way a hand-written mock would. It only ticks while the tab is visible.

`og.png` is generated, never edited:

```bash
cd docs && "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --screenshot=og.png og.source.html
```

The LinkedIn carousel lives outside the repo at `~/Desktop/corebeat-carousel/`
— `carousel.html` is the source, the PDF and the eleven 2160×2160 PNGs are
generated from it, and `post-caption.md` holds the caption plus both sets of
regeneration commands. It is deliberately not checked in: it is marketing copy
with a shelf life, not part of the app.

No Xcode project, no package manager, no dependencies. Command Line Tools only
(version 16+, since the app builds in Swift 6 language mode).

## Invariants — don't break these

Each of these has a reason that is not obvious from the code alone.

1. **A paused process always comes back.** Four mechanisms, all tested:
   a 10-minute auto-resume, `applicationWillTerminate`, an async-signal-safe
   `SIGTERM`/`SIGINT`/`SIGHUP`/`SIGQUIT` handler, and a set persisted to disk
   for the `SIGKILL` case. This is the single most important property here — a
   Mac left with a permanently frozen app, by a utility installed to make things
   better, is far worse than the slowdown it was fixing. The signal handler
   walks a fixed C buffer, not a Swift dictionary, because only the former is
   async-signal-safe.

2. **The app never escalates privileges.** No `sudo`, no admin prompt, no
   helper tool. Processes owned by other users are measured and displayed but
   are not actionable. An app that cannot escalate cannot be tricked into
   escalating, and that is worth more than the ability to kill `mds_stores`.

3. **Sampling goes through `/bin/ps`, not `libproc`.** This looks like the wrong
   call until you measure it. `proc_pid_rusage` and `PROC_PIDTASKINFO` refuse
   processes you do not own — 423 of 600 pids were readable on the development
   machine — which hides WindowServer, antivirus and MDM agents, i.e. some of
   the most common real culprits. `top -l 2` sees everything but costs 5.5s and
   2.9s of CPU per sample. `ps` is setuid root, costs ~50ms, and its centisecond
   `TIME` column differences to within 1% of `top`. Do not "optimise" this back
   to libproc.

4. **Two cadences, because the two sources cost different amounts.**
   `host_statistics` is microseconds, so the menu bar number updates every 2s.
   `ps` is a fork, so the process table updates every 4s. Do not put the process
   sample on the fast timer.

5. **A newly seen pid falls back to its lifetime average, but only if it is
   young.** Without this a brand-new CPU hog reads as 0% for a full cycle, which
   is exactly the case the app exists to catch. Applying it to *old* processes
   instead would libel a long-idle daemon with its startup cost, so the age
   check is load-bearing in both directions.

6. **Percentages are shares of the whole machine, not of one core.** 3 cores of
   10 reads as 30%, not Activity Monitor's 300%. This keeps the per-app numbers
   and the menu bar number on one scale. Changing it means changing both, or
   the menu stops making sense.

7. **The rows must add up to the header.** Named apps always fall short — a
   long tail of ~380 processes, plus work `ps` cannot attribute to anything
   (`kernel_task`, and processes that start and exit between two readings).
   Measured at 56% load: 41.4% visible, 7.3% tail, 7.1% unattributable. The
   "Everything else" row carries the remainder, and `tools/menudump` fails the
   build if the column stops reconciling. Do not drop that row to save space:
   the first thing anyone does with a column of percentages is add it up, and
   coming up 15 points short discredits the header.

8. **Steady load is never reported as a change.** There is a test named after
   this. An app pinned at 40% forever must not appear under "What changed" — the
   moment it does, the section becomes the same noise as every other monitor and
   the product has no reason to exist.

9. **No number in the menu bar.** Colour on a sustained reading is the whole
   signal: `steady` monochrome under 50%, `elevated` amber to 80%, `racing` red
   above. Two rules keep it from crying wolf, and both are tested — the level
   uses the *median of the last ~16s*, never the latest sample, because single
   100% readings happen on every app launch; and load owned 40%-or-more by
   routine work is damped to `elevated`, because a Mac pinned by a backup is
   working, not broken. Re-adding a percentage would undo the point: a bare
   number cannot distinguish a build from a runaway, which is the only
   distinction that matters at a glance.

   The three words are the one place the name earns its keep, so `Level`,
   `StatusIcon.summary` and the README table must not drift apart. `menudump`
   asserts the tooltip strings literally for exactly this reason — a word that
   disagrees with its tint is invisible in a screenshot.

10. **`KnownCauses` entries describe, they do not advise.** Each says what a
    process is for and whether the work is finite. `endsOnItsOwn` is load-
    bearing — it damps the menu bar colour and it is a promise to the user, so
    it is set only where the work genuinely terminates. WindowServer is the
    worked example: explained, but explicitly *not* self-resolving, because
    sustained WindowServer load is a symptom of how the machine is being used.
    Matching runs against the executable path as well as its name; without that,
    ManageEngine's `dcuserhandler` and most antivirus daemons are unidentifiable.

## Conventions

- Comments explain *why*, not *what*.
- **Plain, calm user-facing strings.** No alarm language, no exclamation marks.
  The app appears when something is already going wrong; it should read like a
  colleague pointing at a line of a log, not a warning dialog.
- Claims in the UI must be earned. "Nothing unusual" is only shown once a
  baseline exists; before that it says it is still learning. Do not replace that
  with a confident-sounding default. "Spread across many apps" is the one
  verdict allowed to speak before calibration, and only because it is a
  statement about the sample in hand rather than about what is normal.
- **Scope is the feature.** CPU only. No memory/disk/network/GPU/thermal
  monitoring, no preferences window, no history graphs. Stats already does all
  of that, is free and open source, and is linked from the README for exactly
  this reason.

## Testing

`test.sh` is what CI runs. A menu bar app needs a logged-in GUI session, so the
app itself cannot be clicked, but everything short of that is covered:

- `tools/verify` exercises the sampler against the real process table, drives
  the change detector with synthetic samples over a controlled timeline, and
  tests the resume guarantee by actually killing child processes and checking
  the victim thawed.
- `tools/menudump` builds the real menu from a real sample and prints it, which
  catches anything that would crash or render empty. Run it on its own to see
  what the app currently says.

To check the sampler against the system's own numbers by hand, compare
`tools/menudump` output with `top -l 2 -o cpu` — remembering that `top` reports
per-core percentages, so its figures are `cores ×` larger.

### You cannot see the menu bar

Screen recording is denied to the terminal, so `screencapture` fails with
"could not create image from display" and an agent working here cannot look at
its own UI. `tools/menudump` covers structure, wording and column widths, and
it should be extended whenever a new visual rule needs protecting — it already
fails the build if a name overflows its column or the percentages stop
reconciling with the header.

It does not cover appearance. **Every layout bug found so far came from a
screenshot Arsalan sent**: a name running into its percentage, a row wrapping
and orphaning its number, square corners on the icon fill. When the question is
genuinely visual, ask for one rather than guessing.

### Time fields lie about their units

Twice now, a Darwin struct has reported CPU time in **mach absolute time units**
while naming the field as though it were nanoseconds:

- `proc_taskinfo.pti_total_user` / `pti_total_system`
- `rusage_info_v4.ri_user_time` / `ri_system_time`

Both need `mach_timebase_info` applied (125/3 on Apple silicon). Read as
nanoseconds they come out ~40× too small, which looks like a plausible small
number rather than an obvious error — the second one shipped as a *test* failure
blaming the app for a fault that was in the test. Before trusting any new CPU
time source, measure it against a process pegging one core (`yes > /dev/null`)
and check it agrees with `ps`.

## Known limitations

- `kernel_task` is invisible to `ps`, so the per-app figures sum to slightly
  less than the host CPU figure. This is expected, and is the main reason the
  test bounds on that comparison are loose.
- `Ease Off` (`PRIO_DARWIN_BG`) is a brake, not a dial. macOS offers no way to
  cap a process at a specific percentage, and `renice` does essentially nothing
  on Apple Silicon.
- Launch-at-login registration fails when the app runs from `./build`; macOS
  only accepts it for an installed bundle. The checkbox silently stays off,
  which is correct behaviour rather than a bug to fix.

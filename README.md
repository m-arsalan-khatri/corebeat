# CoreBeat

A menu bar app that answers one question: **what changed?**

Your Mac is suddenly slow. You open Activity Monitor, sort by CPU, and see the
same apps that are always at the top — Chrome, your editor, WindowServer. The
list looks identical whether the machine is fine or struggling, so it tells you
nothing. You close it none the wiser.

CoreBeat watches each app against *its own* normal and reports departures.
Chrome at 30% is unremarkable if Chrome is always at 30%. Chrome at 30% after
ten minutes at 2% is your answer.

```
CPU 71%  ·  2 apps above normal

  Google Chrome        24%    was 3% · 4 min ago
  node                 12%    just started
  ────────────────────────
  Cursor               11%
  VirtualMachine      4.6%
  ────────────────────────
  Background work      12%    3 routine tasks
  Everything else      7.4%   358 small + kernel
  ────────────────────────
  Paused
  Slack                       resumes in 8 min
```

Every row is a menu. Pause it, ease it off, quit it — without leaving the menu
bar.

The line at the top is the whole answer when there is one. When nothing has
departed from its baseline it says `nothing unusual` — and when the machine is
genuinely loaded but no app owns more than a third of it, it says
`spread across many apps`, because "nothing unusual" is technically true and
useless to someone whose Mac is dragging.

## The menu bar shows a trend, not a number

There is no percentage in the menu bar. A number invites you to read it
constantly and tells you nothing on its own — 70% is fine during a build and
alarming while you are typing into a text field. The shape of the last minute
says more: a step up that stays up looks nothing like a spiky sawtooth.

Colour answers the only question worth asking at a glance:

| Colour | Sustained CPU | The word | What it means |
|---|---|---|---|
| **Monochrome** | under 50% | **steady** | Normal. It blends into the menu bar; ignore it. |
| **Amber** | 50–80% | **elevated** | Working. Expected during a build or a render. Worth a glance if the Mac feels slow. |
| **Red** | over 80% | **racing** | Pegged, with nothing routine to account for it. Worth opening. |

Two things stop it crying wolf:

- **It judges sustained load, not the latest reading.** The level comes from the
  median of the last ~16 seconds. Single 100% samples happen constantly — every
  app launch, every page load — and a menu bar that flashes red at each one is
  one you learn to ignore within a day.
- **Known, finite work is damped to amber.** A Mac pinned by a Time Machine
  backup is busy, not broken. If routine background work owns 40% or more of the
  load, it never goes red.

Hover for the number and the word — `CPU 92% · racing` — or, when the load has a
known cause, the cause instead: `CPU 78% · Time Machine, backing up`.

## Known causes

A lot of high CPU on a Mac is routine work that ends by itself, and unexplained
it looks identical to a runaway process. CoreBeat recognises the common ones,
collapses them into a single **Background work** row, and explains them:

Spotlight indexing · Time Machine · Photos and media analysis · macOS updates ·
software installs · XProtect malware scans · Gatekeeper checks · iCloud sync ·
Rosetta translation · scheduled maintenance · antivirus scans (Kaspersky, Sophos,
CrowdStrike, Defender and others) · device management agents (ManageEngine, Jamf,
Intune and others) · WindowServer

Clicking it breaks the total down by task, and each gives the full explanation — what it is, why it is running, and
whether it will stop on its own. Recognition works on the executable's path as
well as its name, which matters because the agent eating your CPU is often called
something like `dcuserhandler` and only identifiable as ManageEngine by where it
lives.

Entries describe what a process is for, never what you should do about it, and
nothing is marked as self-resolving unless the work is genuinely finite —
WindowServer is explained but explicitly not, because sustained WindowServer load
is a symptom of how you are using the machine.

## Install

```bash
git clone <this repo> && cd CoreBeat && ./install.sh
```

Needs the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.
No dependencies, no Xcode project, no package manager.

It builds on your machine on purpose: locally built apps are never quarantined,
so there is no Gatekeeper warning and no paid Apple Developer account involved.

## What you can do about it

Four interventions, gentlest first. All of them are one click from the menu bar.

| | What it does | Reversible |
|---|---|---|
| **Pause** | Stops the app using any CPU at all, keeping every window and all its state. `SIGSTOP`. | Yes — and it resumes itself after 10 minutes |
| **Ease Off** | Leaves it running but pins it to the efficiency cores and throttles its disk I/O. `PRIO_DARWIN_BG`, the same thing `taskpolicy -b` does. | Yes |
| **Quit** | Asks it to close normally, so it can save first. `SIGTERM`. | No |
| **Force Quit** | Kills it. Asks first, because unsaved work is lost. `SIGKILL`. | No |

**Pause is the interesting one.** It is the only intervention that costs you
nothing if you were wrong: a compile finishes, a call ends, you resume, and the
app never noticed. It is safe to reach for precisely because a paused process
is guaranteed to come back — see [the resume guarantee](#the-resume-guarantee).

## Prior art — read this before adding anything

This deliberately does *not* try to be a system monitor. Several already exist
and are better at it than this will ever be:

| | | |
|---|---|---|
| **[Stats](https://github.com/exelban/stats)** | Free, open source | The one to use if you want a dashboard. CPU, GPU, RAM, disk, network, sensors, battery. Genuinely excellent. |
| **[iStat Menus](https://bjango.com/mac/istatmenus/)** | ~$12 | The polished commercial version of the same idea. |
| **[App Tamer](https://www.stclairsoft.com/AppTamer/)** | ~$15 | The closest thing on the intervention side — automatic `SIGSTOP` throttling of background apps. |
| **[Vitals](https://github.com/angristan/vitals)** | Free, open source | Per-process CPU graphs over the last 60 seconds. Monitoring only, no actions. |
| **Activity Monitor** | Built in | Has every number. Requires you to go and interpret them. |

What none of them do is compare against a **baseline**. They all answer "what is
using the most CPU", which on a busy Mac is a question with a boring and
unchanging answer. CoreBeat answers "what is different from ten minutes ago",
and then lets you act on it in the same click.

**If you want live graphs, sensors and fan speeds, install Stats instead — this
is not competing with it, and the two sit happily side by side.**

## How it works

**The menu bar number** comes from `host_statistics`, a syscall costing
microseconds. That is why it can update every two seconds without mattering.

**The process list** comes from `/bin/ps`, forked every four seconds,
differencing each process's cumulative CPU time between samples. This is the
unglamorous approach and it was chosen on evidence:

- `libproc` (`proc_pid_rusage`, `PROC_PIDTASKINFO`) is the obvious API, and it
  refuses processes you do not own — on the machine this was built on, 423 of
  600. WindowServer, `mds_stores`, antivirus daemons and MDM agents are all
  invisible to it, and those are some of the most common reasons a Mac drags.
  A diagnosis that silently omits them is wrong, not merely incomplete.
- `top -l 2` sees everything, but costs 5.5 seconds and ~2.9 seconds of CPU per
  sample. A monitor that shows up in its own list has failed.
- `/bin/ps` is setuid root, so it reports every process, costs ~50ms, and its
  `TIME` column has centisecond resolution. Differencing two samples gives a
  true instantaneous rate — measured against `top` on the same process: 44.5%
  vs 45.1%.

CoreBeat's own cost is about 0.1% of the machine and ~35 MB.

**Percentages are shares of the whole machine, not of one core.** An app
saturating 3 cores of 10 reads as 30%, where Activity Monitor would say 300%.
This is a deliberate departure: it puts the app numbers and the menu bar number
on the same scale, so the column adds up to the header.

Making it actually add up needs one more row. The named apps always fall short
of the total, for two reasons worth knowing about:

- **A long tail.** There are usually ~380 apps running and the menu shows six.
  The rest use a fraction of a percent each and a meaningful amount together.
- **Work `ps` cannot attribute to any process.** `kernel_task` is invisible to
  it, as is anything that starts and exits between two readings.

Measured on a 10-core M4 at 56% load: 41.4% in the visible rows, 7.3% in the
tail, 7.1% unattributable. So the last row is **Everything else**, carrying the
remainder. `./test.sh` fails if the column stops reconciling with the header.

## The resume guarantee

A Mac left with a permanently frozen app — by a utility you installed to make
things *better* — is a far worse outcome than the slowdown it was fixing. So a
paused process is guaranteed to come back, by four independent mechanisms:

1. It resumes itself after 10 minutes, whatever else happens.
2. Quitting CoreBeat normally resumes everything it paused.
3. `SIGTERM`/`SIGINT`/`SIGHUP`/`SIGQUIT` — logout, shutdown, `killall` — are
   caught and resume everything first, from an async-signal-safe handler.
4. `SIGKILL` and kernel panics cannot be caught, so the paused set is written to
   disk. The next launch resumes anything an unclean exit left behind.

All four are covered by `./test.sh`, mechanisms 3 and 4 by actually killing a
child process and checking the victim thawed.

## What it will not do

- **It never asks for an admin password.** Root-owned processes are shown and
  measured, but not actionable — an app that cannot escalate cannot be tricked
  into escalating. If `dcuserhandler` is eating your CPU, CoreBeat will name
  it and you can deal with it yourself.
- **Processes macOS needs are protected outright** — the Dock, `loginwindow`,
  WindowServer, `coreaudiod` and friends can be seen but not touched, however
  much CPU they are using.
- **No memory, disk, network, GPU or thermal monitoring.** Scope is the feature.
  Stats does all of that well.

## Development

```bash
./build.sh     # universal, ad-hoc signed bundle -> build/CoreBeat.app
./test.sh      # what CI runs
./install.sh   # build and install to /Applications
```

`tools/menudump` prints the current menu to the terminal, which is the fastest
way to see what the app would say without clicking anything.

## Licence

MIT.

import Darwin
import Foundation

// Headless exercise of everything under Sources that is not AppKit. A menu bar
// app cannot be driven in CI, but the sampler, the grouping, the change
// detector and — most importantly — the resume guarantee all can be.
//
// Run via ./test.sh.

// Child modes, used by the crash-recovery tests below. They have to run in a
// separate process because the thing being tested is what happens to a paused
// process when the app holding it goes away.
if CommandLine.arguments.count >= 2 {
    let mode = CommandLine.arguments[1]
    let target = CommandLine.arguments.count >= 3 ? pid_t(CommandLine.arguments[2]) ?? 0 : 0
    let victim = AppRow(
        identity: Identity(key: "bin:sh", name: "sh"), cpu: 0, rssBytes: 0,
        members: [ProcessRow(pid: target, uid: getuid(), name: "sleep", command: "/bin/sleep",
                             cpu: 0, rssBytes: 0, stopped: false, age: 1)])
    switch mode {
    case "pause-and-die":
        // Pause, then leave without cleaning up — what a SIGKILL or a panic
        // looks like from the paused process's point of view.
        Interventions.shared.pause(victim)
        _exit(0)
    case "pause-and-wait":
        // Pause, then sit still until signalled, so the SIGTERM handler runs.
        Interventions.shared.pause(victim)
        while true { Thread.sleep(forTimeInterval: 1) }
    case "recover":
        // Constructing the singleton is what triggers recovery.
        _ = Interventions.shared
        exit(0)
    default:
        break
    }
}

var failures = 0

@MainActor
func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func section(_ title: String) { print("\n\(title)") }

// MARK: - Field parsing

section("ps field parsing")
check("mmm:ss.cc", Sampling.parseCPUTime("3798:27.99").map { abs($0 - 227_907.99) < 0.01 } ?? false,
      "got \(String(describing: Sampling.parseCPUTime("3798:27.99")))")
check("hh:mm:ss", Sampling.parseElapsed("01:02:03").map { $0 == 3723 } ?? false)
check("dd-hh:mm:ss", Sampling.parseElapsed("2-01:00:00").map { $0 == 176_400 } ?? false)
check("mm:ss", Sampling.parseElapsed("07:30").map { $0 == 450 } ?? false)
check("garbage rejected", Sampling.parseCPUTime("not-a-time") == nil)

// MARK: - Grouping

section("process grouping")
let chromeGPU = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/151.0.7922.137/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
let chromeMain = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
check("nested helper groups under outer bundle",
      identity(forCommand: chromeGPU).name == "Google Chrome",
      "got \(identity(forCommand: chromeGPU).name)")
check("helper shares its parent's key",
      identity(forCommand: chromeGPU).key == identity(forCommand: chromeMain).key)
check("helper keeps a distinct leaf name",
      leafName(forCommand: chromeGPU) == "Google Chrome Helper (GPU)")
check("non-bundle binary uses its basename",
      identity(forCommand: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer").name == "WindowServer")
check("setproctitle label is trimmed at the colon",
      identity(forCommand: "Cursor Helper (Plugin): extension-host (retrieval) X [12-584]").name
        == "Cursor Helper (Plugin)")
check("bundle path resolves for Reveal in Finder",
      bundlePath(forCommand: chromeGPU) == "/Applications/Google Chrome.app",
      "got \(String(describing: bundlePath(forCommand: chromeGPU)))")

// MARK: - Sampling against the system's own numbers

section("sampler")
guard let first = Sampling.captureProcesses() else {
    print("  FAIL could not read the process table")
    exit(1)
}
check("sees a plausible number of processes", first.processes.count > 50,
      "got \(first.processes.count)")
check("sees processes we do not own",
      first.processes.contains { $0.uid != getuid() },
      "root-owned processes are invisible — the diagnosis would be wrong")
check("kernel/system processes are present",
      first.processes.contains { $0.command.contains("WindowServer") })

let diagnosis = Diagnosis()
diagnosis.ingest(first)
check("a single sample yields no rates", !diagnosis.hasRates)

// A busy child, measured two completely different ways. `ps` is what the app
// uses; proc_pid_rusage is libproc, which works here only because we own the
// child. Agreement between them checks the arithmetic for real.
//
// The earlier version of this asserted the child would read as one whole core.
// That is not true on a machine that is already busy — it competes like
// anything else — and the test failed at 6.3% of a 10-core box for no reason
// other than the box being loaded. Never assert how much CPU a process will
// win; assert that two ways of measuring it agree.
let burner = Process()
burner.executableURL = URL(fileURLWithPath: "/bin/sh")
burner.arguments = ["-c", "end=$((SECONDS+12)); while [ $SECONDS -lt $end ]; do :; done"]
try? burner.run()
let burnerPID = burner.processIdentifier

func consumedCPUSeconds(_ pid: pid_t) -> Double? {
    var usage = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard ok == 0 else { return nil }

    // ri_user_time and ri_system_time are mach absolute time units, not the
    // nanoseconds the field names imply. Measured on a process pegging one
    // core for 3.09s: ps reported 2.15s of CPU, and so does this — but only
    // once the timebase is applied. Read as nanoseconds it comes out at 0.05s.
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(usage.ri_user_time + usage.ri_system_time)
        * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

Thread.sleep(forTimeInterval: 1)
guard let second = Sampling.captureProcesses(), let burnedBefore = consumedCPUSeconds(burnerPID)
else {
    print("  FAIL second sample failed")
    exit(1)
}
diagnosis.ingest(second)
check("two samples yield rates", diagnosis.hasRates)

Thread.sleep(forTimeInterval: 3)
guard let third = Sampling.captureProcesses(), let burnedAfter = consumedCPUSeconds(burnerPID)
else {
    print("  FAIL third sample failed")
    exit(1)
}
diagnosis.ingest(third)

let expected = Scale.normalize(
    coreSeconds: burnedAfter - burnedBefore, over: third.at.timeIntervalSince(second.at))
let reported = diagnosis.apps.flatMap(\.members).first { $0.pid == burnerPID }?.cpu
let reportedText = reported.map { String(format: "%.1f%%", $0) } ?? "nothing"
check("the burner produced measurable load", expected > 1,
      String(format: "only %.1f%% — machine too busy for this check to mean anything", expected))
check("ps-derived CPU agrees with libproc for the same process",
      reported.map { abs($0 - expected) <= max(0.8, expected * 0.2) } ?? false,
      "libproc says \(String(format: "%.1f%%", expected)), ps-derived says \(reportedText)")

let total = diagnosis.apps.reduce(0) { $0 + $1.cpu }
check("total across all apps is a sane share of the machine", total > 0 && total < 100 * 1.2,
      "got \(String(format: "%.1f", total))%")
burner.terminate()

// The per-process figures come from differencing ps; the host figure comes
// from host_statistics. They are wholly independent measurements of the same
// thing, so agreeing to within a factor catches a normalisation mistake that
// no amount of internal consistency would. Bounds are loose on purpose: ps
// cannot see kernel_task, and the two windows do not line up exactly.
section("per-process totals agree with the host counter")
guard let hostBefore = Sampling.hostTicks(), let psBefore = Sampling.captureProcesses() else {
    print("  FAIL could not take a paired sample")
    exit(1)
}
Thread.sleep(forTimeInterval: 3)
guard let hostAfter = Sampling.hostTicks(), let psAfter = Sampling.captureProcesses() else {
    print("  FAIL could not take a paired sample")
    exit(1)
}
let paired = Diagnosis()
paired.ingest(psBefore)
paired.ingest(psAfter)
let processSum = paired.apps.reduce(0) { $0 + $1.cpu }
let hostBusy = Double(hostAfter.busy - hostBefore.busy) / Double(hostAfter.total - hostBefore.total) * 100
check("process sum is within a factor of the host reading",
      hostBusy > 1 ? (processSum > hostBusy * 0.4 && processSum < hostBusy * 2.0) : true,
      String(format: "processes summed to %.1f%%, host says %.1f%%", processSum, hostBusy))
print(String(format: "    processes %.1f%%  ·  host %.1f%%", processSum, hostBusy))

print("\n  top apps as CoreBeat sees them:")
for app in diagnosis.apps.prefix(6) where app.cpu >= 0.5 {
    print(String(format: "    %-34s %5.1f%%  (%d proc)",
                 (app.identity.name as NSString).utf8String!, app.cpu, app.members.count))
}

// MARK: - Change detection
//
// The whole premise of the app: a spike is reported, and steady load — however
// heavy — is not. Driven with synthetic samples because a real baseline takes
// minutes to establish and has to be reproducible.

section("change detection")

/// Cumulative core-seconds a process at `percent` of the whole machine would
/// have burned over `seconds`.
func coreSeconds(percent: Double, over seconds: Double) -> Double {
    percent / 100 * Double(Sampling.coreCount) * seconds
}

func fakeProcess(pid: pid_t, name: String, cpuSeconds: Double, age: Double) -> RawProcess {
    RawProcess(
        pid: pid, ppid: 1, uid: getuid(), stopped: false, age: age,
        cpuSeconds: cpuSeconds, rssBytes: 4096,
        command: "/Applications/\(name).app/Contents/MacOS/\(name)")
}

let cadence = 4.0
let sampleCount = 100
let origin = Date().addingTimeInterval(-cadence * Double(sampleCount))
let spikeIndex = 90 // ~40s before the end, leaving a clean baseline window

let engine = Diagnosis()
var spikerSeconds = 0.0
var steadySeconds = 0.0

for index in 0..<sampleCount {
    let at = origin.addingTimeInterval(cadence * Double(index))
    if index > 0 {
        // Spiker: quiet at 2%, then 40% once the spike starts.
        spikerSeconds += coreSeconds(percent: index >= spikeIndex ? 40 : 2, over: cadence)
        // Steady: a constant 40% for the entire window.
        steadySeconds += coreSeconds(percent: 40, over: cadence)
    }
    engine.ingest(RawSample(at: at, processes: [
        fakeProcess(pid: 900_001, name: "Spiker", cpuSeconds: spikerSeconds,
                    age: 7200 + cadence * Double(index)),
        fakeProcess(pid: 900_002, name: "Steady", cpuSeconds: steadySeconds,
                    age: 7200 + cadence * Double(index)),
    ]))
}

let spikerChange = engine.changes.first { $0.app.identity.name == "Spiker" }
let steadyChange = engine.changes.first { $0.app.identity.name == "Steady" }

check("a spike is reported", spikerChange != nil)
check("steady load is NOT reported — this is the whole point",
      steadyChange == nil,
      "a constantly-busy app was flagged as a change, which would make the list noise")

if let spikerChange {
    check("reported level matches the spike",
          abs(spikerChange.now - 40) < 5,
          String(format: "expected ~40%%, got %.1f%%", spikerChange.now))
    check("baseline recovers the quiet level",
          spikerChange.baseline.map { abs($0 - 2) < 2 } ?? false,
          "expected ~2%, got \(spikerChange.baseline.map { String(format: "%.1f%%", $0) } ?? "none")")
    check("not mistaken for a new process", !spikerChange.isNew)
    let onsetAge = Date().timeIntervalSince(spikerChange.startedAt)
    let expectedAge = cadence * Double(sampleCount - spikeIndex)
    check("onset lands where the spike began",
          abs(onsetAge - expectedAge) < cadence * 2.5,
          String(format: "expected ~%.0fs ago, got %.0fs ago", expectedAge, onsetAge))
}

// A process that has only just launched has no baseline, but its arrival is
// itself the change and must still be reported.
section("newly launched processes")
let launcher = Diagnosis()
let now = Date()
launcher.ingest(RawSample(at: now.addingTimeInterval(-cadence), processes: [
    fakeProcess(pid: 900_003, name: "Latecomer",
                cpuSeconds: coreSeconds(percent: 30, over: 20), age: 20),
]))
launcher.ingest(RawSample(at: now, processes: [
    fakeProcess(pid: 900_003, name: "Latecomer",
                cpuSeconds: coreSeconds(percent: 30, over: 20 + cadence), age: 20 + cadence),
]))
let arrival = launcher.changes.first { $0.app.identity.name == "Latecomer" }
check("a new hog is reported on arrival", arrival != nil)
check("and is marked as new rather than given a bogus baseline",
      arrival?.isNew == true)

// A process first seen mid-flight, but old, must not be reported: its lifetime
// average says nothing about what it is doing now.
let stranger = Diagnosis()
stranger.ingest(RawSample(at: now.addingTimeInterval(-cadence), processes: [
    fakeProcess(pid: 900_004, name: "Veteran",
                cpuSeconds: coreSeconds(percent: 80, over: 9000), age: 9000),
]))
stranger.ingest(RawSample(at: now, processes: [
    fakeProcess(pid: 900_004, name: "Veteran",
                cpuSeconds: coreSeconds(percent: 80, over: 9000), age: 9000 + cadence),
]))
check("a long-running process is not libelled by its lifetime average",
      stranger.changes.isEmpty,
      "an idle-but-old process was reported as a spike")

// MARK: - Known causes

section("known causes")

func appNamed(_ name: String, command: String, cpu: Double = 20) -> AppRow {
    AppRow(
        identity: Identity(key: "k:\(name)", name: name), cpu: cpu, rssBytes: 0,
        members: [ProcessRow(pid: 4242, uid: 0, name: name, command: command,
                             cpu: cpu, rssBytes: 0, stopped: false, age: 60)])
}

check("Spotlight is recognised by process name",
      KnownCauses.match(appNamed("mds_stores", command: "/usr/libexec/mds_stores"))?.title
        == "Spotlight indexing")
check("Time Machine is recognised",
      KnownCauses.match(appNamed("backupd", command: "/System/.../backupd"))?.title
        == "Time Machine backup")
// The name alone is meaningless here; only the path identifies it.
check("a management agent is recognised by its path, not its name",
      KnownCauses.match(appNamed(
        "dcuserhandler",
        command: "/Library/ManageEngine/UEMS_Agent/bin/dcuserhandler"))?.title
        == "Device management agent",
      "got \(KnownCauses.match(appNamed("dcuserhandler", command: "/Library/ManageEngine/UEMS_Agent/bin/dcuserhandler"))?.title ?? "nothing")")
check("antivirus is recognised by vendor path",
      KnownCauses.match(appNamed(
        "kavd",
        command: "/Applications/Kaspersky Anti-Virus For Mac.app/Contents/MacOS/kavd"))?.title
        == "Antivirus scan")
check("WindowServer is explained but not called self-resolving",
      KnownCauses.match(appNamed("WindowServer", command: "/System/.../WindowServer"))
        .map { !$0.endsOnItsOwn } ?? false)
check("an ordinary app matches nothing",
      KnownCauses.match(appNamed(
        "Google Chrome",
        command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")) == nil,
      "an ordinary app was given a bogus explanation")

check("routine load is summed",
      abs(KnownCauses.routineLoad(in: [
        appNamed("mds_stores", command: "/usr/libexec/mds_stores", cpu: 12),
        appNamed("Google Chrome", command: "/Applications/Google Chrome.app/x", cpu: 30),
      ]) - 12) < 0.01)

// MARK: - Host CPU

section("host CPU")
guard let ticksA = Sampling.hostTicks() else {
    print("  FAIL host_statistics unavailable")
    exit(1)
}
Thread.sleep(forTimeInterval: 1)
guard let ticksB = Sampling.hostTicks() else {
    print("  FAIL host_statistics unavailable")
    exit(1)
}
let busy = Double(ticksB.busy - ticksA.busy) / Double(ticksB.total - ticksA.total) * 100
check("host CPU is a percentage", busy >= 0 && busy <= 100, "got \(busy)")

// MARK: - The resume guarantee
//
// This is the part that must never regress: a paused process has to come back.

section("pause and resume")

func spawnSleeper() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 120"]
    try? process.run()
    Thread.sleep(forTimeInterval: 0.3)
    return process
}

func stateOf(_ pid: pid_t) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "state=", "-p", String(pid)]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func rowFor(_ process: Process) -> AppRow {
    let row = ProcessRow(
        pid: process.processIdentifier, uid: getuid(), name: "sh",
        command: "/bin/sh", cpu: 0, rssBytes: 0, stopped: false, age: 1)
    return AppRow(identity: Identity(key: "bin:sh", name: "sh"), cpu: 0, rssBytes: 0, members: [row])
}

let sleeper = spawnSleeper()
let sleeperRow = rowFor(sleeper)
Interventions.shared.pause(sleeperRow)
Thread.sleep(forTimeInterval: 0.3)
check("pause stops the process", stateOf(sleeper.processIdentifier).hasPrefix("T"),
      "state is \(stateOf(sleeper.processIdentifier))")

Interventions.shared.resume(sleeperRow)
Thread.sleep(forTimeInterval: 0.3)
check("resume restarts it", !stateOf(sleeper.processIdentifier).hasPrefix("T"),
      "state is \(stateOf(sleeper.processIdentifier))")
sleeper.terminate()

// Auto-resume: a pause must lapse on its own.
let lapsing = spawnSleeper()
let lapsingRow = rowFor(lapsing)
Interventions.shared.pause(lapsingRow)
Thread.sleep(forTimeInterval: 0.3)
check("paused before the deadline", stateOf(lapsing.processIdentifier).hasPrefix("T"))
Interventions.shared.enforceAutoResume(now: Date().addingTimeInterval(Interventions.autoResumeAfter + 1))
Thread.sleep(forTimeInterval: 0.3)
check("auto-resume lapses the pause", !stateOf(lapsing.processIdentifier).hasPrefix("T"),
      "state is \(stateOf(lapsing.processIdentifier))")
lapsing.terminate()

// Protected and foreign processes must be refused outright.
section("intervention safety")
let dockRow = AppRow(
    identity: Identity(key: "app:Dock", name: "Dock"), cpu: 0, rssBytes: 0,
    members: [ProcessRow(pid: 1, uid: getuid(), name: "Dock", command: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", cpu: 0, rssBytes: 0, stopped: false, age: 99)])
check("the Dock is protected", Interventions.shared.eligibility(of: dockRow) == .protected)

// A root-owned daemon that is not on the protected list: still refused,
// because signalling it would need privileges this app never asks for.
let rootRow = AppRow(
    identity: Identity(key: "bin:somedaemon", name: "somedaemon"), cpu: 0, rssBytes: 0,
    members: [ProcessRow(pid: 999_001, uid: 0, name: "somedaemon", command: "/usr/local/bin/somedaemon", cpu: 0, rssBytes: 0, stopped: false, age: 99)])
check("another user's process is not actionable",
      Interventions.shared.eligibility(of: rootRow) == .notOurs,
      "got \(Interventions.shared.eligibility(of: rootRow))")

// Protection wins over ownership, so the reason shown is the more specific one.
let windowServerRow = AppRow(
    identity: Identity(key: "bin:WindowServer", name: "WindowServer"), cpu: 0, rssBytes: 0,
    members: [ProcessRow(pid: 586, uid: 88, name: "WindowServer", command: "/x/WindowServer", cpu: 0, rssBytes: 0, stopped: false, age: 99)])
check("WindowServer is reported as protected, not merely foreign",
      Interventions.shared.eligibility(of: windowServerRow) == .protected)

// A protected process must survive an attempt to pause it.
let survivor = spawnSleeper()
let disguised = AppRow(
    identity: Identity(key: "app:Dock", name: "Dock"), cpu: 0, rssBytes: 0,
    members: [ProcessRow(pid: survivor.processIdentifier, uid: getuid(), name: "Dock",
                         command: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                         cpu: 0, rssBytes: 0, stopped: false, age: 99)])
Interventions.shared.pause(disguised)
Thread.sleep(forTimeInterval: 0.3)
check("pausing a protected process is a no-op", !stateOf(survivor.processIdentifier).hasPrefix("T"),
      "a protected process was stopped")
survivor.terminate()

// The resume guarantee has to survive CoreBeat dying, because a Mac left
// with a permanently frozen app would be a far worse outcome than the slowdown
// it was fixing. Both surviving mechanisms are exercised for real here, in
// separate processes.
section("the resume guarantee survives CoreBeat dying")

let selfPath = CommandLine.arguments[0]

@MainActor
func runChild(_ arguments: [String]) -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfPath)
    child.arguments = arguments
    try? child.run()
    return child
}

// Mechanism 2: SIGTERM. The handler must resume before the process dies.
let termVictim = spawnSleeper()
let terminating = runChild(["pause-and-wait", String(termVictim.processIdentifier)])
Thread.sleep(forTimeInterval: 1.0)
check("child paused the target", stateOf(termVictim.processIdentifier).hasPrefix("T"),
      "state is \(stateOf(termVictim.processIdentifier))")
kill(terminating.processIdentifier, SIGTERM)
terminating.waitUntilExit()
Thread.sleep(forTimeInterval: 0.5)
check("SIGTERM to CoreBeat resumes what it paused",
      !stateOf(termVictim.processIdentifier).hasPrefix("T"),
      "the process was left frozen — state is \(stateOf(termVictim.processIdentifier))")
termVictim.terminate()

// Mechanism 3: SIGKILL, which no handler can catch. Recovery happens on the
// next launch, from the paused set on disk.
let killVictim = spawnSleeper()
let dying = runChild(["pause-and-die", String(killVictim.processIdentifier)])
dying.waitUntilExit()
Thread.sleep(forTimeInterval: 0.5)
check("target is still paused after an uncleaned exit",
      stateOf(killVictim.processIdentifier).hasPrefix("T"),
      "the test cannot prove anything if the target was never paused")
let recovering = runChild(["recover"])
recovering.waitUntilExit()
Thread.sleep(forTimeInterval: 0.5)
check("the next launch resumes what a killed run left paused",
      !stateOf(killVictim.processIdentifier).hasPrefix("T"),
      "the process was left frozen — state is \(stateOf(killVictim.processIdentifier))")
killVictim.terminate()

print("")
if failures == 0 {
    print("all checks passed")
    exit(0)
} else {
    print("\(failures) check(s) failed")
    exit(1)
}

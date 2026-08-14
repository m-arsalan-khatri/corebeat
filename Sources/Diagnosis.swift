import Foundation

// Every existing menu bar monitor answers "what is using the most CPU right
// now". That question has an unhelpful answer on a busy Mac: the same four
// apps you always run are always at the top, so the list looks identical
// whether the machine is fine or struggling.
//
// The question worth answering is "what is different from normal", so this
// keeps a rolling per-app history and reports departures from each app's own
// baseline. Chrome at 30% is unremarkable if Chrome is always at 30%, and
// alarming if it has sat at 2% for the last ten minutes.

/// All percentages in this file are shares of the whole machine: a process
/// saturating 3 cores of 10 reads as 30%, not Activity Monitor's 300%. The
/// menu bar number and the per-app numbers are then on the same scale and add
/// up, which is what makes the list legible at a glance.
enum Scale {
    static func normalize(coreSeconds: Double, over interval: Double) -> Double {
        guard interval > 0 else { return 0 }
        return (coreSeconds / interval) / Double(Sampling.coreCount) * 100
    }
}

// MARK: - Identity

/// Which app a process belongs to. Chrome alone is 30-odd processes; listing
/// them individually buries the signal, so processes are grouped by the app
/// bundle that contains them.
struct Identity: Sendable, Hashable {
    let key: String
    let name: String
}

func identity(forCommand command: String) -> Identity {
    // Processes that call setproctitle report a label rather than a path, e.g.
    // "Cursor Helper (Plugin): extension-host (retrieval) Projects [12-584]".
    guard command.hasPrefix("/") else {
        let label = command.split(separator: ":").first.map(String.init) ?? command
        let name = label.trimmingCharacters(in: .whitespaces)
        return Identity(key: "label:\(name)", name: name)
    }

    // The *first* .app in the path is the outer bundle. Chrome's helpers live
    // at .../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/...,
    // so taking the first rather than the last is what groups them under Chrome.
    for component in command.split(separator: "/") where component.hasSuffix(".app") {
        let name = String(component.dropLast(4))
        return Identity(key: "app:\(name)", name: name)
    }

    // Key on the raw name but display the readable one: two different
    // reverse-DNS executables can share a last component, and collapsing them
    // into one row would misattribute CPU.
    let leaf = command.split(separator: "/").last.map(String.init) ?? command
    return Identity(key: "bin:\(leaf)", name: readableName(leaf))
}

/// `com.apple.Virtualization.VirtualMachine` -> `VirtualMachine`.
///
/// Reverse-DNS executable names are hard to read in a list and long enough to
/// push the CPU column onto a second line. Anything containing a space is left
/// alone — those are already human names like "Google Chrome Helper (GPU)".
func readableName(_ raw: String) -> String {
    let parts = raw.split(separator: ".")
    guard !raw.contains(" "), parts.count >= 3, let last = parts.last, last.count >= 3
    else { return raw }
    return String(last)
}

/// Display name for a single process within an app, used in the expanded list.
func leafName(forCommand command: String) -> String {
    guard command.hasPrefix("/") else {
        return command.split(separator: ":").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? command
    }
    return readableName(command.split(separator: "/").last.map(String.init) ?? command)
}

/// `/Applications/Foo.app/Contents/MacOS/Foo` -> `/Applications/Foo.app`
func bundlePath(forCommand command: String) -> String? {
    guard command.hasPrefix("/") else { return nil }
    guard let range = command.range(of: ".app/") else { return command }
    return String(command[command.startIndex..<range.lowerBound]) + ".app"
}

// MARK: - Rows

struct ProcessRow: Sendable {
    let pid: pid_t
    let uid: uid_t
    let name: String
    let command: String
    let cpu: Double
    let rssBytes: UInt64
    let stopped: Bool
    let age: Double

    var isOurs: Bool { uid == getuid() }
}

struct AppRow: Sendable {
    let identity: Identity
    let cpu: Double
    let rssBytes: UInt64
    let members: [ProcessRow]

    /// Oldest member. A group whose oldest process is young is genuinely new,
    /// which is stronger evidence than anything our own history can offer in
    /// the first minutes after launch.
    var age: Double { members.map(\.age).max() ?? 0 }
    /// We only signal processes we own — see Interventions.
    var isOurs: Bool { members.allSatisfy(\.isOurs) }
    var isPaused: Bool { !members.isEmpty && members.allSatisfy(\.stopped) }
    var pids: [pid_t] { members.map(\.pid) }
}

/// A departure from an app's own baseline.
struct Change: Sendable {
    let app: AppRow
    let now: Double
    /// Nil when the app is new enough that it has no baseline to depart from.
    let baseline: Double?
    let startedAt: Date
    var isNew: Bool { baseline == nil }
}

// MARK: - Engine

@MainActor
final class Diagnosis {
    /// 10 minutes at the 4s sampling cadence. Long enough that a baseline
    /// survives a burst, short enough that "normal" tracks what you are
    /// actually doing today.
    private static let historyDepth = 150
    private static let baselineFloorAge: TimeInterval = 60
    private static let newProcessAge: TimeInterval = 150

    /// A spike has to clear all of these to be worth showing. The floor exists
    /// because doubling from 0.3% to 0.9% is technically a departure and
    /// entirely uninteresting.
    private static let spikeFloor = 4.0
    private static let spikeMultiple = 2.0
    private static let spikeMargin = 5.0

    private struct Sample { let at: Date; let cpu: Double }

    private var previousCPU: [pid_t: (seconds: Double, command: String)] = [:]
    private var previousAt: Date?
    private var history: [String: [Sample]] = [:]

    private(set) var apps: [AppRow] = []
    private(set) var changes: [Change] = []
    /// False until two samples have been differenced, because a single sample
    /// carries no rate information.
    private(set) var hasRates = false

    private var watchingSince: Date?

    /// Whether we have watched long enough to have a baseline to compare
    /// against. Until then "nothing unusual" would be a claim we cannot
    /// support — we would simply not yet know.
    var isCalibrated: Bool {
        guard let watchingSince else { return false }
        return Date().timeIntervalSince(watchingSince) >= Self.baselineFloorAge
    }

    func ingest(_ sample: RawSample) {
        defer {
            previousCPU = Dictionary(
                sample.processes.map { ($0.pid, ($0.cpuSeconds, $0.command)) },
                uniquingKeysWith: { first, _ in first })
            previousAt = sample.at
        }

        guard let previousAt else { return }
        let interval = sample.at.timeIntervalSince(previousAt)
        guard interval > 0.5 else { return }
        hasRates = true
        if watchingSince == nil { watchingSince = sample.at }

        var grouped: [Identity: [ProcessRow]] = [:]
        for process in sample.processes {
            // A recycled pid running a different binary must not inherit the
            // old one's counter, which would report a wild negative or huge
            // rate for one sample.
            var cpu = 0.0
            if let previous = previousCPU[process.pid], previous.command == process.command {
                cpu = Scale.normalize(
                    coreSeconds: max(0, process.cpuSeconds - previous.seconds), over: interval)
            } else if process.age > 0.5, process.age <= Self.newProcessAge {
                // First time we have seen this pid. Waiting for a second
                // sample would report a brand-new hog as 0% for a full cycle,
                // which is precisely the case this app exists to catch. For a
                // process this young its lifetime average is a fair stand-in
                // for its current rate.
                //
                // Deliberately not applied to older processes: their lifetime
                // average says nothing about what they are doing now, and a
                // long-idle daemon would be libelled by its own startup cost.
                cpu = Scale.normalize(coreSeconds: process.cpuSeconds, over: process.age)
            }

            let row = ProcessRow(
                pid: process.pid,
                uid: process.uid,
                name: leafName(forCommand: process.command),
                command: process.command,
                cpu: cpu,
                rssBytes: process.rssBytes,
                stopped: process.stopped,
                age: process.age)
            grouped[identity(forCommand: process.command), default: []].append(row)
        }

        apps = grouped.map { identity, members in
            AppRow(
                identity: identity,
                cpu: members.reduce(0) { $0 + $1.cpu },
                rssBytes: members.reduce(0) { $0 + $1.rssBytes },
                members: members.sorted { $0.cpu > $1.cpu })
        }
        .sorted { $0.cpu > $1.cpu }

        record(apps, at: sample.at)
        changes = detectChanges(at: sample.at)
    }

    private func record(_ apps: [AppRow], at now: Date) {
        var seen = Set<String>()
        for app in apps {
            seen.insert(app.identity.key)
            var series = history[app.identity.key] ?? []
            series.append(Sample(at: now, cpu: app.cpu))
            if series.count > Self.historyDepth { series.removeFirst(series.count - Self.historyDepth) }
            history[app.identity.key] = series
        }
        // An app that exited keeps its history briefly in case it comes back,
        // but must not grow unbounded across a long uptime.
        for key in history.keys where !seen.contains(key) {
            guard var series = history[key], let last = series.last else { continue }
            if now.timeIntervalSince(last.at) > 600 {
                history[key] = nil
            } else {
                series.append(Sample(at: now, cpu: 0))
                if series.count > Self.historyDepth { series.removeFirst(series.count - Self.historyDepth) }
                history[key] = series
            }
        }
    }

    private func detectChanges(at now: Date) -> [Change] {
        var result: [Change] = []

        for app in apps {
            let current = smoothedCurrent(for: app.identity.key) ?? app.cpu
            guard current >= Self.spikeFloor else { continue }

            let series = history[app.identity.key] ?? []
            let older = series.filter { now.timeIntervalSince($0.at) >= Self.baselineFloorAge }
            let baseline = older.count >= 5 ? median(older.map(\.cpu)) : nil

            if let baseline {
                guard current >= max(baseline * Self.spikeMultiple, baseline + Self.spikeMargin)
                else { continue }
                result.append(Change(
                    app: app,
                    now: current,
                    baseline: baseline,
                    startedAt: onset(series: series, baseline: baseline, current: current, now: now)))
            } else if app.age < Self.newProcessAge {
                // No baseline, but the process itself is new — the launch is
                // the change. Without this arm, nothing would be reported for
                // the first minute of any app's life, which is exactly when
                // you want to know about it.
                result.append(Change(
                    app: app,
                    now: current,
                    baseline: nil,
                    startedAt: now.addingTimeInterval(-app.age)))
            }
        }

        return result.sorted { $0.now > $1.now }
    }

    /// Two samples of smoothing, so a single scheduling hiccup does not get
    /// announced as a spike.
    private func smoothedCurrent(for key: String) -> Double? {
        guard let series = history[key], !series.isEmpty else { return nil }
        let recent = series.suffix(2).map(\.cpu)
        return recent.reduce(0, +) / Double(recent.count)
    }

    /// Walks backwards while the app was above the midpoint between its
    /// baseline and its current level — that crossing is when the spike began.
    private func onset(series: [Sample], baseline: Double, current: Double, now: Date) -> Date {
        let threshold = (baseline + current) / 2
        var started = now
        for sample in series.reversed() {
            guard sample.cpu >= threshold else { break }
            started = sample.at
        }
        return started
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

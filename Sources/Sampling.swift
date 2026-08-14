import Darwin
import Foundation

// Sampling has to cover processes we do not own. WindowServer, mds_stores,
// antivirus daemons and MDM agents run as root or _windowserver and are among
// the most common reasons a Mac feels slow — omitting them would make the
// diagnosis wrong rather than merely incomplete.
//
// libproc refuses PROC_PIDTASKINFO and proc_pid_rusage for other users'
// processes (measured: 423 of 600 pids readable), and task_for_pid needs
// privileges this app deliberately never asks for. /bin/ps is setuid root and
// reports cumulative CPU time for every process to centisecond resolution, so
// differencing two samples yields a true instantaneous rate. Measured against
// `top` on the same process: 44.5% vs 45.1%.
//
// The catch is that ps costs a fork and ~50ms of CPU, which is why it runs off
// the main thread on a slow cadence while the menu bar number comes from
// host_statistics, which is free.

/// One process exactly as `ps` reported it. Rates are derived by differencing
/// two of these; nothing here is a percentage yet.
struct RawProcess: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    /// `ps` state field starts with `T` while a process is SIGSTOPped.
    let stopped: Bool
    /// Wall-clock seconds since the process started.
    let age: Double
    /// Cumulative CPU seconds consumed since the process started.
    let cpuSeconds: Double
    let rssBytes: UInt64
    /// argv0-ish. Usually an absolute path, but processes that call
    /// setproctitle report something like `Cursor Helper (Plugin): extension-host`.
    let command: String
}

struct RawSample: Sendable {
    let at: Date
    let processes: [RawProcess]
}

enum Sampling {
    static let coreCount = max(1, Int(ProcessInfo.processInfo.activeProcessorCount))

    // MARK: - System-wide CPU

    /// Cumulative CPU ticks since boot, aggregated across all cores.
    struct HostTicks: Sendable {
        let busy: UInt64
        let total: UInt64
    }

    static func hostTicks() -> HostTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        return HostTicks(busy: busy, total: busy &+ idle)
    }

    // MARK: - Per-process

    /// Forks `ps` and parses the whole process table. Blocking; call off the
    /// main thread.
    static func captureProcesses() -> RawSample? {
        // `comm` must stay last: it is the only field that can contain spaces.
        let arguments = ["-Ao", "pid=,ppid=,uid=,state=,etime=,time=,rss=,comm="]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        let started = Date()
        guard (try? task.run()) != nil else { return nil }
        guard let data = try? pipe.fileHandleForReading.readToEnd() else {
            task.waitUntilExit()
            return nil
        }
        task.waitUntilExit()

        // Timestamp the middle of the run, not the end. Rates are derived by
        // dividing a CPU-time delta by the gap between two of these, so any
        // error here scales every process's figure at once.
        //
        // ps takes ~50ms idle but far longer on a machine that is already
        // pegged — which is exactly when the numbers are being read. Stamping
        // the end makes the gap wrong by the *difference* between consecutive
        // runs, so a slow sample followed by a fast one inflates everything
        // simultaneously and looks like a system-wide spike that never
        // happened. The midpoint halves that error and, unlike the end,
        // does not drift in one direction as load rises.
        let at = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var processes: [RawProcess] = []
        processes.reserveCapacity(700)
        let mine = getpid()

        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8 else { continue }
            guard let pid = pid_t(fields[0]), pid != mine,
                  let ppid = pid_t(fields[1]),
                  let uid = uid_t(fields[2]),
                  let age = parseElapsed(fields[4]),
                  let cpu = parseCPUTime(fields[5]),
                  let rss = UInt64(fields[6])
            else { continue }

            let command = fields[7].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }

            processes.append(RawProcess(
                pid: pid,
                ppid: ppid,
                uid: uid,
                stopped: fields[3].hasPrefix("T"),
                age: age,
                cpuSeconds: cpu,
                rssBytes: rss * 1024, // ps reports RSS in KiB
                command: command))
        }

        return processes.isEmpty ? nil : RawSample(at: at, processes: processes)
    }

    // MARK: - Field parsing

    /// `ps` CPU time: `mmm:ss.cc`, occasionally `hh:mm:ss.cc` or `d-hh:mm:ss`.
    /// Parsed right-to-left so every one of those shapes falls out of the same
    /// loop.
    static func parseCPUTime(_ field: Substring) -> Double? {
        parseClock(field)
    }

    /// `ps` elapsed time: `mm:ss`, `hh:mm:ss` or `dd-hh:mm:ss`.
    static func parseElapsed(_ field: Substring) -> Double? {
        parseClock(field)
    }

    private static func parseClock(_ field: Substring) -> Double? {
        var rest = field
        var seconds = 0.0

        if let dash = rest.firstIndex(of: "-") {
            guard let days = Double(rest[rest.startIndex..<dash]) else { return nil }
            seconds += days * 86_400
            rest = rest[rest.index(after: dash)...]
        }

        var accumulated = 0.0
        for part in rest.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            accumulated = accumulated * 60 + value
        }
        return seconds + accumulated
    }
}

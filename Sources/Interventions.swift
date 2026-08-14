import Darwin
import Foundation

// The interventions are a ladder, gentlest first:
//
//   Pause     SIGSTOP  — the process stops consuming CPU instantly and keeps
//                        all its state. Reversible, and the only one that
//                        costs you nothing if you were wrong.
//   Ease Off  PRIO_DARWIN_BG — leaves it running but pins it to the efficiency
//                        cores and throttles its disk I/O. Reversible.
//   Quit      SIGTERM  — the app gets to save and close.
//   Force Quit SIGKILL — unsaved work is lost.
//
// Pausing is safe only because a paused process is guaranteed to come back.
// That guarantee is the single most important property in this file: a Mac
// left with a permanently frozen app, by a utility the user installed to make
// things better, is a far worse outcome than the slowdown it was fixing.
// Three independent mechanisms enforce it — see resumeEverything().

// PRIO_DARWIN_PROCESS / PRIO_DARWIN_BG from <sys/resource.h>. Restated here
// because they do not survive the Swift importer. This is the same pair of
// calls `taskpolicy -b -p <pid>` and `taskpolicy -B -p <pid>` make.
private let prioDarwinProcess: Int32 = 4
private let prioDarwinBackground: Int32 = 0x1000

// Storage the SIGTERM handler can walk without allocating. Swift arrays and
// dictionaries are not async-signal-safe; a fixed C buffer with a count in
// slot 0 is. Written only from the main actor, read only by the handler.
private let pauseSlotCapacity = 512
private nonisolated(unsafe) let pauseSlots =
    UnsafeMutablePointer<Int32>.allocate(capacity: pauseSlotCapacity + 1)

@MainActor
final class Interventions {
    static let shared = Interventions()

    /// A pause is a temporary reprieve — "be quiet while I finish this call" —
    /// not a permanent state, so it lapses on its own. Anything longer is what
    /// Quit is for.
    static let autoResumeAfter: TimeInterval = 10 * 60

    private static let persistenceKey = "PausedPIDs"
    /// The bundle id this app shipped under before it was renamed to CoreBeat.
    /// UserDefaults is keyed on the bundle id, so the rename moved the paused
    /// set to a new domain and left anything ChipCrawl was killed holding in
    /// the old one. Read once at launch — see recoverFromPreviousRun.
    private static let previousDomain = "com.arsalaniqbal.chipcrawl"

    /// Processes that keep the session usable. Stopping the Dock or
    /// loginwindow locks you out of your own Mac, and there is no plausible
    /// reason to want to. Root-owned daemons are already excluded by the
    /// same-uid rule below; everything here runs as the logged-in user.
    private static let protected: Set<String> = [
        "loginwindow", "Dock", "SystemUIServer", "WindowServer", "launchd",
        "kernel_task", "cfprefsd", "distnoted", "UserEventAgent", "launchservicesd",
        "coreaudiod", "ControlCenter", "NotificationCenter", "Spotlight",
        "universalaccessd", "opendirectoryd", "securityd", "logind",
        "CoreBeat",
    ]

    private(set) var pausedUntil: [pid_t: Date] = [:]

    private init() {
        pauseSlots[0] = 0
        installCrashSafety()
        recoverFromPreviousRun()
    }

    // MARK: - Eligibility

    /// Two independent reasons an intervention can be unavailable, kept
    /// separate so the menu can say which one applies.
    enum Eligibility {
        case allowed
        case notOurs      // another user's process; signalling needs root
        case protected    // ours, but the session depends on it

        var explanation: String? {
            switch self {
            case .allowed: return nil
            case .notOurs: return "System process — needs admin rights"
            case .protected: return "Needed by macOS"
            }
        }
    }

    func eligibility(of row: ProcessRow) -> Eligibility {
        if Self.protected.contains(row.name) { return .protected }
        // Deliberately no privilege escalation anywhere in this app: it never
        // asks for an admin password, so it can never be tricked into using
        // one. Root-owned hogs are still reported, just not actionable here.
        if !row.isOurs { return .notOurs }
        return .allowed
    }

    func eligibility(of app: AppRow) -> Eligibility {
        if app.members.contains(where: { Self.protected.contains($0.name) }) { return .protected }
        if !app.isOurs { return .notOurs }
        return .allowed
    }

    private func actionable(_ pids: [pid_t], in app: AppRow) -> [pid_t] {
        let allowed = Set(app.members.filter { eligibility(of: $0) == .allowed }.map(\.pid))
        return pids.filter { allowed.contains($0) }
    }

    // MARK: - Actions

    func pause(_ app: AppRow) {
        let pids = actionable(app.pids, in: app)
        guard !pids.isEmpty else { return }
        let deadline = Date().addingTimeInterval(Self.autoResumeAfter)
        for pid in pids where kill(pid, SIGSTOP) == 0 {
            pausedUntil[pid] = deadline
        }
        syncPausedState()
    }

    func resume(_ app: AppRow) {
        resume(pids: app.pids)
    }

    func resume(pids: [pid_t]) {
        for pid in pids {
            kill(pid, SIGCONT)
            pausedUntil[pid] = nil
        }
        syncPausedState()
    }

    func easeOff(_ app: AppRow) {
        for pid in actionable(app.pids, in: app) {
            setpriority(prioDarwinProcess, id_t(pid), prioDarwinBackground)
        }
    }

    func restoreSpeed(_ app: AppRow) {
        for pid in actionable(app.pids, in: app) {
            setpriority(prioDarwinProcess, id_t(pid), 0)
        }
    }

    func quit(_ app: AppRow) {
        // A stopped process cannot act on SIGTERM, so wake it first or the
        // quit silently does nothing.
        let pids = actionable(app.pids, in: app)
        for pid in pids {
            kill(pid, SIGCONT)
            pausedUntil[pid] = nil
            kill(pid, SIGTERM)
        }
        syncPausedState()
    }

    func forceQuit(_ app: AppRow) {
        for pid in actionable(app.pids, in: app) {
            kill(pid, SIGKILL)
            pausedUntil[pid] = nil
        }
        syncPausedState()
    }

    // MARK: - The resume guarantee

    /// Lapse any pause that has run past its deadline.
    func enforceAutoResume(now: Date = Date()) {
        let expired = pausedUntil.filter { $0.value <= now }.map(\.key)
        guard !expired.isEmpty else { return }
        resume(pids: expired)
    }

    /// Mechanism 1 of 3: ordinary quit, via applicationWillTerminate.
    func resumeEverything() {
        resume(pids: Array(pausedUntil.keys))
    }

    /// Mechanism 2 of 3: SIGTERM/SIGINT/SIGHUP/SIGQUIT — `killall`, a logout,
    /// or a shutdown. The handler must be async-signal-safe, which is why it
    /// walks the C buffer rather than the dictionary.
    private func installCrashSafety() {
        let handler: @convention(c) (Int32) -> Void = { received in
            let count = min(Int(pauseSlots[0]), pauseSlotCapacity)
            var index = 1
            while index <= count {
                kill(pid_t(pauseSlots[index]), SIGCONT)
                index += 1
            }
            signal(received, SIG_DFL)
            raise(received)
        }
        for received in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(received, handler)
        }
    }

    /// Mechanism 3 of 3: SIGKILL and panics, which no handler can catch. The
    /// paused set is on disk, so the next launch cleans up. SIGCONT to a pid
    /// that has since been recycled is harmless — it is a no-op on a process
    /// that was never stopped.
    private func recoverFromPreviousRun() {
        var stale = UserDefaults.standard.array(forKey: Self.persistenceKey) as? [Int] ?? []

        // A pause the app made under its old name is still a pause, and the
        // guarantee does not get to lapse because the product was renamed. The
        // old domain is drained, not merely read, so this happens once.
        if let previous = UserDefaults(suiteName: Self.previousDomain) {
            stale += previous.array(forKey: Self.persistenceKey) as? [Int] ?? []
            previous.removeObject(forKey: Self.persistenceKey)
        }

        for pid in stale {
            kill(pid_t(pid), SIGCONT)
        }
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
    }

    private func syncPausedState() {
        let pids = Array(pausedUntil.keys)

        let count = min(pids.count, pauseSlotCapacity)
        for index in 0..<count {
            pauseSlots[index + 1] = Int32(pids[index])
        }
        pauseSlots[0] = Int32(count)

        if pids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        } else {
            UserDefaults.standard.set(pids.map(Int.init), forKey: Self.persistenceKey)
        }
        // Forced out immediately: the whole point is surviving a kill -9 that
        // could land at any moment.
        UserDefaults.standard.synchronize()
    }
}

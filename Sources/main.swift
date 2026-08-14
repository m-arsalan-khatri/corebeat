import AppKit
import ServiceManagement

// Two cadences, because the two data sources cost wildly different amounts.
// The menu bar number comes from host_statistics, which is a syscall costing
// microseconds, so it can be quick. The process table costs a fork of /bin/ps
// and ~50ms of CPU, so it is slow — a monitor that itself shows up in the list
// it prints has failed at its one job.

@MainActor
final class CoreBeat: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let systemInterval: TimeInterval = 2
    private static let processInterval: TimeInterval = 4
    /// Opening the menu takes a fresh reading if the last one is older than
    /// this, so what you are looking at is what is happening.
    private static let staleWhenOpening: TimeInterval = 2

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let diagnosis = Diagnosis()

    private var systemTimer: Timer?
    private var processTimer: Timer?

    private var previousTicks: Sampling.HostTicks?
    private var systemCPU: Double = 0
    private var trace: [Double] = []
    private var renderedTitle: String?
    private var isSampling = false
    private var lastSampleAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Interventions.shared // recovers anything a previous run left paused
        Self.openAtLogin()

        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        systemTimer = .scheduledTimer(withTimeInterval: Self.systemInterval, repeats: true) { _ in
            Task { @MainActor in self.tickSystem() }
        }
        processTimer = .scheduledTimer(withTimeInterval: Self.processInterval, repeats: true) { _ in
            Task { @MainActor in self.tickProcesses() }
        }

        tickSystem()
        tickProcesses()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Interventions.shared.resumeEverything()
    }

    /// Registers the app to start at login, every launch.
    ///
    /// There is deliberately no menu item for this. A monitor that only watches
    /// while you remember to open it cannot know what "normal" looks like — the
    /// baseline is built from ten minutes of history, so an app that starts
    /// with the session is the only one that has an answer when you finally ask.
    ///
    /// Not a silent capture of the login list: macOS shows the registration in
    /// System Settings → General → Login Items and lets it be switched off
    /// there, which is the switch a second checkbox in here would only shadow.
    private static func openAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        // Throws for a bundle macOS does not consider installed — running
        // straight out of ./build, which is every development run. Silent is
        // right: there is nothing the user could usefully do about it, and an
        // installed copy registers on its first launch anyway.
        try? SMAppService.mainApp.register()
    }

    // MARK: - Sampling

    private func tickSystem() {
        Interventions.shared.enforceAutoResume()

        guard let ticks = Sampling.hostTicks() else { return }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return }

        let total = ticks.total &- previous.total
        guard total > 0 else { return }
        systemCPU = Double(ticks.busy &- previous.busy) / Double(total) * 100

        trace.append(systemCPU)
        if trace.count > StatusIcon.sparklineSamples {
            trace.removeFirst(trace.count - StatusIcon.sparklineSamples)
        }
        render()
    }

    /// Off the main thread, because it forks.
    private func tickProcesses() {
        guard !isSampling else { return }
        isSampling = true
        Task.detached(priority: .utility) {
            let sample = Sampling.captureProcesses()
            await MainActor.run {
                self.isSampling = false
                guard let sample else { return }
                self.diagnosis.ingest(sample)
                self.lastSampleAt = sample.at
                self.render()
            }
        }
    }

    /// Blocking, and deliberately so: this runs while the menu is being built,
    /// where ~50ms is imperceptible against the menu's own animation and buys
    /// a guarantee that nothing on screen is stale.
    private func sampleNow() {
        guard let sample = Sampling.captureProcesses() else { return }
        diagnosis.ingest(sample)
        lastSampleAt = sample.at
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }

        // Load that will end by itself does not deserve an alarm colour, so it
        // is weighed before the level is decided.
        let routine = KnownCauses.routineLoad(in: diagnosis.apps)
        let level = Level(
            trace: trace,
            routineShare: systemCPU > 0 ? routine / systemCPU : 0)

        button.image = StatusIcon.sparkline(history: trace, level: level)
        button.imagePosition = .imageOnly

        // The number is not on display any more, so the tooltip has to carry
        // it — along with the reason, when there is a known one.
        let dominantCause = diagnosis.apps
            .first { $0.cpu >= 5 && KnownCauses.match($0) != nil }
            .flatMap(KnownCauses.match)
        let summary = StatusIcon.summary(cpu: systemCPU, level: level, cause: dominantCause)
        if renderedTitle != summary {
            button.toolTip = summary
            renderedTitle = summary
        }
    }

    // MARK: - NSMenuDelegate

    /// Called before every display. The menu is rebuilt here and nowhere else:
    /// refreshing it while it is open would move rows out from under the
    /// cursor, and reassigning statusItem.menu would dismiss it outright.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if lastSampleAt.map({ Date().timeIntervalSince($0) > Self.staleWhenOpening }) ?? true {
            sampleNow()
        }

        let fresh = MenuBuilder.build(
            systemCPU: systemCPU,
            diagnosis: diagnosis,
            onQuit: { NSApp.terminate(nil) })

        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}

let application = NSApplication.shared
let delegate = CoreBeat()
application.delegate = delegate
// Menu bar only: no Dock icon, no window, nothing in the app switcher.
application.setActivationPolicy(.accessory)
application.run()

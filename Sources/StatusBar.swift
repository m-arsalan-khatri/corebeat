import AppKit

// The menu bar item carries three things at a glance, in decreasing order of
// how often they matter: how loaded the machine is, whether that is a spike or
// steady state, and — only when something is clearly to blame — its name. The
// last one means the common case needs no click at all.

/// With no number on show, colour is the entire signal, so it answers exactly
/// one question: is this worth a look?
///
/// Judged on *sustained* load, not the latest reading. A single 100% sample
/// happens constantly — every app launch, every page load — and a menu bar that
/// flashes red at each one is one you learn to ignore within a day.
enum Level {
    /// Under 50%: normal. Monochrome, so it disappears into the menu bar.
    case steady
    /// 50–80%, or heavy load with a known finite cause. Working, but explained.
    case elevated
    /// Over 80% sustained, with nothing routine to account for it.
    case racing

    var tint: NSColor? {
        switch self {
        case .steady: return nil // template rendering, follows the menu bar
        case .elevated: return .systemOrange
        case .racing: return .systemRed
        }
    }

    /// - Parameter routineShare: fraction of the load owned by work that ends
    ///   on its own. A Mac pinned by a Time Machine backup is busy, not broken,
    ///   and should not be shouted about.
    init(trace: [Double], routineShare: Double) {
        let window = trace.suffix(8) // ~16s at the 2s cadence
        guard !window.isEmpty else { self = .steady; return }
        let sorted = window.sorted()
        let sustained = sorted[sorted.count / 2]

        switch sustained {
        case ..<50: self = .steady
        case ..<80: self = .elevated
        default: self = routineShare >= 0.4 ? .elevated : .racing
        }
    }
}

enum StatusIcon {
    static let sparklineSamples = 32

    /// A 32-sample trace of total CPU — about a minute at the 2s cadence.
    ///
    /// The shape is the diagnosis, and it says more than a number could: a step
    /// up that stays up reads completely differently from a spiky sawtooth, and
    /// a percentage shows neither. Wider than it needs to be for a sparkline
    /// because it is now the only thing in the menu bar.
    static func sparkline(history: [Double], level: Level) -> NSImage {
        let size = NSSize(width: 32, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            guard history.count >= 2 else { return true }

            let samples = Array(history.suffix(sparklineSamples))
            let step = size.width / CGFloat(max(1, samples.count - 1))
            let baseline: CGFloat = 1.5
            let ceiling = size.height - 1.5

            func point(_ index: Int) -> NSPoint {
                let fraction = CGFloat(min(100, max(0, samples[index]))) / 100
                return NSPoint(x: CGFloat(index) * step, y: baseline + fraction * (ceiling - baseline))
            }

            // Everything is clipped to a rounded rect. Square corners make the
            // fill read as a solid slab wedged into the menu bar, which sits
            // badly among the rounded glyphs of every other status item.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(
                roundedRect: NSRect(
                    x: 0, y: baseline, width: size.width, height: ceiling - baseline),
                xRadius: 3, yRadius: 3
            ).setClip()

            let area = NSBezierPath()
            area.move(to: NSPoint(x: 0, y: baseline))
            for index in samples.indices { area.line(to: point(index)) }
            area.line(to: NSPoint(x: CGFloat(samples.count - 1) * step, y: baseline))
            area.close()

            let color = level.tint ?? .black
            color.withAlphaComponent(0.28).setFill()
            area.fill()

            let trace = NSBezierPath()
            trace.move(to: point(0))
            for index in samples.indices.dropFirst() { trace.line(to: point(index)) }
            trace.lineWidth = 1.25
            trace.lineJoinStyle = .round
            trace.lineCapStyle = .round
            color.setStroke()
            trace.stroke()

            return true
        }
        // Template images are tinted by the system to match the menu bar, which
        // is what we want when idle. A warning colour has to survive that, so
        // it opts out.
        image.isTemplate = level.tint == nil
        return image
    }

    /// What the trace means, for the tooltip — the number still has to be
    /// reachable, just not permanently on display.
    ///
    /// One word per level, from the same three-rung vocabulary as the enum, so
    /// the tooltip and the colour are saying the same thing in two ways. A
    /// known cause displaces the word entirely: "Time Machine, backing up" is
    /// a better answer than any adjective about the pulse.
    static func summary(cpu: Double, level: Level, cause: KnownCause?) -> String {
        let load = "CPU \(Int(cpu.rounded()))%"
        if let cause { return "\(load) · \(cause.title), \(cause.detail)" }
        switch level {
        case .steady: return "\(load) · steady"
        case .elevated: return "\(load) · elevated"
        case .racing: return "\(load) · racing"
        }
    }
}

// MARK: - Menu

/// NSMenuItem needs an ObjC target/action pair; this carries a closure instead
/// and is retained by the item it belongs to.
@MainActor
final class MenuAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

@MainActor
enum MenuBuilder {
    /// The name is truncated to fit this, rather than being allowed to push
    /// the columns around. An unbounded name either collapses the gap before
    /// the percentage or wraps the row onto a second line, orphaning the
    /// number it belongs to.
    static let nameWidth: CGFloat = 200
    private static let cpuColumn: CGFloat = 252
    private static let detailColumn: CGFloat = 264

    static func build(
        systemCPU: Double,
        diagnosis: Diagnosis,
        onQuit: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard diagnosis.hasRates else {
            menu.addItem(headline(systemCPU, verdict: "taking a first reading"))
            addFooter(to: menu, onQuit: onQuit)
            return menu
        }

        // Anything with a known, routine explanation is pulled out of both
        // lists below and shown separately. A backup or a Spotlight re-index
        // is not something you need to weigh up against Chrome — the question
        // it raises ("is this worth a look?") has a settled answer, and mixing
        // it in with the unexplained load is what makes monitors tiring.
        let routine = diagnosis.apps.compactMap { app -> (AppRow, KnownCause)? in
            guard app.cpu >= 1, let cause = KnownCauses.match(app) else { return nil }
            return (app, cause)
        }
        let explained = Set(routine.map(\.0.identity.key))

        // Ordered by how much you might act on it: what changed, what else is
        // heavy, what is routine, what is too small to name.
        let changes = Array(
            diagnosis.changes.filter { !explained.contains($0.app.identity.key) }.prefix(3))

        // The headline carries the reading and the verdict together. A separate
        // "What changed" label under it was a third row saying what the two
        // either side of it already said.
        menu.addItem(headline(systemCPU, verdict: verdict(
            changes: changes.count,
            calibrated: diagnosis.isCalibrated,
            broad: isBroad(systemCPU: systemCPU, apps: diagnosis.apps))))
        for change in changes {
            menu.addItem(appRow(
                change.app, cpu: change.now, detail: reason(for: change), emphasised: true))
        }

        let listed = addHeaviest(
            diagnosis.apps.filter { !explained.contains($0.identity.key) },
            changes: changes, to: menu)
        addBackground(routine, to: menu)

        // The rows have to account for the header, or the first thing anyone
        // does is add them up, come up short, and stop trusting the number.
        let named = changes.reduce(0) { $0 + $1.now }
            + listed.reduce(0) { $0 + $1.cpu }
            + routine.reduce(0) { $0 + $1.0.cpu }
        addRemainder(
            total: systemCPU,
            named: named,
            hidden: max(0, diagnosis.apps.count - listed.count - changes.count - routine.count),
            to: menu)

        addPaused(diagnosis.apps, to: menu)
        addFooter(to: menu, onQuit: onQuit)
        return menu
    }

    // MARK: Sections

    /// Load below this is not worth remarking on however it is distributed.
    /// Matches the amber threshold, so the menu only offers this explanation
    /// once the menu bar has already suggested a look.
    private static let broadLoadFloor = 50.0
    /// An app owning less than a third of the total is not a culprit. Above
    /// that it is worth naming, and the rows already do.
    private static let culpritShare = 1.0 / 3.0

    /// The one-line answer, sat next to the reading it explains.
    static func verdict(changes: Int, calibrated: Bool, broad: Bool) -> String {
        switch changes {
        case 0:
            // A loaded machine with nothing above its baseline is the case
            // that reads worst: "nothing unusual" is true and unhelpful, since
            // the menu was opened because the Mac feels slow. Saying the load
            // has no owner answers the question that was actually asked.
            if broad { return "spread across many apps" }
            // Claiming "nothing unusual" before there is a baseline would be
            // stating a conclusion we have not earned yet.
            return calibrated ? "nothing unusual" : "still learning what's normal"
        case 1: return "1 app above normal"
        default: return "\(changes) apps above normal"
        }
    }

    /// Whether the load is real but has no single owner.
    ///
    /// Deliberately a claim about this sample alone — no history, no baseline —
    /// which is why it is allowed to speak before calibration, where the
    /// alternative is telling someone with a pegged Mac that we are still
    /// learning.
    static func isBroad(systemCPU: Double, apps: [AppRow]) -> Bool {
        guard systemCPU >= broadLoadFloor else { return false }
        let heaviest = apps.map(\.cpu).max() ?? 0
        return heaviest < systemCPU * culpritShare
    }

    private static func reason(for change: Change) -> String {
        let elapsed = Date().timeIntervalSince(change.startedAt)
        guard let baseline = change.baseline else {
            return elapsed >= 60 ? "started \(ago(change.startedAt))" : "just started"
        }
        // "just now" is the common case and adds nothing under a headline that
        // has already said these apps are above normal.
        return elapsed >= 60
            ? "was \(percent(baseline)) · \(ago(change.startedAt))"
            : "was \(percent(baseline))"
    }

    /// Routine work, collapsed to a single row.
    ///
    /// This is load you have already decided you do not need to act on, so it
    /// earns one line, not a section. Collapsing it also states the useful
    /// thing more plainly than three rows did: *this much of your machine is
    /// busy for reasons that are fine*. The detail is one click away.
    private static func addBackground(_ routine: [(AppRow, KnownCause)], to menu: NSMenu) {
        let sorted = routine.sorted { $0.0.cpu > $1.0.cpu }
        let total = sorted.reduce(0) { $0 + $1.0.cpu }
        guard total >= 1 else { return }

        menu.addItem(.separator())

        // With only one, naming it outright beats hiding it behind a summary.
        if sorted.count == 1, let (app, cause) = sorted.first {
            menu.addItem(backgroundRow(app, cause))
            return
        }

        let item = NSMenuItem()
        item.attributedTitle = rowTitle(
            name: "Background work", value: percent(total),
            detail: "\(sorted.count) routine tasks", emphasised: false)
        item.toolTip = "Work macOS and your admin tools do on a schedule. "
            + sorted.map(\.1.title).joined(separator: ", ") + "."

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (app, cause) in sorted { submenu.addItem(backgroundRow(app, cause)) }
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func backgroundRow(_ app: AppRow, _ cause: KnownCause) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = rowTitle(
            name: cause.title, value: percent(app.cpu), detail: cause.detail, emphasised: false)
        item.toolTip = cause.explanation
        item.submenu = actions(for: app, cause: cause)
        return item
    }

    /// Returns the rows it actually displayed, so the caller can work out what
    /// is left over.
    @discardableResult
    private static func addHeaviest(_ apps: [AppRow], changes: [Change], to menu: NSMenu) -> [AppRow] {
        let alreadyShown = Set(changes.map(\.app.identity.key))
        let rest = apps.filter { !alreadyShown.contains($0.identity.key) && $0.cpu >= 1 }
        guard !rest.isEmpty else { return [] }

        // No label: the separator above is enough to mark these off from the
        // changed apps, and a heading only restates what a list of apps and
        // percentages already shows.
        menu.addItem(.separator())
        let shown = Array(rest.prefix(4))
        for app in shown {
            // Anything we cannot act on is flagged, whichever reason applies,
            // so a row that offers no actions never looks broken.
            let detail = Interventions.shared.eligibility(of: app) == .allowed ? "" : "system"
            menu.addItem(appRow(app, cpu: app.cpu, detail: detail, emphasised: false))
        }
        return shown
    }

    /// Closes the gap between the header and the rows above it.
    ///
    /// The named rows will always fall short, for two reasons that are not the
    /// user's problem to reason about: a long tail of hundreds of processes
    /// each using a fraction of a percent, and work `ps` cannot attribute to
    /// any process at all — `kernel_task`, plus anything that starts and exits
    /// between two samples. Measured on a 10-core M4 at 56% load, that was
    /// 7.3% tail and 7.1% unattributable. Showing the remainder explicitly is
    /// the honest way to present that; silently leaving it out invites the
    /// reader to add up the column, come up short, and distrust the header.
    private static func addRemainder(total: Double, named: Double, hidden: Int, to menu: NSMenu) {
        let remainder = total - named
        guard remainder >= 1 else { return }

        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = rowTitle(
            name: "Everything else",
            value: percent(remainder),
            detail: hidden > 0 ? "\(hidden) small + kernel" : "kernel and short-lived work",
            emphasised: false,
            muted: true)
        item.toolTip = "Hundreds of processes each using a fraction of a percent, plus work "
            + "macOS does not attribute to any process — kernel_task, and anything that "
            + "starts and finishes between two readings."
        menu.addItem(item)
    }

    private static func addPaused(_ apps: [AppRow], to menu: NSMenu) {
        let paused = apps.filter(\.isPaused)
        guard !paused.isEmpty else { return }

        menu.addItem(.separator())
        menu.addItem(section("Paused"))
        for app in paused {
            let remaining = app.pids.compactMap { Interventions.shared.pausedUntil[$0] }.max()
            let detail = remaining.map { "resumes in \(countdown(to: $0))" } ?? "paused"
            let item = NSMenuItem()
            item.attributedTitle = rowTitle(
                name: app.identity.name, value: "", detail: detail, emphasised: false)
            let action = MenuAction { Interventions.shared.resume(app) }
            item.target = action
            item.action = #selector(MenuAction.fire)
            item.representedObject = action
            item.toolTip = "Resume \(app.identity.name)"
            menu.addItem(item)
        }
    }

    private static func addFooter(to menu: NSMenu, onQuit: @escaping () -> Void) {
        menu.addItem(.separator())

        menu.addItem(command("Open Activity Monitor") {
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        })

        // No "Open at Login" checkbox. The app registers itself on launch, and
        // macOS already owns the off switch for that in System Settings →
        // General → Login Items. A second control over the same state is the
        // preferences pane this app does not have, one row at a time.
        menu.addItem(.separator())
        let quit = command("Quit CoreBeat", action: onQuit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: Rows

    private static func appRow(
        _ app: AppRow, cpu: Double, detail: String, emphasised: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = rowTitle(
            name: app.identity.name, value: percent(cpu), detail: detail, emphasised: emphasised)
        item.submenu = actions(for: app, cause: KnownCauses.match(app))
        return item
    }

    private static func actions(for app: AppRow, cause: KnownCause?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // The explanation goes first: it is usually the whole answer, and
        // reading it should not require hovering and waiting for a tooltip.
        if let cause {
            for line in wrap(cause.explanation, every: 52) {
                menu.addItem(note(line))
            }
            menu.addItem(.separator())
        }

        let processes = app.members.count == 1 ? "1 process" : "\(app.members.count) processes"
        menu.addItem(note("\(processes) · \(bytes(app.rssBytes)) memory"))
        menu.addItem(.separator())

        let eligibility = Interventions.shared.eligibility(of: app)
        guard eligibility == .allowed else {
            menu.addItem(note(eligibility.explanation ?? "Not available"))
            addReveal(for: app, to: menu)
            return menu
        }

        if app.isPaused {
            menu.addItem(command("Resume") { Interventions.shared.resume(app) })
        } else {
            let minutes = Int(Interventions.autoResumeAfter / 60)
            let pause = command("Pause for \(minutes) Minutes") { Interventions.shared.pause(app) }
            pause.toolTip = "Stops it using any CPU while keeping it open. Resumes by itself."
            menu.addItem(pause)
        }

        let ease = command("Ease Off") { Interventions.shared.easeOff(app) }
        ease.toolTip = "Keeps it running on the efficiency cores, out of your way."
        menu.addItem(ease)
        menu.addItem(command("Restore Full Speed") { Interventions.shared.restoreSpeed(app) })

        menu.addItem(.separator())
        menu.addItem(command("Quit") { Interventions.shared.quit(app) })

        let force = command("Force Quit…") { confirmForceQuit(app) }
        force.toolTip = "Unsaved work in \(app.identity.name) will be lost."
        menu.addItem(force)

        addReveal(for: app, to: menu)
        return menu
    }

    private static func addReveal(for app: AppRow, to menu: NSMenu) {
        guard let path = bundlePath(forCommand: app.members.first?.command ?? "") else { return }
        menu.addItem(.separator())
        menu.addItem(command("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        })
    }

    private static func confirmForceQuit(_ app: AppRow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force quit \(app.identity.name)?"
        alert.informativeText =
            "It will be killed immediately and any unsaved work will be lost. "
            + "Try Quit first if you can."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Interventions.shared.forceQuit(app)
        }
    }

    // MARK: Item helpers

    /// The reading and the verdict on one line: what the machine is doing, and
    /// whether that is worth your attention.
    private static func headline(_ cpu: Double, verdict: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false

        let text = NSMutableAttributedString(
            string: "CPU \(Int(cpu.rounded()))%",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ])
        text.append(NSAttributedString(string: "  ·  " + verdict, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        item.attributedTitle = text
        item.toolTip = "Share of all \(Sampling.coreCount) cores. An app using 3 cores "
            + "of \(Sampling.coreCount) reads as \(300 / Sampling.coreCount)%."
        return item
    }

    private static func section(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private static func command(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        return item
    }

    /// Three columns — name, CPU, context — aligned with tab stops so the
    /// numbers line up and the list can be read down rather than across.
    private static func rowTitle(
        name: String, value: String, detail: String, emphasised: Bool, muted: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: cpuColumn),
            NSTextTab(textAlignment: .left, location: detailColumn),
        ]
        // Belt and braces: even a fitted name must never wrap, because a
        // wrapped row separates a number from the app it describes.
        paragraph.lineBreakMode = .byTruncatingTail

        let nameFont = NSFont.systemFont(
            ofSize: NSFont.systemFontSize, weight: emphasised ? .semibold : .regular)
        let name = fit(name, within: nameWidth, font: nameFont)

        let text = NSMutableAttributedString(
            string: "\(name)\t\(value)\t\(detail)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraph,
            ])

        let nameEnd = (name as NSString).length
        if emphasised {
            text.addAttribute(.font, value: nameFont, range: NSRange(location: 0, length: nameEnd))
        }
        if muted {
            // A summary row, not an app — it must not read as something you
            // could click and act on.
            text.addAttribute(
                .foregroundColor, value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: (text.string as NSString).length))
        }

        let detailStart = nameEnd + 1 + (value as NSString).length + 1
        let detailLength = (text.string as NSString).length - detailStart
        if detailLength > 0 {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: NSRange(location: detailStart, length: detailLength))
        }

        return text
    }

    // MARK: Formatting

    /// Breaks a paragraph into menu-width lines. NSMenu will not wrap an item
    /// for us — it renders one long unreadable row instead — so explanations
    /// are split across several disabled items.
    private static func wrap(_ text: String, every characters: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + word.count + 1 <= characters {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Shortens `text` until it actually measures under `width` in `font`.
    /// Measured rather than counted: "Kaspersky Anti-Virus For Mac" and
    /// "IIIIIIIIIIIIIIIIIIIIIIIIIIII" are the same number of characters and
    /// nothing like the same width.
    static func fit(_ text: String, within width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }

        var candidate = text
        while !candidate.isEmpty {
            candidate.removeLast()
            let trimmed = candidate.trimmingCharacters(in: .whitespaces) + "…"
            if (trimmed as NSString).size(withAttributes: attributes).width <= width {
                return trimmed
            }
        }
        return text
    }

    private static func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }

    private static func countdown(to date: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSinceNow / 60).rounded(.up)))
        return minutes <= 1 ? "under a minute" : "\(minutes) min"
    }

}

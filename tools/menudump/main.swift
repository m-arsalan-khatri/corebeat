import AppKit

// Builds the real menu from a real sample and prints it. A menu bar app cannot
// be clicked in CI, but this exercises everything up to the moment of drawing:
// the sparkline renders, every row builds, every submenu is populated and the
// eligibility rules pick the right actions for real processes on this machine.
//
// Run via ./test.sh, or on its own to see what the menu currently says.

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

guard let first = Sampling.captureProcesses() else {
    print("could not read the process table")
    exit(1)
}
let diagnosis = Diagnosis()
diagnosis.ingest(first)
Thread.sleep(forTimeInterval: 3)
guard let second = Sampling.captureProcesses() else {
    print("could not read the process table")
    exit(1)
}
diagnosis.ingest(second)

var hostCPU = 0.0
if let before = Sampling.hostTicks() {
    Thread.sleep(forTimeInterval: 1)
    if let after = Sampling.hostTicks(), after.total > before.total {
        hostCPU = Double(after.busy - before.busy) / Double(after.total - before.total) * 100
    }
}

// The colour ladder is the entire signal now that the number is gone, so it
// must not be trippable by a momentary spike.
let quiet = [Double](repeating: 8, count: 32)
guard Level(trace: quiet, routineShare: 0).tint == nil else {
    print("a quiet machine is not showing as steady")
    exit(1)
}
guard Level(trace: quiet.dropLast() + [100], routineShare: 0).tint == nil else {
    print("a single 100% sample turned the menu bar red — it must judge sustained load")
    exit(1)
}
guard Level(trace: [Double](repeating: 65, count: 32), routineShare: 0).tint == NSColor.systemOrange else {
    print("sustained 65% should read as elevated")
    exit(1)
}
let pegged = [Double](repeating: 95, count: 32)
guard Level(trace: pegged, routineShare: 0).tint == NSColor.systemRed else {
    print("sustained 95% with no explanation should read as racing")
    exit(1)
}
guard Level(trace: pegged, routineShare: 0.7).tint == NSColor.systemOrange else {
    print("load explained by routine work should be damped to elevated, not red")
    exit(1)
}
print("levels: steady < 50% < elevated < 80% < racing (sustained, routine work damped)")

// The tooltip is the only place the number survives, and its wording is the
// same three-rung vocabulary as the colour. Checked literally, because a
// mismatch between the word and the tint is a bug nobody would see in a
// screenshot.
for (trace, share, expected) in [
    (quiet, 0.0, "CPU 8% · steady"),
    ([Double](repeating: 65, count: 32), 0.0, "CPU 65% · elevated"),
    (pegged, 0.0, "CPU 95% · racing"),
    (pegged, 0.7, "CPU 95% · elevated"),
] {
    let level = Level(trace: trace, routineShare: share)
    let text = StatusIcon.summary(cpu: trace.last ?? 0, level: level, cause: nil)
    guard text == expected else {
        print("tooltip reads \"\(text)\", expected \"\(expected)\"")
        exit(1)
    }
}
print("tooltips: \"CPU 8% · steady\" / \"CPU 65% · elevated\" / \"CPU 95% · racing\"")

// A loaded machine with no owner for the load must say so rather than fall
// through to "nothing unusual", which is the reading that sends someone back
// to Activity Monitor.
func spread(_ shares: [Double]) -> [AppRow] {
    shares.map {
        AppRow(identity: Identity(key: "app:\($0)", name: "app"), cpu: $0, rssBytes: 0, members: [])
    }
}
let diffuse = spread([14, 12, 11, 9, 8])          // 71% total, nothing owning a third
let concentrated = spread([44, 12, 8, 5])         // one obvious culprit
guard MenuBuilder.isBroad(systemCPU: 71, apps: diffuse) else {
    print("load split five ways was not reported as spread")
    exit(1)
}
guard !MenuBuilder.isBroad(systemCPU: 71, apps: concentrated) else {
    print("an app owning 44 of 71 points is a culprit, not spread load")
    exit(1)
}
guard !MenuBuilder.isBroad(systemCPU: 22, apps: spread([5, 4, 4, 3])) else {
    print("a quiet machine must not be described as spread — there is nothing to explain")
    exit(1)
}
// The verdict is only offered when nothing has departed from its baseline;
// named changes are the better answer and must keep the headline.
guard MenuBuilder.verdict(changes: 0, calibrated: true, broad: true) == "spread across many apps",
      MenuBuilder.verdict(changes: 0, calibrated: false, broad: true) == "spread across many apps",
      MenuBuilder.verdict(changes: 0, calibrated: true, broad: false) == "nothing unusual",
      MenuBuilder.verdict(changes: 0, calibrated: false, broad: false) == "still learning what's normal",
      MenuBuilder.verdict(changes: 2, calibrated: true, broad: true) == "2 apps above normal" else {
    print("the headline verdict said the wrong thing")
    exit(1)
}
print("verdict: broad load reads \"spread across many apps\", changes still win the headline")

// The sparkline has to survive both a cold start and a full buffer.
let empty = StatusIcon.sparkline(history: [], level: .steady)
let full = StatusIcon.sparkline(
    history: (0..<StatusIcon.sparklineSamples).map { Double($0) * 3 }, level: .racing)
guard empty.size.width > 0, full.size.width > 0 else {
    print("sparkline failed to render")
    exit(1)
}
guard full.tiffRepresentation != nil else {
    print("sparkline produced no bitmap")
    exit(1)
}
print("sparkline: renders at \(Int(full.size.width))x\(Int(full.size.height)), "
      + "template=\(empty.isTemplate) tinted=\(!full.isTemplate)")
print("tooltip: \"\(StatusIcon.summary(cpu: hostCPU, level: Level(trace: [hostCPU], routineShare: 0), cause: nil))\"")

// Long names must be truncated to fit their column. Unbounded, they either
// collapse the gap before the percentage ("Kaspersky Anti-Virus For Mac9.8%")
// or wrap the row, orphaning the number from the app it describes.
let rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
for sample in [
    "Kaspersky Anti-Virus For Mac",
    "com.apple.Virtualization.VirtualMachine",
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII",
] {
    let fitted = MenuBuilder.fit(sample, within: MenuBuilder.nameWidth, font: rowFont)
    let width = (fitted as NSString).size(withAttributes: [.font: rowFont]).width
    guard width <= MenuBuilder.nameWidth else {
        print("name column overflows: \"\(fitted)\" is \(Int(width))pt")
        exit(1)
    }
}
print("names: fitted to \(Int(MenuBuilder.nameWidth))pt "
      + "(e.g. \"\(MenuBuilder.fit("com.apple.Virtualization.VirtualMachine", within: MenuBuilder.nameWidth, font: rowFont))\")")
guard readableName("com.apple.Virtualization.VirtualMachine") == "VirtualMachine",
      readableName("Google Chrome Helper (GPU)") == "Google Chrome Helper (GPU)",
      readableName("node") == "node" else {
    print("readableName mangled something it should not have")
    exit(1)
}

let menu = MenuBuilder.build(systemCPU: hostCPU, diagnosis: diagnosis, onQuit: {})

// Nothing that reaches the screen may exceed the name column either.
for item in menu.items {
    guard let attributed = item.attributedTitle, attributed.string.contains("\t") else { continue }
    let name = attributed.string.components(separatedBy: "\t")[0]
    let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? rowFont
    let width = (name as NSString).size(withAttributes: [.font: font]).width
    guard width <= MenuBuilder.nameWidth else {
        print("live row overflows: \"\(name)\" is \(Int(width))pt")
        exit(1)
    }
}

print("\n--- menu ---")
var rows = 0
var submenus = 0
for item in menu.items {
    if item.isSeparatorItem {
        print("  ----------------")
        continue
    }
    let title = item.attributedTitle?.string ?? item.title
    print("  \(title.replacingOccurrences(of: "\t", with: "  |  "))")
    rows += 1

    guard let submenu = item.submenu else { continue }
    submenus += 1
    for sub in submenu.items {
        if sub.isSeparatorItem { continue }
        let subtitle = sub.attributedTitle?.string ?? sub.title
        print("      · \(subtitle)")
    }
}

// The percentages in the menu must reconcile with the header, or the first
// thing anyone does is add them up, come up short, and distrust the number.
var column = 0.0
var percentRows = 0
for item in menu.items {
    guard let attributed = item.attributedTitle else { continue }
    let fields = attributed.string.components(separatedBy: "\t")
    guard fields.count >= 2, fields[1].hasSuffix("%"),
          let value = Double(fields[1].dropLast()) else { continue }
    column += value
    percentRows += 1
}
// Rounding is the only drift there should be: rows at or above 10% are shown
// as whole numbers, so each can be off by up to half a point.
let tolerance = 0.5 * Double(percentRows) + 0.2
let drift = abs(column - hostCPU)
print(String(format: "\naccounting: %d rows sum to %.1f%%, header says %.1f%% "
             + "(drift %.1f, rounding allows %.1f)",
             percentRows, column, hostCPU, drift, tolerance))
guard hostCPU < 2 || drift <= tolerance else {
    print("the menu does not add up — the remainder row is wrong or missing")
    exit(1)
}

print("\n\(rows) rows, \(submenus) with actions")
guard rows > 3 else {
    print("menu is suspiciously empty")
    exit(1)
}
print("menu built cleanly")

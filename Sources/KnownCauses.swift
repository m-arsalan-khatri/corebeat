import Foundation

// A lot of high CPU on a Mac is routine work that finishes by itself:
// Spotlight rebuilding an index after a big copy, Time Machine running a
// backup, Photos scanning a library, a corporate antivirus doing its nightly
// pass. Left unexplained, all of these look identical to a runaway process.
//
// Naming them is most of the value. "Spotlight is indexing, it stops on its
// own" turns an alarming number into something you can ignore, and it is the
// difference between a tool that worries you and one that settles the
// question.
//
// Only claims that hold generally belong here. Every entry describes what the
// process is for, not what the user should do about it, and `endsOnItsOwn` is
// set only where the work genuinely is finite.

struct KnownCause: Sendable {
    let title: String
    /// One short phrase for the row's detail column.
    let detail: String
    /// The full explanation, shown in the submenu and as a tooltip.
    let explanation: String
    /// Whether this finishes without intervention. Drives the menu bar colour:
    /// a saturated Mac that is saturated for a known, finite reason is not
    /// worth an alarm.
    let endsOnItsOwn: Bool
}

enum KnownCauses {
    /// Recognises an app by its own name, its processes' names, or their paths.
    /// Paths matter: ManageEngine's agent runs as `dcuserhandler`, which is
    /// meaningless on its own but sits under `/Library/ManageEngine/`.
    static func match(_ app: AppRow) -> KnownCause? {
        var haystack = [app.identity.name.lowercased()]
        for member in app.members {
            haystack.append(member.name.lowercased())
            haystack.append(member.command.lowercased())
        }

        for rule in rules {
            if rule.names.contains(where: { name in
                haystack.contains { $0 == name || $0.hasSuffix("/" + name) }
            }) {
                return rule.cause
            }
            if rule.fragments.contains(where: { fragment in
                haystack.contains { $0.contains(fragment) }
            }) {
                return rule.cause
            }
        }
        return nil
    }

    /// How much of the current load is routine work that will end by itself.
    static func routineLoad(in apps: [AppRow]) -> Double {
        apps.reduce(0) { total, app in
            guard let cause = match(app), cause.endsOnItsOwn else { return total }
            return total + app.cpu
        }
    }

    private struct Rule {
        let names: [String]
        let fragments: [String]
        let cause: KnownCause

        init(names: [String] = [], fragments: [String] = [], _ cause: KnownCause) {
            self.names = names
            self.fragments = fragments
            self.cause = cause
        }
    }

    private static let rules: [Rule] = [
        Rule(names: ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
                     "corespotlightd", "spotlight", "mdsyncd"],
             KnownCause(
                title: "Spotlight indexing",
                detail: "ends on its own",
                explanation: "Spotlight is building its search index. This is normal after a "
                    + "large file copy, a macOS update, a git checkout of a big repository, or "
                    + "connecting a new drive. It stops by itself — usually minutes, occasionally "
                    + "an hour or two for a full re-index.",
                endsOnItsOwn: true)),

        Rule(names: ["backupd", "backupd-helper"],
             KnownCause(
                title: "Time Machine backup",
                detail: "ends on its own",
                explanation: "A Time Machine backup is running. It yields CPU when you need it "
                    + "and finishes on its own. The first backup to a new disk takes far longer "
                    + "than later ones.",
                endsOnItsOwn: true)),

        Rule(names: ["photoanalysisd", "photolibraryd"],
             KnownCause(
                title: "Photos analysis",
                detail: "ends on its own",
                explanation: "Photos is scanning your library for people, scenes and duplicates. "
                    + "It runs after an import and mostly while plugged in, and finishes on its "
                    + "own.",
                endsOnItsOwn: true)),

        Rule(names: ["mediaanalysisd"],
             KnownCause(
                title: "Media analysis",
                detail: "ends on its own",
                explanation: "macOS is analysing images and video for Visual Look Up and "
                    + "Memories. It finishes on its own.",
                endsOnItsOwn: true)),

        Rule(names: ["softwareupdated", "softwareupdate_download_service", "suhelperd"],
             KnownCause(
                title: "macOS update",
                detail: "ends on its own",
                explanation: "macOS is downloading or preparing a system update.",
                endsOnItsOwn: true)),

        Rule(names: ["installd", "packagekitd", "system_installd", "appstoreagent"],
             KnownCause(
                title: "Installing software",
                detail: "ends on its own",
                explanation: "Something is being installed or updated in the background.",
                endsOnItsOwn: true)),

        Rule(names: ["xprotectremediator", "xprotectservice", "mrt"],
             fragments: ["xprotect"],
             KnownCause(
                title: "Malware scan",
                detail: "ends on its own",
                explanation: "XProtect, the malware scanner built into macOS, is running its "
                    + "routine check. It runs periodically and takes a few minutes.",
                endsOnItsOwn: true)),

        Rule(names: ["syspolicyd", "amfid", "gatekeeperd"],
             KnownCause(
                title: "App security check",
                detail: "ends on its own",
                explanation: "macOS is verifying an app's signature — normally the first time "
                    + "you open something newly downloaded or rebuilt. It is brief.",
                endsOnItsOwn: true)),

        Rule(names: ["cloudd", "bird", "fileproviderd", "nsurlsessiond"],
             KnownCause(
                title: "iCloud sync",
                detail: "settles when uploads finish",
                explanation: "iCloud is syncing files in the background. It settles once "
                    + "uploads and downloads finish.",
                endsOnItsOwn: true)),

        Rule(names: ["oahd", "oahd-helper"],
             KnownCause(
                title: "Translating an Intel app",
                detail: "ends on its own",
                explanation: "Rosetta is translating an Intel app to run on Apple silicon. "
                    + "This happens once per app version, on first launch.",
                endsOnItsOwn: true)),

        Rule(names: ["dasd", "coreduetd", "knowledge-agent", "suggestd", "parsecd"],
             KnownCause(
                title: "Background maintenance",
                detail: "ends on its own",
                explanation: "macOS is running scheduled background housekeeping — the kind of "
                    + "work it defers until it thinks you are not busy.",
                endsOnItsOwn: true)),

        Rule(fragments: ["kaspersky", "sophos", "mcafee", "norton", "avast", "eset",
                         "crowdstrike", "falcond", "sentinelone", "carbonblack", "cbdaemon",
                         "mpengine", "malwarebytes", "bitdefender", "trendmicro", "webroot",
                         "cylance", "/kavd", "kav_agent"],
             KnownCause(
                title: "Antivirus scan",
                detail: "usually ends on its own",
                explanation: "Your antivirus is scanning. Scheduled scans finish on their own. "
                    + "On-access scanning also spikes whenever a lot of files change at once — a "
                    + "build, a large copy, or a git checkout — and settles when that stops.",
                endsOnItsOwn: true)),

        Rule(fragments: ["manageengine", "dcuserhandler", "dcdevicehandler", "uems_agent",
                         "jamf", "intune", "kandji", "munki", "workspaceone", "airwatch",
                         "mosyle", "addigy"],
             KnownCause(
                title: "Device management agent",
                detail: "checks in periodically",
                explanation: "Your organisation's device management agent is checking in or "
                    + "running an inventory scan. These run on a schedule and are not something "
                    + "you can usefully turn off on a managed Mac.",
                endsOnItsOwn: true)),

        // Deliberately not marked as ending on its own: sustained WindowServer
        // load is a symptom of how you are using the machine, not a finite job.
        Rule(names: ["windowserver"],
             KnownCause(
                title: "Drawing your screen",
                detail: "scales with displays and windows",
                explanation: "WindowServer composites everything you see. It rises with large "
                    + "or multiple displays, a lot of open windows, and animation-heavy pages. "
                    + "If it is persistently high, closing windows or disconnecting a display "
                    + "does more than anything you could do to an app.",
                endsOnItsOwn: false)),
    ]
}

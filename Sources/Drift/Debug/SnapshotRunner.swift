import AppKit
import DriftCore
import SwiftUI

/// Renders the widget and launcher in a set of representative states to PNG
/// files, then quits. Used by CI so UI changes can be reviewed as images
/// without a Mac at hand:
///
///   DRIFT_SNAPSHOT_DIR=out .build/debug/Drift
///
/// Rendering uses AppKit's cached display, which skips the behind-window blur,
/// so each image is drawn over a neutral "desktop" backdrop instead.
@MainActor
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let settings: AppSettings
    private let store: TimerStore
    private let schedule: ScheduleStore
    private let voice = VoiceController()
    private var window: NSWindow?

    init(directory: URL) {
        self.directory = directory
        let suite = UserDefaults(suiteName: "drift.snapshots") ?? .standard
        suite.removePersistentDomain(forName: "drift.snapshots")
        settings = AppSettings(defaults: suite)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drift-snapshots-\(UUID().uuidString).json")
        store = TimerStore(settings: settings, fileURL: file)
        let scheduleFile = FileManager.default.temporaryDirectory.appendingPathComponent("drift-snapshots-schedule-\(UUID().uuidString).json")
        schedule = ScheduleStore(timers: store, settings: settings, fileURL: scheduleFile, autoTick: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await self.renderAll()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Scenarios

    private struct Scenario {
        var name: String
        var timers: [DriftTimer]
        var primary: UUID?
        var expanded = false
        var hideHint = false
        var alerting = false
        var renaming = false
        var dial: TimeInterval?
        var blocks: [ScheduledBlock] = []
        var promptFor: Int?
        /// Open the editor on this block; -1 for a new one.
        var editBlock: Int?
        var editChange: ((inout BlockDraft) -> Void)?
        var focusSound = false
        var dark = false
    }

    private func running(_ name: String?, total: TimeInterval, left: TimeInterval, pomodoro: PomodoroCycle? = nil) -> DriftTimer {
        let now = Date()
        var t = DriftTimer(name: name, duration: total, pomodoro: pomodoro)
        t.state = .running(endDate: now.addingTimeInterval(left))
        t.startedAt = now.addingTimeInterval(left - total)
        return t
    }

    private func paused(_ name: String?, total: TimeInterval, left: TimeInterval) -> DriftTimer {
        var t = DriftTimer(name: name, duration: total)
        t.state = .paused(remaining: left)
        t.startedAt = Date().addingTimeInterval(-60)
        return t
    }

    private func finished(_ name: String?, total: TimeInterval) -> DriftTimer {
        var t = DriftTimer(name: name, duration: total)
        t.state = .finished(at: Date())
        return t
    }

    private func scenarios() -> [Scenario] {
        let writing = running("Writing", total: 2_700, left: 1_453.4)
        let unnamed = running(nil, total: 1_500, left: 1_213.4)
        let laundry = running("Laundry", total: 3_600, left: 2_462.4)
        let tea = paused("Tea", total: 300, left: 192)
        var focus = PomodoroCycle()
        focus.round = 2
        let pomo = running(nil, total: 1_500, left: 931.4, pomodoro: focus)
        var rest = PomodoroCycle()
        rest.round = 2
        rest.phase = .rest
        let pomoBreak = running(nil, total: 300, left: 244.4, pomodoro: rest)
        let done = finished("Email", total: 1_500)

        return [
            Scenario(name: "01-idle", timers: []),
            Scenario(name: "02-running-collapsed", timers: [writing], primary: writing.id),
            Scenario(name: "03-several-collapsed", timers: [writing, laundry, tea], primary: writing.id),
            Scenario(name: "04-several-expanded", timers: [writing, laundry, tea], primary: writing.id, expanded: true),
            Scenario(name: "05-unnamed-expanded", timers: [unnamed], primary: unnamed.id, expanded: true, focusSound: true),
            Scenario(name: "06-renaming", timers: [unnamed], primary: unnamed.id, expanded: true, renaming: true),
            Scenario(name: "07-pomodoro-focus-expanded", timers: [pomo], primary: pomo.id, expanded: true),
            Scenario(name: "08-pomodoro-break-collapsed", timers: [pomoBreak], primary: pomoBreak.id),
            Scenario(name: "09-finished-alerting", timers: [done, laundry], primary: done.id, expanded: true, alerting: true),
            Scenario(name: "10-hide-hint", timers: [writing], primary: writing.id, hideHint: true),
            Scenario(name: "11-dark-expanded", timers: [writing, laundry, tea], primary: writing.id, expanded: true, focusSound: true, dark: true),
            Scenario(name: "12-dark-collapsed", timers: [writing, laundry], primary: writing.id, dark: true),
            Scenario(name: "13-unnamed-collapsed", timers: [unnamed], primary: unnamed.id),
            Scenario(name: "14-dial", timers: [writing], primary: writing.id, dial: 1_920),
            Scenario(name: "15-dial-dark-hours", timers: [laundry], primary: laundry.id, dial: 5_400, dark: true),
            Scenario(name: "30-plan-idle-next", timers: [], blocks: plan()),
            Scenario(name: "31-plan-expanded", timers: [writing], primary: writing.id, expanded: true, blocks: plan()),
            Scenario(name: "32-plan-prompt", timers: [writing], primary: writing.id, blocks: plan(), promptFor: 1),
            Scenario(name: "33-plan-editor-new", timers: [writing], primary: writing.id, blocks: plan(), editBlock: -1),
            Scenario(name: "34-plan-editor-just-today", timers: [writing], primary: writing.id, blocks: plan(), editBlock: 0,
                     editChange: { $0.startMinute += 30 }),
            Scenario(name: "35-plan-dark-expanded", timers: [], expanded: true, blocks: plan(), dark: true),
        ]
    }

    /// A day's plan around the current time: one block every day an hour from
    /// now, one starting now (for the prompt), and one later on.
    private func plan() -> [ScheduledBlock] {
        let cal = Calendar.current
        let now = Date()
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let key = Schedule.dayKey(now)
        let soon = min(1_380, (minute / 15 + 4) * 15)
        return [
            ScheduledBlock(name: "Deep work", startMinute: soon, duration: 5_400, days: Array(0...6), date: nil),
            ScheduledBlock(name: "Email", startMinute: max(0, minute - 1), duration: 1_800, days: nil, date: key),
            ScheduledBlock(name: "Reading", startMinute: min(1_410, soon + 120), duration: 1_800, days: [0, 1, 2, 3, 4, 5, 6], date: nil),
        ]
    }

    // MARK: - Rendering

    private func renderAll() async {
        for s in scenarios() {
            store.replaceAll(s.timers, primary: s.primary)
            settings.focusSoundEnabled = s.focusSound
            let ui = WidgetUIState()
            ui.expanded = s.expanded
            ui.hideHint = s.hideHint
            ui.alerting = s.alerting
            if s.renaming, let id = s.primary {
                ui.renamingID = id
                ui.draft = "Email"
            }
            if let value = s.dial, let id = s.primary {
                ui.dialID = id
                ui.dialValue = value
            }
            var prompt: ScheduleStore.Prompt?
            if let i = s.promptFor, i < s.blocks.count {
                prompt = .init(blockID: s.blocks[i].id, deadline: Date().addingTimeInterval(42))
            }
            schedule.replaceAll(s.blocks, prompt: prompt)
            if let i = s.editBlock {
                ui.editBlock(i >= 0 && i < s.blocks.count ? s.blocks[i].id : nil, schedule: schedule)
                if i < 0 { ui.blockDraft?.name = "Gym" }
                if let change = s.editChange, var d = ui.blockDraft {
                    change(&d)
                    ui.blockDraft = d
                }
            }
            let actions = WidgetActions(
                openComposer: {}, openVoice: {}, acknowledge: {}, hide: {},
                resize: { _ in }, focusPanel: {}, releaseFocus: {}
            )
            let view = WidgetView(store: store, settings: settings, ui: ui, schedule: schedule, actions: actions)
            await render(view, name: s.name, dark: s.dark)
        }

        // Launcher states.
        let runner = CommandRunner(store: store, settings: settings)
        let launcher: [(String, String, Bool, Bool)] = [
            ("20-launcher-first-run", "", false, false),
            ("21-launcher-task-only", "Write intro", false, false),
            ("22-launcher-task-and-time", "Write intro 45m", false, false),
            ("23-launcher-number", "25", false, false),
            ("24-launcher-recents", "", true, false),
            ("25-launcher-dark-words", "Reading for an hour and a half", true, true),
            ("26-launcher-schedule", "Deep work 9-10:30 weekdays", true, false),
            ("27-launcher-schedule-at", "Email at 1pm for 30m", true, true),
        ]
        for (name, text, returning, dark) in launcher {
            settings.forgetRecents()
            settings.hasWrittenTask = false
            if returning {
                settings.remember(task: "Email", seconds: 1_500)
                settings.remember(task: "Write intro", seconds: 2_700)
            }
            let model = ComposerModel()
            model.text = text
            let view = ComposerView(
                model: model, settings: settings, voice: voice,
                preview: { runner.preview($0) },
                plan: { runner.plan($0) },
                submit: {}, startPreset: { _ in }, startRecent: { _ in }, startPomodoro: {},
                toggleVoice: {}, close: {}, resize: { _ in }
            )
            await render(view, name: name, dark: dark)
        }

        // First-launch guide.
        settings.hasSeenWelcome = false
        await render(WelcomeView(settings: settings, tryIt: {}, close: {}).background(Color(nsColor: .windowBackgroundColor)), name: "40-welcome", dark: false)
        await render(WelcomeView(settings: settings, tryIt: {}, close: {}).background(Color(nsColor: .windowBackgroundColor)), name: "41-welcome-dark", dark: true)

        await renderStoreShots(runner: runner)
    }

    // MARK: - App Store screenshots

    private enum ShotLayout { case stacked, side }

    /// Marketing screenshots at 2880×1800 (Apple's largest Mac size): a headline
    /// beside the real UI, scaled up, on a dark ember backdrop.
    private func renderStoreShots(runner: CommandRunner) async {
        let writing = running("Write intro", total: 2_700, left: 2_699.4)
        let email = running("Email", total: 1_500, left: 1_453.4)
        let laundry = running("Laundry", total: 3_600, left: 2_462.4)
        let tea = paused("Tea", total: 300, left: 192)
        let reading = running("Reading", total: 1_800, left: 1_312.4)
        // Store shots show a typical day, not the build machine's clock.
        let plan = [
            ScheduledBlock(name: "Deep work", startMinute: 9 * 60, duration: 5_400, days: Array(0...6), date: nil),
            ScheduledBlock(name: "Email", startMinute: 13 * 60, duration: 1_800, days: Array(0...6), date: nil),
            ScheduledBlock(name: "Reading", startMinute: 20 * 60, duration: 1_800, days: Array(0...6), date: nil),
        ]

        func widget(_ timers: [DriftTimer], primary: UUID?, blocks: [ScheduledBlock] = [], prompt: Int? = nil,
                    focus: Bool = false, configure: (WidgetUIState) -> Void = { _ in }) -> WidgetView {
            store.replaceAll(timers, primary: primary)
            settings.focusSoundEnabled = focus
            var p: ScheduleStore.Prompt?
            if let prompt { p = .init(blockID: blocks[prompt].id, deadline: Date().addingTimeInterval(52)) }
            schedule.replaceAll(blocks, prompt: p)
            let ui = WidgetUIState()
            configure(ui)
            let actions = WidgetActions(openComposer: {}, openVoice: {}, acknowledge: {}, hide: {},
                                        resize: { _ in }, focusPanel: {}, releaseFocus: {})
            return WidgetView(store: store, settings: settings, ui: ui, schedule: schedule, actions: actions)
        }

        // 1. The launcher.
        settings.forgetRecents()
        settings.hasWrittenTask = true
        let model = ComposerModel()
        model.text = "Write intro 45m"
        let launcher = ComposerView(
            model: model, settings: settings, voice: voice,
            preview: { runner.preview($0) }, plan: { runner.plan($0) },
            submit: {}, startPreset: { _ in }, startRecent: { _ in }, startPomodoro: {},
            toggleVoice: {}, close: {}, resize: { _ in }, autofocus: false
        )
        let w1 = widget([writing], primary: writing.id)
        await renderShot(
            name: "store-1-launcher",
            headline: "Write the task.\nDrift keeps the time.",
            sub: "Press ⌥ Space in any app and type what you're working on and for how long.",
            layout: .stacked
        ) {
            ZStack {
                launcher.fixedSize().scaleEffect(1.7).position(x: 720, y: 470)
                w1.fixedSize().scaleEffect(2.1).position(x: 720, y: 755)
            }
        }

        // 2. The dial.
        let w2 = widget([writing], primary: writing.id) { ui in
            ui.dialID = writing.id
            ui.dialValue = 1_920
        }
        await renderShot(name: "store-2-dial", headline: "Click the time.\nTurn the dial.",
                         sub: "Drag a minute at a time, or tap 5, 10, 15, 20, 25, 30 or 45 minutes, 1 or 2 hours.",
                         layout: .side) {
            w2.fixedSize().scaleEffect(1.75).position(x: 1_060, y: 455)
        }

        // 3. Plan your day.
        let w3 = widget([email], primary: email.id, blocks: plan, prompt: 0) { ui in ui.expanded = true }
        await renderShot(name: "store-3-plan", headline: "Plan your day.\nBlocks start on time.",
                         sub: "Type “Deep work 9–10:30 weekdays”. When it's time, Drift asks, then starts it. Move any block just for today.",
                         layout: .side) {
            w3.fixedSize().scaleEffect(1.85).position(x: 1_060, y: 450)
        }

        // 4. Several timers, named in place.
        let w4 = widget([email, laundry, tea, reading], primary: email.id, blocks: plan) { ui in
            ui.expanded = true
            ui.renamingID = email.id
            ui.draft = "Email inbox"
        }
        await renderShot(name: "store-4-several", headline: "Name it in place.\nRun several at once.",
                         sub: "Click a name to type, a time to change it. Every timer in one small widget.",
                         layout: .side) {
            w4.fixedSize().scaleEffect(1.85).position(x: 1_060, y: 450)
        }

        // 5. Focus sound.
        let w5 = widget([reading], primary: reading.id, blocks: plan, focus: true) { ui in ui.expanded = true }
        await renderShot(name: "store-5-sound", headline: "Soft focus sound,\nmade on your Mac.",
                         sub: "Rain, ocean, fireplace, lo-fi, binaural beats and more. Off until you want it; quiet on breaks.",
                         layout: .side) {
            w5.fixedSize().scaleEffect(1.95).position(x: 1_060, y: 450)
        }
        settings.focusSoundEnabled = false
    }

    private func renderShot<Content: View>(name: String, headline: String, sub: String, layout: ShotLayout,
                                           @ViewBuilder content: () -> Content) async {
        let cream = Color(red: 0.96, green: 0.93, blue: 0.90)
        let canvas = ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.085), Color(red: 0.16, green: 0.12, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.30).opacity(0.38), .clear],
                           center: .bottomTrailing, startRadius: 40, endRadius: 900)
            switch layout {
            case .stacked:
                VStack(spacing: 14) {
                    Text(headline.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(cream)
                    Text(sub)
                        .font(.system(size: 24))
                        .foregroundStyle(cream.opacity(0.62))
                }
                .multilineTextAlignment(.center)
                .frame(width: 1_200)
                .position(x: 720, y: 150)
            case .side:
                VStack(alignment: .leading, spacing: 20) {
                    Text(headline)
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundStyle(cream)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sub)
                        .font(.system(size: 24))
                        .foregroundStyle(cream.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 560, alignment: .leading)
                .position(x: 96 + 280, y: 450)
            }
            content()
        }
        .frame(width: 1_440, height: 900)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: canvas)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: -5_000, y: -5_000, width: 1_440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        try? await Task.sleep(nanoseconds: 900_000_000)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_880, pixelsHigh: 1_800,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: 1_440, height: 900)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // App Store screenshots must not have an alpha channel.
        guard let cg = rep.cgImage,
              let ctx = CGContext(data: nil, width: 2_880, height: 1_800, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 2_880, height: 1_800))
        guard let flat = ctx.makeImage() else { return }
        let out = NSBitmapImageRep(cgImage: flat)
        if let png = out.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
            print("snapshot \(name) 2880x1800")
        }
        window.orderOut(nil)
    }

    private func render<V: View>(_ content: V, name: String, dark: Bool) async {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = dark ? Color(red: 0.13, green: 0.12, blue: 0.11) : Color(red: 0.86, green: 0.85, blue: 0.83)
        let framed = content
            .padding(28)
            .background(backdrop)
            .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window

        // Let SwiftUI lay out, settle animations and resize.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let finalSize = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: finalSize)
        window.setContentSize(finalSize)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
            print("snapshot \(name) \(Int(finalSize.width))x\(Int(finalSize.height))")
        }
        window.orderOut(nil)
    }
}

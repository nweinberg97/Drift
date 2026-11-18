import DriftCore
import Foundation

/// One thing to do on a break: "Torso twists", with a one-line how-to and,
/// for movements, a few short steps.
struct BreakActivity: Codable, Identifiable, Equatable {
    var id: String
    var kind: BreakKind
    var name: String
    var detail: String
    var steps: [String]
    var enabled: Bool
    /// Added by you rather than part of the starter set.
    var custom: Bool

    init(_ kind: BreakKind, _ id: String, _ name: String, _ detail: String, steps: [String] = [], enabled: Bool = true, custom: Bool = false) {
        self.kind = kind
        self.id = "\(kind.rawValue).\(id)"
        self.name = name
        self.detail = detail
        self.steps = steps
        self.enabled = enabled
        self.custom = custom
    }

    static func yours(_ kind: BreakKind, name: String) -> BreakActivity {
        BreakActivity(kind, "custom-\(UUID().uuidString.prefix(8))", name, "Your own.", custom: true)
    }

    /// The starter library.
    static let starters: [BreakActivity] = [
        BreakActivity(.move, "torso", "Torso twists", "Stand tall, feet planted, twist slowly.",
                      steps: ["Hands on hips, feet hip-width", "Twist left, then right, from the waist", "10 slow twists each side"]),
        BreakActivity(.move, "legs", "Leg swings", "Hold the desk, swing each leg.",
                      steps: ["One hand on your desk", "10 forward-and-back swings", "Switch legs"]),
        BreakActivity(.move, "shoulders", "Shoulder rolls", "Roll back slowly, then forward.",
                      steps: ["Drop your shoulders", "10 rolls backwards", "10 rolls forwards"]),
        BreakActivity(.move, "reach", "Stand and reach", "Reach up tall, then fold forward.",
                      steps: ["Reach both arms overhead", "Hold for a slow breath", "Fold forward and let your arms hang"]),
        BreakActivity(.move, "squats", "Desk squats", "Ten slow squats, chair behind you.",
                      steps: ["Feet shoulder-width", "Lower until you touch the chair", "Stand up, 10 times"]),
        BreakActivity(.walk, "block", "Walk around the block", "Leave your phone on the desk."),
        BreakActivity(.walk, "stairs", "Take the stairs", "Up and down one flight, twice."),
        BreakActivity(.walk, "window", "Walk to the window", "Look at something far away for a minute."),
        BreakActivity(.walk, "lap", "Lap of the house", "Every room, no stopping to tidy."),
        BreakActivity(.hydrate, "glass", "Glass of water", "A full glass, slowly."),
        BreakActivity(.hydrate, "refill", "Refill your bottle", "Fill it to the top and bring it back."),
        BreakActivity(.hydrate, "tea", "Make a tea", "Herbal if it's late in the day."),
        BreakActivity(.snack, "fruit", "Piece of fruit", "Away from the screen."),
        BreakActivity(.snack, "nuts", "Handful of nuts", "A small handful, not the bag."),
        BreakActivity(.snack, "protein", "Yogurt or cheese", "Something with a bit of protein."),
        BreakActivity(.breathe, "box", "Box breathing", "In 4, hold 4, out 4, hold 4.",
                      steps: ["Breathe in for 4", "Hold for 4", "Out for 4, hold for 4, repeat"]),
        BreakActivity(.breathe, "exhale", "Long exhales", "Breathe out twice as long as in."),
        BreakActivity(.breathe, "eyes", "Eyes closed, one minute", "Just notice your breathing."),
    ]
}

/// What's showing on a break card.
struct BreakNow: Equatable {
    var kind: BreakKind
    var activity: BreakActivity
}

extension AppSettings {
    func activities(_ kind: BreakKind) -> [BreakActivity] {
        breakActivities.filter { $0.kind == kind }
    }

    func activity(named name: String?, kind: BreakKind) -> BreakActivity {
        if let name, let found = breakActivities.first(where: { $0.kind == kind && $0.name == name }) { return found }
        return BreakActivity(kind, "fallback", name ?? "\(kind.title) break", "Step away for a moment.")
    }

    /// The next short-break kind from your plan: in order, or mixed without
    /// repeating the last one.
    func nextShortKind() -> BreakKind {
        let kinds = breakShortKinds.isEmpty ? [BreakKind.move] : breakShortKinds
        let key = "breakKindTurn"
        let turn = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(turn + 1, forKey: key)
        if breakMix, kinds.count > 1 {
            let last = UserDefaults.standard.string(forKey: "breakKindLast").flatMap(BreakKind.init(rawValue:))
            let choice = kinds.filter { $0 != last }.randomElement() ?? kinds[0]
            UserDefaults.standard.set(choice.rawValue, forKey: "breakKindLast")
            return choice
        }
        return kinds[turn % kinds.count]
    }

    /// The next activity of a kind, rotating through the ones switched on.
    /// `avoiding` skips the one on screen (for Swap).
    func pickActivity(_ kind: BreakKind, avoiding: String? = nil) -> BreakActivity {
        let on = activities(kind).filter(\.enabled)
        guard !on.isEmpty else { return activity(named: nil, kind: kind) }
        let key = "breakTurn.\(kind.rawValue)"
        var turn = UserDefaults.standard.integer(forKey: key)
        var choice = on[turn % on.count]
        if choice.name == avoiding, on.count > 1 {
            turn += 1
            choice = on[turn % on.count]
        }
        UserDefaults.standard.set(turn + 1, forKey: key)
        return choice
    }

    /// Fills in what a timer's break will be: the kind of the break coming up
    /// during focus, and the activity once a break starts.
    func guide(_ t: inout DriftTimer) {
        guard guidedBreaks else { return }
        if var c = t.pomodoro {
            if c.breakKind == nil {
                let longNext = c.isBreak ? c.phase == .longRest : c.advanced().phase == .longRest
                c.breakKind = longNext ? breakLongKind : nextShortKind()
            }
            if c.isBreak, c.activity == nil, let kind = c.breakKind {
                c.activity = pickActivity(kind).name
            }
            if c != t.pomodoro { t.pomodoro = c }
        }
        if var steps = t.steps, let i = t.stepIndex, steps.indices.contains(i), steps[i].isBreak, steps[i].activity == nil {
            let kind = steps[i].breakKind ?? nextShortKind()
            steps[i].breakKind = kind
            steps[i].activity = pickActivity(kind).name
            t.steps = steps
        }
    }

    /// The break on screen right now, if the timer is in one.
    func breakNow(_ t: DriftTimer) -> BreakNow? {
        guard guidedBreaks, !t.isFinished, !t.isWaiting else { return nil }
        if let c = t.pomodoro, c.isBreak, let kind = c.breakKind {
            return BreakNow(kind: kind, activity: activity(named: c.activity, kind: kind))
        }
        if let b = t.currentBlock, b.isBreak, let kind = b.breakKind {
            return BreakNow(kind: kind, activity: activity(named: b.activity, kind: kind))
        }
        return nil
    }

    func addActivity(_ kind: BreakKind, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        breakActivities.append(.yours(kind, name: trimmed))
    }

    func setActivity(_ id: String, enabled: Bool) {
        guard let i = breakActivities.firstIndex(where: { $0.id == id }) else { return }
        breakActivities[i].enabled = enabled
    }

    func removeActivity(_ id: String) {
        breakActivities.removeAll { $0.id == id && $0.custom }
    }

    func toggleShortKind(_ kind: BreakKind) {
        if breakShortKinds.contains(kind) {
            guard breakShortKinds.count > 1 else { return }
            breakShortKinds.removeAll { $0 == kind }
        } else {
            breakShortKinds = BreakKind.allCases.filter { $0 == kind || breakShortKinds.contains($0) }
        }
    }
}

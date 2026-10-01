import Foundation

/// Picks where a plain open lands and learns from where the owner ends up.
/// Jev drives; Luna answers the same moments in the shadow; a Codex reviewer rewrites the rules both read.
/// Calls run in the background; an open with no current pick may wait briefly for Jev, never for Luna.
@Observable
final class SectionPredictor {
    enum Status: Equatable { case waiting, ready, off, missingKey, capReached, failed(String) }

    struct Rate {
        var hits = 0, total = 0
        var text: String { total == 0 ? "no data yet" : "\(hits * 100 / total)% (\(hits) of \(total))" }
        mutating func count(_ hit: Bool) { total += 1; hits += hit ? 1 : 0 }
    }

    /// The opens one model drove. `rulesWhereModel` scores the rules on the opens the model answered.
    struct Rates {
        var model = Rate(), rules = Rate(), rulesWhereModel = Rate(), shadow = Rate(), landedWhereShadow = Rate()

        mutating func add(_ s: SessionRecord, _ outcome: Outcome) {
            let rulesHit = s.heuristic?.matches(outcome) == true
            rules.count(rulesHit)
            if let pick = s.shadow?.intent { shadow.count(pick.matches(outcome)); landedWhereShadow.count(s.landed.matches(outcome)) }
            if let pick = s.model?.intent { model.count(pick.matches(outcome)); rulesWhereModel.count(rulesHit) }
        }
    }

    /// Jev, which picks the landing.
    let driver: any ModelRunner
    /// Codex: Luna in the shadow, on one kept thread, and the reviewer.
    let codex: any ModelRunner
    static let jevModel = "jev-latest"
    let memory: DataStore
    let activity: ActivityLog
    private let settings: AppSettings
    private let capture: () -> PredictionContext
    /// Jev's state; Codex trouble shows only in `codexPath` and the ledger.
    private(set) var status: Status = .waiting
    private(set) var sessions: [SessionRecord] = []
    private(set) var calls: [CallRecord] = []
    private(set) var strategies = ""
    private(set) var lastReview: Date?
    /// The reviewer is running.
    private(set) var isBusy = false
    /// Nil leaves Luna and the reviewer out, never Jev.
    private(set) var codexPath: String?
    /// Luna's kept Codex thread.
    private(set) var thread: DriverThread?
    /// The first open Jev drove, read from the whole predictions file.
    private(set) var jevSince: Date?
    @ObservationIgnored private var events: [EventRecord] = []
    @ObservationIgnored private var cache: [String: ModelPick] = [:]
    @ObservationIgnored private var shadowCache: [String: ModelPick] = [:]
    @ObservationIgnored private var driverBusy = false
    /// Jev's key was found; until then an open never waits.
    @ObservationIgnored private var driverReady = false
    /// After a failed Jev call, opens stop asking until this time.
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var shadowBusy = false
    @ObservationIgnored private var nextShadow = Date.distantPast
    @ObservationIgnored private var open: SessionRecord?
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var lastAges: [Int?] = []
    @ObservationIgnored private var nextCall = Date.distantPast
    @ObservationIgnored private var nextReview = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    init(settings: AppSettings, memory: DataStore, driver: any ModelRunner, codex: any ModelRunner,
         probe: @escaping @Sendable (pid_t, String?) -> ActivityEvent? = ActivityProbe.read, capture: @escaping () -> PredictionContext) {
        self.settings = settings
        self.memory = memory
        activity = ActivityLog(memory: memory, probe: probe)
        self.driver = driver
        self.codex = codex
        self.capture = capture
    }

    func start() async {
        let all = await memory.lines(SessionRecord.self, in: "predictions.jsonl")
        sessions = Array(all.suffix(500))
        jevSince = all.first { $0.driver == Self.jevModel }?.t
        calls = Array(await memory.lines(CallRecord.self, in: "calls.jsonl").suffix(300))
        events = Array(await memory.lines(EventRecord.self, in: "events.jsonl").suffix(200))
        thread = await memory.lines(DriverThread.self, in: "driver.jsonl").last
        let saved = await memory.text("strategies.md")
        strategies = saved?.text ?? ""
        lastReview = saved?.modified
        await activity.load()
        driverReady = await driver.codexPath() != nil
        if !driverReady { status = .missingKey }
        codexPath = await codex.codexPath()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A key must hold for one tick before Jev is asked, and activity must have held still 10 s.
    private func tick() {
        activity.pruneIfDue(now: .now)
        guard settings.prediction.enabled else { return }
        Task { await activity.sample() }
        let context = self.context()
        // A younger item means a new one arrived, even when the key stays the same; log it so Luna hears of it.
        let ages = [context.clipboardAge, context.screenshotAge, context.dictationAge]
        let newItem = zip(ages, lastAges).contains { ($0 ?? .max) < ($1 ?? .max) }
        lastAges = ages
        if context.key != lastKey || newItem {
            let event = EventRecord(t: .now, context: context)
            events.append(event)
            if events.count > 200 { events.removeFirst(events.count - 200) }
            Task { await memory.appendLine(event, to: "events.jsonl") }
        }
        guard context.key == lastKey else {
            lastKey = context.key
            return
        }
        if wantsRefresh(context, at: .now) { Task { await refresh(context) } }
        reviewIfDue()
    }

    /// What both models are told about this moment. Reads memory only, never Accessibility, so an open can afford it.
    func context() -> PredictionContext {
        var context = capture()
        context.activity = activity.line(now: .now)
        context.focus = activity.focus(app: context.app, now: .now)
        return context
    }

    private func fresh(_ pick: ModelPick?) -> ModelPick? {
        guard let pick, settings.prediction.useModel, Date.now.timeIntervalSince(pick.madeAt) < 30 * 60 else { return nil }
        return pick
    }

    /// A pick from before the app, title or address last changed is out of date, though an open may still land on it.
    private func needsPick(_ pick: ModelPick?) -> Bool {
        guard let pick = fresh(pick) else { return true }
        return pick.madeAt < activity.changedAt ?? .distantPast
    }

    func wantsRefresh(_ context: PredictionContext, at now: Date) -> Bool {
        now.timeIntervalSince(activity.changedAt ?? .distantPast) >= 10 && needsPick(cache[context.key])
    }

    /// An open may wait for Jev when it has no current pick and a call is allowed now, cap included.
    func wantsCallBeforeOpen(_ context: PredictionContext) -> Bool {
        let config = settings.prediction
        return config.useModel && driverReady && !driverBusy && Date.now >= retryAt && callsToday < config.dailyCallCap
            && needsPick(cache[context.key])
    }

    /// Asks Jev before an open lands, waiting at most `budget`; a later reply fills the cache, never this open.
    func callBeforeOpen(_ context: PredictionContext, budget: Duration) async {
        let wait = Task { try? await Task.sleep(for: budget) }
        Task { await refresh(context, onOpen: true); wait.cancel() }
        await wait.value
    }

    // MARK: Opening and outcome

    /// What a plain open should land on: Jev's fresh intent for this context, else the heuristic's.
    /// `opened` says where the UI put it, for the log.
    func intentForOpen(_ context: PredictionContext? = nil, opened: (LandingIntent) -> String) -> LandingIntent? {
        let started = ContinuousClock.now
        let context = context ?? self.context()
        let model = fresh(cache[context.key]).flatMap { context.kinds.contains($0.intent.kind) ? $0 : nil }
        guard let landed = model?.intent ?? context.heuristic else { return nil }
        let source = model == nil ? "heuristic" : "model"
        let place = opened(landed)
        open = SessionRecord(t: .now, context: context, heuristic: context.heuristic, model: model, landed: landed, source: source,
                             driver: Self.jevModel, opened: place,
                             shadow: fresh(shadowCache[context.key]).flatMap { context.kinds.contains($0.intent.kind) ? $0 : nil })
        Trace.log("predict open=\(place) intent=\(PredictionPrompts.describe(landed)) source=\(source) took=\(ContinuousClock.now - started)")
        return landed
    }

    /// The first thing the owner uses decides what they really wanted.
    func noteAction(_ action: String, outcome: Outcome, in place: String) {
        guard let started = open?.t, open?.outcome == nil else { return }
        open?.outcome = outcome
        open?.actedIn = place
        open?.action = action
        open?.secs = (Date.now.timeIntervalSince(started) * 10).rounded() / 10
    }

    func sessionEnded() {
        guard var record = open else { return }
        open = nil
        record.hit = record.outcome.map(record.landed.matches)
        record.shadowHit = record.outcome.flatMap { outcome in record.shadow.map { $0.intent.matches(outcome) } }
        sessions.append(record)
        if sessions.count > 500 { sessions.removeFirst(sessions.count - 500) }
        if jevSince == nil, record.driver == Self.jevModel { jevSince = record.t }
        Task { await memory.appendLine(record, to: "predictions.jsonl") }
        Trace.log("predict session landed=\(PredictionPrompts.describe(record.landed)) used=\(record.outcome.map { "\($0.kind.rawValue) newest=\($0.newest.map { "\($0)" } ?? "-")" } ?? "-") hit=\(record.hit.map { "\($0)" } ?? "-")")
        if record.hit == false { reviewIfDue() }
    }

    // MARK: Model calls

    /// Asks Jev about `context` and caches its pick; Luna is asked about the same moment, never more often.
    /// An open skips the 20 s pause after a success, not the cap or the pause after a failure. Returns Luna's call.
    @discardableResult
    func refresh(_ context: PredictionContext, onOpen: Bool = false) async -> Task<Void, Never>? {
        guard await mayAskDriver(after: onOpen ? retryAt : nextCall) else { return nil }
        defer { driverBusy = false }
        let shadow = Task { await shadowRefresh(context) }
        let prompt = PredictionPrompts.jev(context: context, strategies: strategies, recent: Array(sessions.filter { $0.hit != nil }.suffix(15)),
                                           model: Self.jevModel)
        let reply = await call(ModelCall(purpose: "driver", model: Self.jevModel, effort: "-", prompt: prompt, schema: "",
                                         timeout: .seconds(10)), on: driver, activity: context.activity) { DriverReply.parse($0, kinds: context.kinds) }
        nextCall = .now + (reply != nil ? 20 : 300)
        retryAt = reply != nil ? .distantPast : nextCall
        if let reply { remember(pick(reply, context, model: Self.jevModel), in: &cache) }
        return shadow
    }

    /// Luna's pick for the same moment, scored but never landed on. Outside the daily cap.
    /// A kept thread gets only what changed since its last turn; a new one gets the whole instruction.
    private func shadowRefresh(_ context: PredictionContext) async {
        guard settings.prediction.useModel, !shadowBusy, Date.now >= nextShadow else { return }
        shadowBusy = true
        defer { shadowBusy = false }
        codexPath = await codex.codexPath()
        guard codexPath != nil else { return }
        let config = settings.prediction
        let resume = DriverThread.resumable(thread, model: config.lunaModel, maxTurns: config.threadTurns, maxTokens: config.threadTokens)
        let prompt = resume.map {
            PredictionPrompts.delta(context: context, since: $0.lastCall, sessions: sessions, events: events, strategies: strategies,
                                    written: lastReview)
        } ?? PredictionPrompts.luna(context: context, strategies: strategies, recent: Array(sessions.filter { $0.hit != nil }.suffix(15)))
        let reply = await call(ModelCall(purpose: "shadow", model: config.lunaModel, effort: config.lunaEffort, prompt: prompt,
                                         schema: PredictionPrompts.lunaSchema(context.kinds), timeout: .seconds(30),
                                         keepThread: true, thread: resume?.id), on: codex, activity: context.activity) {
            DriverReply.parse($0, kinds: context.kinds)
        }
        // A lost thread is not an outage: start a new one on the next call.
        let lost = resume != nil && thread == nil
        guard let reply else { if !lost { nextShadow = .now + 300 }; return }
        remember(pick(reply, context, model: config.lunaModel), in: &shadowCache)
        // An open that came before Luna's answer for its moment still gets it.
        if open?.context.key == context.key, open?.shadow == nil { open?.shadow = shadowCache[context.key] }
    }

    private func pick(_ reply: DriverReply, _ context: PredictionContext, model: String) -> ModelPick {
        let app = reply.kind == .app && reply.app?.isEmpty == false ? reply.app : nil
        return ModelPick(intent: LandingIntent(kind: reply.kind, hint: reply.hint, confidence: min(max(reply.confidence, 0), 1), app: app),
                         note: String(reply.note.prefix(300)), key: context.key, madeAt: .now, model: model)
    }

    private func remember(_ pick: ModelPick, in cache: inout [String: ModelPick]) {
        cache[pick.key] = pick
        if cache.count > 20, let oldest = cache.min(by: { $0.value.madeAt < $1.value.madeAt })?.key { cache[oldest] = nil }
    }

    var unreviewedMisses: [SessionRecord] { sessions.filter { $0.hit == false && $0.t > (lastReview ?? .distantPast) } }

    private func reviewIfDue() {
        let config = settings.prediction
        guard ReviewTrigger.isDue(misses: unreviewedMisses.count, since: lastReview ?? sessions.first?.t, now: .now,
                                  threshold: config.missThreshold, hours: config.reviewHours) else { return }
        Task { await review() }
    }

    /// Asks the reviewer to rewrite the strategies both models read.
    func review() async {
        let config = settings.prediction
        guard config.useModel, !isBusy, Date.now >= nextReview, callsToday < config.dailyCallCap else { return }
        codexPath = await codex.codexPath()
        guard codexPath != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let jev = rates.jev
        let prompt = PredictionPrompts.reviewer(strategies: strategies, misses: Array(unreviewedMisses.suffix(40)),
                                                hits: Array(sessions.filter { $0.hit == true }.suffix(20)),
                                                rates: "since Jev started driving: Jev \(jev.model.text); rules \(jev.rules.text); Luna in the shadow \(jev.shadow.text)")
        let reply = await call(ModelCall(purpose: "reviewer", model: config.reviewerModel, effort: config.reviewerEffort,
                                         prompt: prompt, schema: PredictionPrompts.reviewerSchema, timeout: .seconds(120)),
                               on: codex, parse: ReviewerReply.parse)
        guard let reply else { nextReview = .now + 1800; return }
        strategies = reply.strategies
        lastReview = .now
        await memory.writeText(reply.strategies + "\n", to: "strategies.md")
    }

    /// One Jev call at a time, behind the kill switch, the daily cap and its key. Claims the slot when true.
    private func mayAskDriver(after time: Date) async -> Bool {
        guard settings.prediction.useModel else { status = .off; return false }
        guard !driverBusy, Date.now >= time else { return false }
        guard callsToday < settings.prediction.dailyCallCap else { status = .capReached; return false }
        driverReady = await driver.codexPath() != nil
        guard driverReady else { status = .missingKey; return false }
        guard !driverBusy else { return false }
        driverBusy = true
        return true
    }

    /// Every call lands in the ledger, whatever happens, so the owner can read what was sent and received.
    private func call<T>(_ call: ModelCall, on runner: any ModelRunner, activity: String? = nil, parse: (String) -> T?) async -> T? {
        let started = Date.now
        var record = CallRecord(t: started, purpose: call.purpose, model: call.model, effort: call.effort, prompt: call.prompt, activity: activity)
        var result: T?
        do {
            let reply = try await runner.run(call)
            record.reply = reply.text
            record.tokens = reply.tokens - (call.thread == nil ? TokenUsage() : thread?.total ?? TokenUsage())
            if call.keepThread, let id = reply.thread {
                let next = DriverThread(id: id, model: call.model, turns: (call.thread == nil ? 0 : thread?.turns ?? 0) + 1,
                                        size: record.tokens?.input ?? 0, total: reply.tokens, lastCall: started)
                thread = next
                record.thread = id
                record.turn = next.turns
                await memory.appendLine(next, to: "driver.jsonl")
            }
            result = parse(reply.text)
            if result == nil { record.status = "unusable"; record.error = "Reply did not match the schema" }
        } catch {
            record.status = "failed"
            record.error = error.localizedDescription
            if (error as? ModelError)?.threadGone == true {
                thread = nil
                await memory.remove(["driver.jsonl"])
            }
        }
        record.ms = Int(Date.now.timeIntervalSince(started) * 1000)
        calls.append(record)
        if calls.count > 300 { calls.removeFirst(calls.count - 300) }
        await memory.appendLine(record, to: "calls.jsonl")
        if call.purpose == "driver" { status = record.error.map { .failed($0) } ?? .ready }
        Trace.log("predict call \(call.purpose) \(record.status) \(record.ms)ms input=\(record.tokens?.input ?? 0) cached=\(record.tokens?.cached ?? 0) thread=\(record.thread ?? "-") turn=\(record.turn ?? 0)")
        return result
    }

    // MARK: What Settings and automation show

    /// Shadow calls stay outside the cap.
    var callsToday: Int { calls.filter { Calendar.current.isDateInToday($0.t) && $0.purpose != "shadow" }.count }

    /// Jev's opens apart from the ones Luna drove before the swap, so old results never count as Jev's.
    var rates: (jev: Rates, luna: Rates) {
        var jev = Rates(), luna = Rates()
        for s in sessions {
            guard let outcome = s.outcome else { continue }
            if s.driver == Self.jevModel { jev.add(s, outcome) } else { luna.add(s, outcome) }
        }
        return (jev, luna)
    }

    func resetMemory() async {
        cache = [:]
        shadowCache = [:]
        sessions = []
        jevSince = nil
        strategies = ""
        lastReview = nil
        open = nil
        events = []
        thread = nil
        await activity.reset()
        await memory.remove(["events.jsonl", "predictions.jsonl", "strategies.md", "driver.jsonl"])
    }

    func dump() -> [String: Any] {
        let last = sessions.last.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return ["status": String(describing: status), "busy": isBusy, "cached": cache.count, "key": context().key,
                "sessions": sessions.count, "unreviewedMisses": unreviewedMisses.count, "callsToday": callsToday,
                "strategyLines": strategies.split(separator: "\n").count, "lastReview": lastReview?.ISO8601Format() ?? "",
                "thread": thread?.id ?? "", "threadTurns": thread?.turns ?? 0, "threadSize": thread?.size ?? 0,
                "codex": codexPath ?? "", "shadowCached": shadowCache.count, "jevSince": jevSince?.ISO8601Format() ?? "",
                "last": last ?? [:]]
    }
}

nonisolated enum ReviewTrigger {
    /// Due after `threshold` misses, or after `hours` with at least one miss waiting, whichever comes first.
    static func isDue(misses: Int, since: Date?, now: Date, threshold: Int, hours: Int) -> Bool {
        guard misses > 0 else { return false }
        guard misses < threshold else { return true }
        return since.map { now.timeIntervalSince($0) >= Double(hours) * 3600 } ?? false
    }
}

/// Luna's Codex thread, kept from when Luna drove. The last line of `driver.jsonl`, so a relaunch resumes it.
nonisolated struct DriverThread: Codable, Equatable, Sendable {
    var id: String
    var model: String
    var turns = 1
    /// Input tokens of the last turn: about what the thread holds now.
    var size = 0
    /// Codex's running total, so the next turn's own usage is the difference.
    var total = TokenUsage()
    var lastCall: Date

    /// A long thread costs more per turn than a new one saves, so past either limit Luna starts over.
    static func resumable(_ thread: DriverThread?, model: String, maxTurns: Int, maxTokens: Int) -> DriverThread? {
        guard let thread, thread.model == model, thread.turns < maxTurns, thread.size < maxTokens else { return nil }
        return thread
    }
}

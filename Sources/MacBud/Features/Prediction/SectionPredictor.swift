import Foundation

/// Picks where a plain open lands and learns from where the owner ends up.
/// Opening only reads a cache; every model call runs in the background.
@Observable
final class SectionPredictor {
    enum Status: Equatable { case waiting, ready, off, missingCLI, capReached, failed(String) }

    struct Rate {
        var hits = 0, total = 0
        var text: String { total == 0 ? "no data yet" : "\(hits * 100 / total)% (\(hits) of \(total))" }
    }

    let runner: any ModelRunner
    let memory: DataStore
    private let settings: AppSettings
    private let capture: () -> PredictionContext
    private(set) var status: Status = .waiting
    private(set) var sessions: [SessionRecord] = []
    private(set) var calls: [CallRecord] = []
    private(set) var strategies = ""
    private(set) var lastReview: Date?
    private(set) var isBusy = false
    private(set) var codexPath: String?
    @ObservationIgnored private var cache: [String: ModelPick] = [:]
    @ObservationIgnored private var open: SessionRecord?
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var nextCall = Date.distantPast
    @ObservationIgnored private var nextReview = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    init(settings: AppSettings, memory: DataStore, runner: any ModelRunner, capture: @escaping () -> PredictionContext) {
        self.settings = settings
        self.memory = memory
        self.runner = runner
        self.capture = capture
    }

    func start() async {
        sessions = Array(await memory.lines(SessionRecord.self, in: "predictions.jsonl").suffix(500))
        calls = Array(await memory.lines(CallRecord.self, in: "calls.jsonl").suffix(300))
        let saved = await memory.text("strategies.md")
        strategies = saved?.text ?? ""
        lastReview = saved?.modified
        codexPath = await runner.codexPath()
        if codexPath == nil { status = .missingCLI }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A key must hold for one tick before the driver runs, which debounces bursts of changes.
    private func tick() {
        guard settings.prediction.enabled else { return }
        let context = capture()
        guard context.key == lastKey else {
            lastKey = context.key
            Task { await memory.appendLine(EventRecord(t: .now, context: context), to: "events.jsonl") }
            return
        }
        if fresh(cache[context.key]) == nil { Task { await refresh(context) } }
        reviewIfDue()
    }

    private func fresh(_ pick: ModelPick?) -> ModelPick? {
        guard let pick, settings.prediction.useModel, Date.now.timeIntervalSince(pick.madeAt) < 30 * 60 else { return nil }
        return pick
    }

    // MARK: Opening and outcome

    /// Where a plain open lands: a fresh model intent for this context, else the heuristic's, as today's tab.
    func sectionForOpen() -> Section? {
        let started = ContinuousClock.now
        let context = capture()
        let model = fresh(cache[context.key]).flatMap { context.kinds.contains($0.intent.kind) ? $0 : nil }
        guard let landed = model?.intent ?? context.heuristic else { return nil }
        let source = model == nil ? "heuristic" : "model"
        open = SessionRecord(t: .now, context: context, heuristic: context.heuristic, model: model, landed: landed, source: source,
                             opened: landed.kind.section)
        Trace.log("predict open=\(landed.kind.section.rawValue) intent=\(PredictionPrompts.describe(landed)) source=\(source) took=\(ContinuousClock.now - started)")
        return landed.kind.section
    }

    /// The first thing the owner uses decides what they really wanted.
    func noteAction(_ action: String, outcome: Outcome, in section: Section) {
        guard let started = open?.t, open?.outcome == nil else { return }
        open?.outcome = outcome
        open?.actedIn = section
        open?.action = action
        open?.secs = (Date.now.timeIntervalSince(started) * 10).rounded() / 10
    }

    func sessionEnded() {
        guard var record = open else { return }
        open = nil
        record.hit = record.outcome.map(record.landed.matches)
        sessions.append(record)
        if sessions.count > 500 { sessions.removeFirst(sessions.count - 500) }
        Task { await memory.appendLine(record, to: "predictions.jsonl") }
        Trace.log("predict session landed=\(PredictionPrompts.describe(record.landed)) used=\(record.outcome.map { "\($0.kind.rawValue) newest=\($0.newest.map { "\($0)" } ?? "-")" } ?? "-") hit=\(record.hit.map { "\($0)" } ?? "-")")
        if record.hit == false { reviewIfDue() }
    }

    // MARK: Model calls

    /// Asks the driver about `context` and caches its pick for that context key.
    func refresh(_ context: PredictionContext) async {
        guard await mayCall(after: nextCall) else { return }
        defer { isBusy = false }
        let config = settings.prediction
        let prompt = PredictionPrompts.driver(context: context, strategies: strategies,
                                              recent: Array(sessions.filter { $0.hit != nil }.suffix(15)))
        let reply = await call(ModelCall(purpose: "driver", model: config.driverModel, effort: config.driverEffort, prompt: prompt,
                                         schema: PredictionPrompts.driverSchema(context.kinds), timeout: .seconds(30))) {
            DriverReply.parse($0, kinds: context.kinds)
        }
        nextCall = .now + (reply == nil ? 300 : 20)
        guard let reply else { return }
        cache[context.key] = ModelPick(intent: LandingIntent(kind: reply.kind, hint: reply.hint, confidence: min(max(reply.confidence, 0), 1)),
                                       note: String(reply.note.prefix(300)), key: context.key, madeAt: .now)
        if cache.count > 20, let oldest = cache.min(by: { $0.value.madeAt < $1.value.madeAt })?.key { cache[oldest] = nil }
    }

    var unreviewedMisses: [SessionRecord] { sessions.filter { $0.hit == false && $0.t > (lastReview ?? .distantPast) } }

    private func reviewIfDue() {
        let config = settings.prediction
        guard ReviewTrigger.isDue(misses: unreviewedMisses.count, since: lastReview ?? sessions.first?.t, now: .now,
                                  threshold: config.missThreshold, hours: config.reviewHours) else { return }
        Task { await review() }
    }

    /// Asks the reviewer to rewrite the strategies the driver reads.
    func review() async {
        guard await mayCall(after: nextReview) else { return }
        defer { isBusy = false }
        let config = settings.prediction
        let prompt = PredictionPrompts.reviewer(strategies: strategies, misses: Array(unreviewedMisses.suffix(40)),
                                                hits: Array(sessions.filter { $0.hit == true }.suffix(20)),
                                                rates: "model \(rates.model.text); heuristic \(rates.heuristic.text)")
        let reply = await call(ModelCall(purpose: "reviewer", model: config.reviewerModel, effort: config.reviewerEffort,
                                         prompt: prompt, schema: PredictionPrompts.reviewerSchema, timeout: .seconds(120)),
                               parse: ReviewerReply.parse)
        guard let reply else { nextReview = .now + 1800; return }
        strategies = reply.strategies
        lastReview = .now
        await memory.writeText(reply.strategies + "\n", to: "strategies.md")
    }

    /// One call at a time, behind the kill switch, the daily cap and a found CLI. Claims the slot when true.
    private func mayCall(after time: Date) async -> Bool {
        guard settings.prediction.useModel else { status = .off; return false }
        guard !isBusy, Date.now >= time else { return false }
        guard callsToday < settings.prediction.dailyCallCap else { status = .capReached; return false }
        codexPath = await runner.codexPath()
        guard codexPath != nil else { status = .missingCLI; return false }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    /// Every call lands in the ledger, whatever happens, so the owner can read what was sent and received.
    private func call<T>(_ call: ModelCall, parse: (String) -> T?) async -> T? {
        let started = Date.now
        var record = CallRecord(t: started, purpose: call.purpose, model: call.model, effort: call.effort, prompt: call.prompt)
        var result: T?
        do {
            let reply = try await runner.run(call)
            record.reply = reply.text
            record.tokens = reply.tokens
            result = parse(reply.text)
            if result == nil { record.status = "unusable"; record.error = "Reply did not match the schema" }
        } catch {
            record.status = "failed"
            record.error = error.localizedDescription
        }
        record.ms = Int(Date.now.timeIntervalSince(started) * 1000)
        calls.append(record)
        if calls.count > 300 { calls.removeFirst(calls.count - 300) }
        await memory.appendLine(record, to: "calls.jsonl")
        status = record.error.map { .failed($0) } ?? .ready
        Trace.log("predict call \(call.purpose) \(record.status) \(record.ms)ms input=\(record.tokens?.input ?? 0)")
        return result
    }

    // MARK: What Settings and automation show

    var callsToday: Int { calls.filter { Calendar.current.isDateInToday($0.t) }.count }

    /// Last 7 days. `heuristicWhereModel` scores the heuristic on the same opens the model answered.
    var rates: (model: Rate, heuristic: Rate, heuristicWhereModel: Rate) {
        var model = Rate(), heuristic = Rate(), same = Rate()
        for s in sessions where s.t > .now - 7 * 86_400 {
            guard let outcome = s.outcome else { continue }
            let heuristicHit = s.heuristic?.matches(outcome) == true ? 1 : 0
            heuristic.total += 1; heuristic.hits += heuristicHit
            guard let pick = s.model?.intent else { continue }
            model.total += 1; model.hits += pick.matches(outcome) ? 1 : 0
            same.total += 1; same.hits += heuristicHit
        }
        return (model, heuristic, same)
    }

    func resetMemory() async {
        cache = [:]
        sessions = []
        strategies = ""
        lastReview = nil
        open = nil
        await memory.remove(["events.jsonl", "predictions.jsonl", "strategies.md"])
    }

    func dump() -> [String: Any] {
        let last = sessions.last.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return ["status": String(describing: status), "busy": isBusy, "cached": cache.count, "key": capture().key,
                "sessions": sessions.count, "unreviewedMisses": unreviewedMisses.count, "callsToday": callsToday,
                "strategyLines": strategies.split(separator: "\n").count, "lastReview": lastReview?.ISO8601Format() ?? "",
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

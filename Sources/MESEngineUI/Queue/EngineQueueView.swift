import DesignScaffold
import DesignScaffoldStatus
import MESCore
import MESEngineCore
import SwiftUI

/// The Queue section: what the engine is working on now, what's next in the order the slot will take it, and what
/// finished recently. Every client's jobs, which only the operator sees (a client sees its own, Base §5).
struct EngineQueueView: View {
    let console: EngineConsoleModel
    @State private var confirmCancel: JobActivity?

    private var activity: EngineActivity { console.activity }

    var body: some View {
        VStack(spacing: 0) {
            ConsoleSectionHeader(title: "Queue", subtitle: "What the engine is working on, and what's next") {
                HStack(spacing: Tokens.Space.l) {
                    Count(value: activity.running.count, label: "running", tint: Tokens.Color.working)
                    Count(value: activity.upcoming.count, label: "waiting", tint: Tokens.Color.accent)
                    Count(value: activity.finished.count, label: "recent", tint: Tokens.Color.secondaryLabel)
                }
            }
            Separator(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    now
                    upNext
                    recent
                }
                .padding(Tokens.Space.xl)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Cancel this job?", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
               presenting: confirmCancel) { job in
            Button("Cancel Job", role: .destructive) { console.cancel(job: job.id) }
            Button("Keep", role: .cancel) {}
        } message: { job in
            Text("\(console.operationTitle(job.operation)) from \(clientName(job)) ends as cancelled, and its client is told.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var now: some View {
        SectionHeader("Now")
        if activity.running.isEmpty {
            ConsolePanel {
                HStack(spacing: Tokens.Space.m) {
                    IconTile(symbol: "checkmark.circle", tint: Tokens.Color.ready)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle").font(Tokens.Font.headline)
                        Text(idleLine).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                }
            }
        } else {
            ForEach(activity.running) { job in
                RunningJobCard(console: console, job: job, client: clientName(job)) { confirmCancel = job }
            }
        }
    }

    private var idleLine: String {
        switch console.status {
        case .starting(let message): message
        case .failed(let message): message
        case .serving: console.endpoint.map { "Waiting for requests at \($0)" } ?? "Waiting for requests"
        }
    }

    @ViewBuilder private var upNext: some View {
        SectionHeader("Up next") {
            if !activity.upcoming.isEmpty { SectionHeaderTrailing("\(activity.upcoming.count) waiting") }
        }
        if activity.upcoming.isEmpty {
            Text("Nothing waiting.").font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
                .padding(.vertical, Tokens.Space.xs)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(activity.upcoming.enumerated()), id: \.element.id) { index, job in
                    if index > 0 { Separator(.horizontal) }
                    UpcomingRow(console: console, job: job, client: clientName(job)) { confirmCancel = job }
                }
            }
            .cardSurface()
        }
    }

    @ViewBuilder private var recent: some View {
        SectionHeader("Recent")
        if activity.finished.isEmpty {
            Text("No finished jobs yet.").font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
                .padding(.vertical, Tokens.Space.xs)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(activity.finished.enumerated()), id: \.element.id) { index, job in
                    if index > 0 { Separator(.horizontal) }
                    FinishedRow(console: console, job: job, client: clientName(job))
                }
            }
            .cardSurface()
        }
    }

    private func clientName(_ job: JobActivity) -> String {
        job.client == "local" ? "This Mac" : job.clientHost.map { "\(job.client) (\($0))" } ?? job.client
    }
}

private struct Count: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)").font(Tokens.Font.headline.monospacedDigit()).foregroundStyle(value > 0 ? tint : Tokens.Color.tertiaryLabel)
            Text(label).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
        }
    }
}

// MARK: - Rows

/// The job holding the slot: its operation and model, what it's doing, how far along, and for how long.
private struct RunningJobCard: View {
    let console: EngineConsoleModel
    let job: JobActivity
    let client: String
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                HStack(alignment: .top, spacing: Tokens.Space.m) {
                    IconTile(symbol: OperationSymbol.symbol(job.operation), tint: Tokens.Color.working, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(console.operationTitle(job.operation)).font(Tokens.Font.panelTitle)
                            Pill(text: job.quality.rawValue)
                        }
                        Text(job.model.title ?? job.model.id).font(Tokens.Font.body.weight(.medium))
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                        if let summary = job.summary {
                            Text("“\(summary)”").font(Tokens.Font.body).lineLimit(2).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    StatusPill(stageLabel, status: .working(elapsed: job.ran(now: context.date)))
                    Button("Cancel", systemImage: "xmark.circle", action: onCancel)
                        .help("Cancel this job")
                }
                progress
                HStack(spacing: Tokens.Space.l) {
                    Label(client, systemImage: "person.crop.circle")
                    Label("waited \(ConsoleFormat.duration(job.waited(now: context.date)))", systemImage: "hourglass")
                    Label("running \(ConsoleFormat.duration(job.ran(now: context.date) ?? 0))", systemImage: "timer")
                    if !job.warnings.isEmpty {
                        Label("\(job.warnings.count) warning\(job.warnings.count == 1 ? "" : "s")",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tokens.Color.working)
                            .help(job.warnings.map(\.message).joined(separator: "\n"))
                    }
                    Spacer()
                    Text(job.id).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.tertiaryLabel).textSelection(.enabled)
                }
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
            }
            .padding(Tokens.Space.l)
            .cardSurface()
        }
    }

    private var stageLabel: String {
        switch job.progress?.stage {
        case .preparing: "Loading model"
        case .finishing: "Finishing"
        case .fetching: "Fetching inputs"
        default: "Running"
        }
    }

    @ViewBuilder private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = job.progress?.fraction {
                ProgressView(value: min(max(fraction, 0), 1)).tint(Tokens.Color.working)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Tokens.Color.working)
            }
            HStack {
                Text(job.progress?.message ?? stageLabel)
                Spacer()
                if let step = job.progress?.step, let steps = job.progress?.steps {
                    Text("step \(step) of \(steps)").monospacedDigit()
                } else if let fraction = job.progress?.fraction {
                    Text(ConsoleFormat.percent(fraction)).monospacedDigit()
                }
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Color.secondaryLabel)
        }
    }
}

private struct UpcomingRow: View {
    let console: EngineConsoleModel
    let job: JobActivity
    let client: String
    let onCancel: () -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Tokens.Space.m) {
                Text(job.queuePosition.map { "\($0)" } ?? "·")
                    .font(Tokens.Font.headline.monospacedDigit())
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                    .frame(width: 24)
                Image(systemName: OperationSymbol.symbol(job.operation)).foregroundStyle(Tokens.Color.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(console.operationTitle(job.operation)).font(Tokens.Font.headline)
                        Text(job.model.title ?? job.model.id).foregroundStyle(Tokens.Color.secondaryLabel)
                        Pill(text: job.quality.rawValue)
                    }
                    if let summary = job.summary {
                        Text(summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state).font(Tokens.Font.caption.weight(.medium))
                    Text("\(client) · waiting \(ConsoleFormat.duration(job.waited(now: context.date)))")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                }
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Tokens.Color.tertiaryLabel)
                    .opacity(hovered ? 1 : 0.4)
                    .help("Cancel this job")
            }
            .font(Tokens.Font.body)
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.s + 2)
            .background(hovered ? Tokens.Color.fillElevated : Color.clear)
            .onHover { hovered = $0 }
        }
    }

    private var state: String {
        switch job.state {
        case .received: "Received"
        case .fetching: "Fetching inputs"
        default: "Waiting for the slot"
        }
    }
}

private struct FinishedRow: View {
    let console: EngineConsoleModel
    let job: JobActivity
    let client: String

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(console.operationTitle(job.operation)).font(Tokens.Font.headline)
                    Text(job.model.title ?? job.model.id).foregroundStyle(Tokens.Color.secondaryLabel)
                }
                if let error = job.error {
                    Text(error).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure).lineLimit(2).textSelection(.enabled)
                } else if let summary = job.summary {
                    Text(summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timing).font(Tokens.Font.caption.monospacedDigit())
                Text("\(client) · \((job.finishedAt ?? job.createdAt).formatted(date: .omitted, time: .shortened))")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .font(Tokens.Font.body)
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.s + 2)
    }

    private var timing: String {
        guard let ran = job.ran(now: job.finishedAt ?? Date()) else { return outcome }
        return "\(outcome) · ran \(ConsoleFormat.duration(ran))"
    }

    private var outcome: String {
        switch job.outcome {
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        case nil: ""
        }
    }

    private var symbol: String {
        switch job.outcome {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        default: "clock.badge.xmark"
        }
    }

    private var tint: Color {
        switch job.outcome {
        case .succeeded: Tokens.Color.ready
        case .failed: Tokens.Color.failure
        default: Tokens.Color.secondaryLabel
        }
    }
}

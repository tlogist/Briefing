import SwiftUI

// The "Tidy Up" section of the popover: Claude proposes maintenance actions
// over the full task state; the user approves or skips each; approved actions
// are written through ThingsService's verified URL-scheme channel one by one.
// The human stays in the approval seat — nothing is written without a tap.
struct MaintenanceSection: View {
    let thingsService: ThingsService
    let settings: AppSettings
    let tagNames: [String]
    /// Called after any actions were applied so the popover can reload
    /// tasks and invalidate stale briefings.
    let onApplied: () -> Void
    let onDismiss: () -> Void

    private enum Phase {
        case generating
        case review
        case applying(current: Int, total: Int)
        case done(applied: Int, failures: [String])
        case error(String)
    }

    @State private var phase: Phase = .generating
    @State private var proposals: [ProposedAction] = []

    private var approvedCount: Int {
        proposals.filter { $0.approved }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Tidy Up", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Close without applying")
            }

            switch phase {
            case .generating:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                    Text("Claude is reviewing your tasks…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

            case .review:
                if proposals.isEmpty {
                    Text("Nothing needs attention — your system looks healthy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach($proposals) { $proposal in
                        ProposedActionRow(proposal: $proposal)
                    }

                    HStack {
                        Button(action: applyApproved) {
                            Text("Apply \(approvedCount) action\(approvedCount == 1 ? "" : "s")")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(approvedCount == 0)

                        Spacer()

                        Text("\(proposals.count) proposed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .applying(let current, let total):
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                    Text("Applying \(current) of \(total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

            case .done(let applied, let failures):
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "\(applied) action\(applied == 1 ? "" : "s") applied and verified",
                        systemImage: "checkmark.seal"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    ForEach(failures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Button("Done") { onDismiss() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") { generate() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .background(Color.teal.opacity(0.06))
        .cornerRadius(8)
        .task { generate() }
    }

    // MARK: - Actions

    private func generate() {
        phase = .generating
        let things = thingsService
        let model = settings.claudeModel
        let tags = tagNames
        Task {
            do {
                // Full task state (all lists), live only — proposals against
                // cached tasks would write against a stale picture
                let tasks = try await things.fetchAllTasks()
                let service = MaintenanceService(thingsService: things)
                let actions = try await service.proposeActions(
                    tasks: tasks, tagNames: tags, model: model
                )
                await MainActor.run {
                    proposals = actions
                    phase = .review
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    private func applyApproved() {
        let approved = proposals.filter { $0.approved }
        guard !approved.isEmpty else { return }
        let things = thingsService
        Task {
            let service = MaintenanceService(thingsService: things)
            var applied = 0
            var failures: [String] = []

            for (index, action) in approved.enumerated() {
                await MainActor.run {
                    phase = .applying(current: index + 1, total: approved.count)
                }
                do {
                    // Each write is verified by read-back inside ThingsService —
                    // a non-throwing return means Things confirmed the change
                    try await service.apply(action)
                    applied += 1
                } catch {
                    failures.append("\(action.taskName): \(error.localizedDescription)")
                }
            }

            let appliedCount = applied
            let failureList = failures
            await MainActor.run {
                phase = .done(applied: appliedCount, failures: failureList)
                if appliedCount > 0 { onApplied() }
            }
        }
    }
}

// MARK: - Row

private struct ProposedActionRow: View {
    @Binding var proposal: ProposedAction

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { proposal.approved.toggle() }) {
                Image(systemName: proposal.approved ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(proposal.approved ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(proposal.approved ? "Approved — click to skip" : "Skipped — click to approve")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Label(proposal.kind.label, systemImage: proposal.kind.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                    Text(proposal.taskName)
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(proposal.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .opacity(proposal.approved ? 1.0 : 0.5)
        .padding(.vertical, 1)
    }
}

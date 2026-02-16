import SwiftUI

// Shows the diff between Things 3 and todo.md, letting the user
// approve or reject each proposed change before applying.
struct SyncDiffView: View {
    @State var diffs: [TaskDiff]
    let onApply: ([TaskDiff]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Review")
                        .font(.headline)
                    Text("\(diffs.count) changes found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All") { setAll(true) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Deselect All") { setAll(false) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(12)

            Divider()

            // Diff list
            if diffs.isEmpty {
                VStack {
                    Spacer()
                    Text("Everything is in sync!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Group by action type
                        let grouped = Dictionary(grouping: diffs.indices, by: { diffs[$0].action })

                        if let addToFileIndices = grouped[.addToFile], !addToFileIndices.isEmpty {
                            diffSection(title: "New in Things 3 → Add to todo.md",
                                       icon: "plus.circle.fill",
                                       color: .green,
                                       indices: addToFileIndices)
                        }

                        if let addToThingsIndices = grouped[.addToThings], !addToThingsIndices.isEmpty {
                            diffSection(title: "In todo.md → Add to Things 3",
                                       icon: "plus.circle",
                                       color: .blue,
                                       indices: addToThingsIndices)
                        }

                        if let completedIndices = grouped[.markCompleted], !completedIndices.isEmpty {
                            diffSection(title: "Completion Mismatches",
                                       icon: "checkmark.circle.fill",
                                       color: .orange,
                                       indices: completedIndices)
                        }

                        if let staleIndices = grouped[.flagStale], !staleIndices.isEmpty {
                            diffSection(title: "Stale Tasks",
                                       icon: "exclamationmark.triangle.fill",
                                       color: .red,
                                       indices: staleIndices)
                        }

                        if let updateIndices = grouped[.updateInfo], !updateIndices.isEmpty {
                            diffSection(title: "Info Updates",
                                       icon: "arrow.triangle.2.circlepath",
                                       color: .purple,
                                       indices: updateIndices)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            // Footer with action buttons
            HStack {
                let approvedCount = diffs.filter(\.isApproved).count
                Text("\(approvedCount) of \(diffs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button("Apply \(approvedCount) Changes") {
                    onApply(diffs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(approvedCount == 0)
            }
            .padding(12)
        }
        .frame(width: 420, height: 480)
    }

    // MARK: - Subviews

    private func diffSection(title: String, icon: String, color: Color, indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)

            ForEach(indices, id: \.self) { idx in
                DiffRow(diff: $diffs[idx])
            }
        }
        .padding(.bottom, 4)
    }

    private func setAll(_ approved: Bool) {
        for i in diffs.indices {
            diffs[i].isApproved = approved
        }
    }
}

// Individual diff row with toggle
struct DiffRow: View {
    @Binding var diff: TaskDiff

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: $diff.isApproved) {
                EmptyView()
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(diff.taskName)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(diff.isApproved ? .primary : .secondary)

                Text(diff.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.leading, 4)
    }
}

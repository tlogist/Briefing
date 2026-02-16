import SwiftUI

// Renders a BriefingResult's markdown content in a scrollable view.
// Used in both the popover (compact) and the full window.
struct BriefingContentView: View {
    let briefing: BriefingResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Generation metadata
                HStack {
                    Label(
                        "Generated \(DateFormatting.time.string(from: briefing.generatedAt))",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Text(briefing.model.replacingOccurrences(of: "claude-", with: ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // Render the markdown as attributed text
                // On macOS 14+, SwiftUI's Text supports basic Markdown natively
                Text(LocalizedStringKey(briefing.markdownContent))
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
    }
}

// A view showing the briefing generation status with appropriate UI.
struct BriefingStatusView: View {
    let status: BriefingStatus
    let onGenerate: () -> Void

    var body: some View {
        switch status {
        case .idle:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No briefing generated yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Generate Briefing", action: onGenerate)
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity)

        case .gatheringData:
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Gathering calendar and task data...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)

        case .callingClaude:
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Claude is analyzing your day...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This usually takes 10-15 seconds")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)

        case .complete(let result):
            BriefingContentView(briefing: result)

        case .error(let message):
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Try Again", action: onGenerate)
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

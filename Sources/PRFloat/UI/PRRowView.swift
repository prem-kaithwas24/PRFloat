import SwiftUI
import PRFloatCore

struct PRRowView: View {
    let pr: PRSummary
    let agents: [AgentSession]
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                StatusDot(color: healthColor)

                Text("#\(pr.number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Text(pr.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if pr.isDraft {
                    Pill(text: "Draft")
                }

                Spacer(minLength: Theme.Space.xs)

                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open on GitHub")
            }

            if pr.checklistTotal > 0 {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ProgressView(value: pr.checklistFraction)
                        .progressViewStyle(.linear)
                        .tint(healthColor)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                    Text(pr.checklistLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Theme.Space.sm) {
                Text(pr.checks.label)
                    .font(.caption2)
                    .foregroundStyle(checksColor)

                if !agents.isEmpty {
                    AgentBadge(agents: agents)
                }

                Spacer(minLength: Theme.Space.xs)

                Text(pr.headRefName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(Theme.Space.sm + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.rowBackground))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PR \(pr.number), \(pr.title), \(pr.checklistLabel), \(pr.checks.label)")
    }

    private var healthColor: Color {
        Theme.color(for: pr.health)
    }

    private var checksColor: Color {
        if pr.checks.failing > 0 { return .red }
        if pr.checks.pending > 0 { return .orange }
        if pr.checks.passing > 0 { return .green }
        return .secondary
    }
}

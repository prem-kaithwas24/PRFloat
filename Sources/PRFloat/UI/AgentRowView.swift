import SwiftUI
import PRFloatCore

struct AgentRowView: View {
    let agent: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            StatusDot(color: color, pulsing: agent.status == .working)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.sm) {
                    Text(agent.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                    Text(agent.statusDetail())
                        .font(.caption2)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Text(agent.locationLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let task = agent.task, !task.isEmpty {
                    Text(task)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(task)
                }
            }
        }
        .padding(Theme.Space.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .fill(agent.justFinished ? Color.green.opacity(0.10) : Theme.rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .strokeBorder(agent.status == .blocked ? Color.orange.opacity(0.45) : .clear, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(agent.statusDetail()), \(agent.locationLabel)")
    }

    private var color: Color {
        Theme.color(for: agent.status)
    }
}

/// Compact agent marker shown on a PR row that an agent is working on.
struct AgentBadge: View {
    let agents: [AgentSession]

    var body: some View {
        if let first = agents.first {
            HStack(spacing: Theme.Space.xs) {
                StatusDot(color: Theme.color(for: first.status), pulsing: first.status == .working, size: 6)
                Text(label(for: first))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.color(for: first.status))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill)
                    .fill(Theme.color(for: first.status).opacity(0.13))
            )
            .help(agents.map { "\($0.name) — \($0.statusDetail())" }.joined(separator: "\n"))
        }
    }

    private func label(for agent: AgentSession) -> String {
        agents.count > 1 ? "\(agent.name) +\(agents.count - 1)" : agent.name
    }
}

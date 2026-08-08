import SwiftUI
import PRFloatCore

/// Design tokens. Everything visual reads from here so spacing and colour stay consistent
/// and the app renders correctly in both light and dark appearance.
enum Theme {
    /// 4pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let row: CGFloat = 8
        static let pill: CGFloat = 4
    }

    static let rowBackground = Color.primary.opacity(0.04)
    static let rowBorder = Color.primary.opacity(0.07)

    static func color(for health: HealthColor) -> Color {
        switch health {
        case .green: return .green
        case .yellow: return .orange
        case .red: return .red
        }
    }

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .working: return .blue
        case .done: return .green
        case .blocked: return .orange
        case .unknown: return .secondary
        }
    }
}

/// Section heading: small, uppercase, with a count.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.xs)
    }
}

/// Coloured status dot; the working state pulses so movement is visible at a glance.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if pulsing {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 1.5)
                        .scaleEffect(animating ? 2.1 : 1)
                        .opacity(animating ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                            value: animating
                        )
                }
            }
            .onAppear { if pulsing { animating = true } }
            .accessibilityHidden(true)
    }
}

/// Small capsule label, e.g. "Draft".
struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill)
                    .fill(color.opacity(0.14))
            )
    }
}

/// Placeholder rows shown while the first fetch is in flight.
struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.rowBorder)
                .frame(height: 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.rowBorder)
                .frame(width: 120, height: 8)
        }
        .padding(Theme.Space.sm + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.rowBackground))
        .redacted(reason: .placeholder)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.lg)
    }
}

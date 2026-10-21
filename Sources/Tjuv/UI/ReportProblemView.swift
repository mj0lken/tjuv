import AppKit
import SwiftUI

enum TjuvProblemKind: String, CaseIterable {
    case falseAlarm = "Triggered too easily"
    case didNotTrigger = "Didn't trigger"
    case sirenAudio = "Siren / speaker routing"
    case lidClosed = "Lid-closed protection"
    case touchIDLock = "Touch ID / screen lock"
    case other = "Something else"

    var symbol: String {
        switch self {
        case .falseAlarm: return "waveform.path.ecg"
        case .didNotTrigger: return "gyroscope"
        case .sirenAudio: return "speaker.wave.3.fill"
        case .lidClosed: return "laptopcomputer"
        case .touchIDLock: return "touchid"
        case .other: return "ellipsis.bubble"
        }
    }

    var prompt: String {
        switch self {
        case .falseAlarm: return "What caused the false trigger, and which sensitivity setting were you using?"
        case .didNotTrigger: return "Which trigger didn't fire (motion, charger unplugged, lid opened)?"
        case .sirenAudio: return "Which headphones or speakers were connected when the siren played?"
        case .lidClosed: return "Did the MacBook still go to sleep when you closed the lid while armed?"
        case .touchIDLock: return "What happened when locking the screen or disarming with Touch ID?"
        case .other: return "What did you expect to happen, and what happened instead?"
        }
    }
}

/// Interactive bug report window with problem chips, optional note, and redacted diagnostics preview (matching `thumbs-out`).
struct ReportProblemView: View {
    let close: () -> Void

    @State private var kind: TjuvProblemKind?
    @State private var summary = ""
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                kindPicker
                summaryField
                includedPreview
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 16)

            Divider()
            bottomBar
        }
        .frame(width: 600, height: 720)
        .background(.background)
        .tint(Theme.working)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Theme.grace.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Report a Bug").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Pick what went wrong and add a line if you like. Tjuv fills in the rest and opens a ready-to-submit GitHub issue.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What went wrong?").font(.tileTitle)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(TjuvProblemKind.allCases, id: \.self) { option in
                    ProblemChip(kind: option, isSelected: kind == option) {
                        withAnimation(.snappy(duration: 0.18)) { kind = (kind == option) ? nil : option }
                    }
                }
            }
        }
    }

    private var summaryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Anything else?").font(.tileTitle)
                Text("Optional").font(.caption).foregroundStyle(.tertiary)
            }
            TextEditor(text: $summary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(height: 76)
                .overlay(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text((kind ?? .other).prompt)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.tileStroke, lineWidth: 0.5)
                )
        }
    }

    private var includedPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Added to the issue").font(.tileTitle)
            ScrollView {
                Text(composedMarkdown)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.tilePadding)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .strokeBorder(Theme.tileStroke, lineWidth: 0.5)
            )

            Label {
                Text("Only Tjuv's own version, hardware checks and settings. Your home folder shows as ~ and your user name as <user>. Nothing leaves this Mac until you submit the issue on GitHub.")
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(Theme.workingInk)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Copy Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(composedMarkdown, forType: .string)
                notice = "Copied to clipboard."
            }
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button("Open GitHub Issue…") {
                let title = kind?.rawValue ?? "Bug report"
                let url = GitHubIssueLink.url(title: title, body: composedMarkdown)
                NSWorkspace.shared.open(url)
                notice = "Opened in your browser."
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Theme.workingInk)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var composedMarkdown: String {
        let base = GitHubIssueLink.buildDiagnosticBody()
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || kind != nil else { return base }
        var headerLines: [String] = []
        if let kind {
            headerLines.append("**Category:** \(kind.rawValue)")
        }
        if !trimmed.isEmpty {
            headerLines.append(trimmed)
        }
        return base.replacingOccurrences(
            of: "<!-- What did you see, and what did you expect? Steps to reproduce help. -->",
            with: headerLines.joined(separator: "\n\n")
        )
    }
}

private struct ProblemChip: View {
    let kind: TjuvProblemKind
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .secondary)
                    .frame(width: 18)
                Text(kind.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Self.shape.fill(fill))
            .overlay(Self.shape.strokeBorder(isSelected ? accent : Theme.tileStroke, lineWidth: isSelected ? 1.5 : 0.5))
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var accent: Color { colorScheme == .dark ? Theme.working : Theme.workingInk }

    private var fill: Color {
        if isSelected { return Theme.working.opacity(colorScheme == .dark ? 0.2 : 0.14) }
        return Color.primary.opacity(isHovering ? 0.09 : 0.055)
    }
}

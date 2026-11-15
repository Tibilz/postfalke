import SwiftUI
import MailEngine

/// An error the user can read, select and copy (e.g. to search for it or report it).
struct ErrorNotice: View {
    let message: String
    var hint: String?
    var helpURL: URL?
    var helpTitle = "Anleitung öffnen"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                Button {
                    UIPasteboard.general.string = message
                    copied = true
                } label: {
                    Label(copied ? "Kopiert" : "Fehler kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if let helpURL {
                    Link(destination: helpURL) {
                        Label(helpTitle, systemImage: "arrow.up.right.square")
                    }
                }
            }
            .font(.footnote.weight(.medium))
            // Several buttons in one list row must not all fire on a tap.
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = message }
        }
        .onChange(of: message) { copied = false }
    }
}

/// Circle with the sender's initials, like Contacts and Mail.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let base = name.contains("@") ? String(name.split(separator: "@").first ?? "") : name
        let words = base.split { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }
            .filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.68), Color(white: 0.53)],
                                         startPoint: .top, endPoint: .bottom))
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.48))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Gerade aktualisiert" / "Aktualisiert um 14:05" for the bottom toolbar.
struct UpdateStatusText: View {
    let lastUpdated: Date?
    let isLoading: Bool
    var detail: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 1) {
                Text(title(now: context.date))
                    .font(.caption)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func title(now: Date) -> String {
        if isLoading { return "Suche nach E-Mails …" }
        guard let lastUpdated else { return "" }
        let seconds = now.timeIntervalSince(lastUpdated)
        if seconds < 60 { return "Gerade aktualisiert" }
        if seconds < 3600 { return "Aktualisiert vor \(Int(seconds / 60)) Min." }
        return "Aktualisiert um \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }
}

/// A small on/off capsule, used for the OpenPGP options when writing.
struct ChipToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? tint : Color.secondary)
                .background(isOn ? tint.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "Ein" : "Aus")
    }
}

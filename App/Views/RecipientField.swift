import SwiftUI
import Contacts
import ContactsUI
import MailEngine

/// Recipients as chips with suggestions while typing, like Mail.
/// The binding holds a regular address list ("Name <a@b>, c@d").
struct RecipientField: View {
    @Environment(ContactDirectory.self) private var directory
    @Environment(KeyStore.self) private var keys

    @Binding var text: String
    let identifier: String
    /// Chips show whether a key exists (encryption is on).
    var showKeyState = false
    var autofocus = false

    @State private var tokens: [MailAddress] = []
    @State private var input = ""
    @State private var didLoad = false
    /// What this field last wrote into the binding; anything else came from outside.
    @State private var lastWritten: String?
    @FocusState private var isFocused: Bool

    private var taken: Set<String> { Set(tokens.map { $0.email.lowercased() }) }
    private var suggestions: [ContactDirectory.Entry] {
        isFocused ? directory.suggestions(for: input, excluding: taken) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(tokens, id: \.email) { chip($0) }
                TextField("", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .focused($isFocused)
                    .submitLabel(.next)
                    .onSubmit { commit(all: true) }
                    .accessibilityIdentifier(identifier)
                    .layoutValue(key: FlowFill.self, value: true)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { entry in
                        Button {
                            add(entry.address)
                        } label: {
                            suggestionRow(entry)
                        }
                        .buttonStyle(.plain)
                        if entry != suggestions.last { Divider() }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            tokens = HeaderCodec.parseAddressList(text)
            if autofocus {
                Task { try? await Task.sleep(for: .milliseconds(350)); isFocused = true }
            }
        }
        // Addresses added from outside (contact picker, opened draft).
        .onChange(of: text) {
            // Our own writes arrive here late, while typing goes on; only outside changes reset the field.
            if text != lastWritten, text != serialized() {
                tokens = HeaderCodec.parseAddressList(text)
                input = ""
            }
        }
        .onChange(of: input) {
            if input.contains(",") || input.contains(";") { commit(all: false) }
            sync()
        }
        .onChange(of: isFocused) {
            if !isFocused { commit(all: true) }
        }
    }

    // MARK: Chips

    private func keyState(_ address: MailAddress) -> Bool? {
        guard showKeyState else { return nil }
        return keys.encryptionKey(for: address.email) != nil
    }

    private func chip(_ address: MailAddress) -> some View {
        let state = keyState(address)
        let tint: Color = state == nil ? .accentColor : (state! ? .green : .orange)
        return Menu {
            Text(address.email)
            if state == false { Text("Kein Schlüssel – nicht verschlüsselbar") }
            Button(role: .destructive) {
                tokens.removeAll { $0.email.lowercased() == address.email.lowercased() }
                sync()
            } label: { Label("Entfernen", systemImage: "xmark") }
        } label: {
            HStack(spacing: 4) {
                if state == true { Image(systemName: "lock.fill").font(.caption2) }
                if state == false { Image(systemName: "lock.open").font(.caption2) }
                Text(address.displayName).lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
        }
        .accessibilityLabel(address.displayName)
        .accessibilityHint(address.email)
    }

    private func suggestionRow(_ entry: ContactDirectory.Entry) -> some View {
        HStack(spacing: 10) {
            AvatarView(name: entry.name ?? entry.email, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name ?? entry.email).font(.subheadline.weight(.medium)).lineLimit(1)
                if entry.name != nil {
                    Text(entry.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if keys.encryptionKey(for: entry.email) != nil {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
                    .accessibilityLabel("Schlüssel vorhanden")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Editing

    func add(_ address: MailAddress) {
        if !taken.contains(address.email.lowercased()) { tokens.append(address) }
        input = ""
        sync()
    }

    /// Turns typed addresses into chips. Without `all`, the part after the last separator stays.
    private func commit(all: Bool) {
        var parts = input.components(separatedBy: CharacterSet(charactersIn: ",;"))
        let rest = all ? "" : (parts.popLast() ?? "")
        var unparsed: [String] = []
        for part in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let found = HeaderCodec.parseAddressList(part)
            if found.isEmpty { unparsed.append(part) }
            for address in found where !taken.contains(address.email.lowercased()) { tokens.append(address) }
        }
        // Keep what is not an address yet, so nothing typed gets lost.
        input = (unparsed + [rest.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: ", ")
        sync()
    }

    private func serialized() -> String {
        let complete = tokens.map(HeaderCodec.formatAddress)
        let pending = input.trimmingCharacters(in: .whitespaces)
        return (complete + (pending.isEmpty ? [] : [pending])).joined(separator: ", ")
    }

    private func sync() {
        let value = serialized()
        if text != value {
            lastWritten = value
            text = value
        }
    }
}

/// ⊕: pick an address from the iOS contacts. Needs no contacts permission;
/// iOS hands over only the chosen address.
struct ContactPickerButton: View {
    var onPick: (MailAddress) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
        }
        .accessibilityLabel("Aus Kontakten hinzufügen")
        .background(ContactPickerPresenter(isPresented: $isPresented, onPick: onPick))
    }
}

private struct ContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (MailAddress) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, controller.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        // One address: pick the contact; several: choose the address.
        picker.predicateForSelectionOfContact = NSPredicate(format: "emailAddresses.@count == 1")
        DispatchQueue.main.async { controller.present(picker, animated: true) }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPickerPresenter
        init(_ parent: ContactPickerPresenter) { self.parent = parent }

        private func name(_ contact: CNContact) -> String? {
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? nil : name
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let email = contact.emailAddresses.first?.value as String? {
                parent.onPick(MailAddress(name: name(contact), email: email))
            }
            parent.isPresented = false
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            if let email = property.value as? String {
                parent.onPick(MailAddress(name: name(property.contact), email: email))
            }
            parent.isPresented = false
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}

/// Marks the view that fills the rest of its line (the text field after the chips).
struct FlowFill: LayoutValueKey {
    static let defaultValue = false
}

/// Lays views out left to right and wraps to the next line when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var minimumFillWidth: CGFloat = 120

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let fills = subview[FlowFill.self]
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = fills ? minimumFillWidth : size.width
            if x > 0, x + needed > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if fills {
                size = subview.sizeThatFits(ProposedViewSize(width: width - x, height: nil))
                size.width = width - x
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, y + lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            // Chips and the text field share a baseline-ish centre on each line.
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

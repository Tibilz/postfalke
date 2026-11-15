import Foundation

/// Large mail providers with their own login rules.
public enum MailProvider: String, Sendable, CaseIterable {
    case google, microsoft, apple, yahoo, gmxWebDe, other

    public static func detect(host: String, email: String) -> MailProvider {
        let host = host.lowercased()
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        func matches(_ hosts: [String], _ domains: [String]) -> Bool {
            hosts.contains { host == $0 || host.hasSuffix("." + $0) } || domains.contains { domain == $0 || domain.hasPrefix($0 + ".") }
        }
        if matches(["gmail.com", "googlemail.com"], ["gmail", "googlemail"]) { return .google }
        if matches(["office365.com", "outlook.com", "hotmail.com"], ["outlook", "hotmail", "live", "msn"]) { return .microsoft }
        if matches(["mail.me.com"], ["icloud", "me", "mac"]) { return .apple }
        if matches(["yahoo.com", "aol.com"], ["yahoo", "ymail", "aol"]) { return .yahoo }
        if matches(["gmx.net", "gmx.com", "web.de"], ["gmx", "web"]) { return .gmxWebDe }
        return .other
    }

    public var name: String {
        switch self {
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        case .apple: return "iCloud"
        case .yahoo: return "Yahoo/AOL"
        case .gmxWebDe: return "GMX/WEB.DE"
        case .other: return ""
        }
    }

    /// What the user has to know to log in, or nil when a normal password works.
    public var loginHint: String? {
        switch self {
        case .google:
            return "Google erlaubt die Anmeldung mit dem normalen Konto-Passwort nicht. Erstelle ein App-Passwort (dafür muss die Bestätigung in zwei Schritten aktiv sein) und gib es hier als Passwort ein."
        case .microsoft:
            return "Microsoft lässt bei Outlook.com, Hotmail und Live keine Anmeldung per Passwort mehr zu, nur noch über OAuth. Das unterstützt Postfalke noch nicht."
        case .apple:
            return "iCloud Mail braucht ein app-spezifisches Passwort, das du in deinem Apple-Account erstellst."
        case .yahoo:
            return "Yahoo und AOL brauchen ein App-Passwort aus den Sicherheitseinstellungen des Kontos."
        case .gmxWebDe:
            return "Bei GMX und WEB.DE muss der Abruf per IMAP erst im Postfach erlaubt werden (Einstellungen › POP3/IMAP Abruf)."
        case .other:
            return nil
        }
    }

    public var helpURL: URL? {
        switch self {
        case .google: return URL(string: "https://myaccount.google.com/apppasswords")
        case .apple: return URL(string: "https://account.apple.com/account/manage")
        case .yahoo: return URL(string: "https://login.yahoo.com/account/security")
        default: return nil
        }
    }

    /// Google shows app passwords as four groups of four letters; the spaces are not part of it.
    public func normalizedPassword(_ password: String) -> String {
        guard self == .google else { return password }
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = trimmed.split(separator: " ")
        guard groups.count == 4, groups.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isLetter) }) else { return password }
        return groups.joined()
    }
}

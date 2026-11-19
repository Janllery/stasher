import AppKit
import Carbon

struct WebsiteSuggestion: Equatable, Sendable {
    let host: String
    private let isHTTPS: Bool
    private let port: Int?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host(percentEncoded: true)?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        self.host = host
        isHTTPS = scheme == "https"
        let defaultPort = isHTTPS ? 443 : 80
        port = url.port == defaultPort ? nil : url.port
    }

    func suggestions(from entries: [Credential]) -> [Credential] {
        let suffixes = PublicSuffixList.bundled
        let domain = suffixes?.registrableDomain(for: host)
        let currentHost = suggestionHost(in: domain)
        var exact: [Credential] = []
        var parent: [Credential] = []
        for entry in entries {
            guard let site = WebsiteSuggestion(url: entry.url), port == site.port,
                  isHTTPS || !site.isHTTPS else { continue }
            if host == site.host {
                exact.append(entry)
            } else if let domain, domain == suffixes?.registrableDomain(for: site.host) {
                let savedHost = site.suggestionHost(in: domain)
                if currentHost == savedHost {
                    exact.append(entry)
                } else if currentHost.hasSuffix("." + savedHost) {
                    parent.append(entry)
                }
            }
        }
        return exact + parent
    }

    private func suggestionHost(in domain: String?) -> String {
        guard let domain, host.hasPrefix("www.") else { return host }
        let base = String(host.dropFirst(4))
        return base == domain || base.hasSuffix("." + domain) ? base : host
    }
}

enum ChromeTab {
    static let bundleIdentifier = "com.google.Chrome"
    private static let queue = DispatchQueue(label: "local.passwordreminder.chrome-tab")

    enum Lookup: Sendable {
        case site(WebsiteSuggestion)
        case unavailable
        case permissionRequired
        case permissionDenied
    }

    static func website(processIdentifier: pid_t, askUserIfNeeded: Bool) async -> Lookup {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: readWebsite(processIdentifier: processIdentifier,
                                                            askUserIfNeeded: askUserIfNeeded))
            }
        }
    }

    private static func readWebsite(processIdentifier: pid_t, askUserIfNeeded: Bool) -> Lookup {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                               AEEventID(kAEGetData), askUserIfNeeded)
        if permission == errAEEventNotPermitted { return .permissionDenied }
        if permission == errAEEventWouldRequireUserConsent { return .permissionRequired }
        guard permission == noErr else { return .unavailable }

        // Chrome's scripting dictionary defines «acTa» as active tab and «URL » as its address.
        guard let window = specifier(want: DescType(cWindow), form: DescType(formAbsolutePosition),
                                     key: NSAppleEventDescriptor(int32: 1), from: .null()),
              let tab = specifier(want: DescType(typeProperty), form: DescType(formPropertyID),
                                  key: NSAppleEventDescriptor(typeCode: 0x61635461), from: window),
              let address = specifier(want: DescType(typeProperty), form: DescType(formPropertyID),
                                      key: NSAppleEventDescriptor(typeCode: 0x55524C20), from: tab)
        else { return .unavailable }

        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite),
                                           eventID: AEEventID(kAEGetData), targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(address, forKeyword: AEKeyword(keyDirectObject))
        do {
            let reply = try event.sendEvent(options: .waitForReply, timeout: 3)
            guard let string = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
                  let url = URL(string: string), let site = WebsiteSuggestion(url: url) else { return .unavailable }
            return .site(site)
        } catch let error as NSError {
            return error.code == Int(errAEEventNotPermitted) ? .permissionDenied : .unavailable
        }
    }

    private static func specifier(want: DescType, form: DescType, key: NSAppleEventDescriptor,
                                  from: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(from, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }
}

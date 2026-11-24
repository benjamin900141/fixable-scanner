import Foundation
import Darwin
import UIKit
import SideSign
import Minimuxer

struct Handshake: Decodable {
    let clientInfo: String
    let anisette: [String]
    let bundleId: String
}

enum ProfileRefresh {
    static let refreshedKey = "fixable.refreshAt"

    static func daysLeft(now: Date = Date()) -> Int {
        let fromProfile = profileDays(now: now)
        guard let renewed = UserDefaults.standard.object(forKey: refreshedKey) as? Date else { return fromProfile }
        let fromStamp = max(0, 7 - Int(now.timeIntervalSince(renewed) / 86_400))
        return max(fromProfile, fromStamp)
    }

    private static func profileDays(now: Date) -> Int {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>ExpirationDate</key>"),
              let start = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let end = text.range(of: "</date>", range: start.upperBound..<text.endIndex) else { return 0 }
        let raw = String(text[start.upperBound..<end.lowerBound])
        guard let expiry = ISO8601DateFormatter().date(from: raw) else { return 0 }
        return max(0, Int(expiry.timeIntervalSince(now) / 86_400))
    }

    static func prepare(code typedCode: String) async -> String? {
        let saved = Bookmark.read()
        Bookmark.save(
            token: saved["token"] ?? "",
            runId: saved["runId"] ?? "",
            months: Int(saved["months"] ?? "") ?? 1,
            chatKey: saved["chatKey"] ?? "",
            screenId: saved["screenId"] ?? ""
        )
        let before = daysLeft()
        if before >= 2 {
            if let update = await updateURL() {
                await MainActor.run { UIApplication.shared.open(update) }
                return "A newer scanner is installing. Open Fixable again when it finishes."
            }
            return nil
        }
        guard let handshake = await fetchHandshake() else { return "The handshake could not be read." }
        if handshake.clientInfo.contains("macOS;") { return "The handshake is not safe to send to Apple." }
        if !vpnIsUp() { return "Turn on LocalDevVPN and Wi-Fi, then open Fixable again." }
        if pairingMissing() { return "Connect the computer once and run the Fixable installer again." }
        let appleID = AppleAccount.appleID()
        let password = AppleAccount.password()
        if appleID.isEmpty || password.isEmpty {
            return "Type the Apple ID that installed this app. It stays on this phone."
        }
        let code = typedCode.isEmpty ? AppleAccount.code() : typedCode
        do {
            let renewed = try await renew(handshake: handshake, appleID: appleID, password: password, code: code)
            if !renewed { return "Apple did not return a profile, so this app was not stamped." }
            if daysLeft() < 2 { return "Apple did not move the day counter, so the scan did not start." }
            return nil
        } catch {
            return spoken(error)
        }
    }

    private static func renew(handshake: Handshake, appleID: String, password: String, code: String) async throws -> Bool {
        let anisette = try await fetchAnisette(servers: handshake.anisette, clientInfo: handshake.clientInfo)
        let portal = DeveloperPortal.shared
        let auth = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisette,
            xcodeVersion: "16.2",
            verificationHandler: { request in
                if case .selectDeliveryMethod = request { return .requestTrustedDevice }
                if code.isEmpty { throw DeveloperPortalError.requiresTwoFactorAuthentication }
                return .verificationCode(code)
            }
        )
        let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
        guard let team = teams.first(where: { $0.type == .free }) ?? teams.first else {
            throw DeveloperPortalError.noTeams
        }
        let ids = try await portal.fetchAppIDs(for: team, session: auth.session)
        let appID: AppID
        if let found = ids.first(where: { $0.bundleIdentifier == handshake.bundleId }) {
            appID = found
        } else {
            appID = try await portal.addAppID(withName: "Fixable", bundleIdentifier: handshake.bundleId, team: team, session: auth.session)
        }
        let kind: DeviceType = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let profile = try await portal.downloadProvisioningProfile(for: appID, isTeamProfile: true, deviceType: kind, team: team, session: auth.session)
        guard profileIsUsable(profile.data) else { return false }
        try await install(profile.data)
        ProfileRefresh.noteRenewed()
        return true
    }

    private static func noteRenewed() {
        UserDefaults.standard.set(Date(), forKey: refreshedKey)
    }

    private static func profileIsUsable(_ data: Data) -> Bool {
        data.count > 200 && data.range(of: Data("<plist".utf8)) != nil && data.range(of: Data("ExpirationDate".utf8)) != nil
    }

    private static func install(_ profile: Data) async throws {
        let mux = Minimuxer.shared
        _ = await mux.network.start()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let mount = support?.appendingPathComponent("ddi", isDirectory: true)
        if let mount { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true) }
        try await mux.core.start(pairingFile: pairingPath(), mountPath: mount?.path ?? "", preferred: nil)
        do {
            try await mux.core.installProvisioningProfile(profile: profile)
            try? await mux.core.stop()
        } catch {
            try? await mux.core.stop()
            throw error
        }
    }

    private static func fetchAnisette(servers: [String], clientInfo: String) async throws -> AnisetteData {
        if clientInfo.contains("macOS;") { throw DeveloperPortalError.invalidAnisetteData(cause: "handshake") }
        for server in servers {
            if server == "on-device" {
                if let local = await onDeviceAnisette(clientInfo: clientInfo) { return local }
                continue
            }
            guard server.hasPrefix("https://") else { continue }
            guard let url = URL(string: server) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { continue }
            let mapped = mapAnisette(json)
            guard !mapped.machineID.isEmpty, !mapped.oneTimePassword.isEmpty, !mapped.deviceID.isEmpty else { continue }
            if let made = anisette(from: mapped, clientInfo: clientInfo) { return made }
        }
        throw DeveloperPortalError.invalidAnisetteData(cause: "No anisette server answered.")
    }

    private static func onDeviceAnisette(clientInfo: String) async -> AnisetteData? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let file = support?.appendingPathComponent("anisette.json"),
           let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let mapped = mapAnisette(json)
            if let made = anisette(from: mapped, clientInfo: clientInfo) { return made }
        }
        guard let url = URL(string: "http://127.0.0.1:6969") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return anisette(from: mapAnisette(json), clientInfo: clientInfo)
    }

    private static func anisette(from mapped: (machineID: String, oneTimePassword: String, localUserID: String, routingInfo: String, deviceID: String, serialNumber: String, userAgent: String, clientTime: String, locale: String, timeZone: String), clientInfo: String) -> AnisetteData? {
        guard !mapped.machineID.isEmpty, !mapped.oneTimePassword.isEmpty, !mapped.deviceID.isEmpty else { return nil }
        return AnisetteData(
            machineID: mapped.machineID,
            oneTimePassword: mapped.oneTimePassword,
            localUserID: mapped.localUserID,
            routingInfo: mapped.routingInfo.isEmpty ? "0" : mapped.routingInfo,
            deviceID: mapped.deviceID,
            serialNumber: mapped.serialNumber,
            clientInfo: clientInfo,
            userAgent: mapped.userAgent.isEmpty ? "Xcode" : mapped.userAgent,
            clientTime: mapped.clientTime.isEmpty ? ISO8601DateFormatter().string(from: Date()) : mapped.clientTime,
            locale: mapped.locale.isEmpty ? "en_US" : mapped.locale,
            timeZone: mapped.timeZone.isEmpty ? "PST" : mapped.timeZone
        )
    }

    private static func updateURL() async -> URL? {
        guard let url = URL(string: "https://hearty-mammoth-35.convex.site/device/manifest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ios = json["ios"] as? [String: Any],
              let file = ios["url"] as? String, !file.isEmpty,
              let posted = ios["version"] as? String,
              let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              posted != installed else { return nil }
        var parts = URLComponents()
        parts.scheme = "sidestore"
        parts.host = "install"
        parts.queryItems = [URLQueryItem(name: "url", value: file)]
        return parts.url
    }

    private static func mapAnisette(_ json: [String: String]) -> (machineID: String, oneTimePassword: String, localUserID: String, routingInfo: String, deviceID: String, serialNumber: String, userAgent: String, clientTime: String, locale: String, timeZone: String) {
        func pick(_ keys: String...) -> String {
            for key in keys {
                if let value = json[key], !value.isEmpty { return value }
            }
            return ""
        }
        return (
            pick("X-Apple-I-MD-M", "machineID"),
            pick("X-Apple-I-MD", "oneTimePassword"),
            pick("X-Apple-I-MD-LU", "localUserID"),
            pick("X-Apple-I-MD-RINFO", "routingInfo"),
            pick("X-Mme-Device-Id", "deviceID"),
            pick("X-Apple-I-SRL-NO", "serialNumber"),
            pick("User-Agent", "userAgent"),
            pick("X-Apple-I-Client-Time", "clientTime"),
            pick("X-Apple-Locale", "locale"),
            pick("X-Apple-I-TimeZone", "timeZone")
        )
    }

    private static func spoken(_ error: Error) -> String {
        let portal = error as? DeveloperPortalError
        let text: String
        switch portal {
        case .requiresTwoFactorAuthentication, .incorrectVerificationCode:
            text = "Apple sent a code. Type it in the code box and press the button again."
        case .incorrectCredentials:
            text = "Apple did not accept that Apple ID or password."
        case .maximumAppIDLimitReached:
            text = "This Apple ID already has its three free apps."
        case .invalidAnisetteData:
            text = "The anisette server did not answer. Try again on Wi-Fi."
        case .noTeams:
            text = "This Apple ID cannot create a free certificate."
        default:
            let raw = (error as? LocalizedError)?.errorDescription ?? "Apple did not renew this app."
            if raw.localizedCaseInsensitiveContains("too new") || raw.localizedCaseInsensitiveContains("child") || raw.localizedCaseInsensitiveContains("managed") {
                text = "This Apple ID cannot create a free certificate."
            } else {
                text = raw
            }
        }
        let secret = AppleAccount.password()
        if !secret.isEmpty && text.contains(secret) { return text.replacingOccurrences(of: secret, with: "") }
        return text
    }

    private static func fetchHandshake() async -> Handshake? {
        guard let url = URL(string: "https://hearty-mammoth-35.convex.site/device/handshake") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(Handshake.self, from: data)
    }

    static func vpnIsUp() -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if ip == "10.7.0.1" || ip == "10.7.0.2" { return true }
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }

    static func pairingMissing() -> Bool {
        !FileManager.default.fileExists(atPath: pairingPath())
    }

    static func pairingPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("pairing.plist").path ?? ""
    }
}

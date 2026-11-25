import Foundation
import Minimuxer
import UIKit

struct PhoneApp {
    var app: String
    var bundle: String
    var url: URL
}

struct PhoneRow {
    var key: String
    var text: String
    var loading: Bool
}

enum ScanRun {
    static var going = true
}

enum PhoneScreen {
    static func connect() async -> String? {
        if ProfileRefresh.pairingMissing() {
            return "Connect the computer once and run the Fixable installer again."
        }
        if !ProfileRefresh.vpnIsUp() {
            return "Turn on LocalDevVPN and Wi-Fi, then open Fixable again."
        }
        let mux = Minimuxer.shared
        _ = await mux.network.start()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let mount = support?.appendingPathComponent("ddi", isDirectory: true)
        if let mount { try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true) }
        do {
            try await mux.core.start(pairingFile: ProfileRefresh.pairingPath(), mountPath: mount?.path ?? "", preferred: preferredPairingProtocol())
            let ready = await mux.core.isReady(withNetworkCheck: true, withDDIMountCheck: false)
            if case .failure = ready {
                return "The phone's screen reader did not answer, so chats were not opened."
            }
        } catch {
            return "The phone's screen reader did not answer, so chats were not opened."
        }
        return nil
    }

    @MainActor
    static func apps() -> [PhoneApp] {
        let all = [
            PhoneApp(app: "whatsapp", bundle: "net.whatsapp.WhatsApp", url: URL(string: "whatsapp://")!),
            PhoneApp(app: "whatsapp_business", bundle: "net.whatsapp.WhatsAppSMB", url: URL(string: "whatsapp-smb://")!),
            PhoneApp(app: "gmail", bundle: "com.google.Gmail", url: URL(string: "googlegmail://")!),
            PhoneApp(app: "outlook", bundle: "com.microsoft.Office.Outlook", url: URL(string: "ms-outlook://")!),
        ]
        return all.filter { UIApplication.shared.canOpenURL($0.url) }
    }

    @MainActor
    static func open(_ app: PhoneApp) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(app.url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    static func refresh() async {
        await AccessibilityTree.shared.reload()
    }

    static func rows() async -> [PhoneRow] {
        await AccessibilityTree.shared.rows()
    }

    static func tap(_ labels: [String]) async -> Bool {
        await AccessibilityTree.shared.press(labels: labels)
    }

    static func longPress(_ label: String) async -> Bool {
        await AccessibilityTree.shared.press(labels: [label], hold: true)
    }

    static func dropText() async {
        await AccessibilityTree.shared.dropText()
    }

    static func scroll() async -> Bool {
        await AccessibilityTree.shared.scroll()
    }
}

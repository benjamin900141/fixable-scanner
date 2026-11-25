import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct FixableApp: App {
    var body: some Scene {
        WindowGroup {
            ScannerView()
                .onOpenURL { url in
                    guard url.scheme == "fixable" else { return }
                    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let saved = Bookmark.read()
                    let incomingRun = parts?.queryItems?.first { $0.name == "run" }?.value ?? saved["runId"] ?? ""
                    let sameRun = !incomingRun.isEmpty && incomingRun == (saved["runId"] ?? "")
                    Bookmark.save(
                        token: parts?.queryItems?.first { $0.name == "token" }?.value ?? saved["token"] ?? "",
                        runId: incomingRun,
                        months: Int(parts?.queryItems?.first { $0.name == "months" }?.value ?? "") ?? Int(saved["months"] ?? "") ?? 1,
                        chatKey: sameRun ? saved["chatKey"] ?? "" : "",
                        screenId: sameRun ? saved["screenId"] ?? "" : "",
                        chat: sameRun ? saved["chat"] ?? "" : ""
                    )
                }
        }
    }
}

struct ScannerView: View {
    @State private var note = "Opening a chat can send read receipts. Those blue ticks cannot be taken back."
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var offered: [String] = []
    @State private var ticked: Set<String> = []
    @State private var pickingPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The scanner reads what is on the screen in the apps you pick.")
            Text("WhatsApp can restrict an account that is automated.")
            Text("The Apple ID stays on this phone. It is not sent to Fixable.")
            TextField("Apple ID", text: $appleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Apple ID password", text: $password)
            TextField("Apple code, if one arrives", text: $code)
            Button("Choose the pairing file") { pickingPairing = true }
            Text(note)
            ForEach(offered, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { ticked.contains(name) },
                    set: { on in
                        if on { ticked.insert(name) } else { ticked.remove(name) }
                    }
                ))
            }
            Button("Keep the screen awake and read calendars") {
                Task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    if !appleID.isEmpty && !password.isEmpty {
                        AppleAccount.save(appleID: appleID, password: password, code: code)
                    } else if !code.isEmpty {
                        AppleAccount.save(appleID: AppleAccount.appleID(), password: AppleAccount.password(), code: code)
                    }
                    if let problem = await ProfileRefresh.prepare(code: code) {
                        note = problem
                        return
                    }
                    let saved = Bookmark.read()
                    guard let token = saved["token"], !token.isEmpty else {
                        note = "Open this app from the Fixable scan button."
                        return
                    }
                    await CalendarReader.postAll(token: token, months: Int(saved["months"] ?? "") ?? 1)
                    ScanRun.going = true
                    note = await ChatScan.read(token: token, months: Int(saved["months"] ?? "") ?? 1, ticked: ticked) { names in
                        offered = names
                    }
                }
            }
            Button("Stop") {
                ScanRun.going = false
                UIApplication.shared.isIdleTimerDisabled = false
                let token = Bookmark.read()["token"] ?? ""
                if !token.isEmpty {
                    Task { await Poster.stop(token: token) }
                }
                note = "Stopped"
            }
        }
        .padding()
        .fileImporter(isPresented: $pickingPairing, allowedContentTypes: [.propertyList, .data]) { result in
            guard case .success(let url) = result else { return }
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dest = folder.appendingPathComponent("pairing.plist")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
                note = "The pairing file is on this phone."
            } catch {
                note = "The pairing file could not be saved on this phone."
            }
        }
    }
}

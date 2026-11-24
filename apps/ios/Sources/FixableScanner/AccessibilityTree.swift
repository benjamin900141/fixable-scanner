import Foundation
import Minimuxer
import NIOCore
import NIOPosix
import NIOSSL

enum TreeError: Error {
    case timeout
    case closed
    case refused
}

final class AccessibilityTree: @unchecked Sendable {
    static let shared = AccessibilityTree()

    private let gate = NSLock()
    private var tail: Task<Void, Never> = Task {}
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var service: Link?
    private var deviceID = 0
    private var cached: [PhoneRow] = []
    private var elements: [String: Data] = [:]
    private var pending: [Incoming] = []

    func rows() async -> [PhoneRow] {
        await run { self.cached }
    }

    func reload() async {
        await run {
            do {
                try await self.prepare()
                self.cached = []
                self.elements = [:]
                self.pending = []
                try await self.invoke("deviceSetAppMonitoringEnabled:", args: [.object(NSNumber(value: true))], expectsReply: false)
                try await self.invoke("deviceInspectorSetMonitoredEventType:", args: [.object(NSNumber(value: 0))], expectsReply: false)
                try await self.invoke("deviceInspectorMoveWithOptions:", args: [.object(self.moveOptions(direction: 5))], expectsReply: false)
                self.absorb(await self.collect(seconds: 1.2))
                if let data = self.elements.values.first {
                    if let reply = try await self.invoke(
                        "deviceElement:valueForAttribute:",
                        args: [.object(self.element(data)), .object(self.attribute("_AXHierarchyElementsAttribute"))],
                        expectsReply: true
                    ) {
                        self.absorb([reply])
                    }
                }
                if self.cached.isEmpty {
                    for _ in 0..<30 {
                        try await self.invoke("deviceInspectorMoveWithOptions:", args: [.object(self.moveOptions(direction: 4))], expectsReply: false)
                        let batch = await self.collect(seconds: 0.35)
                        if batch.isEmpty { break }
                        let before = self.cached.count
                        self.absorb(batch)
                        if self.cached.count == before { break }
                    }
                }
            } catch {
                self.closeService()
                self.cached = []
                self.elements = [:]
            }
        }
    }

    func press(labels: [String], hold: Bool = false) async -> Bool {
        await run {
            let wanted = Set(labels)
            guard let row = self.cached.first(where: { wanted.contains($0.text) }), let data = self.elements[row.key] else { return false }
            do {
                try await self.prepare()
                var code = "AXAction-2010"
                var name = hold ? "Long Press" : "Activate"
                if hold, let reply = try await self.invoke(
                    "deviceElement:valueForAttribute:",
                    args: [.object(self.element(data)), .object(self.attribute("Actions"))],
                    expectsReply: true
                ) {
                    let found = reply.texts.first { value in
                        value.contains("AXAction-") && (value.localizedCaseInsensitiveContains("long") || value.localizedCaseInsensitiveContains("menu") || value.localizedCaseInsensitiveContains("hold"))
                    }
                    if let found {
                        code = found
                        name = "Long Press"
                    }
                }
                try await self.invoke(
                    "deviceElement:performAction:withValue:",
                    args: [.object(self.pressElement(data)), .object(self.action(code: code, name: name)), .int(0)],
                    expectsReply: false
                )
                return true
            } catch {
                self.closeService()
                return false
            }
        }
    }

    func scroll() async -> Bool {
        await run {
            let before = self.cached.map(\.text).joined(separator: "\n")
            do {
                try await self.prepare()
                for _ in 0..<6 {
                    try await self.invoke("deviceInspectorMoveWithOptions:", args: [.object(self.moveOptions(direction: 4))], expectsReply: false)
                    self.absorb(await self.collect(seconds: 0.25))
                }
            } catch {
                self.closeService()
                return false
            }
            let after = self.cached.map(\.text).joined(separator: "\n")
            return !after.isEmpty && after != before
        }
    }

    private func run<T>(_ body: @escaping () async -> T) async -> T {
        let box = ResultBox<T>()
        gate.lock()
        let previous = tail
        gate.unlock()
        let next = Task {
            _ = await previous.value
            box.value = await body()
        }
        gate.lock()
        tail = next
        gate.unlock()
        _ = await next.value
        return box.value!
    }

    private func prepare() async throws {
        if service?.channel.isActive == true { return }
        closeService()
        let pairing = try pairingRecord()
        let lockdown = try await connect(port: Int(MinimuxerConstants.lockdowndPort))
        try await lockdown.sendLockdown(["Label": "fixable", "Request": "QueryType", "ProtocolVersion": "2"])
        _ = try await lockdown.readLockdown()
        try await lockdown.sendLockdown([
            "Label": "fixable",
            "Request": "StartSession",
            "HostID": pairing.hostID,
            "SystemBUID": pairing.systemBUID,
            "ProtocolVersion": "2",
        ])
        let started = try await lockdown.readLockdown()
        if started["Error"] != nil { throw TreeError.refused }
        if (started["EnableSessionSSL"] as? Bool) ?? true {
            try await lockdown.upgrade(certificate: pairing.certificate, key: pairing.key)
        }
        var start: [String: Any] = [
            "Label": "fixable",
            "Request": "StartService",
            "Service": "com.apple.accessibility.axAuditDaemon.remoteserver",
        ]
        if let bag = pairing.escrow { start["EscrowBag"] = bag }
        if let sessionID = started["SessionID"] as? String { start["SessionID"] = sessionID }
        try await lockdown.sendLockdown(start)
        let serviceReply = try await lockdown.readLockdown()
        if serviceReply["Error"] != nil { throw TreeError.refused }
        guard let port = intValue(serviceReply["Port"]), port > 0 else { throw TreeError.refused }
        try await lockdown.channel.close().get()
        let link = try await connect(port: port)
        service = link
        let capabilities: NSDictionary = [
            "com.apple.private.DTXBlockCompression": 0,
            "com.apple.private.DTXConnection": 1,
        ]
        try await invoke("_notifyOfPublishedCapabilities:", args: [.object(capabilities)], expectsReply: false)
        let deadline = Date().addingTimeInterval(4)
        var ready = false
        while Date() < deadline {
            let message = try await readMessage(timeout: 1)
            if message.texts.contains("_notifyOfPublishedCapabilities:") {
                ready = true
                break
            }
            pending.append(message)
        }
        if !ready { throw TreeError.closed }
    }

    private func connect(port: Int) async throws -> Link {
        let pipe = BytePipe()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.pipeline.addHandler(pipe)
            }
        var channel: Channel?
        var last: Error = TreeError.closed
        for _ in 0..<3 {
            do {
                channel = try await bootstrap.connect(host: MinimuxerConstants.usbmuxdHost, port: Int(MinimuxerConstants.usbmuxdPort)).get()
                break
            } catch {
                last = error
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        guard let channel else { throw last }
        let link = Link(channel: channel, pipe: pipe)
        if deviceID == 0 {
            try await link.sendUsbmux(["MessageType": "ListDevices", "ClientVersionString": "fixable", "ProgName": "fixable"], tag: 1)
            let listed = try await link.readUsbmux()
            deviceID = deviceIdentifier(listed)
            try await channel.close()
            return try await connect(port: port)
        }
        let swapped = Int(UInt16(port).bigEndian)
        try await link.sendUsbmux([
            "MessageType": "Connect",
            "ClientVersionString": "fixable",
            "ProgName": "fixable",
            "DeviceID": deviceID,
            "PortNumber": swapped,
        ], tag: 2)
        let connected = try await link.readUsbmux()
        if intValue(connected["Number"]) != 0 { throw TreeError.refused }
        return link
    }

    private func invoke(_ selector: String, args: [Aux], expectsReply: Bool) async throws -> Incoming? {
        guard let link = service else { throw TreeError.closed }
        let identifier = link.nextIdentifier
        link.nextIdentifier += 1
        let packet = try dtxPacket(selector: selector, args: args, identifier: identifier, expectsReply: expectsReply)
        try await link.write(packet)
        if !expectsReply { return nil }
        if let index = pending.firstIndex(where: { $0.identifier == identifier && $0.conversation % 2 == 1 }) {
            return pending.remove(at: index)
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let message = try await readMessage(timeout: min(1, max(0.2, deadline.timeIntervalSinceNow)))
            if message.identifier == identifier && message.conversation % 2 == 1 { return message }
            pending.append(message)
        }
        return nil
    }

    private func readMessage(timeout: Double) async throws -> Incoming {
        guard let link = service else { throw TreeError.closed }
        var fragments: [UInt32: Data] = [:]
        while true {
            let header = try await link.read(32, timeout: timeout)
            if header.u32(0) != 0x1F3D5B79 { throw TreeError.closed }
            let headerSize = Int(header.u32(4))
            if headerSize < 32 || headerSize > 4096 { throw TreeError.closed }
            if headerSize > 32 { _ = try await link.read(headerSize - 32, timeout: timeout) }
            let index = Int(header.u16(8))
            let count = Int(header.u16(10))
            let length = header.u32(12)
            let identifier = header.u32(16)
            let conversation = header.u32(20)
            if count > 1 && index == 0 { continue }
            if length > 8_000_000 { throw TreeError.closed }
            let chunk = length == 0 ? Data() : try await link.read(Int(length), timeout: max(timeout, 4))
            var body = chunk
            if count > 1 {
                var assembled = fragments[identifier] ?? Data()
                assembled.append(chunk)
                if index + 1 < count {
                    fragments[identifier] = assembled
                    continue
                }
                fragments[identifier] = nil
                body = assembled
            }
            return incoming(body, identifier: identifier, conversation: conversation)
        }
    }

    private func collect(seconds: Double) async -> [Incoming] {
        var batch: [Incoming] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            do {
                batch.append(try await readMessage(timeout: min(0.4, max(0.15, deadline.timeIntervalSinceNow))))
            } catch {
                break
            }
        }
        return batch
    }

    private func absorb(_ messages: [Incoming]) {
        for message in messages {
            let texts = message.texts.filter(visible)
            let blobs = message.blobs.filter { $0.count >= 8 && $0.count <= 512 }
            if texts.isEmpty { continue }
            let blob = blobs.count == 1 ? blobs[0] : nil
            for text in texts {
                if cached.contains(where: { $0.text == text }) { continue }
                let key = blob?.hex ?? text
                if let blob { elements[key] = blob }
                cached.append(PhoneRow(key: key, text: text, loading: false))
                if cached.count >= 200 { return }
            }
        }
    }

    private func closeService() {
        if let service {
            service.channel.close(promise: nil)
        }
        service = nil
        pending = []
    }

    private func moveOptions(direction: Int) -> NSDictionary {
        [
            "ObjectType": "passthrough",
            "Value": [
                "allowNonAX": ["ObjectType": "passthrough", "Value": 0],
                "direction": ["ObjectType": "passthrough", "Value": direction],
                "includeContainers": ["ObjectType": "passthrough", "Value": 1],
            ],
        ]
    }

    private func pressElement(_ data: Data) -> NSDictionary {
        [
            "ObjectType": "AXAuditElement_v1",
            "Value": [
                "ObjectType": "passthrough",
                "Value": [
                    "PlatformElementValue_v1": ["ObjectType": "passthrough"],
                    "Value": data,
                ],
            ],
        ]
    }

    private func element(_ data: Data) -> NSDictionary {
        [
            "ObjectType": "AXAuditElement_v1",
            "Value": [
                "ObjectType": "passthrough",
                "Value": [
                    "PlatformElementValue_v1": ["ObjectType": "passthrough", "Value": data],
                ],
            ],
        ]
    }

    private func attribute(_ name: String) -> NSDictionary {
        [
            "ObjectType": "AXAuditElementAttribute_v1",
            "Value": [
                "ObjectType": "passthrough",
                "Value": [
                    "AttributeNameValue_v1": ["ObjectType": "passthrough", "Value": name],
                ],
            ],
        ]
    }

    private func action(code: String, name: String) -> NSDictionary {
        [
            "ObjectType": "AXAuditElementAttribute_v1",
            "Value": [
                "ObjectType": "passthrough",
                "Value": [
                    "AttributeNameValue_v1": ["ObjectType": "passthrough", "Value": code],
                    "DisplayAsTree_v1": ["ObjectType": "passthrough", "Value": 0],
                    "HumanReadableNameValue_v1": ["ObjectType": "passthrough", "Value": name],
                    "IsInternal_v1": ["ObjectType": "passthrough", "Value": 0],
                    "PerformsActionValue_v1": ["ObjectType": "passthrough", "Value": 1],
                    "SettableValue_v1": ["ObjectType": "passthrough", "Value": 0],
                    "ValueTypeValue_v1": ["ObjectType": "passthrough", "Value": 1],
                ],
            ],
        ]
    }

    private func visible(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count < 1 || value.count > 180 { return false }
        if value == "passthrough" || value == "ObjectType" || value == "fixable" { return false }
        if value.hasPrefix("com.apple.") || value.hasPrefix("AX") || value.hasPrefix("$") { return false }
        if value.hasSuffix(":") || value.contains("Value_v1") { return false }
        return true
    }
}

private struct PairingMaterial {
    var hostID: String
    var systemBUID: String
    var certificate: Data
    var key: Data
    var escrow: Data?
}

private func pairingRecord() throws -> PairingMaterial {
    let url = URL(fileURLWithPath: ProfileRefresh.pairingPath())
    let data = try Data(contentsOf: url)
    let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let root = parsed as? [String: Any] ?? [:]
    let record = root["PairRecord"] as? [String: Any] ?? root
    guard let hostID = record["HostID"] as? String,
          let systemBUID = record["SystemBUID"] as? String,
          let certificate = blob("HostCertificate", record),
          let key = blob("HostPrivateKey", record) else { throw TreeError.refused }
    return PairingMaterial(hostID: hostID, systemBUID: systemBUID, certificate: certificate, key: key, escrow: blob("EscrowBag", record))
}

private func blob(_ key: String, _ record: [String: Any]) -> Data? {
    if let data = record[key] as? Data, !data.isEmpty { return data }
    if let text = record[key] as? String, let data = Data(base64Encoded: text), !data.isEmpty { return data }
    return nil
}

private func deviceIdentifier(_ reply: [String: Any]) -> Int {
    let list = reply["DeviceList"] as? [[String: Any]] ?? []
    for item in list {
        if let id = intValue(item["DeviceID"]) { return id }
        if let props = item["Properties"] as? [String: Any], let id = intValue(props["DeviceID"]) { return id }
    }
    return 1
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? UInt { return Int(value) }
    if let value = value as? NSNumber { return value.intValue }
    return nil
}

private enum Aux {
    case object(NSObject)
    case int(UInt32)
}

private struct Incoming {
    var identifier: UInt32
    var conversation: UInt32
    var texts: [String]
    var blobs: [Data]
}

private func incoming(_ body: Data, identifier: UInt32, conversation: UInt32) -> Incoming {
    guard body.count >= 16 else { return Incoming(identifier: identifier, conversation: conversation, texts: [], blobs: []) }
    let auxLen = Int(body.u32(4))
    let total = Int(body.u64(8))
    var texts: [String] = []
    var blobs: [Data] = []
    if auxLen >= 0, total >= auxLen, 16 + total <= body.count {
        collect(body.subdata(in: 16..<(16 + auxLen)), texts: &texts, blobs: &blobs)
        collect(body.subdata(in: (16 + auxLen)..<(16 + total)), texts: &texts, blobs: &blobs)
    } else {
        collect(body, texts: &texts, blobs: &blobs)
    }
    return Incoming(identifier: identifier, conversation: conversation, texts: texts, blobs: blobs)
}

private func collect(_ data: Data, texts: inout [String], blobs: inout [Data]) {
    guard !data.isEmpty else { return }
    if let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSNull.self], from: data) {
        walk(object, texts: &texts, blobs: &blobs)
    }
    if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
        walk(plist, texts: &texts, blobs: &blobs)
    }
}

private func walk(_ value: Any, texts: inout [String], blobs: inout [Data]) {
    switch value {
    case let text as String:
        texts.append(text)
    case let data as Data:
        blobs.append(data)
    case let dict as [String: Any]:
        for item in dict.values { walk(item, texts: &texts, blobs: &blobs) }
    case let dict as NSDictionary:
        for item in dict.allValues { walk(item, texts: &texts, blobs: &blobs) }
    case let array as [Any]:
        for item in array { walk(item, texts: &texts, blobs: &blobs) }
    case let array as NSArray:
        for item in array { walk(item, texts: &texts, blobs: &blobs) }
    default:
        break
    }
}

private func dtxPacket(selector: String, args: [Aux], identifier: UInt32, expectsReply: Bool) throws -> Data {
    let aux = try auxBytes(args)
    let selectorData = try NSKeyedArchiver.archivedData(withRootObject: selector as NSString, requiringSecureCoding: false)
    let payloadCount = 16 + aux.count + selectorData.count
    var packet = Data()
    packet.appendU32(0x1F3D5B79)
    packet.appendU32(32)
    packet.appendU16(0)
    packet.appendU16(1)
    packet.appendU32(UInt32(payloadCount))
    packet.appendU32(identifier)
    packet.appendU32(0)
    packet.appendU32(0)
    packet.appendU32(expectsReply ? 1 : 0)
    packet.appendU32(2)
    packet.appendU32(UInt32(aux.count))
    packet.appendU64(UInt64(aux.count + selectorData.count))
    packet.append(aux)
    packet.append(selectorData)
    return packet
}

private func auxBytes(_ args: [Aux]) throws -> Data {
    if args.isEmpty { return Data() }
    var body = Data()
    for arg in args {
        body.appendU32(10)
        switch arg {
        case .int(let value):
            body.appendU32(3)
            body.appendU32(value)
        case .object(let object):
            let archived = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
            body.appendU32(2)
            body.appendU32(UInt32(archived.count))
            body.append(archived)
        }
    }
    var out = Data()
    out.appendU64(0x1F0)
    out.appendU64(UInt64(body.count))
    out.append(body)
    return out
}

private func loadIdentity(certificate: Data, key: Data) throws -> NIOSSLContext {
    let certBytes = [UInt8](certificate)
    let certificateObject = try (try? NIOSSLCertificate(bytes: certBytes, format: .der)) ?? NIOSSLCertificate(bytes: certBytes, format: .pem)
    let keyObject = try loadKey(key)
    var config = TLSConfiguration.makeClientConfiguration()
    config.certificateVerification = .none
    config.certificateChain = [.certificate(certificateObject)]
    config.privateKey = .privateKey(keyObject)
    return try NIOSSLContext(configuration: config)
}

private func loadKey(_ data: Data) throws -> NIOSSLPrivateKey {
    let bytes = [UInt8](data)
    if let key = try? NIOSSLPrivateKey(bytes: bytes, format: .der) { return key }
    if let key = try? NIOSSLPrivateKey(bytes: bytes, format: .pem) { return key }
    return try NIOSSLPrivateKey(bytes: [UInt8](pkcs8(data)), format: .der)
}

private func pkcs8(_ pkcs1: Data) -> Data {
    let version = Data([0x02, 0x01, 0x00])
    let oid = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
    let algorithm = derSequence(oid + Data([0x05, 0x00]))
    let wrapped = Data([0x04]) + derLength(pkcs1.count) + pkcs1
    return derSequence(version + algorithm + wrapped)
}

private func derSequence(_ body: Data) -> Data {
    Data([0x30]) + derLength(body.count) + body
}

private func derLength(_ count: Int) -> Data {
    if count < 128 { return Data([UInt8(count)]) }
    var value = count
    var bytes: [UInt8] = []
    while value > 0 {
        bytes.insert(UInt8(value & 0xff), at: 0)
        value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
}

private final class Link {
    let channel: Channel
    let pipe: BytePipe
    var nextIdentifier: UInt32 = 1

    init(channel: Channel, pipe: BytePipe) {
        self.channel = channel
        self.pipe = pipe
    }

    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes([UInt8](data))
        try await channel.writeAndFlush(buffer).get()
    }

    func read(_ count: Int, timeout: Double) async throws -> Data {
        try await pipe.read(count, timeout: timeout)
    }

    func sendUsbmux(_ plist: [String: Any], tag: UInt32) async throws {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var packet = Data()
        packet.appendU32(UInt32(16 + body.count))
        packet.appendU32(1)
        packet.appendU32(8)
        packet.appendU32(tag)
        packet.append(body)
        try await write(packet)
    }

    func readUsbmux() async throws -> [String: Any] {
        let header = try await read(16, timeout: 5)
        let length = Int(header.u32(0))
        if length < 16 || length > 8_000_000 { throw TreeError.closed }
        let body = try await read(length - 16, timeout: 5)
        let parsed = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
        return parsed as? [String: Any] ?? [:]
    }

    func sendLockdown(_ plist: [String: Any]) async throws {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var packet = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(body)
        try await write(packet)
    }

    func readLockdown() async throws -> [String: Any] {
        let prefix = try await read(4, timeout: 5)
        let length = Int(prefix.beU32(0))
        if length <= 0 || length > 8_000_000 { throw TreeError.closed }
        let body = try await read(length, timeout: 5)
        let parsed = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
        return parsed as? [String: Any] ?? [:]
    }

    func upgrade(certificate: Data, key: Data) async throws {
        let context = try loadIdentity(certificate: certificate, key: key)
        let handler = try NIOSSLClientHandler(context: context, serverHostname: "localhost")
        try await channel.pipeline.addHandler(handler, position: .first).get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

private final class OnceResume: @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ data: Data) {
        finish(.success(data))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class BytePipe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: (Int, OnceResume)?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        let bytes = incoming.readBytes(length: incoming.readableBytes) ?? []
        lock.lock()
        buffer.append(contentsOf: bytes)
        guard let pending = waiter, buffer.count >= pending.0 else {
            lock.unlock()
            return
        }
        let chunk = Data(buffer.prefix(pending.0))
        buffer.removeFirst(pending.0)
        waiter = nil
        lock.unlock()
        pending.1.succeed(chunk)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(TreeError.closed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func read(_ count: Int, timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume(continuation)
            lock.lock()
            if buffer.count >= count {
                let chunk = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                lock.unlock()
                once.succeed(chunk)
                return
            }
            waiter = (count, once)
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.cancel(once)
            }
        }
    }

    private func cancel(_ once: OnceResume) {
        lock.lock()
        if waiter?.1 === once { waiter = nil }
        lock.unlock()
        once.fail(TreeError.timeout)
    }

    private func fail(_ error: Error) {
        lock.lock()
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.1.fail(error)
    }
}

private extension Data {
    private func byte(_ offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(byte(offset)) | (UInt16(byte(offset + 1)) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(byte(offset))
            | (UInt32(byte(offset + 1)) << 8)
            | (UInt32(byte(offset + 2)) << 16)
            | (UInt32(byte(offset + 3)) << 24)
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(byte(offset + index)) << (8 * UInt64(index))
        }
        return value
    }

    func beU32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(byte(offset)) << 24)
            | (UInt32(byte(offset + 1)) << 16)
            | (UInt32(byte(offset + 2)) << 8)
            | UInt32(byte(offset + 3))
    }

    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendU64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

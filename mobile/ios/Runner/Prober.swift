import Foundation
import Libbox
import Network

/// The node check while the tunnel is off ("Проверить" on the Servers tab): a sing-box inside the app itself with
/// only the nodes and the Clash API. It has no tun inbound, so iOS shows no VPN and other apps are not affected;
/// its requests leave the phone the same way the tunnel's would. The tunnel runs in the PacketTunnel extension and
/// is never started at the same time (the app checks through the tunnel while it is on).
final class Prober: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    static let shared = Prober()

    private let queue = DispatchQueue(label: "vlessclient.probe")
    private var server: LibboxCommandServer?
    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?
    private var setupDone = false

    func start(_ config: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startLocked(config)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopLocked()
                cont.resume()
            }
        }
    }

    private func startLocked(_ config: String) throws {
        stopLocked()
        // the app's own folder: the extension keeps its command socket in the app group
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("probe", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        if !setupDone {
            let setup = LibboxSetupOptions()
            setup.basePath = base.path
            setup.workingPath = base.path
            setup.tempPath = NSTemporaryDirectory()
            setup.logMaxLines = 200
            setup.debug = false
            setup.crashReportSource = "Application"
            var setupError: NSError?
            LibboxSetup(setup, &setupError)
            if let setupError { throw setupError }
            setupDone = true
        }
        var error: NSError?
        let s = LibboxNewCommandServer(self, self, &error)
        if let error { throw error }
        guard let s else { throw Self.error("command server") }
        try s.start()
        server = s
        do {
            try s.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            stopLocked()
            throw error
        }
    }

    private func stopLocked() {
        guard let s = server else { return }
        server = nil
        try? s.closeService()
        s.close()
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "VlessClient", code: 0, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // ------------------------------------------------------------------ platform (no tunnel here)

    func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw Self.error("the node check has no tunnel")
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw Self.error("not supported on iOS")
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onPath(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in self.onPath(listener, path) }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private func onPath(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let desc = "\(path.status) " + path.availableInterfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ",")
        listener.updateNetworkPath(desc)
        if desc == lastNetworkPath { return }
        lastNetworkPath = desc
        guard path.status != .unsatisfied, let first = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(first.name, interfaceIndex: Int32(first.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else { throw Self.error("NWMonitor not started") }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied { return InterfaceArray([]) }
        var list: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let i = LibboxNetworkInterface()
            i.name = it.name
            i.index = Int32(it.index)
            switch it.type {
            case .wifi: i.type = LibboxInterfaceTypeWIFI
            case .cellular: i.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: i.type = LibboxInterfaceTypeEthernet
            default: i.type = LibboxInterfaceTypeOther
            }
            list.append(i)
        }
        return InterfaceArray(list)
    }

    class InterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var value: LibboxNetworkInterface?
        init(_ array: [LibboxNetworkInterface]) { iterator = array.makeIterator() }
        func hasNext() -> Bool {
            value = iterator.next()
            return value != nil
        }

        func next() -> LibboxNetworkInterface? { value }
    }

    func underNetworkExtension() -> Bool { false }

    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {}

    func readWIFIState() -> LibboxWIFIState? { nil }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func send(_: LibboxNotification?) throws {}

    func cancelNotification(_: String?, typeID _: Int32) throws {}

    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func registerMyInterface(_: String?) {}

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws { throw Self.error("not supported") }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw Self.error("not supported")
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.error("not supported")
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.error("not supported")
        return ""
    }

    func tailscaleHostname() -> String { "iphone" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol { throw Self.error("not supported") }

    func lookupUser(_: String?) throws -> LibboxPlatformUser { throw Self.error("not supported") }

    // ------------------------------------------------------------------ command server handler

    func serviceStop() throws {
        queue.async { self.stopLocked() }
    }

    func serviceReload() throws {}

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }

    func setSystemProxyEnabled(_: Bool) throws {}

    func triggerNativeCrash() throws {}

    func writeDebugMessage(_: String?) {}

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws { throw Self.error("not supported") }
}

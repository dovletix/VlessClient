import Foundation
import Libbox
import Network
import NetworkExtension

/// The iOS tunnel: a Packet Tunnel extension around sing-box (libbox). The app passes the sing-box
/// config in the start options ("configContent") and as a provider message on reload; a copy is kept
/// in the app group so that "Connect On Demand" / Settings can start the tunnel without the app.
/// Modelled on sing-box for Apple platforms (SFI, GPL-3.0).
class PacketTunnelProvider: NEPacketTunnelProvider, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    static let appGroup = "group.io.github.dovletix.vlessclient"

    private var commandServer: LibboxCommandServer?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?

    private var shared: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)!
    }

    private func writeError(_ text: String) {
        try? text.write(to: shared.appendingPathComponent("tunnel-error.txt"), atomically: true, encoding: .utf8)
    }

    private func fail(_ text: String) -> NSError {
        writeError(text)
        return NSError(domain: "VlessClient", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        let configURL = shared.appendingPathComponent("config.json")
        try? FileManager.default.removeItem(at: shared.appendingPathComponent("tunnel-error.txt"))
        var config = options?["configContent"] as? String
        if let config {
            try? config.write(to: configURL, atomically: true, encoding: .utf8)
        } else {
            config = try? String(contentsOf: configURL, encoding: .utf8)
        }
        guard let config, !config.isEmpty else {
            throw fail("нет настроек туннеля — откройте приложение и нажмите кнопку")
        }

        let base = shared.path
        let setup = LibboxSetupOptions()
        setup.basePath = base
        setup.workingPath = shared.appendingPathComponent("work").path
        setup.tempPath = NSTemporaryDirectory()
        setup.logMaxLines = 1000
        setup.debug = false
        setup.crashReportSource = "NetworkExtension"
        setup.oomKillerEnabled = true
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            throw fail("libbox: \(setupError.localizedDescription)")
        }

        var error: NSError?
        commandServer = LibboxNewCommandServer(self, self, &error)
        if let error {
            throw fail("command server: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
            try commandServer!.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            throw fail(error.localizedDescription)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        try? commandServer?.closeService()
        reset()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    /// Reload with a new config sent by the app (rules, node, default route changed).
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let config = String(data: messageData, encoding: .utf8), let server = commandServer else {
            return "tunnel is not running".data(using: .utf8)
        }
        try? config.write(to: shared.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        reasserting = true
        defer { reasserting = false }
        do {
            try server.startOrReloadService(config, options: LibboxOverrideOptions())
            return nil
        } catch {
            writeError(error.localizedDescription)
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    private func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    private func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "VlessClient", code: 0, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // ------------------------------------------------------------------ tun

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else { throw Self.error("nil options") }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var dnsSettings: NEDNSSettings?
            if options.getDNSMode()!.value != LibboxDNSModeDisabled {
                let it = try options.getDNSServerAddress()
                var servers: [String] = []
                while it.hasNext() { servers.append(it.next()) }
                if !servers.isEmpty { dnsSettings = NEDNSSettings(servers: servers) }
            }

            var v4: [String] = [], v4mask: [String] = []
            let a4 = options.getInet4Address()!
            while a4.hasNext() {
                let p = a4.next()!
                v4.append(p.address())
                v4mask.append(p.mask())
            }
            let ipv4 = NEIPv4Settings(addresses: v4, subnetMasks: v4mask)
            var routes4: [NEIPv4Route] = [], exclude4: [NEIPv4Route] = []
            let r4 = options.getInet4RouteAddress()!
            if r4.hasNext() {
                while r4.hasNext() {
                    let p = r4.next()!
                    routes4.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            } else {
                routes4.append(NEIPv4Route.default())
            }
            let e4 = options.getInet4RouteExcludeAddress()!
            while e4.hasNext() {
                let p = e4.next()!
                exclude4.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
            }
            ipv4.includedRoutes = routes4
            ipv4.excludedRoutes = exclude4
            settings.ipv4Settings = ipv4

            var v6: [String] = [], v6len: [NSNumber] = []
            let a6 = options.getInet6Address()!
            while a6.hasNext() {
                let p = a6.next()!
                v6.append(p.address())
                v6len.append(NSNumber(value: p.prefix()))
            }
            let ipv6 = NEIPv6Settings(addresses: v6, networkPrefixLengths: v6len)
            var routes6: [NEIPv6Route] = [], exclude6: [NEIPv6Route] = []
            let r6 = options.getInet6RouteAddress()!
            if r6.hasNext() {
                while r6.hasNext() {
                    let p = r6.next()!
                    routes6.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                }
            } else {
                routes6.append(NEIPv6Route.default())
            }
            let e6 = options.getInet6RouteExcludeAddress()!
            while e6.hasNext() {
                let p = e6.next()!
                exclude6.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
            }
            ipv6.includedRoutes = routes6
            ipv6.excludedRoutes = exclude6
            settings.ipv6Settings = ipv6
            settings.dnsSettings = dnsSettings
        }

        networkSettings = settings
        try runBlocking { [self] in
            try await setTunnelNetworkSettings(settings)
        }
        if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd == -1 { throw Self.error("missing tunnel file descriptor") }
        ret0_.pointee = fd
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw Self.error("not supported on iOS")
    }

    // ------------------------------------------------------------------ network monitor

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

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {
        guard let networkSettings else { return }
        _ = try? runBlocking { [self] in
            reasserting = true
            defer { reasserting = false }
            try await setTunnelNetworkSettings(nil)
            try await setTunnelNetworkSettings(networkSettings)
        }
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    // ------------------------------------------------------------------ unused platform features

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
        try? commandServer?.closeService()
        reset()
        cancelTunnelWithError(nil)
    }

    func serviceReload() throws {
        let config = try String(contentsOf: shared.appendingPathComponent("config.json"), encoding: .utf8)
        try commandServer?.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }

    func setSystemProxyEnabled(_: Bool) throws {}

    func triggerNativeCrash() throws {}

    func writeDebugMessage(_: String?) {}

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws { throw Self.error("not supported") }
}

import Flutter
import NetworkExtension
import UIKit

/// The app side of the iOS tunnel: the "vlessclient/vpn" channel over NETunnelProviderManager.
/// The tunnel itself lives in the PacketTunnel extension (sing-box), see PacketTunnel/PacketTunnelProvider.swift.
final class VpnChannel {
    static let appGroup = "group.io.github.dovletix.vlessclient"
    static let tunnelBundle = "io.github.dovletix.vlessclient.PacketTunnel"

    private var manager: NETunnelProviderManager?

    private var shared: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)!
    }

    func register(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "vlessclient/vpn", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            Task { @MainActor in
                await self.handle(call, result)
            }
        }
    }

    @MainActor
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) async {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "info":
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                result(["platform": "ios", "dataDir": shared.path, "version": version, "abi": ""])
            case "start":
                try await start(args["config"] as? String ?? "")
                result(nil)
            case "reload":
                try await reload(args["config"] as? String ?? "")
                result(nil)
            case "stop":
                try await loadManager()?.connection.stopVPNTunnel()
                result(nil)
            case "status":
                let m = try await loadManager()
                let s = m?.connection.status ?? .invalid
                let error = (try? String(contentsOf: shared.appendingPathComponent("tunnel-error.txt"), encoding: .utf8)) ?? ""
                result([
                    "running": s == .connected,
                    "starting": s == .connecting || s == .reasserting,
                    "error": s == .connected ? "" : error,
                ])
            case "takeLink":
                // vlessclient:// links are Android-only for now: FlutterSceneDelegate does not expose its URL callbacks to Swift
                result(nil)
            case "apps":
                result([])
            case "icon":
                result(nil)
            case "openUrl":
                if let s = args["url"] as? String, let url = URL(string: s) {
                    await UIApplication.shared.open(url)
                }
                result(nil)
            case "share":
                share(args["text"] as? String ?? "")
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            let ns = error as NSError
            // the user tapped "Don't Allow" on the "add VPN configuration" prompt
            if ns.domain == NEVPNErrorDomain, ns.code == NEVPNError.configurationReadWriteFailed.rawValue {
                result(FlutterError(code: "denied", message: ns.localizedDescription, details: nil))
            } else {
                result(FlutterError(code: "failed", message: ns.localizedDescription, details: nil))
            }
        }
    }

    @MainActor
    private func loadManager() async throws -> NETunnelProviderManager? {
        if let manager { return manager }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundle }
        return manager
    }

    @MainActor
    private func ensureManager() async throws -> NETunnelProviderManager {
        let m = try await loadManager() ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundle
        proto.serverAddress = "VlessClient"
        m.protocolConfiguration = proto
        m.localizedDescription = "VlessClient"
        m.isEnabled = true
        // iOS shows "Add VPN Configurations?" the first time
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        return m
    }

    @MainActor
    private func start(_ config: String) async throws {
        try config.write(to: shared.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: shared.appendingPathComponent("tunnel-error.txt"))
        let m = try await ensureManager()
        try m.connection.startVPNTunnel(options: ["configContent": config as NSString])
    }

    @MainActor
    private func reload(_ config: String) async throws {
        try config.write(to: shared.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        guard let m = try await loadManager(), let session = m.connection as? NETunnelProviderSession,
              m.connection.status == .connected
        else {
            try await start(config)
            return
        }
        let reply: Data? = try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(config.data(using: .utf8)!) { data in cont.resume(returning: data) }
            } catch {
                cont.resume(throwing: error)
            }
        }
        if let reply, let text = String(data: reply, encoding: .utf8), !text.isEmpty {
            throw NSError(domain: "VlessClient", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    @MainActor
    private func share(_ text: String) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = root.view
        root.present(vc, animated: true)
    }
}

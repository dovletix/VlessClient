import 'package:flutter/services.dart';

import '../core/config.dart';

class InstalledApp {
  InstalledApp(this.package, this.label, this.system);
  final String package, label;
  final bool system;
}

class NativeStatus {
  NativeStatus({required this.running, required this.starting, required this.error});
  final bool running, starting;
  final String error;
}

/// The native half: Android VpnService / iOS Packet Tunnel extension around sing-box (libbox).
class Vpn {
  static const _ch = MethodChannel('vlessclient/vpn');

  late MobileOs os;
  late String dataDir;
  late String version;
  String abi = '';

  Future<void> init() async {
    final info = (await _ch.invokeMapMethod<String, dynamic>('info'))!;
    os = info['platform'] == 'ios' ? MobileOs.ios : MobileOs.android;
    dataDir = info['dataDir'] as String;
    version = (info['version'] ?? '1.0.0') as String;
    abi = (info['abi'] ?? '') as String;
    xray = info['xray'] == true;
  }

  /// The build ships Xray for the nodes sing-box cannot carry (Android arm64 / x86_64).
  bool xray = false;

  /// Starts the tunnel with this sing-box config and, when some node needs it, the Xray config
  /// (asks for the VPN permission the first time).
  Future<void> start(String config, {String xray = ''}) => _ch.invokeMethod('start', {'config': config, 'xray': xray});

  /// Applies a new config to the running tunnel (sing-box restarts inside; open connections drop).
  Future<void> reload(String config, {String xray = ''}) => _ch.invokeMethod('reload', {'config': config, 'xray': xray});

  Future<void> stop() => _ch.invokeMethod('stop');

  /// Starts a sing-box (plus Xray when a node needs it) that only measures the nodes while the tunnel is off:
  /// no TUN, no VPN icon. Returns once its Clash API can start listening, throws when it could not start.
  Future<void> probeStart(String config, {String xray = ''}) => _ch.invokeMethod('probeStart', {'config': config, 'xray': xray});

  Future<void> probeStop() => _ch.invokeMethod('probeStop');

  Future<NativeStatus> status() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('status') ?? {};
    return NativeStatus(running: m['running'] == true, starting: m['starting'] == true, error: (m['error'] ?? '').toString());
  }

  /// Android: launchable apps (package, label). Empty on iOS.
  Future<List<InstalledApp>> apps() async {
    if (os != MobileOs.android) return [];
    final list = await _ch.invokeListMethod<Map>('apps') ?? [];
    return list.map((m) => InstalledApp(m['package'].toString(), m['label'].toString(), m['system'] == true)).toList();
  }

  final Map<String, Uint8List?> _icons = {};

  /// Android: the app icon as PNG (cached).
  Future<Uint8List?> icon(String package) async {
    if (os != MobileOs.android) return null;
    if (_icons.containsKey(package)) return _icons[package];
    Uint8List? b;
    try {
      b = await _ch.invokeMethod<Uint8List>('icon', {'package': package});
    } catch (_) {}
    _icons[package] = b;
    return b;
  }

  /// Android: checks the SHA-256 of a downloaded APK and opens the system installer.
  Future<void> installApk(String path, String sha256) => _ch.invokeMethod('installApk', {'path': path, 'sha256': sha256});

  Future<void> openUrl(String url) => _ch.invokeMethod('openUrl', {'url': url});

  /// A subscription passed by a link (vlessclient://add/<link or vless:// lines>) since the last call, or null.
  Future<String?> takeLink() async {
    try {
      final link = await _ch.invokeMethod<String>('takeLink');
      if (link == null || link.isEmpty) return null;
      const prefix = 'vlessclient://add/';
      if (!link.toLowerCase().startsWith(prefix)) return null;
      final rest = link.substring(prefix.length);
      try {
        return Uri.decodeComponent(rest);
      } catch (_) {
        return rest;
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> share(String text) => _ch.invokeMethod('share', {'text': text});
}

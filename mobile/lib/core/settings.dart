import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'node.dart';

/// A named group of Android apps (package names) that go through the VPN or directly.
class AppRule {
  AppRule({required this.name, required this.packages, required this.vpn});

  String name;
  List<String> packages;
  bool vpn;

  Map<String, dynamic> toJson() => {'name': name, 'packages': packages, 'vpn': vpn};

  static AppRule? fromJson(Object? j) {
    if (j is! Map) return null;
    final pk = _strings(j['packages']);
    final name = (j['name'] ?? '').toString();
    if (pk.isEmpty) return null;
    return AppRule(name: name.isEmpty ? pk.first : name, packages: pk, vpn: j['vpn'] == true);
  }
}

List<String> _strings(Object? v) => v is List ? v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList() : <String>[];

/// A backup subscription link: a mirror of the main one (the same panel through another address) or another
/// provider. Its servers are used when the main subscription cannot be downloaded or none of its servers answers.
class BackupSub {
  BackupSub(this.url, {this.insecure = false});

  final String url;
  bool insecure; // self-signed certificate, accepted the first time it was added

  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  Map<String, dynamic> toJson() => {'url': url, 'insecure': insecure};

  static BackupSub? fromJson(Object? j) {
    if (j is String && j.trim().isNotEmpty) return BackupSub(j.trim());
    if (j is! Map || (j['url'] ?? '').toString().trim().isEmpty) return null;
    return BackupSub(j['url'].toString().trim(), insecure: j['insecure'] == true);
  }
}

/// All user settings, stored as JSON in the app's data folder. Mirrors the Windows app's settings.json where it makes sense.
class Settings {
  // subscription
  String subscriptionUrl = '';
  bool inlineNodes = false; // servers were pasted as vless:// lines instead of a link
  bool insecureTls = false;
  int updateHours = 12;
  List<BackupSub> backups = [];

  // connection
  String node = 'auto'; // "auto", node number or part of its name
  String autoExclude = ''; // regex on node names that "auto" must never use
  String lastGoodNode = '';
  bool nodeFallback = true; // a pinned node gets a spare that takes over only while it is dead
  String defaultRoute = 'proxy'; // where traffic without a rule goes: proxy | direct
  bool blockQuicOnProxy = true;
  String dnsProxy = '1.1.1.1';

  int apiPort = 12090;
  String apiSecret = '';

  // Russia
  bool ruDirect = true;

  // rules
  List<AppRule> apps = [];
  List<String> directDomains = [];
  List<String> proxyDomains = [];
  List<String> directIps = [];
  List<String> proxyIps = [];

  String theme = 'dark';
  String logLevel = 'warn';
  bool autoConnect = false; // connect when the app opens

  bool get hasSubscription => inlineNodes || subscriptionUrl.trim().isNotEmpty;
  bool get canDownload => !inlineNodes && subscriptionUrl.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'subscription': {
          'url': subscriptionUrl,
          'inline': inlineNodes,
          'insecure_tls': insecureTls,
          'update_hours': updateHours,
          'backups': backups.map((b) => b.toJson()).toList(),
        },
        'node': node,
        'auto_exclude': autoExclude,
        'last_good_node': lastGoodNode,
        'node_fallback': nodeFallback ? 'on' : 'off',
        'default': defaultRoute,
        'block_quic_on_proxy': blockQuicOnProxy,
        'dns': {'proxy': dnsProxy},
        'api': {'port': apiPort, 'secret': apiSecret},
        'ru_direct': {'enabled': ruDirect},
        'apps': apps.map((a) => a.toJson()).toList(),
        'rules': {
          'direct_domains': directDomains,
          'proxy_domains': proxyDomains,
          'direct_ips': directIps,
          'proxy_ips': proxyIps,
        },
        'theme': theme,
        'log_level': logLevel,
        'auto_connect': autoConnect,
      };

  static Settings fromJson(Map<String, dynamic> j) {
    final s = Settings();
    final sub = j['subscription'];
    if (sub is Map) {
      s.subscriptionUrl = (sub['url'] ?? '').toString();
      s.inlineNodes = sub['inline'] == true;
      s.insecureTls = sub['insecure_tls'] == true;
      s.updateHours = max(1, (sub['update_hours'] is int) ? sub['update_hours'] as int : 12);
      final b = sub['backups'];
      if (b is List) s.backups = b.map(BackupSub.fromJson).whereType<BackupSub>().toList();
    }
    s.node = (j['node'] ?? 'auto').toString();
    s.autoExclude = (j['auto_exclude'] ?? '').toString();
    s.lastGoodNode = (j['last_good_node'] ?? '').toString();
    s.nodeFallback = j['node_fallback'] != 'off';
    s.defaultRoute = j['default'] == 'direct' ? 'direct' : 'proxy';
    s.blockQuicOnProxy = j['block_quic_on_proxy'] != false;
    final dns = j['dns'];
    if (dns is Map && (dns['proxy'] ?? '').toString().isNotEmpty) s.dnsProxy = dns['proxy'].toString();
    final api = j['api'];
    if (api is Map) {
      if (api['port'] is int) s.apiPort = api['port'] as int;
      s.apiSecret = (api['secret'] ?? '').toString();
    }
    final ru = j['ru_direct'];
    if (ru is Map) s.ruDirect = ru['enabled'] != false;
    final apps = j['apps'];
    if (apps is List) s.apps = apps.map(AppRule.fromJson).whereType<AppRule>().toList();
    final r = j['rules'];
    if (r is Map) {
      s.directDomains = _strings(r['direct_domains']);
      s.proxyDomains = _strings(r['proxy_domains']);
      s.directIps = _strings(r['direct_ips']);
      s.proxyIps = _strings(r['proxy_ips']);
    }
    s.theme = j['theme'] == 'light' ? 'light' : 'dark';
    s.logLevel = (j['log_level'] ?? 'warn').toString();
    s.autoConnect = j['auto_connect'] == true;
    return s;
  }

  Settings clone() => fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  static String randomSecret() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ------------------------------------------------------------------ files

  static Settings load(String path) {
    var s = Settings();
    try {
      final f = File(path);
      if (f.existsSync()) s = fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      s = Settings();
    }
    if (s.apiSecret.isEmpty) s.apiSecret = randomSecret();
    return s;
  }

  void save(String path) {
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n', flush: true);
    tmp.renameSync(path);
  }

  // ------------------------------------------------------------------ apps

  /// Creates or updates an app rule; the listed packages are removed from every other rule.
  void setApp(String name, List<String> packages, bool vpn) {
    final pk = packages.map((p) => p.trim()).where((p) => p.isNotEmpty).toSet().toList();
    for (final a in apps) {
      if (a.name != name) a.packages.removeWhere(pk.contains);
    }
    apps.removeWhere((a) => a.packages.isEmpty);
    final existing = apps.where((a) => a.name == name).firstOrNull;
    if (existing == null) {
      apps.add(AppRule(name: name, packages: pk, vpn: vpn));
    } else {
      if (pk.isNotEmpty) existing.packages = pk;
      existing.vpn = vpn;
    }
  }

  void removeApp(String name) => apps.removeWhere((a) => a.name == name);

  /// The rule a package belongs to, if any.
  AppRule? ruleFor(String package) => apps.where((a) => a.packages.contains(package)).firstOrNull;

  // ------------------------------------------------------------------ nodes

  /// Nodes that "auto" may use: supported, auto_exclude applied (falls back to all supported when the filter removes everything).
  List<Node> autoPool(List<Node> all) {
    final ok = all.where((n) => n.supported).toList();
    if (autoExclude.trim().isEmpty) return ok;
    try {
      final rx = RegExp(autoExclude, caseSensitive: false);
      final pool = ok.where((n) => !rx.hasMatch(n.name)).toList();
      return pool.isNotEmpty ? pool : ok;
    } catch (_) {
      return ok;
    }
  }

  /// A pinned node by number or by (part of) its name; null for "auto" or when not found.
  Node? findPinned(List<Node> all) {
    final sel = node.trim();
    if (sel.isEmpty || sel.toLowerCase() == 'auto') return null;
    final idx = int.tryParse(sel);
    if (idx != null) return all.where((n) => n.index == idx).firstOrNull;
    final lower = sel.toLowerCase();
    return all.where((n) => n.name.toLowerCase() == lower).firstOrNull ??
        all.where((n) => n.name.toLowerCase().contains(lower)).firstOrNull;
  }
}

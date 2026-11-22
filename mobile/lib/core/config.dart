import 'dart:convert';
import 'dart:io';

import 'node.dart';
import 'settings.dart';
import 'xray.dart';

/// Where the phone build differs from the Windows one.
enum MobileOs { android, ios }

/// The node group the tunnel uses: who goes first and how sticky the choice is.
class NodePlan {
  NodePlan(this.nodes, this.tolerance, {required this.pinned, this.group = 0});

  /// Candidates in order of preference. sing-box's urltest keeps the first working one
  /// unless another one is faster by more than [tolerance] ms.
  final List<Node> nodes;
  final int tolerance;
  final bool pinned;

  /// The subscription the candidates come from: 0 = main, 1.. = backup (see [Node.group]).
  final int group;

  /// Subscription groups that have at least one usable node, in order (main first).
  static List<int> groups(List<Node> all) => (all.where((n) => n.supported).map((n) => n.group).toSet().toList())..sort();

  /// Builds the plan from the settings: a pinned node (plus a spare), or the "auto" pool with the last good node first.
  /// "auto" takes one subscription at a time: the first one with usable nodes, or [group] when the caller falls back
  /// to a backup subscription because none of the earlier ones answered.
  static NodePlan? make(Settings s, List<Node> all, {int? group}) {
    final pinned = group == null ? s.findPinned(all) : null;
    if (pinned != null && pinned.supported) {
      final list = [pinned];
      if (s.nodeFallback) {
        final spare = s.autoPool(all.where((n) => n.group == pinned.group).toList()).where((n) => n.index != pinned.index).firstOrNull;
        if (spare != null) list.add(spare);
      }
      // a spare takes over only while the pinned node does not answer at all
      return NodePlan(list, 60000, pinned: true, group: pinned.group);
    }
    for (final g in group == null ? groups(all) : [group]) {
      final pool = s.autoPool(all.where((n) => n.group == g).toList());
      if (pool.isEmpty) continue;
      final last = pool.where((n) => n.name == s.lastGoodNode).firstOrNull;
      final ordered = [?last, ...pool.where((n) => n != last)];
      // keep the node that works unless another one is much faster: a voice call is a new flow and must not hop
      return NodePlan(ordered, 300, pinned: false, group: g);
    }
    return null;
  }
}

/// Builds the sing-box config (TUN, routing rules, DNS, Clash API) and the rule-set files it watches.
/// Port of Core/SingBoxConfig.cs of the Windows app; the phone has only sing-box, so the VLESS outbounds live here too.
class SingBoxConfig {
  static const userRuleSets = ['apps-direct', 'apps-proxy', 'direct-domains', 'direct-ips', 'proxy-domains', 'proxy-ips'];
  static const geoRuleSets = ['geosite-ru-blocked', 'geosite-ru', 'geoip-ru'];
  static const probeUrl = 'https://www.gstatic.com/generate_204';

  /// Private and special ranges that never enter the tunnel (home router, printers, link-local, multicast).
  static const excludeRoutes = [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10',
    '224.0.0.0/4', '255.255.255.255/32', 'fc00::/7', 'fe80::/10', 'ff00::/8',
  ];

  // ------------------------------------------------------------------ rule-set files

  static Map<String, dynamic> _ruleSetFile(Map<String, dynamic>? rule) => {
        'version': 3,
        'rules': rule == null || rule.isEmpty ? [] : [rule],
      };

  /// Plain entry = the domain and its subdomains; prefixes full: keyword: regex:.
  static Map<String, dynamic> domainRule(Iterable<String> entries) {
    final dom = <String>[], suf = <String>[], kw = <String>[], rx = <String>[];
    for (final e in entries) {
      final v = e.trim();
      if (v.isEmpty) continue;
      var lower = v.toLowerCase();
      if (lower.startsWith('full:')) {
        dom.add(lower.substring(5));
      } else if (lower.startsWith('keyword:')) {
        kw.add(lower.substring(8));
      } else if (lower.startsWith('regex:')) {
        rx.add(v.substring(6));
      } else {
        while (lower.startsWith('.')) {
          lower = lower.substring(1);
        }
        dom.add(lower);
        suf.add('.$lower');
      }
    }
    return {
      if (dom.isNotEmpty) 'domain': dom,
      if (suf.isNotEmpty) 'domain_suffix': suf,
      if (kw.isNotEmpty) 'domain_keyword': kw,
      if (rx.isNotEmpty) 'domain_regex': rx,
    };
  }

  static Map<String, dynamic>? _packages(Iterable<String> names) {
    final list = names.where((n) => n.trim().isNotEmpty).toSet().toList();
    return list.isEmpty ? null : {'package_name': list};
  }

  /// The contents of the small user rule-sets (file name without .json -> JSON text).
  static Map<String, String> userRuleSetFiles(Settings s) {
    final sets = <String, Map<String, dynamic>?>{
      'apps-direct': _packages(s.apps.where((a) => !a.vpn).expand((a) => a.packages)),
      'apps-proxy': _packages(s.apps.where((a) => a.vpn).expand((a) => a.packages)),
      'direct-domains': domainRule(s.directDomains),
      'proxy-domains': domainRule(s.proxyDomains),
      'direct-ips': s.directIps.isEmpty ? null : {'ip_cidr': s.directIps},
      'proxy-ips': s.proxyIps.isEmpty ? null : {'ip_cidr': s.proxyIps},
    };
    return sets.map((k, v) => MapEntry(k, jsonEncode(_ruleSetFile(v))));
  }

  /// Rewrites the user rule-sets; sing-box picks the changes up without a restart. Returns true when a file changed.
  static bool writeUserRuleSets(Settings s, String rulesDir) {
    Directory(rulesDir).createSync(recursive: true);
    var changed = false;
    for (final e in userRuleSetFiles(s).entries) {
      final f = File('$rulesDir/${e.key}.json');
      if (f.existsSync() && f.readAsStringSync() == e.value) continue;
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(e.value, flush: true);
      tmp.renameSync(f.path);
      changed = true;
    }
    return changed;
  }

  // ------------------------------------------------------------------ VLESS outbound

  static Map<String, dynamic>? outbound(Node n) {
    if (!n.supported) return null;
    if (n.viaXray) {
      // XHTTP and friends: the bundled Xray listens for this node on its own local SOCKS port
      return {'type': 'socks', 'tag': n.tag, 'server': '127.0.0.1', 'server_port': XrayConfig.portOf(n), 'version': '5'};
    }
    final o = <String, dynamic>{
      'type': 'vless',
      'tag': n.tag,
      'server': n.address,
      'server_port': n.port,
      'uuid': n.id,
      'packet_encoding': 'xudp',
    };
    if (n.q('flow').isNotEmpty) o['flow'] = n.q('flow');

    final sec = n.security;
    final fp = n.q('fp').toLowerCase();
    if (sec == 'reality') {
      o['tls'] = {
        'enabled': true,
        'server_name': n.q('sni'),
        'utls': {'enabled': true, 'fingerprint': fp.isEmpty ? 'chrome' : fp},
        'reality': {'enabled': true, 'public_key': n.q('pbk'), 'short_id': n.q('sid')},
      };
    } else if (sec == 'tls') {
      final tls = <String, dynamic>{'enabled': true};
      final sni = n.q('sni').isNotEmpty ? n.q('sni') : n.q('host');
      if (sni.isNotEmpty) tls['server_name'] = sni;
      if (n.q('alpn').isNotEmpty) tls['alpn'] = n.q('alpn').split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
      if (n.q('allowinsecure') == '1' || n.q('insecure') == '1') tls['insecure'] = true;
      if (fp.isNotEmpty) tls['utls'] = {'enabled': true, 'fingerprint': fp};
      o['tls'] = tls;
    }

    switch (n.network) {
      case 'ws':
        var path = n.q('path').isEmpty ? '/' : n.q('path');
        final t = <String, dynamic>{'type': 'ws'};
        // "?ed=2048" in the path is Xray's early-data hint; sing-box has its own fields for it
        final ed = RegExp(r'[?&]ed=(\d+)').firstMatch(path);
        if (ed != null) {
          path = path.replaceFirst(RegExp(r'[?&]ed=\d+'), '');
          t['max_early_data'] = int.parse(ed.group(1)!);
          t['early_data_header_name'] = 'Sec-WebSocket-Protocol';
        }
        t['path'] = path;
        if (n.q('host').isNotEmpty) t['headers'] = {'Host': n.q('host')};
        o['transport'] = t;
      case 'grpc':
        o['transport'] = {'type': 'grpc', 'service_name': n.q('servicename')};
      case 'httpupgrade':
        o['transport'] = {
          'type': 'httpupgrade',
          if (n.q('host').isNotEmpty) 'host': n.q('host'),
          'path': n.q('path').isEmpty ? '/' : n.q('path'),
        };
      case 'http':
      case 'h2':
        o['transport'] = {
          'type': 'http',
          if (n.q('host').isNotEmpty) 'host': n.q('host').split(','),
          'path': n.q('path').isEmpty ? '/' : n.q('path'),
        };
    }
    return o;
  }

  // ------------------------------------------------------------------ node check without the tunnel

  /// A sing-box with only the nodes and the Clash API, for "Проверить" while the VPN is off: no TUN, so no VPN icon
  /// and no change for other apps; the requests leave the phone the same way the tunnel's would. [apiPort] is not the
  /// tunnel's, so a leftover check can never be taken for a running tunnel.
  static Map<String, dynamic> buildProbe(Settings s, List<Node> all, {required String dataDir, required int apiPort}) {
    final xray = all.any((n) => n.supported && n.viaXray);
    return {
      'log': {'level': 'warn', 'output': '$dataDir/probe.log', 'timestamp': true},
      'dns': {
        'servers': [
          {'type': 'local', 'tag': 'dns-direct'},
        ],
        'final': 'dns-direct',
        'strategy': 'ipv4_only',
      },
      'inbounds': [
        if (xray) {'type': 'mixed', 'tag': 'xray-in', 'listen': '127.0.0.1', 'listen_port': XrayConfig.dialerPort},
      ],
      'outbounds': [
        ...all.map(outbound).whereType<Map<String, dynamic>>(),
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'direct', 'default_domain_resolver': 'dns-direct'},
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:$apiPort', 'secret': s.apiSecret},
      },
    };
  }

  // ------------------------------------------------------------------ main config

  static void _addRoute(List<Object> list, Map<String, dynamic> match, String target, bool blockQuic) {
    if (target == 'proxy' && blockQuic) list.add({...match, 'protocol': 'quic', 'action': 'reject'});
    list.add({...match, 'outbound': target});
  }

  static Map<String, dynamic> _ruleSet(List<String> tags) => {'rule_set': tags};

  /// [dataDir] holds rules/ and sing-box.log; on iOS it is the app group folder shared with the tunnel.
  static Map<String, dynamic> build(Settings s, List<Node> all, NodePlan plan, {required String dataDir, required MobileOs os}) {
    final rulesDir = '$dataDir/rules';
    final def = s.defaultRoute == 'direct' ? 'direct' : 'proxy';
    final order = def == 'proxy' ? ['proxy', 'direct'] : ['direct', 'proxy'];
    final q = s.blockQuicOnProxy;
    final geo = s.ruDirect;

    final xray = all.any((n) => n.supported && n.viaXray);
    final rules = <Object>[
      // Xray's own connections to the servers: straight out, past the tunnel and every other rule
      if (xray) {'inbound': ['xray-in'], 'outbound': 'direct'},
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];
    if (os == MobileOs.android) {
      _addRoute(rules, _ruleSet(['apps-direct']), 'direct', q);
      _addRoute(rules, _ruleSet(['apps-proxy']), 'proxy', q);
    }
    for (final t in order) {
      _addRoute(rules, _ruleSet(['$t-domains', '$t-ips']), t, q);
    }
    if (geo) {
      _addRoute(rules, _ruleSet(['geosite-ru-blocked']), 'proxy', q);
      _addRoute(rules, _ruleSet(['geosite-ru', 'geoip-ru']), 'direct', false);
    }
    if (def == 'proxy' && q) rules.add({'protocol': 'quic', 'action': 'reject'});

    final dnsRules = <Object>[
      for (final t in order) {..._ruleSet(['$t-domains']), 'server': 'dns-$t'},
      if (geo) {..._ruleSet(['geosite-ru-blocked']), 'server': 'dns-proxy'},
      if (geo) {..._ruleSet(['geosite-ru']), 'server': 'dns-direct'},
    ];
    final dns = {
      'servers': [
        {'type': 'https', 'tag': 'dns-proxy', 'server': s.dnsProxy.isEmpty ? '1.1.1.1' : s.dnsProxy, 'detour': 'proxy'},
        {'type': 'local', 'tag': 'dns-direct'},
      ],
      'rules': dnsRules,
      'final': 'dns-$def',
      'strategy': 'ipv4_only',
    };

    final ruleSets = <Object>[
      for (final tag in userRuleSets)
        if (os == MobileOs.android || !tag.startsWith('apps-'))
          {'type': 'local', 'tag': tag, 'format': 'source', 'path': '$rulesDir/$tag.json'},
      if (geo)
        for (final tag in geoRuleSets) {'type': 'local', 'tag': tag, 'format': 'binary', 'path': '$rulesDir/$tag.srs'},
    ];

    final nodeOuts = all.map(outbound).whereType<Map<String, dynamic>>().toList();
    final group = {
      'type': 'urltest',
      'tag': 'proxy',
      'outbounds': plan.nodes.map((n) => n.tag).toList(),
      'url': probeUrl,
      'interval': '3m',
      'tolerance': plan.tolerance,
      'idle_timeout': '30m',
      'interrupt_exist_connections': false,
    };

    final tun = {
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': os == MobileOs.android ? 9000 : 4064,
      'auto_route': true,
      'strict_route': true,
      'stack': 'mixed',
      'route_exclude_address': excludeRoutes,
    };

    return {
      'log': {'level': s.logLevel.isEmpty ? 'warn' : s.logLevel, 'output': '$dataDir/sing-box.log', 'timestamp': true},
      'dns': dns,
      'inbounds': [
        tun,
        if (xray) {'type': 'mixed', 'tag': 'xray-in', 'listen': '127.0.0.1', 'listen_port': XrayConfig.dialerPort},
      ],
      'outbounds': [
        group,
        ...nodeOuts,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': rules,
        'rule_set': ruleSets,
        'final': def,
        'auto_detect_interface': true,
        'default_domain_resolver': 'dns-direct',
        if (os == MobileOs.android) 'find_process': true,
      },
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:${s.apiPort}', 'secret': s.apiSecret},
      },
    };
  }
}

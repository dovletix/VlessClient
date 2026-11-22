import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vlessclient/core/config.dart';
import 'package:vlessclient/core/engine.dart';
import 'package:vlessclient/core/node.dart';
import 'package:vlessclient/core/settings.dart';
import 'package:vlessclient/core/traffic.dart';
import 'package:vlessclient/core/xray.dart';

// Made-up servers (documentation addresses, random keys): never real ones in this public repository.
const reality = 'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp&security=reality&flow=xtls-rprx-vision'
    '&fp=firefox&sni=www.example.com&pbk=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg&sid=0123abcd#Server%20One';
const xhttp = 'vless://11111111-2222-3333-4444-555555555555@203.0.113.11:8443?type=xhttp&security=reality&fp=chrome'
    '&sni=www.example.com&pbk=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg&sid=01#Relay%20Two';
const ws = 'vless://11111111-2222-3333-4444-555555555555@cdn.example.org:443?type=ws&security=tls&host=cdn.example.org'
    '&path=%2Fws%3Fed%3D2048&sni=cdn.example.org&alpn=h2,http/1.1#Three';

void main() {
  group('subscription', () {
    test('plain and base64 lists', () {
      final plain = '$reality\n$xhttp\n# comment\n$ws';
      expect(Subscription.parseAll(Subscription.decode(plain)).length, 3);
      final b64 = base64.encode(utf8.encode(plain));
      final nodes = Subscription.parseAll(Subscription.decode(b64));
      expect(nodes.map((n) => n.name), ['Server One', 'Relay Two', 'Three']);
      expect(nodes.map((n) => n.index), [1, 2, 3]);
      expect(Subscription.decode('not a subscription'), isNull);
    });

    test('unsupported transports are marked', () {
      final nodes = Subscription.parseAll('$reality\n$xhttp');
      expect(nodes[0].supported, isTrue);
      expect(nodes[1].supported, isFalse);
      expect(nodes[1].unsupportedReason, contains('xhttp'));
      expect(SingBoxConfig.outbound(nodes[1]), isNull);
    });
  });

  group('outbound', () {
    test('reality + vision', () {
      final o = SingBoxConfig.outbound(Node.parse(reality, 1)!)!;
      expect(o['type'], 'vless');
      expect(o['server'], '203.0.113.10');
      expect(o['server_port'], 443);
      expect(o['flow'], 'xtls-rprx-vision');
      final tls = o['tls'] as Map;
      expect(tls['server_name'], 'www.example.com');
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
      expect((tls['reality'] as Map)['public_key'], 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg');
      expect((tls['reality'] as Map)['short_id'], '0123abcd');
      expect(o.containsKey('transport'), isFalse);
    });

    test('websocket with early data', () {
      final o = SingBoxConfig.outbound(Node.parse(ws, 3)!)!;
      final t = o['transport'] as Map;
      expect(t['type'], 'ws');
      expect(t['path'], '/ws');
      expect(t['max_early_data'], 2048);
      expect((t['headers'] as Map)['Host'], 'cdn.example.org');
      expect((o['tls'] as Map)['alpn'], ['h2', 'http/1.1']);
    });
  });

  group('node plan', () {
    final nodes = Subscription.parseAll('$reality\n$xhttp\n$ws');

    test('auto keeps the last good node first and skips unsupported ones', () {
      final s = Settings()..lastGoodNode = 'Three';
      final plan = NodePlan.make(s, nodes)!;
      expect(plan.pinned, isFalse);
      expect(plan.nodes.map((n) => n.name), ['Three', 'Server One']);
      expect(plan.tolerance, lessThan(1000));
    });

    test('auto_exclude', () {
      final s = Settings()..autoExclude = 'one';
      expect(NodePlan.make(s, nodes)!.nodes.map((n) => n.name), ['Three']);
    });

    test('pinned node gets a spare that only takes over when it is dead', () {
      final s = Settings()..node = '3';
      final plan = NodePlan.make(s, nodes)!;
      expect(plan.pinned, isTrue);
      expect(plan.nodes.map((n) => n.index), [3, 1]);
      expect(plan.tolerance, greaterThan(10000));
      s.nodeFallback = false;
      expect(NodePlan.make(s, nodes)!.nodes.length, 1);
    });
  });

  group('config', () {
    final nodes = Subscription.parseAll('$reality\n$xhttp\n$ws');

    test('android config', () {
      final s = Settings()..apiSecret = 'x';
      s.setApp('Bank', ['ru.bank.app'], false);
      final c = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: '/data/x', os: MobileOs.android);
      final route = c['route'] as Map;
      expect(route['find_process'], isTrue);
      expect(route['final'], 'proxy');
      final rules = (route['rules'] as List).cast<Map>();
      expect(rules.any((r) => (r['rule_set'] as List?)?.contains('apps-direct') == true && r['outbound'] == 'direct'), isTrue);
      final outs = (c['outbounds'] as List).cast<Map>();
      expect(outs.first['type'], 'urltest');
      expect(outs.where((o) => o['type'] == 'vless').length, 2);
      final sets = (route['rule_set'] as List).cast<Map>();
      expect(sets.firstWhere((r) => r['tag'] == 'geoip-ru')['path'], '/data/x/rules/geoip-ru.srs');
      // the result must be valid JSON for sing-box
      expect(jsonDecode(jsonEncode(c)), isA<Map>());
    });

    test('ios config has no app rules and no process lookup', () {
      final s = Settings()
        ..apiSecret = 'x'
        ..defaultRoute = 'direct'
        ..ruDirect = false;
      final c = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: '/g', os: MobileOs.ios);
      final route = c['route'] as Map;
      expect(route.containsKey('find_process'), isFalse);
      expect(route['final'], 'direct');
      expect(jsonEncode(c).contains('apps-'), isFalse);
      expect(jsonEncode(c).contains('geoip-ru'), isFalse);
      expect((c['dns'] as Map)['final'], 'dns-direct');
    });

    test('user rule-sets', () {
      final s = Settings()
        ..directDomains = ['gosuslugi.ru', 'full:exact.example', 'keyword:bank', 'regex:^a.*b\$']
        ..proxyIps = ['198.51.100.0/24'];
      s.setApp('Game', ['com.game'], true);
      final f = SingBoxConfig.userRuleSetFiles(s);
      final dd = (jsonDecode(f['direct-domains']!)['rules'] as List).first as Map;
      expect(dd['domain'], ['gosuslugi.ru', 'exact.example']);
      expect(dd['domain_suffix'], ['.gosuslugi.ru']);
      expect(dd['domain_keyword'], ['bank']);
      expect(dd['domain_regex'], [r'^a.*b$']);
      expect((jsonDecode(f['proxy-ips']!)['rules'] as List).first, {'ip_cidr': ['198.51.100.0/24']});
      expect((jsonDecode(f['apps-proxy']!)['rules'] as List).first, {'package_name': ['com.game']});
      expect(jsonDecode(f['apps-direct']!)['rules'], isEmpty);
    });
  });

  group('xray', () {
    tearDown(() => Node.xrayAvailable = false);

    test('xhttp and reality nodes go through the bundled Xray when it is there', () {
      final nodes = Subscription.parseAll('$reality\n$xhttp\n$ws');
      expect(nodes[1].viaXray, isFalse);
      expect(nodes[0].supported, isTrue, reason: 'without Xray sing-box carries tcp+reality itself');
      Node.xrayAvailable = true;
      expect(nodes[0].viaXray, isTrue, reason: 'Xray servers since 26.9.8 refuse the Reality handshake of sing-box');
      expect(nodes[1].viaXray, isTrue);
      expect(nodes[1].supported, isTrue);
      expect(nodes[2].viaXray, isFalse, reason: 'ws+tls stays with sing-box');

      final s = Settings()..apiSecret = 'x';
      final c = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: '/d', os: MobileOs.android);
      final outs = (c['outbounds'] as List).cast<Map>();
      final relay = outs.firstWhere((o) => o['tag'] == 'node-02');
      expect(relay['type'], 'socks');
      expect(relay['server_port'], XrayConfig.basePort + 2);
      expect(outs.firstWhere((o) => o['tag'] == 'node-03')['type'], 'vless');
      expect(((c['outbounds'] as List).first as Map)['outbounds'], ['node-01', 'node-02', 'node-03']);
      final rules = ((c['route'] as Map)['rules'] as List).cast<Map>();
      expect(rules.first, {'inbound': ['xray-in'], 'outbound': 'direct'});
      expect((c['inbounds'] as List).any((i) => (i as Map)['tag'] == 'xray-in'), isTrue);

      final x = XrayConfig.build(nodes, '/d/xray.log')!;
      final ins = (x['inbounds'] as List).cast<Map>();
      expect(ins.map((i) => i['port']), [XrayConfig.basePort + 1, XrayConfig.basePort + 2]);
      final vless = (x['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'node-02');
      final stream = vless['streamSettings'] as Map;
      expect(stream['network'], 'xhttp');
      expect(stream['security'], 'reality');
      expect((stream['sockopt'] as Map)['dialerProxy'], 'via-singbox');
      final vision = (x['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'node-01');
      expect((((vision['settings'] as Map)['vnext'] as List).first as Map)['users'], [
        {'id': '11111111-2222-3333-4444-555555555555', 'encryption': 'none', 'flow': 'xtls-rprx-vision'},
      ]);
      expect((vision['streamSettings'] as Map)['network'], 'raw');
      expect(jsonDecode(jsonEncode(x)), isA<Map>());
    });

    test('the node check without the tunnel has no TUN and its own API port', () {
      Node.xrayAvailable = true;
      final nodes = Subscription.parseAll('$reality\n$xhttp');
      final s = Settings()..apiSecret = 'x';
      final c = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: '/d', os: MobileOs.android);
      final p = SingBoxConfig.buildProbe(s, nodes, dataDir: '/d', apiPort: s.apiPort + 1);
      final ins = (p['inbounds'] as List).cast<Map>();
      expect(ins.map((i) => i['type']), ['mixed'], reason: 'only the inbound for the bundled Xray, no tun');
      expect(ins.single['listen_port'], XrayConfig.dialerPort);
      final tags = (p['outbounds'] as List).cast<Map>().map((o) => o['tag']).toList();
      expect(tags, ['node-01', 'node-02', 'direct']);
      // the same outbounds as the tunnel uses, so the check measures what the tunnel would get
      final tunnelOuts = (c['outbounds'] as List).cast<Map>().where((o) => (o['tag'] as String).startsWith('node-'));
      expect(jsonEncode((p['outbounds'] as List).take(2).toList()), jsonEncode(tunnelOuts.toList()));
      expect(((p['experimental'] as Map)['clash_api'] as Map)['external_controller'], '127.0.0.1:${s.apiPort + 1}');
      expect((p['route'] as Map)['final'], 'direct');
      expect(jsonEncode(p).contains('tun'), isFalse);
    });

    test('no Xray config and no xray-in inbound without such nodes', () {
      Node.xrayAvailable = true;
      final nodes = Subscription.parseAll(ws);
      expect(XrayConfig.build(nodes, '/d/xray.log'), isNull);
      final s = Settings()..apiSecret = 'x';
      final c = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: '/d', os: MobileOs.android);
      expect(jsonEncode(c).contains('xray-in'), isFalse);
    });
  });

  group('backup subscriptions', () {
    // a backup that mirrors the main subscription (same links, other names) plus one server of its own
    const other = 'vless://11111111-2222-3333-4444-555555555555@198.51.100.7:443?type=tcp&security=reality&flow=xtls-rprx-vision'
        '&fp=chrome&sni=www.example.net&pbk=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg&sid=02#Other%20provider';

    List<Node> load() {
      final seen = <String>{};
      final main = Subscription.parseAll('$reality\n$ws', seen: seen);
      // the mirror renames the server and (like 3x-ui) hands out another short id: still the same server
      final backup = Subscription.parseAll('${reality.split('#').first.replaceFirst('sid=0123abcd', 'sid=ffff')}#Same%20server%20renamed\n$other',
          start: main.length + 1, group: 1, seen: seen);
      return [...main, ...backup];
    }

    test('backup servers are numbered on and duplicates of the main list are skipped', () {
      final all = load();
      expect(all.map((n) => '${n.index}:${n.group}:${n.name}'), ['1:0:Server One', '2:0:Three', '3:1:Other provider']);
      expect(all.map((n) => n.tag).toSet().length, 3, reason: 'tags stay unique across subscriptions');
    });

    test('auto uses the main subscription first and a backup only when asked to fall back', () {
      final all = load();
      final s = Settings();
      expect(NodePlan.groups(all), [0, 1]);
      final plan = NodePlan.make(s, all)!;
      expect(plan.group, 0);
      expect(plan.nodes.map((n) => n.index), [1, 2]);
      final alt = NodePlan.make(s, all, group: 1)!;
      expect(alt.group, 1);
      expect(alt.nodes.map((n) => n.name), ['Other provider']);
      // without usable main servers (e.g. the main list never downloaded) the first backup is the plan
      expect(NodePlan.make(s, all.where((n) => n.group == 1).toList())!.group, 1);
    });

    test('a pinned backup server gets its spare from the same subscription', () {
      final all = [...load(), Node.parse(other.replaceFirst('198.51.100.7', '198.51.100.8').replaceFirst('Other%20provider', 'Other%202'), 4, group: 1)!];
      final s = Settings()..node = '3';
      final plan = NodePlan.make(s, all)!;
      expect(plan.pinned, isTrue);
      expect(plan.group, 1);
      expect(plan.nodes.map((n) => n.index), [3, 4]);
    });

    test('settings keep the backup links', () {
      final s = Settings()
        ..subscriptionUrl = 'https://example.com/sub/a'
        ..backups = [BackupSub('https://example.org/sub/a', insecure: true), BackupSub('https://example.net/s')];
      final r = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(r.backups.map((b) => '${b.url}|${b.insecure}|${b.host}'),
          ['https://example.org/sub/a|true|example.org', 'https://example.net/s|false|example.net']);
    });
  });

  group('settings', () {
    test('json round trip', () {
      final s = Settings()
        ..subscriptionUrl = 'https://sub.example/abc'
        ..node = '2'
        ..autoExclude = 'relay'
        ..ruDirect = false
        ..theme = 'light';
      s.setApp('A', ['a.b'], true);
      final t = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(t.subscriptionUrl, s.subscriptionUrl);
      expect(t.node, '2');
      expect(t.autoExclude, 'relay');
      expect(t.ruDirect, isFalse);
      expect(t.theme, 'light');
      expect(t.apps.single.packages, ['a.b']);
    });

    test('a package belongs to one rule only', () {
      final s = Settings();
      s.setApp('A', ['x', 'y'], true);
      s.setApp('B', ['y'], false);
      expect(s.ruleFor('y')!.name, 'B');
      expect(s.ruleFor('x')!.name, 'A');
      s.setApp('C', ['x'], false);
      expect(s.apps.map((a) => a.name), ['B', 'C']);
    });
  });

  group('sites', () {
    test('entries keep IP masks and drop link paths', () {
      expect(AppState.normalizeEntry('https://Example.com/path?q=1'), 'example.com');
      expect(AppState.normalizeEntry('1.2.3.0/24'), '1.2.3.0/24');
      expect(AppState.normalizeEntry('regex:^A/b'), 'regex:^A/b');
      expect(AppState.isIpEntry('1.2.3.4'), isTrue);
      expect(AppState.isIpEntry('example.com'), isFalse);
    });
  });

  group('traffic', () {
    test('package names from processPath', () {
      expect(TrafficMonitor.packageOf('org.telegram.messenger (org.telegram.messenger)'), 'org.telegram.messenger');
      expect(TrafficMonitor.packageOf('com.app (10123)'), 'com.app');
      expect(TrafficMonitor.packageOf('1000'), 'uid:1000');
      expect(TrafficMonitor.packageOf(''), '');
    });

    test('failure reasons', () {
      expect(TrafficMonitor.classify('dial tcp 1.2.3.4:443: i/o timeout'), 'timeout');
      expect(TrafficMonitor.classify('connect: connection refused'), 'refused');
      expect(TrafficMonitor.classify('lookup example.com: no such host'), 'dns');
    });

    test('formatting like the web UI', () {
      expect(Fmt.rate(100), '0');
      expect(Fmt.rate(12500), '100 Кбит/с');
      expect(Fmt.rate(1250000), '10,0 Мбит/с');
      expect(Fmt.bytes(512), '512 Б');
      expect(Fmt.bytes(1536), '1,5 КБ');
      expect(Fmt.bytes(50 * 1024 * 1024), '50 МБ');
    });
  });
}

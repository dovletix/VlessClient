import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vlessclient/core/config.dart';
import 'package:vlessclient/core/engine.dart';
import 'package:vlessclient/core/node.dart';
import 'package:vlessclient/core/settings.dart';
import 'package:vlessclient/core/traffic.dart';

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

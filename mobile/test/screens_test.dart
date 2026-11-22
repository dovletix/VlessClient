// Renders every screen with sample data to PNG files (test/goldens/), for looking at the layout without a phone.
// Run: SCREENS=1 flutter test test/screens_test.dart --update-goldens   (PowerShell: $env:SCREENS=1)
// Skipped in normal runs and in CI.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlessclient/core/engine.dart';
import 'package:vlessclient/core/node.dart';
import 'package:vlessclient/core/settings.dart';
import 'package:vlessclient/core/traffic.dart';
import 'package:vlessclient/main.dart';

final _enabled = Platform.environment.containsKey('SCREENS');

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) l.addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
    }
    await l.load();
  }

  await load('Roboto', ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf', 'roboto-black.ttf']);
  await load('MaterialIcons', ['materialicons-regular.otf']);
  await load('monospace', ['robotocondensed-regular.ttf']);
}

ProcData _row(String key, {double down = 0, double up = 0, int fail = 0, int udp = 0, int p = 0, int d = 0}) {
  final r = ProcData(key)
    ..total = 40
    ..active = 6
    ..rDown = down
    ..rUp = up
    ..down = 80 << 20
    ..up = 6 << 20
    ..pBytes = p
    ..dBytes = d
    ..fail = fail
    ..udp = udp
    ..fProxy = fail
    ..proxyN = 30
    ..directN = 10
    ..nHosts = 14;
  r.hosts = [
    HostRec('rr3---sn-abc.googlevideo.com', 'proxy', 60 << 20, 2 << 20, 900000, 20000),
    HostRec('i.ytimg.com', 'proxy', 4 << 20, 1 << 20, 0, 0),
    HostRec('yandex.ru', 'direct', 2 << 20, 1 << 19, 0, 0),
  ];
  if (fail + udp > 0) {
    r.fails = [
      FailRec(time: '12:41:07', dest: '198.51.100.7:443', out: 'proxy', reason: 'no-answer', udp: false)..n = 3,
      FailRec(time: '12:40:55', dest: 'stun.example.org:3478', out: 'proxy', reason: 'no-answer', udp: true),
    ];
  }
  return r;
}

void main() {
  for (final platform in ['android', 'ios']) {
    testWidgets('screens $platform', skip: !_enabled, (tester) async {
      await _loadFonts();
      final dir = Directory.systemTemp.createTempSync('vc-$platform');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('vlessclient/vpn'), (call) async {
        switch (call.method) {
          case 'info':
            return {'platform': platform, 'dataDir': dir.path, 'version': '1.0.0', 'abi': 'arm64-v8a'};
          case 'status':
            return {'running': true, 'starting': false, 'error': ''};
          case 'apps':
            return [
              {'package': 'com.google.android.youtube', 'label': 'YouTube', 'system': false},
              {'package': 'org.telegram.messenger', 'label': 'Telegram', 'system': false},
              {'package': 'ru.sberbankmobile', 'label': 'СберБанк', 'system': false},
            ];
        }
        return null;
      });
      // the smallest common phone (320 x 640 dp), as on the CI emulator
      tester.view.physicalSize = const Size(720, 1440);
      tester.view.devicePixelRatio = 2.25;
      addTearDown(tester.view.reset);

      final app = AppState();
      await app.init();
      app.pause();
      app.nodes = Subscription.parseAll([
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp&security=reality&pbk=k&sid=1&sni=a.example#Нидерланды 1',
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.11:443?type=tcp&security=reality&pbk=k&sid=1&sni=a.example#Нидерланды 2',
        'vless://11111111-2222-3333-4444-555555555555@203.0.113.12:443?type=xhttp&security=reality&pbk=k&sid=1&sni=a.example#Через ретранслятор',
      ].join('\n'));
      app.nodes.add(Node.parse(
          'vless://11111111-2222-3333-4444-555555555555@198.51.100.20:443?type=tcp&security=reality&pbk=k&sid=1&sni=b.example#Другой сервис',
          4,
          group: 1)!);
      app.settings
        ..backups = [BackupSub('https://mirror.example.net/sub/abc')]
        ..subscriptionUrl = 'https://sub.example.org/abc'
        ..directDomains = ['gosuslugi.ru', 'sberbank.ru']
        ..proxyDomains = ['youtube.com']
        ..directIps = ['198.51.100.0/24'];
      app.settings.setApp('Telegram', ['org.telegram.messenger'], true);
      app.settings.setApp('СберБанк', ['ru.sberbankmobile'], false);
      app.state = VpnState.on;
      app.since = DateTime.now().subtract(const Duration(minutes: 42));
      app.currentTag = 'node-01';
      app.delays = {'node-01': 182, 'node-02': 240};
      app.snapshot = TrafficSnapshot()
        ..apiOk = true
        ..rows = [
          _row(platform == 'android' ? 'com.google.android.youtube' : TrafficMonitor.unknown, down: 1200000, up: 30000, p: 70 << 20, d: 9 << 20),
          if (platform == 'android') _row('org.telegram.messenger', down: 20000, up: 4000, fail: 5, udp: 2, p: 12 << 20),
          if (platform == 'android') _row('ru.sberbankmobile', d: 3 << 20),
        ];

      await tester.pumpWidget(VlessClientApp(app: app));
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$platform-1-home.png'));

      Future<void> tab(String label, String name) async {
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$platform-$name.png'));
      }

      await tab(platform == 'android' ? 'Программы' : 'Трафик', '2-apps');
      final first = find.text(platform == 'android' ? 'YouTube' : 'Все приложения');
      await tester.ensureVisible(first.last);
      await tester.tap(first.last);
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$platform-2b-apps-open.png'));
      await tab('Сайты', '3-sites');
      await tab('Серверы', '4-servers');
      await tab('Настройки', '5-settings');
      await app.change((s) => s.theme = 'light');
      await tester.pump(const Duration(milliseconds: 300));
      await tab('VPN', '6-home-light');
      await tab(platform == 'android' ? 'Программы' : 'Трафик', '7-apps-light');
      app.pause();
    });
  }
}

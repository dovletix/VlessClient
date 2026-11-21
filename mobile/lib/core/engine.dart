import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/vpn.dart';
import 'clash_api.dart';
import 'config.dart';
import 'node.dart';
import 'settings.dart';
import 'traffic.dart';
import 'xray.dart';

enum VpnState { off, connecting, on, error, noSubscription }

class UpdateInfo {
  UpdateInfo(this.version, this.url, this.sha256, this.size);
  final String version, url, sha256;
  final int size;
}

/// Everything the screens show and do: subscription, node choice, the tunnel, rules, statistics.
/// The phone's counterpart of the Windows service's Engine.cs; the tunnel itself runs in native code.
class AppState extends ChangeNotifier {
  static const repo = 'dovletix/VlessClient';

  final Vpn vpn = Vpn();
  late Settings settings;
  List<Node> nodes = [];
  DateTime? subscriptionTime;

  VpnState state = VpnState.off;
  String message = '';
  String error = '';
  DateTime? since;
  String currentTag = '';
  Map<String, int?> delays = {};
  bool testing = false;
  bool geoAvailable = false;

  final TrafficMonitor monitor = TrafficMonitor();
  TrafficSnapshot snapshot = TrafficSnapshot();
  ClashApi? _api;

  bool _busy = false;
  bool _wantOn = false;
  DateTime _nextRetry = DateTime(2100);
  Timer? _timer;
  int _ticks = 0;
  bool _ready = false;

  UpdateInfo? update;
  String updateNote = '';
  bool updating = false;

  bool get ready => _ready;
  bool get isAndroid => vpn.os == MobileOs.android;
  String get dataDir => vpn.dataDir;
  String get _settingsPath => '$dataDir/settings.json';
  String get _subPath => '$dataDir/subscription.txt';
  String get rulesDir => '$dataDir/rules';
  String get logFile => '$dataDir/sing-box.log';
  ClashApi get api => _api ??= ClashApi(settings.apiPort, settings.apiSecret);

  Node? nodeByTag(String tag) => nodes.where((n) => n.tag == tag).firstOrNull;
  Node? get currentNode => nodeByTag(currentTag);

  Future<void> init() async {
    await vpn.init();
    Node.xrayAvailable = vpn.xray;
    Directory(dataDir).createSync(recursive: true);
    settings = Settings.load(_settingsPath);
    _saveSettings();
    _loadNodes();
    geoAvailable = await _installGeoRules();
    try {
      SingBoxConfig.writeUserRuleSets(settings, rulesDir);
    } catch (_) {}
    final st = await vpn.status();
    if (st.running) {
      _wantOn = true;
      state = VpnState.on;
      message = 'VPN включён';
      since = DateTime.now();
      currentTag = await api.selected();
    } else if (!settings.hasSubscription) {
      _set(VpnState.noSubscription, 'Нужна ссылка на подписку');
    } else {
      _set(VpnState.off, 'Нажмите на кнопку, чтобы включить');
    }
    _ready = true;
    notifyListeners();
    resume();
    if (!st.running && settings.autoConnect && settings.hasSubscription) unawaited(connect());
  }

  // ------------------------------------------------------------------ lifecycle

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    pause();
    _api?.close();
    super.dispose();
  }

  void _set(VpnState s, String msg, [String err = '']) {
    state = s;
    message = msg;
    error = err;
    if (s == VpnState.on) since ??= DateTime.now();
    if (s != VpnState.on) since = null;
    notifyListeners();
  }

  Future<void> _tick() async {
    _ticks++;
    if (_busy) return;
    try {
      final st = await vpn.status();
      if (st.running) {
        if (state != VpnState.on && state != VpnState.connecting) _set(VpnState.on, 'VPN включён');
        if (_ticks % 3 == 0) {
          final tag = await api.selected();
          if (tag.isNotEmpty && tag != currentTag) {
            currentTag = tag;
            final n = currentNode;
            if (n != null && settings.lastGoodNode != n.name) {
              settings.lastGoodNode = n.name;
              _saveSettings();
            }
          }
        }
        snapshot = await monitor.sample(api, logFile, settings.apps.expand((a) => a.packages).toSet());
        notifyListeners();
      } else {
        if (state == VpnState.on) {
          _wantOn = false;
          _set(VpnState.off, st.error.isNotEmpty ? 'VPN выключен: ${st.error}' : 'VPN выключен');
        }
        if (state == VpnState.error && _wantOn && DateTime.now().isAfter(_nextRetry)) unawaited(connect());
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------ files

  void _saveSettings() {
    try {
      settings.save(_settingsPath);
    } catch (_) {}
  }

  void _loadNodes() {
    final f = File(_subPath);
    if (f.existsSync()) {
      nodes = Subscription.parseAll(f.readAsStringSync());
      subscriptionTime = f.lastModifiedSync();
    } else {
      nodes = [];
      subscriptionTime = null;
    }
  }

  void _writeSubscription(String text) {
    File(_subPath).writeAsStringSync(text, flush: true);
    _loadNodes();
  }

  /// Copies the bundled Russian geo rule-sets (built in CI from the same Xray databases as the Windows app).
  Future<bool> _installGeoRules() async {
    try {
      Directory(rulesDir).createSync(recursive: true);
      final stamp = File('$rulesDir/geo.version');
      final want = '${vpn.version}|${SingBoxConfig.geoRuleSets.join(',')}';
      final present = SingBoxConfig.geoRuleSets.every((t) => File('$rulesDir/$t.srs').existsSync());
      if (present && stamp.existsSync() && stamp.readAsStringSync() == want) return true;
      for (final t in SingBoxConfig.geoRuleSets) {
        final data = await rootBundle.load('assets/rules/$t.srs');
        File('$rulesDir/$t.srs').writeAsBytesSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      stamp.writeAsStringSync(want);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ connect

  String _buildConfig(NodePlan plan) {
    final s = settings.clone();
    if (!geoAvailable) s.ruDirect = false;
    return jsonEncode(SingBoxConfig.build(s, nodes, plan, dataDir: dataDir, os: vpn.os));
  }

  void _fail(String text) {
    _nextRetry = DateTime.now().add(const Duration(seconds: 60));
    currentTag = '';
    _set(VpnState.error, text, text);
  }

  Future<void> connect() async {
    if (_busy) return;
    _busy = true;
    _wantOn = true;
    _nextRetry = DateTime(2100);
    try {
      if (!settings.hasSubscription) {
        _set(VpnState.noSubscription, 'Нужна ссылка на подписку');
        return;
      }
      final probe = _probeRun;
      if (probe != null) {
        _set(VpnState.connecting, 'Заканчиваю проверку серверов…');
        try {
          await probe;
        } catch (_) {}
      }
      _set(VpnState.connecting, 'Загружаю список серверов…');
      final stale = subscriptionTime == null || DateTime.now().difference(subscriptionTime!).inHours >= settings.updateHours;
      if (settings.canDownload && (nodes.isEmpty || stale)) {
        try {
          final body = await Subscription.fetch(settings.subscriptionUrl, insecure: settings.insecureTls, version: vpn.version);
          if (body != null) _writeSubscription(body);
        } catch (_) {}
      }
      if (nodes.isEmpty) {
        _fail('Не удалось загрузить список серверов: сервер подписки не отвечает. Возможно, ваш интернет-провайдер его не пропускает. '
            'Попросите того, кто выдал подписку, прислать сами серверы (строки vless://) и вставьте их в «Настройках».');
        return;
      }
      final plan = NodePlan.make(settings, nodes);
      if (plan == null) {
        _fail('Ни один сервер из подписки не работает на телефоне: ${nodes.first.unsupportedReason ?? ''}.');
        return;
      }
      SingBoxConfig.writeUserRuleSets(settings, rulesDir);
      final config = _buildConfig(plan);
      final xrayConfig = XrayConfig.build(nodes, '$dataDir/xray.log');
      final xray = xrayConfig == null ? '' : jsonEncode(xrayConfig);
      for (final f in [logFile, '$dataDir/xray.log']) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
      monitor.reset();

      _set(VpnState.connecting, 'Запускаю туннель…');
      final st = await vpn.status();
      if (st.running) {
        await vpn.reload(config, xray: xray);
      } else {
        await vpn.start(config, xray: xray);
      }
      var alive = false;
      for (var i = 0; i < 50 && !alive; i++) {
        alive = await api.alive();
        if (!alive) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!alive) {
        final st2 = await vpn.status();
        await vpn.stop();
        _fail('Туннель не запустился${st2.error.isNotEmpty ? ': ${st2.error}' : '.'}');
        return;
      }

      _set(VpnState.connecting, plan.pinned ? 'Проверяю сервер «${plan.nodes.first.name}»…' : 'Ищу самый быстрый сервер…');
      final results = await Future.wait(plan.nodes.map((n) => api.delay(n.tag)));
      for (var i = 0; i < plan.nodes.length; i++) {
        delays[plan.nodes[i].tag] = results[i];
      }
      if (results.every((r) => r == null)) {
        await vpn.stop();
        _fail('Ни один сервер не отвечает. Возможно, нет интернета или провайдер их блокирует. Попробую ещё раз через минуту.');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      var tag = await api.selected();
      if (nodeByTag(tag) == null) {
        final i = results.indexWhere((r) => r != null);
        tag = plan.nodes[i].tag;
      }
      currentTag = tag;
      settings.lastGoodNode = currentNode?.name ?? settings.lastGoodNode;
      _saveSettings();
      since = DateTime.now();
      _set(VpnState.on, 'VPN включён');
    } on PlatformException catch (e) {
      if (e.code == 'denied') {
        _wantOn = false;
        _set(VpnState.off, 'Без разрешения на VPN телефон не даст включить защиту. Нажмите на кнопку ещё раз и разрешите.');
      } else {
        _fail('Не удалось включить VPN: ${e.message ?? e.code}');
      }
    } catch (e) {
      _fail('Ошибка: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _wantOn = false;
    _nextRetry = DateTime(2100);
    try {
      await vpn.stop();
    } catch (_) {}
    currentTag = '';
    _set(settings.hasSubscription ? VpnState.off : VpnState.noSubscription,
        settings.hasSubscription ? 'VPN выключен' : 'Нужна ссылка на подписку');
  }

  Future<void> toggle() async {
    if (state == VpnState.on || state == VpnState.connecting) {
      await disconnect();
    } else {
      await connect();
    }
  }

  bool get running => state == VpnState.on;

  Future<void> _reconnectIfRunning() async {
    if ((await vpn.status()).running) await connect();
  }

  // ------------------------------------------------------------------ subscription

  /// A link (https://...) or the servers themselves (vless:// lines). Returns an error text or null.
  Future<String?> setSubscription(String input) async {
    final text = input.trim();
    if (text.toLowerCase().contains('vless://')) {
      final list = Subscription.decode(text);
      if (list == null || Subscription.parseAll(list).isEmpty) return 'Не нашёл ни одного сервера vless:// во вставленном тексте.';
      _writeSubscription(list);
      settings
        ..subscriptionUrl = ''
        ..inlineNodes = true
        ..lastGoodNode = '';
      _saveSettings();
      unawaited(connect());
      return null;
    }
    final u = Uri.tryParse(text);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
      return 'Это не похоже на ссылку подписки. Она должна начинаться с https://';
    }
    var insecure = false;
    String? body;
    try {
      body = await Subscription.fetch(text, version: vpn.version);
    } on HandshakeException {
      // many self-hosted panels use a self-signed certificate: retry once without checking it
      try {
        body = await Subscription.fetch(text, insecure: true, version: vpn.version);
        insecure = true;
      } catch (e) {
        return 'Не удалось загрузить подписку: ${_short(e)}';
      }
    } catch (e) {
      return 'Не удалось загрузить подписку: ${_short(e)}';
    }
    if (body == null) return 'По ссылке нет серверов VLESS.';
    _writeSubscription(body);
    settings
      ..subscriptionUrl = text
      ..inlineNodes = false
      ..insecureTls = insecure
      ..lastGoodNode = '';
    _saveSettings();
    unawaited(connect());
    return null;
  }

  Future<String?> refreshSubscription() async {
    if (!settings.hasSubscription) return 'Подписка не задана';
    if (!settings.canDownload) return 'Серверы были вставлены вручную, скачивать нечего. Чтобы обновить их, вставьте новые в «Изменить ссылку».';
    try {
      final body = await Subscription.fetch(settings.subscriptionUrl, insecure: settings.insecureTls, version: vpn.version);
      if (body == null) return 'По ссылке нет серверов VLESS.';
      final old = File(_subPath).existsSync() ? File(_subPath).readAsStringSync() : '';
      _writeSubscription(body);
      notifyListeners();
      if (old != body) await _reconnectIfRunning();
      return null;
    } catch (e) {
      return 'Не удалось обновить подписку: ${_short(e)}';
    }
  }

  static String _short(Object e) {
    var s = e.toString();
    s = s.replaceFirst(RegExp(r'^\w*Exception: ?'), '');
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  // ------------------------------------------------------------------ settings and rules

  /// Applies a settings change. Rules are hot-reloaded by sing-box; structural changes reconnect.
  Future<void> change(void Function(Settings s) fn, {bool reconnect = false}) async {
    fn(settings);
    _saveSettings();
    try {
      SingBoxConfig.writeUserRuleSets(settings, rulesDir);
    } catch (_) {}
    notifyListeners();
    if (reconnect) await _reconnectIfRunning();
  }

  /// sing-box needs up to ~100 ms to pick up a rule-set file; an app that reconnects sooner lands on the old route.
  Future<void> _afterRuleWrite(bool Function(Map<String, dynamic> c) affected) async {
    if (!running) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    try {
      for (final c in await api.connections()) {
        if (affected(c)) await api.closeConnection((c['id'] ?? '').toString());
      }
    } catch (_) {}
  }

  Future<void> setAppRoute(String name, List<String> packages, bool vpnRoute) async {
    await change((s) => s.setApp(name, packages, vpnRoute));
    final set = packages.toSet();
    await _afterRuleWrite((c) => set.contains(TrafficMonitor.packageOf(((c['metadata'] as Map?)?['processPath'] ?? '').toString())));
  }

  Future<void> removeApp(AppRule rule) async {
    await change((s) => s.removeApp(rule.name));
    final set = rule.packages.toSet();
    await _afterRuleWrite((c) => set.contains(TrafficMonitor.packageOf(((c['metadata'] as Map?)?['processPath'] ?? '').toString())));
  }

  static final RegExp _cidr = RegExp(r'^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$|^[0-9a-fA-F:]+:[0-9a-fA-F:]*(/\d{1,3})?$');

  /// A pasted link keeps only its host; an IP range keeps its "/24" mask.
  static String normalizeEntry(String value) {
    var v = value.trim();
    if (v.toLowerCase().startsWith('regex:')) return v;
    v = v.toLowerCase().replaceFirst(RegExp(r'^https?://'), '');
    if (!RegExp(r'^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$|^[0-9a-f:]+:[0-9a-f:]*/\d{1,3}$').hasMatch(v)) v = v.split('/')[0];
    return v;
  }

  static bool isIpEntry(String v) => _cidr.hasMatch(v);

  /// Adds a site or an address to the direct or the VPN list (and removes it from the other one).
  Future<String?> addSite(String raw, bool vpnRoute) async {
    final v = normalizeEntry(raw);
    if (v.isEmpty) return 'Введите адрес сайта, например example.com';
    final ip = isIpEntry(v);
    final entry = ip && !v.contains('/') ? (v.contains(':') ? '$v/128' : '$v/32') : v;
    await change((s) {
      for (final l in [s.directDomains, s.proxyDomains, s.directIps, s.proxyIps]) {
        l.remove(entry);
      }
      (ip ? (vpnRoute ? s.proxyIps : s.directIps) : (vpnRoute ? s.proxyDomains : s.directDomains)).add(entry);
    });
    await _afterRuleWrite((c) => _hostMatches(c, entry, ip));
    return null;
  }

  Future<void> removeSite(String entry) async {
    final ip = isIpEntry(entry);
    await change((s) {
      for (final l in [s.directDomains, s.proxyDomains, s.directIps, s.proxyIps]) {
        l.remove(entry);
      }
    });
    await _afterRuleWrite((c) => _hostMatches(c, entry, ip));
  }

  static bool _hostMatches(Map<String, dynamic> c, String entry, bool ip) {
    final m = (c['metadata'] as Map?) ?? {};
    if (ip) return _inCidr((m['destinationIP'] ?? '').toString(), entry);
    final host = (m['host'] ?? '').toString().toLowerCase();
    if (host.isEmpty) return false;
    var e = entry.toLowerCase();
    if (e.startsWith('full:')) return host == e.substring(5);
    if (e.startsWith('keyword:')) return host.contains(e.substring(8));
    if (e.startsWith('regex:')) {
      try {
        return RegExp(entry.substring(6)).hasMatch(host);
      } catch (_) {
        return false;
      }
    }
    while (e.startsWith('.')) {
      e = e.substring(1);
    }
    return host == e || host.endsWith('.$e');
  }

  static bool _inCidr(String ip, String cidr) {
    final a = InternetAddress.tryParse(ip);
    final parts = cidr.split('/');
    final b = InternetAddress.tryParse(parts[0]);
    if (a == null || b == null || a.type != b.type) return false;
    final bits = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : a.rawAddress.length * 8;
    final x = a.rawAddress, y = b.rawAddress;
    for (var i = 0; i < bits; i++) {
      final byte = i >> 3, mask = 0x80 >> (i & 7);
      if ((x[byte] & mask) != (y[byte] & mask)) return false;
    }
    return true;
  }

  // ------------------------------------------------------------------ nodes

  Future<void> selectNode(String value) => change((s) {
        s.node = value;
        if (value != 'auto') s.lastGoodNode = '';
      }, reconnect: true);

  /// Measures every supported node: through the running tunnel, or, while the VPN is off, through a separate
  /// sing-box with only the nodes (no tunnel: other apps are not affected and the phone shows no VPN).
  Future<String?> testNodes() async {
    if (testing) return null;
    final list = nodes.where((n) => n.supported).toList();
    if (list.isEmpty) return nodes.isEmpty ? 'Список серверов пуст.' : 'Ни один сервер из подписки не работает на этом телефоне.';
    if (_busy || state == VpnState.connecting) return 'Подождите, VPN включается.';
    testing = true;
    notifyListeners();
    final run = running ? _testThroughTunnel(list) : _testWithoutTunnel(list);
    if (!running) _probeRun = run;
    try {
      return await run;
    } finally {
      _probeRun = null;
      testing = false;
      notifyListeners();
    }
  }

  /// The check that runs without the tunnel; connect() waits for it (both use the same local ports).
  Future<String?>? _probeRun;
  DateTime? checkedAt;
  bool checkedWithoutTunnel = false;

  Future<String?> _testThroughTunnel(List<Node> list) async {
    final res = await Future.wait(list.map((n) => api.delay(n.tag)));
    _storeDelays(list, res, withoutTunnel: false);
    return null;
  }

  Future<String?> _testWithoutTunnel(List<Node> list) async {
    final probe = ClashApi(settings.apiPort + 1, settings.apiSecret);
    try {
      final config = jsonEncode(SingBoxConfig.buildProbe(settings, nodes, dataDir: dataDir, apiPort: probe.port));
      final x = XrayConfig.build(nodes, '$dataDir/xray-probe.log');
      for (final f in ['$dataDir/probe.log', '$dataDir/xray-probe.log']) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
      await vpn.probeStart(config, xray: x == null ? '' : jsonEncode(x));
      var alive = false;
      for (var i = 0; i < 50 && !alive; i++) {
        alive = await probe.alive();
        if (!alive) await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!alive) return 'Не удалось запустить проверку серверов.';
      // Xray starts next to sing-box; a request through a node of its own before it listens would count as dead
      final first = list.where((n) => n.viaXray).firstOrNull;
      if (first != null) await _waitPort(XrayConfig.portOf(first), const Duration(seconds: 5));
      final res = await Future.wait(list.map((n) => probe.delay(n.tag)));
      _storeDelays(list, res, withoutTunnel: true);
      return null;
    } on PlatformException catch (e) {
      return 'Не удалось проверить серверы: ${e.message ?? e.code}';
    } finally {
      try {
        await vpn.probeStop();
      } catch (_) {}
      probe.close();
    }
  }

  static Future<void> _waitPort(int port, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 300));
        s.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  void _storeDelays(List<Node> list, List<int?> res, {required bool withoutTunnel}) {
    for (var i = 0; i < list.length; i++) {
      delays[list[i].tag] = res[i];
    }
    checkedAt = DateTime.now();
    checkedWithoutTunnel = withoutTunnel;
    try {
      File('$dataDir/last-check.json').writeAsStringSync(jsonEncode({
        'time': checkedAt!.toIso8601String(),
        'tunnel': !withoutTunnel,
        'delays': {for (var i = 0; i < list.length; i++) list[i].tag: res[i]},
      }));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ updates (Android: GitHub releases)

  static int _cmp(String a, String b) {
    final x = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final y = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  Future<Object?> _getJson(String url) async {
    final client = HttpClient()
      ..userAgent = 'VlessClient/${vpn.version}'
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final text = await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
      if (resp.statusCode != 200) throw HttpException('GitHub ответил ${resp.statusCode}');
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> checkUpdate() async {
    updateNote = 'Проверяю…';
    update = null;
    notifyListeners();
    try {
      final list = await _getJson('https://api.github.com/repos/$repo/releases?per_page=30');
      UpdateInfo? best;
      for (final r in (list as List).whereType<Map>()) {
        final tag = (r['tag_name'] ?? '').toString();
        if (r['draft'] == true || r['prerelease'] == true || !tag.startsWith('mobile-v')) continue;
        final ver = tag.substring('mobile-v'.length);
        if (best != null && _cmp(ver, best.version) <= 0) continue;
        final assets = (r['assets'] as List? ?? []).whereType<Map>().where((a) => a['name'].toString().endsWith('.apk')).toList();
        Map? pick = assets.where((a) => vpn.abi.isNotEmpty && a['name'].toString().contains(vpn.abi)).firstOrNull;
        pick ??= assets.where((a) => a['name'].toString().contains('universal')).firstOrNull;
        if (pick == null) continue;
        final digest = (pick['digest'] ?? '').toString();
        if (!digest.startsWith('sha256:')) continue;
        best = UpdateInfo(ver, pick['browser_download_url'].toString(), digest.substring(7), (pick['size'] as num?)?.toInt() ?? 0);
      }
      if (best != null && _cmp(best.version, vpn.version) > 0) {
        update = best;
        updateNote = 'Доступна версия ${best.version}';
      } else {
        updateNote = 'У вас последняя версия.';
      }
    } catch (e) {
      updateNote = 'Не удалось проверить обновления: ${_short(e)}';
    }
    notifyListeners();
  }

  Future<void> installUpdate() async {
    final u = update;
    if (u == null || updating) return;
    updating = true;
    updateNote = 'Скачиваю обновление…';
    notifyListeners();
    final client = HttpClient()..userAgent = 'VlessClient/${vpn.version}';
    try {
      final path = '$dataDir/update.apk';
      final req = await client.getUrl(Uri.parse(u.url));
      final resp = await req.close();
      if (resp.statusCode != 200) throw HttpException('загрузка: код ${resp.statusCode}');
      final sink = File(path).openWrite();
      var got = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        got += chunk.length;
        if (u.size > 0 && got % (1 << 20) < chunk.length) {
          updateNote = 'Скачиваю обновление… ${(100 * got / u.size).round()}%';
          notifyListeners();
        }
      }
      await sink.close();
      updateNote = 'Открываю установку…';
      notifyListeners();
      await vpn.installApk(path, u.sha256);
      updateNote = 'Подтвердите установку в окне Android.';
    } catch (e) {
      updateNote = 'Не удалось обновить: ${e is PlatformException ? e.message : _short(e)}';
    } finally {
      client.close(force: true);
      updating = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ report

  String report() {
    final b = StringBuffer();
    final s = settings;
    b.writeln('VlessClient ${vpn.version} (${vpn.os.name}) ${DateTime.now()}');
    b.writeln('state: ${state.name}  message: $message  error: $error');
    b.writeln('node: ${currentNode?.index} ${currentNode?.name}');
    var host = '';
    try {
      host = Uri.parse(s.subscriptionUrl).host;
    } catch (_) {}
    b.writeln('subscription host: $host  inline: ${s.inlineNodes}  cached: $subscriptionTime  nodes: ${nodes.length}');
    b.writeln('default: ${s.defaultRoute}  node setting: ${s.node}  auto_exclude: ${s.autoExclude}  ru_direct: ${s.ruDirect} geo: $geoAvailable');
    b.writeln('apps: ${s.apps.map((a) => '${a.name}=${a.vpn ? 'vpn' : 'direct'}').join('; ')}');
    b.writeln('nodes: (checked ${checkedAt ?? '-'}${checkedAt == null ? '' : checkedWithoutTunnel ? ' without tunnel' : ' through tunnel'})');
    for (final n in nodes) {
      final d = delays[n.tag];
      b.writeln('  ${n.index.toString().padLeft(2)} ${n.name}  ${n.kind}${n.viaXray ? '  via xray' : ''}'
          '${n.supported ? '' : '  (${n.unsupportedReason})'}${d != null ? '  $d ms' : ''}');
    }
    b.writeln('--- sing-box.log ---');
    try {
      final lines = File(logFile).readAsLinesSync();
      for (final l in lines.skip(lines.length > 40 ? lines.length - 40 : 0)) {
        b.writeln(l);
      }
    } catch (_) {}
    return b.toString();
  }
}

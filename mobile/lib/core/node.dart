import 'dart:convert';
import 'dart:io';

/// One server from the subscription (a vless:// link). Port of Core/Subscription.cs of the Windows app.
class Node {
  Node({
    required this.index,
    required this.name,
    required this.id,
    required this.address,
    required this.port,
    required this.query,
    this.group = 0,
  });

  /// 0 = the main subscription, 1.. = backup subscription number (its servers are used when none of the main ones works).
  final int group;
  final int index;
  final String name;
  final String id;
  final String address;
  final int port;
  final Map<String, String> query;

  String get tag => 'node-${index.toString().padLeft(2, '0')}';

  String q(String key) => query[key.toLowerCase()] ?? '';

  String get network {
    final t = q('type');
    return t.isEmpty ? 'tcp' : t.toLowerCase();
  }

  String get security => q('security').toLowerCase();

  /// Short transport description, e.g. "tcp+reality".
  String get kind {
    var k = network;
    if (security.isNotEmpty) k += '+$security';
    if (q('encryption').isNotEmpty && q('encryption') != 'none') k += '+mlkem';
    return k;
  }

  /// True when the app ships Xray next to sing-box (Android arm64 / x86_64): it carries what sing-box cannot.
  /// Set once at start from the native side.
  static bool xrayAvailable = false;

  /// Why sing-box itself cannot use this node (null when it can).
  String? get singboxReason {
    const transports = {'tcp', 'raw', 'ws', 'grpc', 'httpupgrade', 'http', 'h2'};
    if (!transports.contains(network)) return 'тип соединения $network';
    if (q('encryption').isNotEmpty && q('encryption') != 'none') return 'шифрование VLESS (mlkem)';
    if (security.isNotEmpty && security != 'none' && security != 'tls' && security != 'reality') return 'защита $security';
    return null;
  }

  /// Transports Xray understands (everything a VLESS link of 3x-ui can describe).
  bool get _xrayCan {
    const transports = {'tcp', 'raw', 'ws', 'grpc', 'httpupgrade', 'http', 'h2', 'xhttp', 'splithttp', 'kcp', 'mkcp'};
    return transports.contains(network) && (security.isEmpty || security == 'none' || security == 'tls' || security == 'reality');
  }

  /// This node goes through the bundled Xray (sing-box connects to it over a local SOCKS port): what sing-box cannot
  /// carry, and every Reality node. Xray servers since v26.9.8 refuse sing-box's Reality handshake (it sends no
  /// X25519MLKEM768 key share, SagerNet/sing-box#4520), and 3x-ui panels update their Xray by themselves.
  bool get viaXray => xrayAvailable && _xrayCan && (singboxReason != null || security == 'reality');

  /// Why the phone cannot use this node at all; null when it can.
  String? get unsupportedReason {
    if (security == 'reality' && q('pbk').isEmpty) return 'в ссылке нет ключа Reality (pbk)';
    final r = singboxReason;
    if (r == null || viaXray) return null;
    return '$r на этом телефоне не поддерживается';
  }

  bool get supported => unsupportedReason == null;

  static final RegExp _link = RegExp(r'^vless://([^@]+)@(\[[^\]]+\]|[^:/?#]+):(\d+)/?\??([^#]*)#?(.*)$', caseSensitive: false);

  static String _unescape(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static Node? parse(String line, int index, {int group = 0}) {
    final m = _link.firstMatch(line.trim());
    if (m == null) return null;
    final port = int.tryParse(m.group(3)!);
    if (port == null || port <= 0 || port > 65535) return null;
    final query = <String, String>{};
    for (final kv in m.group(4)!.split('&')) {
      if (kv.isEmpty) continue;
      final i = kv.indexOf('=');
      if (i < 0) {
        query[kv.toLowerCase()] = '';
      } else {
        query[kv.substring(0, i).toLowerCase()] = _unescape(kv.substring(i + 1));
      }
    }
    var name = _unescape(m.group(5)!.replaceAll('+', '%20')).trim();
    if (name.isEmpty) name = 'Сервер $index';
    var address = m.group(2)!;
    if (address.startsWith('[')) address = address.substring(1, address.length - 1);
    return Node(index: index, name: name, id: _unescape(m.group(1)!), address: address, port: port, query: query, group: group);
  }
}

class Subscription {
  /// Accepts a plain list of links or a base64 blob; returns only vless:// lines (null when there are none).
  static String? decode(String body) {
    var text = body.trim();
    if (!text.contains('://')) {
      try {
        var b = text.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
        while (b.length % 4 != 0) {
          b += '=';
        }
        text = utf8.decode(base64.decode(b), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
    final lines = text
        .replaceAll('\r', '')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.toLowerCase().startsWith('vless://'))
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// Numbers the nodes from [start]. With [seen], a link already there (same server, any name) is skipped and the
  /// new ones are added to it: a backup subscription that mirrors the main one adds no duplicates.
  static List<Node> parseAll(String? text, {int start = 1, int group = 0, Set<String>? seen}) {
    final res = <Node>[];
    if (text == null) return res;
    var i = start - 1;
    for (final line in text.split('\n')) {
      // the same server = the same user id, address and port; the query may differ between two downloads
      // (3x-ui picks a random short id from the inbound's list for every answer)
      final key = line.trim().split('#').first.split('?').first.toLowerCase();
      if (seen != null && seen.contains(key)) continue;
      final n = Node.parse(line, i + 1, group: group);
      if (n == null) continue;
      seen?.add(key);
      i++;
      res.add(n);
    }
    return res;
  }

  /// Downloads the subscription; throws on network errors, returns null when the answer has no vless:// lines.
  static Future<String?> fetch(String url, {bool insecure = false, String version = '1.0.0'}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'VlessClient/$version';
    if (insecure) client.badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await client.getUrl(Uri.parse(url.trim())).timeout(const Duration(seconds: 20));
      final resp = await req.close().timeout(const Duration(seconds: 25));
      if (resp.statusCode != 200) throw HttpException('сервер подписки ответил ${resp.statusCode}');
      final body = await resp.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(seconds: 25));
      return decode(body);
    } finally {
      client.close(force: true);
    }
  }
}

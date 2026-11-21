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
  });

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

  /// Why sing-box (the only core on the phone) cannot use this node; null when it can.
  String? get unsupportedReason {
    const transports = {'tcp', 'raw', 'ws', 'grpc', 'httpupgrade', 'http', 'h2'};
    if (!transports.contains(network)) return 'тип соединения $network на телефоне не поддерживается';
    if (q('encryption').isNotEmpty && q('encryption') != 'none') return 'шифрование VLESS (mlkem) на телефоне не поддерживается';
    if (security.isNotEmpty && security != 'none' && security != 'tls' && security != 'reality') {
      return 'защита $security на телефоне не поддерживается';
    }
    if (security == 'reality' && q('pbk').isEmpty) return 'в ссылке нет ключа Reality (pbk)';
    return null;
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

  static Node? parse(String line, int index) {
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
    return Node(index: index, name: name, id: _unescape(m.group(1)!), address: address, port: port, query: query);
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

  static List<Node> parseAll(String? text) {
    final res = <Node>[];
    if (text == null) return res;
    var i = 0;
    for (final line in text.split('\n')) {
      final n = Node.parse(line, i + 1);
      if (n == null) continue;
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

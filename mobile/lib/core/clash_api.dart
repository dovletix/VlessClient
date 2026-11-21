import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// sing-box's Clash API on 127.0.0.1 (the only way the app sees inside the running tunnel).
class ClashApi {
  ClashApi(this.port, this.secret);

  final int port;
  final String secret;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (_) => 'DIRECT';

  Uri _u(String path, [Map<String, String>? query]) => Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: query);

  Future<Object?> _send(String method, String path, {Map<String, String>? query, Object? body, Duration timeout = const Duration(seconds: 3)}) async {
    final req = await _http.openUrl(method, _u(path, query)).timeout(timeout);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close().timeout(timeout);
    final text = await resp.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(timeout);
    if (resp.statusCode >= 300) throw HttpException('clash api ${resp.statusCode}: $text');
    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }

  Future<bool> alive() async {
    try {
      await _send('GET', '/version', timeout: const Duration(milliseconds: 1500));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> connections() async {
    final j = await _send('GET', '/connections');
    if (j is Map && j['connections'] is List) {
      return (j['connections'] as List).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    }
    return [];
  }

  Future<void> closeConnection(String id) async {
    try {
      await _send('DELETE', '/connections/$id');
    } catch (_) {}
  }

  /// The node the "proxy" group uses right now (its tag), or "" when unknown.
  Future<String> selected() async {
    try {
      final j = await _send('GET', '/proxies/proxy');
      if (j is Map) return (j['now'] ?? '').toString();
    } catch (_) {}
    return '';
  }

  /// Last measured delay of every outbound (tag -> ms; 0 = failed). Taken from the Clash API history.
  Future<Map<String, int>> delays() async {
    final res = <String, int>{};
    try {
      final j = await _send('GET', '/proxies');
      final proxies = j is Map ? j['proxies'] : null;
      if (proxies is Map) {
        proxies.forEach((k, v) {
          if (v is Map && v['history'] is List && (v['history'] as List).isNotEmpty) {
            final last = (v['history'] as List).last;
            if (last is Map && last['delay'] is int) res[k.toString()] = last['delay'] as int;
          }
        });
      }
    } catch (_) {}
    return res;
  }

  /// A real request through one outbound; returns milliseconds or null when it failed.
  Future<int?> delay(String tag, {String url = 'https://www.gstatic.com/generate_204', int timeoutMs = 8000}) async {
    try {
      final j = await _send('GET', '/proxies/${Uri.encodeComponent(tag)}/delay',
          query: {'url': url, 'timeout': '$timeoutMs'}, timeout: Duration(milliseconds: timeoutMs + 2000));
      if (j is Map && j['delay'] is int && (j['delay'] as int) > 0) return j['delay'] as int;
    } catch (_) {}
    return null;
  }

  void close() => _http.close(force: true);
}

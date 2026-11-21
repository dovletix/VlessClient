import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'clash_api.dart';

class FailRec {
  FailRec({required this.time, required this.dest, required this.out, required this.reason, required this.udp});
  String time;
  final String dest, out, reason;
  final bool udp;
  int n = 1;
}

class HostRec {
  HostRec(this.host, this.out, this.up, this.down, this.rUp, this.rDown);
  final String host, out;
  final int up, down;
  final double rUp, rDown;
}

/// One app as seen by the monitor (a copy: the UI never touches the monitor's own state).
class ProcData {
  ProcData(this.key);
  final String key; // Android package name, or TrafficMonitor.unknown
  int total = 0, active = 0, fail = 0, udp = 0, proxyN = 0, directN = 0, fProxy = 0, fDirect = 0, nHosts = 0;
  int up = 0, down = 0, pBytes = 0, dBytes = 0;
  double rUp = 0, rDown = 0, rP = 0, rD = 0;
  List<FailRec> fails = [];
  List<HostRec> hosts = [];
}

class TrafficSnapshot {
  bool apiOk = false;
  List<ProcData> rows = [];
}

class _Conn {
  _Conn(this.key, this.dest, this.hostKey, this.out, this.udp, this.start);
  final String key, dest, hostKey, out;
  final bool udp;
  final DateTime start;
  bool flagged = false;
  int up = 0, down = 0;
}

class _HostStat {
  _HostStat(this.host);
  final String host;
  String out = 'proxy';
  int up = 0, down = 0, tUp = 0, tDown = 0;
  double rUp = 0, rDown = 0;
  DateTime last = DateTime.now();
}

class _Stat {
  _Stat(this.key);
  final String key;
  int total = 0, ok = 0, fail = 0, udp = 0, proxyN = 0, directN = 0, fProxy = 0, fDirect = 0;
  int up = 0, down = 0, pBytes = 0, dBytes = 0, tUp = 0, tDown = 0, tP = 0, tD = 0;
  double rUp = 0, rDown = 0, rP = 0, rD = 0;
  final List<FailRec> fails = [];
  final Map<String, _HostStat> hosts = {};
}

/// Per-app traffic, destinations and failed connections; a port of the Windows window's Ui/Traffic.cs
/// (which itself ports the PowerShell web UI). Source: the Clash API's /connections about once a second and
/// the ERROR lines of sing-box.log (failed dials). A connection that sent data but never got a byte back
/// counts as "no answer". Everything counts from the moment the monitor starts.
class TrafficMonitor {
  static const unknown = '(unknown)';
  static final RegExp _errorLine = RegExp(r'connection: open connection to (\S+) using outbound/[\w-]+\[([\w-]+)\]: (.+)$');
  static final RegExp _ansi = RegExp(r'\x1b\[[0-9;]*m');

  final Map<String, _Conn> _conns = {};
  final Map<String, _Stat> _stats = {};
  final Map<String, MapEntry<String, DateTime>> _destMap = {};
  DateTime? _lastTick;
  bool _first = true;
  int _logPos = -1;

  void reset() {
    _conns.clear();
    _stats.clear();
    _destMap.clear();
    _first = true;
    _lastTick = null;
    _logPos = -1;
  }

  /// [ruled] package names that have an app rule: they get a row even before their first connection.
  Future<TrafficSnapshot> sample(ClashApi api, String logFile, Set<String> ruled) async {
    final snap = TrafficSnapshot();
    List<Map<String, dynamic>>? list;
    try {
      list = await api.connections();
      snap.apiOk = true;
    } catch (_) {}
    if (list != null) {
      _poll(list);
      _readLogErrors(logFile);
    }
    final active = <String, int>{};
    for (final c in _conns.values) {
      active[c.key] = (active[c.key] ?? 0) + 1;
    }
    final keys = {..._stats.keys, ...ruled};
    for (final k in keys) {
      final x = _stats[k];
      final row = ProcData(k)..active = active[k] ?? 0;
      if (x != null) {
        row
          ..total = x.total
          ..fail = x.fail
          ..udp = x.udp
          ..up = x.up
          ..down = x.down
          ..proxyN = x.proxyN
          ..directN = x.directN
          ..fProxy = x.fProxy
          ..fDirect = x.fDirect
          ..rUp = x.rUp
          ..rDown = x.rDown
          ..rP = x.rP
          ..rD = x.rD
          ..pBytes = x.pBytes
          ..dBytes = x.dBytes
          ..fails = x.fails.map((f) => FailRec(time: f.time, dest: f.dest, out: f.out, reason: f.reason, udp: f.udp)..n = f.n).toList()
          ..nHosts = x.hosts.length;
        final hs = x.hosts.values.toList()
          ..sort((a, b) {
            final r = (b.rUp + b.rDown).compareTo(a.rUp + a.rDown);
            return r != 0 ? r : (b.up + b.down).compareTo(a.up + a.down);
          });
        row.hosts = hs.take(10).map((h) => HostRec(h.host, h.out, h.up, h.down, h.rUp, h.rDown)).toList();
      }
      snap.rows.add(row);
    }
    return snap;
  }

  /// "com.example.app (com.example.app)" or "com.example.app (10123)" -> "com.example.app".
  static String packageOf(String processPath) {
    final p = processPath.trim();
    if (p.isEmpty) return '';
    final i = p.indexOf(' (');
    final head = i > 0 ? p.substring(0, i) : p;
    return int.tryParse(head) != null ? 'uid:$head' : head;
  }

  void _poll(List<Map<String, dynamic>> list) {
    final now = DateTime.now();
    final seen = <String>{};
    for (final c in list) {
      final id = (c['id'] ?? '').toString();
      seen.add(id);
      final up = (c['upload'] as num?)?.toInt() ?? 0, down = (c['download'] as num?)?.toInt() ?? 0;
      var t = _conns[id];
      if (t == null) {
        final m = (c['metadata'] as Map?)?.cast<String, dynamic>() ?? {};
        var key = packageOf((m['processPath'] ?? '').toString());
        if (key.isEmpty) key = unknown;
        final ip = (m['destinationIP'] ?? '').toString();
        final dport = (m['destinationPort'] ?? '').toString();
        final ipDest = '${ip.contains(':') ? '[$ip]' : ip}:$dport';
        final host = (m['host'] ?? '').toString();
        final dest = host.isNotEmpty ? '$host:$dport' : ipDest;
        final chains = (c['chains'] is List) ? (c['chains'] as List).map((e) => e.toString()).toList() : <String>[];
        final outb = chains.contains('direct') ? 'direct' : 'proxy';
        t = _Conn(key, dest, host.isNotEmpty ? host : ip, outb, m['network'] == 'udp', now);
        // connections that were already open before the first sample: count only what they transfer from now on
        if (_first) {
          t.up = up;
          t.down = down;
        }
        _conns[id] = t;
        final st = _stats.putIfAbsent(key, () => _Stat(key));
        st.total++;
        if (outb == 'direct') {
          st.directN++;
        } else {
          st.proxyN++;
        }
        _destMap[ipDest] = MapEntry(key, now);
        _destMap[dest] = MapEntry(key, now);
      }
      if (up != t.up || down != t.down) {
        final st = _stats[t.key]!;
        final du = max(0, up - t.up), dd = max(0, down - t.down);
        st.up += du;
        st.down += dd;
        st.tUp += du;
        st.tDown += dd;
        if (t.out == 'direct') {
          st.dBytes += du + dd;
          st.tD += du + dd;
        } else {
          st.pBytes += du + dd;
          st.tP += du + dd;
        }
        if (t.hostKey.isNotEmpty) {
          final hs = st.hosts.putIfAbsent(t.hostKey, () => _HostStat(t!.hostKey));
          hs.up += du;
          hs.down += dd;
          hs.tUp += du;
          hs.tDown += dd;
          hs.out = t.out;
          hs.last = now;
        }
        t.up = up;
        t.down = down;
      }
      if (!t.flagged && down == 0 && up > 0 && now.difference(t.start).inSeconds >= 6) {
        t.flagged = true;
        _addFail(_stats[t.key]!, t.dest, t.out, 'no-answer', t.udp);
      }
    }
    for (final id in _conns.keys.where((x) => !seen.contains(x)).toList()) {
      final t = _conns.remove(id)!;
      if (!t.flagged) {
        if (t.down > 0) {
          _stats[t.key]!.ok++;
        } else if (t.up > 0 && now.difference(t.start).inSeconds >= 2) {
          _addFail(_stats[t.key]!, t.dest, t.out, 'no-answer', t.udp);
        }
      }
    }
    if (_destMap.length > 4000) {
      _destMap.removeWhere((k, v) => now.difference(v.value).inSeconds > 60);
    }

    // this tick's byte counts -> smoothed speeds (bytes per second)
    final dt = _lastTick == null ? 1.0 : max(0.2, now.difference(_lastTick!).inMilliseconds / 1000.0);
    _lastTick = now;
    _first = false;
    for (final st in _stats.values) {
      st.rUp = _smooth(st.rUp, st.tUp, dt);
      st.rDown = _smooth(st.rDown, st.tDown, dt);
      st.rP = _smooth(st.rP, st.tP, dt);
      st.rD = _smooth(st.rD, st.tD, dt);
      st.tUp = st.tDown = st.tP = st.tD = 0;
      for (final hs in st.hosts.values) {
        hs.rUp = _smooth(hs.rUp, hs.tUp, dt);
        hs.rDown = _smooth(hs.rDown, hs.tDown, dt);
        hs.tUp = hs.tDown = 0;
      }
      if (st.hosts.length > 120) {
        // keep it bounded: drop the destinations silent the longest
        final old = st.hosts.values.toList()..sort((a, b) => a.last.compareTo(b.last));
        for (final h in old.take(st.hosts.length - 80)) {
          st.hosts.remove(h.host);
        }
      }
    }
  }

  static double _smooth(double prev, int bytes, double dt) {
    final v = 0.5 * prev + 0.5 * bytes / dt;
    return v < 50 ? 0 : v;
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  static void _addFail(_Stat st, String dest, String outb, String reason, bool udp) {
    if (udp) {
      st.udp++;
    } else {
      st.fail++;
      if (outb == 'direct') {
        st.fDirect++;
      } else {
        st.fProxy++;
      }
    }
    final time = _hhmmss(DateTime.now());
    if (st.fails.isNotEmpty && st.fails[0].dest == dest && st.fails[0].reason == reason && st.fails[0].out == outb) {
      st.fails[0].n++;
      st.fails[0].time = time;
      return;
    }
    st.fails.insert(0, FailRec(time: time, dest: dest, out: outb, reason: reason, udp: udp));
    while (st.fails.length > 10) {
      st.fails.removeLast();
    }
  }

  static String classify(String msg) {
    final m = msg.toLowerCase();
    if (RegExp('timeout|timed out|did not properly respond').hasMatch(m)) return 'timeout';
    if (m.contains('refused')) return 'refused';
    if (RegExp('reset|forcibly closed|aborted').hasMatch(m)) return 'reset';
    if (RegExp('unreachable|no route').hasMatch(m)) return 'unreachable';
    if (RegExp('lookup|empty result|no such host').hasMatch(m)) return 'dns';
    return 'error';
  }

  /// New ERROR lines of sing-box.log (failed dials), attributed to the app that connected to that address.
  void _readLogErrors(String path) {
    String text;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final len = f.lengthSync();
      if (_logPos < 0 || _logPos > len) {
        _logPos = len; // start (or the log was recreated): only what comes next
        return;
      }
      if (len == _logPos) return;
      final raf = f.openSync();
      try {
        raf.setPositionSync(_logPos);
        final bytes = raf.readSync(min(len - _logPos, 262144));
        _logPos += bytes.length;
        text = utf8.decode(bytes, allowMalformed: true);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return;
    }
    final now = DateTime.now();
    for (final raw in text.split('\n')) {
      if (!raw.contains('ERROR')) continue;
      final m = _errorLine.firstMatch(raw.replaceAll(_ansi, '').trimRight());
      if (m == null) continue;
      final dest = m.group(1)!, outb = m.group(2)!, msg = m.group(3)!;
      var key = unknown;
      final d = _destMap[dest];
      if (d != null && now.difference(d.value).inSeconds < 30) key = d.key;
      _addFail(_stats.putIfAbsent(key, () => _Stat(key)), dest, outb == 'direct' ? 'direct' : 'proxy', classify(msg), false);
    }
  }
}

/// The web UI's rate() and bytes(): speeds in bits per second, sizes in binary units, Russian labels.
class Fmt {
  static String _ru(double v, int digits) => v.toStringAsFixed(digits).replaceAll('.', ',');

  static String rate(double bytesPerSec) {
    final b = bytesPerSec * 8;
    if (b < 1000) return '0';
    if (b < 1e6) return '${(b / 1e3).round()} Кбит/с';
    return '${_ru(b / 1e6, 1)} Мбит/с';
  }

  static String bytes(int n) {
    if (n < 1024) return '$n Б';
    const u = ['КБ', 'МБ', 'ГБ', 'ТБ'];
    var v = n.toDouble();
    var i = -1;
    do {
      v /= 1024;
      i++;
    } while (v >= 1024 && i < u.length - 1);
    return '${_ru(v, v < 10 ? 1 : 0)} ${u[i]}';
  }

  static const reasons = {
    'no-answer': 'нет ответа',
    'timeout': 'таймаут соединения',
    'refused': 'соединение отклонено',
    'reset': 'соединение сброшено',
    'unreachable': 'сеть недоступна',
    'dns': 'адрес не найден',
    'error': 'ошибка соединения',
  };

  /// The same advice the Windows window gives under the failure list.
  static String advice(ProcData d) {
    if (d.fails.isEmpty) return '';
    if (d.fail < 3 || d.fail < 0.15 * d.total) return 'Единичные сбои на фоне работающих соединений — обычно это норма.';
    if (d.fProxy > d.fDirect) return 'Сбои в основном через VPN — попробуйте пустить приложение напрямую.';
    if (d.fDirect > 0) return 'Сбои в основном при прямом соединении — попробуйте пустить приложение через VPN.';
    return '';
  }
}

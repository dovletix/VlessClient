import 'dart:convert';

import 'node.dart';

/// Xray carries the nodes sing-box cannot (XHTTP, VLESS encryption). Port of Core/XrayConfig.cs of the Windows app.
///
/// Chain on the phone: app -> TUN -> sing-box -> SOCKS 127.0.0.1:(basePort + node index) -> Xray -> the server.
/// Xray runs as a child process, which cannot "protect" its sockets from the VPN, so it dials the servers through
/// sing-box's local "xray-in" inbound (dialerProxy): sing-box sends that traffic out directly, past the tunnel.
class XrayConfig {
  static const basePort = 12200;
  static const dialerPort = 12079;

  static int portOf(Node n) => basePort + n.index;

  static Map<String, dynamic> outbound(Node n) {
    final user = <String, dynamic>{'id': n.id, 'encryption': n.q('encryption').isNotEmpty ? n.q('encryption') : 'none'};
    if (n.q('flow').isNotEmpty) user['flow'] = n.q('flow');

    var net = n.network;
    if (net == 'tcp') net = 'raw';
    if (net == 'splithttp') net = 'xhttp';
    if (net == 'mkcp') net = 'kcp';
    final sec = n.security.isEmpty ? 'none' : n.security;
    final stream = <String, dynamic>{'network': net, 'security': sec};

    if (sec == 'reality') {
      final re = <String, dynamic>{
        'serverName': n.q('sni'),
        'fingerprint': n.q('fp').isNotEmpty ? n.q('fp') : 'chrome',
        'publicKey': n.q('pbk'),
        'shortId': n.q('sid'),
      };
      if (n.q('spx').isNotEmpty) re['spiderX'] = n.q('spx');
      if (n.q('pqv').isNotEmpty) re['mldsa65Verify'] = n.q('pqv');
      stream['realitySettings'] = re;
    } else if (sec == 'tls') {
      final tls = <String, dynamic>{'serverName': n.q('sni')};
      if (n.q('fp').isNotEmpty) tls['fingerprint'] = n.q('fp');
      if (n.q('alpn').isNotEmpty) tls['alpn'] = n.q('alpn').split(',');
      if (n.q('allowinsecure') == '1') tls['allowInsecure'] = true;
      stream['tlsSettings'] = tls;
    }

    switch (net) {
      case 'xhttp':
        final x = <String, dynamic>{};
        if (n.q('path').isNotEmpty) x['path'] = n.q('path');
        if (n.q('host').isNotEmpty) x['host'] = n.q('host');
        if (n.q('mode').isNotEmpty) x['mode'] = n.q('mode');
        if (n.q('extra').isNotEmpty) {
          try {
            x['extra'] = jsonDecode(n.q('extra'));
          } catch (_) {}
        }
        stream['xhttpSettings'] = x;
      case 'ws':
        stream['wsSettings'] = {if (n.q('path').isNotEmpty) 'path': n.q('path'), if (n.q('host').isNotEmpty) 'host': n.q('host')};
      case 'grpc':
        stream['grpcSettings'] = {'serviceName': n.q('servicename'), if (n.q('authority').isNotEmpty) 'authority': n.q('authority')};
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {if (n.q('path').isNotEmpty) 'path': n.q('path'), if (n.q('host').isNotEmpty) 'host': n.q('host')};
      case 'kcp':
        stream['kcpSettings'] = {if (n.q('seed').isNotEmpty) 'seed': n.q('seed')};
    }
    // reach the server through sing-box, which sends it out directly (see the class comment)
    stream['sockopt'] = {'dialerProxy': 'via-singbox'};

    return {
      'tag': n.tag,
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': n.address,
            'port': n.port,
            'users': [user],
          },
        ],
      },
      'streamSettings': stream,
    };
  }

  /// One SOCKS inbound per node (127.0.0.1:basePort + index), routed to that node; null when no node needs Xray.
  static Map<String, dynamic>? build(List<Node> nodes, String logFile) {
    final list = nodes.where((n) => n.viaXray).toList();
    if (list.isEmpty) return null;
    return {
      'log': {'loglevel': 'warning', 'error': logFile, 'access': 'none'},
      'inbounds': [
        for (final n in list)
          {
            'tag': 'in-${n.tag}',
            'listen': '127.0.0.1',
            'port': portOf(n),
            'protocol': 'socks',
            'settings': {'auth': 'noauth', 'udp': true},
          },
      ],
      'outbounds': [
        for (final n in list) outbound(n),
        {
          'tag': 'via-singbox',
          'protocol': 'socks',
          'settings': {
            'servers': [
              {'address': '127.0.0.1', 'port': dialerPort},
            ],
          },
        },
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          for (final n in list)
            {
              'type': 'field',
              'inboundTag': ['in-${n.tag}'],
              'outboundTag': n.tag,
            },
        ],
      },
    };
  }
}

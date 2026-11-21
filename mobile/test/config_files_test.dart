// Writes a full sing-box config and the Xray config for made-up nodes into $CONFIG_OUT, so that CI (and a developer)
// can check them with the real cores: `sing-box check -c sing-box.json` and `xray run -test -c xray.json`.
// Skipped when CONFIG_OUT is not set.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vlessclient/core/config.dart';
import 'package:vlessclient/core/node.dart';
import 'package:vlessclient/core/settings.dart';
import 'package:vlessclient/core/xray.dart';

final _out = Platform.environment['CONFIG_OUT'];

void main() {
  test('write configs for the real cores', skip: _out == null, () {
    Node.xrayAvailable = true;
    final nodes = Subscription.parseAll([
      'vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome'
          '&sni=www.example.com&pbk=nVOBcUpdSp9yo6FJxnNxCwQPUlX7KfbJBFtd8Ad9VSU&sid=0123abcd#One',
      'vless://11111111-2222-3333-4444-555555555555@203.0.113.11:8443?type=xhttp&security=reality&fp=chrome&mode=stream-one'
          '&path=%2Fdl&sni=www.example.com&pbk=nVOBcUpdSp9yo6FJxnNxCwQPUlX7KfbJBFtd8Ad9VSU&sid=01#Two',
      'vless://11111111-2222-3333-4444-555555555555@cdn.example.org:443?type=ws&security=tls&host=cdn.example.org&path=%2Fws&sni=cdn.example.org#Three',
    ].join('\n'));
    final dir = Directory(_out!)..createSync(recursive: true);
    final s = Settings()..apiSecret = 'secret';
    for (final t in [...SingBoxConfig.userRuleSets]) {
      File('${dir.path}/rules/$t.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(SingBoxConfig.userRuleSetFiles(s)[t]!);
    }
    s.ruDirect = false; // the geo rule-sets are binary files built in CI
    final sb = SingBoxConfig.build(s, nodes, NodePlan.make(s, nodes)!, dataDir: dir.path.replaceAll('\\', '/'), os: MobileOs.android);
    File('${dir.path}/sing-box.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(sb));
    final x = XrayConfig.build(nodes, '${dir.path}/xray.log'.replaceAll('\\', '/'))!;
    File('${dir.path}/xray.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(x));
    Node.xrayAvailable = false;
  });
}

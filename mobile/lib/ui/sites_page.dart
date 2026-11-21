import 'package:flutter/material.dart';

import '../core/engine.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Сайты": domains and IP ranges that always go directly or always through the VPN (chips, as in the web UI).
class SitesPage extends StatelessWidget {
  const SitesPage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Сайты', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PanelCard(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Российские сайты напрямую', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Hint(app.geoAvailable
                        ? 'Российские сайты и адреса идут напрямую автоматически; заблокированные в России — через VPN.'
                        : 'В этой сборке нет базы российских сайтов, правило не работает.'),
                  ]),
                ),
                Switch(
                  value: s.ruDirect,
                  onChanged: app.geoAvailable ? (v) => app.change((x) => x.ruDirect = v, reconnect: true) : null,
                ),
              ]),
            ),
            _ListCard(app: app, vpn: false, entries: [...s.directDomains, ...s.directIps]),
            _ListCard(app: app, vpn: true, entries: [...s.proxyDomains, ...s.proxyIps]),
            const Hint(
                'Можно вставить ссылку — останется только адрес сайта. Сайт попадает в список вместе со всеми поддоменами. '
                'Подсеть пишется как 1.2.3.0/24. Для особых случаев: full:точный.адрес, keyword:слово, regex:выражение.',
                size: 12),
          ],
        );
      },
    );
  }
}

class _ListCard extends StatefulWidget {
  const _ListCard({required this.app, required this.vpn, required this.entries});
  final AppState app;
  final bool vpn;
  final List<String> entries;

  @override
  State<_ListCard> createState() => _ListCardState();
}

class _ListCardState extends State<_ListCard> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _c.text;
    if (text.trim().isEmpty) return;
    final err = await widget.app.addSite(text, widget.vpn);
    if (!mounted) return;
    if (err != null) {
      toast(context, err);
    } else {
      _c.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PanelCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        H2(widget.vpn ? 'Всегда через VPN' : 'Всегда напрямую'),
        Hint(widget.vpn
            ? 'Эти сайты открываются через VPN, даже если остальной трафик идёт напрямую.'
            : 'Эти сайты открываются без VPN — например, банки и госуслуги, которые не пускают зарубежные адреса.'),
        const SizedBox(height: 10),
        if (widget.entries.isEmpty)
          Hint('пусто', color: p.muted)
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in widget.entries) RemovableChip(e, onRemove: () => widget.app.removeSite(e)),
          ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _c,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'example.com'),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _add, child: const Text('Добавить')),
        ]),
      ]),
    );
  }
}

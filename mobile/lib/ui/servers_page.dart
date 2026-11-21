import 'package:flutter/material.dart';

import '../core/engine.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Серверы": automatic choice or a pinned node, and a delay check through the tunnel.
class ServersPage extends StatelessWidget {
  const ServersPage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        final pinned = s.findPinned(app.nodes);
        final auto = pinned == null;
        final pool = s.autoPool(app.nodes).map((n) => n.index).toSet();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(children: [
              Expanded(child: Text('Серверы', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800))),
              FilledButton.icon(
                onPressed: app.testing
                    ? null
                    : () async {
                        final err = await app.testNodes();
                        if (err != null && context.mounted) toast(context, err);
                      },
                icon: app.testing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.speed, size: 18),
                label: Text(app.testing ? 'Проверяю…' : 'Проверить'),
              ),
            ]),
            const SizedBox(height: 6),
            Hint(
                'Время — полный запрос через сервер; меньше — лучше. '
                '${app.running ? 'Проверка идёт через включённый VPN.' : 'VPN включать не нужно: серверы проверяются и без него.'}'
                '${app.checkedAt == null ? '' : ' Последняя проверка в ${_hm(app.checkedAt!)}${app.checkedWithoutTunnel ? ', без VPN' : ', через VPN'}.'}',
                size: 12),
            const SizedBox(height: 12),
            if (app.nodes.isEmpty)
              const PanelCard(child: Hint('Список серверов пуст. Добавьте подписку на вкладке «VPN» или в «Настройках».'))
            else
              PanelCard(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: RadioGroup<String>(
                  groupValue: auto ? 'auto' : '${pinned.index}',
                  onChanged: (v) {
                    if (v != null) app.selectNode(v);
                  },
                  child: Column(children: [
                    RadioListTile<String>(
                      value: 'auto',
                      title: Text('Автоматически (рекомендуется)', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                      subtitle: const Hint('Самый быстрый рабочий сервер; при сбое — следующий.', size: 12),
                    ),
                    for (final n in app.nodes)
                      RadioListTile<String>(
                        value: '${n.index}',
                        enabled: n.supported,
                        title: Row(children: [
                          Expanded(
                            child: Text('${n.index}. ${n.name}',
                                style: TextStyle(color: n.supported ? p.text : p.muted), overflow: TextOverflow.ellipsis),
                          ),
                          if (app.running && n.tag == app.currentTag) const Pill('сейчас', kind: PillKind.ok),
                        ]),
                        subtitle: Row(children: [
                          Expanded(
                            child: Hint(
                              n.supported
                                  ? '${n.kind}${n.viaXray ? ' · через Xray' : ''}${auto && !pool.contains(n.index) ? ' · не участвует в автовыборе' : ''}'
                                  : n.unsupportedReason!,
                              size: 12,
                            ),
                          ),
                          if (app.delays.containsKey(n.tag))
                            Text(app.delays[n.tag] == null ? 'не работает' : '${app.delays[n.tag]} мс',
                                style: TextStyle(color: app.delays[n.tag] == null ? p.bad : p.ok, fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                  ]),
                ),
              ),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Не использовать в автовыборе'),
                const Hint(
                    'Часть названия сервера (или регулярное выражение). Например, медленные серверы-ретрансляторы: их не стоит смешивать с быстрыми, иначе новые соединения — звонки, игры — могут попасть на медленный.',
                    size: 12),
                const SizedBox(height: 10),
                _ExcludeField(app: app),
              ]),
            ),
            if (pinned != null)
              PanelCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.nodeFallback,
                  onChanged: (v) => app.change((x) => x.nodeFallback = v, reconnect: true),
                  title: Text('Запасной сервер', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                  subtitle: const Hint('Если выбранный сервер перестанет отвечать, трафик временно пойдёт через другой.', size: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _ExcludeField extends StatefulWidget {
  const _ExcludeField({required this.app});
  final AppState app;

  @override
  State<_ExcludeField> createState() => _ExcludeFieldState();
}

class _ExcludeFieldState extends State<_ExcludeField> {
  late final TextEditingController _c = TextEditingController(text: widget.app.settings.autoExclude);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() {
    final v = _c.text.trim();
    try {
      RegExp(v);
    } catch (_) {
      toast(context, 'Ошибка в выражении');
      return;
    }
    if (v == widget.app.settings.autoExclude) return;
    widget.app.change((s) => s.autoExclude = v, reconnect: widget.app.settings.node == 'auto');
    toast(context, 'Сохранено');
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: TextField(controller: _c, decoration: const InputDecoration(hintText: 'например, relay'), onSubmitted: (_) => _save())),
      const SizedBox(width: 8),
      OutlinedButton(onPressed: _save, child: const Text('Сохранить')),
    ]);
  }
}

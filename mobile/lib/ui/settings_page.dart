import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/traffic.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppState app;

  static String _date(DateTime? t) {
    if (t == null) return 'ещё не загружен';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        var subHost = '';
        try {
          subHost = Uri.parse(s.subscriptionUrl).host;
        } catch (_) {}
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Настройки', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Подписка'),
                Hint(!s.hasSubscription
                    ? 'Подписка не задана.'
                    : s.inlineNodes
                        ? 'Серверы вставлены вручную: ${app.nodes.length}.'
                        : 'Сервер подписки: $subHost. Серверов: ${app.nodes.length}.'),
                const SizedBox(height: 2),
                if (s.hasSubscription) Hint('Список обновлён: ${_date(app.subscriptionTime)}', size: 12),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(onPressed: () => _changeLink(context), child: const Text('Изменить ссылку')),
                  if (s.canDownload)
                    OutlinedButton(
                      onPressed: () async {
                        toast(context, 'Обновляю список серверов…');
                        final err = await app.refreshSubscription();
                        if (context.mounted) toast(context, err ?? 'Список серверов обновлён.');
                      },
                      child: const Text('Обновить серверы'),
                    ),
                ]),
              ]),
            ),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Остальной трафик'),
                const Hint('Куда идёт всё, для чего нет отдельного правила (приложения, сайты, российские адреса).', size: 12),
                const SizedBox(height: 10),
                Segmented<String>(
                  value: s.defaultRoute,
                  options: const [('proxy', 'Через VPN'), ('direct', 'Напрямую')],
                  onChanged: (v) => app.change((x) => x.defaultRoute = v, reconnect: true),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.blockQuicOnProxy,
                  onChanged: (v) => app.change((x) => x.blockQuicOnProxy = v, reconnect: true),
                  title: Text('Не пускать QUIC через VPN', style: TextStyle(color: p.text)),
                  subtitle: const Hint('Браузеры и YouTube тогда переходят на обычный HTTPS, который через VPN работает быстрее и стабильнее.', size: 12),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.autoConnect,
                  onChanged: (v) => app.change((x) => x.autoConnect = v),
                  title: Text('Включать VPN при открытии приложения', style: TextStyle(color: p.text)),
                  subtitle: Hint(
                      app.isAndroid
                          ? 'Чтобы VPN включался сам после перезагрузки телефона, включите «Постоянная VPN» для VlessClient в настройках Android (Сеть → VPN).'
                          : 'Можно также добавить VPN в «Пункт управления».',
                      size: 12),
                ),
              ]),
            ),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Оформление'),
                Segmented<String>(
                  value: s.theme,
                  options: const [('dark', 'Тёмная'), ('light', 'Светлая')],
                  onChanged: (v) => app.change((x) => x.theme = v),
                ),
              ]),
            ),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Версия'),
                Hint('Установлена версия ${app.vpn.version}'),
                if (app.isAndroid) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    OutlinedButton(onPressed: app.updating ? null : app.checkUpdate, child: const Text('Проверить обновления')),
                    if (app.update != null)
                      FilledButton(
                        onPressed: app.updating ? null : app.installUpdate,
                        child: Text('Обновить до ${app.update!.version}${app.update!.size > 0 ? ' (${Fmt.bytes(app.update!.size)})' : ''}'),
                      ),
                  ]),
                  if (app.updateNote.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Hint(app.updateNote, size: 12)),
                ] else
                  const Hint('Обновления на iPhone приходят через TestFlight или магазин, из которого приложение установлено.', size: 12),
              ]),
            ),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const H2('Если что-то не работает'),
                const Hint('Отчёт — текст с состоянием подключения, списком серверов и последними строками журнала sing-box. Ссылка на подписку в него не попадает.',
                    size: 12),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(onPressed: () => app.vpn.share(app.report()), child: const Text('Поделиться отчётом')),
                  OutlinedButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: app.report()));
                      toast(context, 'Отчёт скопирован');
                    },
                    child: const Text('Скопировать'),
                  ),
                ]),
              ]),
            ),
            Center(child: Hint('VlessClient · GitHub: ${AppState.repo}', size: 11)),
          ],
        );
      },
    );
  }

  Future<void> _changeLink(BuildContext context) async {
    final c = TextEditingController();
    String error = '';
    bool busy = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final p = Palette.of(ctx);
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Новая ссылка на подписку', style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Hint('Ссылка https://… или сами серверы — строки vless://, если сервер подписки недоступен.', size: 12),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                autofocus: true,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: 'https://…',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    onPressed: () async {
                      final d = await Clipboard.getData(Clipboard.kTextPlain);
                      if (d?.text != null) c.text = d!.text!.trim();
                    },
                  ),
                ),
              ),
              if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Hint(error, color: p.bad)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = '';
                          });
                          final err = await app.setSubscription(c.text);
                          if (err == null) {
                            if (ctx.mounted) Navigator.pop(ctx);
                          } else {
                            setState(() {
                              busy = false;
                              error = err;
                            });
                          }
                        },
                  child: Text(busy ? 'Проверяю ссылку…' : 'Сохранить и подключить'),
                ),
              ),
            ]),
          );
        },
      ),
    );
    c.dispose();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/traffic.dart';
import 'theme.dart';
import 'widgets.dart';

/// The one big button, as in the Windows window.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app, required this.onOpen});
  final AppState app;
  final ValueChanged<int> onOpen;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _link = TextEditingController();
  bool _checking = false;
  String _linkError = '';

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) _link.text = d!.text!.trim();
  }

  Future<void> _save() async {
    setState(() {
      _checking = true;
      _linkError = '';
    });
    final err = await widget.app.setSubscription(_link.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _linkError = err ?? '';
    });
  }

  static String _duration(Duration d) {
    if (d.inHours > 0) return '${d.inHours} ч ${d.inMinutes % 60} мин';
    if (d.inMinutes > 0) return '${d.inMinutes} мин';
    return 'меньше минуты';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final st = app.state;
        final (title, color) = switch (st) {
          VpnState.on => ('VPN включён', p.ok),
          VpnState.connecting => ('Подключение…', p.warn),
          VpnState.error => ('Нет подключения', p.bad),
          VpnState.noSubscription => ('Нужна ссылка на подписку', p.muted),
          VpnState.off => ('VPN выключен', p.muted),
        };
        final node = app.currentNode;
        var down = 0.0, up = 0.0;
        for (final r in app.snapshot.rows) {
          down += r.rDown;
          up += r.rUp;
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(children: [
              Text('VlessClient', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800)),
              const Spacer(),
              Pill(
                st == VpnState.on ? 'Туннель активен' : st == VpnState.connecting ? 'Подключение' : 'Выключен',
                kind: st == VpnState.on ? PillKind.ok : st == VpnState.connecting ? PillKind.warn : PillKind.muted,
              ),
            ]),
            const SizedBox(height: 28),
            Center(child: _BigButton(state: st, onTap: st == VpnState.noSubscription ? null : app.toggle)),
            const SizedBox(height: 22),
            Center(child: Text(title, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w700))),
            const SizedBox(height: 6),
            if (st == VpnState.on && node != null)
              Center(child: Hint('Сервер: ${node.name}', size: 15))
            else if (st != VpnState.on && st != VpnState.noSubscription)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Hint(st == VpnState.off && app.message.isEmpty ? 'Нажмите на кнопку, чтобы включить' : app.message,
                      size: 14, color: st == VpnState.error ? p.bad : null),
                ),
              ),
            if (st == VpnState.on && app.since != null)
              Center(child: Padding(padding: const EdgeInsets.only(top: 4), child: Hint('Подключено ${_duration(DateTime.now().difference(app.since!))}'))),
            if (st == VpnState.on) ...[
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: _Stat(label: 'Загрузка', value: Fmt.rate(down), icon: Icons.arrow_downward)),
                const SizedBox(width: 12),
                Expanded(child: _Stat(label: 'Отдача', value: Fmt.rate(up), icon: Icons.arrow_upward)),
              ]),
            ],
            const SizedBox(height: 22),
            if (!app.settings.hasSubscription) _subscriptionCard(p) else _factsCard(p, app),
          ],
        );
      },
    );
  }

  Widget _subscriptionCard(Palette p) {
    return PanelCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const H2('Ссылка на подписку'),
        const Hint('Вставьте ссылку, которую вам дали вместе с VPN (начинается с https://). Можно вставить и сами серверы — строки vless://.'),
        const SizedBox(height: 12),
        TextField(
          controller: _link,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'https://…',
            suffixIcon: IconButton(icon: const Icon(Icons.content_paste), tooltip: 'Вставить', onPressed: _paste),
          ),
        ),
        if (_linkError.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Hint(_linkError, color: p.bad)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _checking ? null : _save,
            child: Text(_checking ? 'Проверяю ссылку…' : 'Подключить'),
          ),
        ),
      ]),
    );
  }

  Widget _factsCard(Palette p, AppState app) {
    final s = app.settings;
    Widget fact(IconData icon, String text, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(icon, size: 18, color: p.muted),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(color: p.text, fontSize: 14))),
              if (onTap != null) Icon(Icons.chevron_right, size: 18, color: p.muted),
            ]),
          ),
        );
    return PanelCard(
      child: Column(children: [
        fact(Icons.alt_route, 'Остальной трафик: ${s.defaultRoute == 'direct' ? 'напрямую' : 'через VPN'}', onTap: () => widget.onOpen(4)),
        fact(Icons.flag_outlined,
            s.ruDirect && app.geoAvailable ? 'Российские сайты — напрямую, заблокированные в России — через VPN' : 'Правило для российских сайтов выключено',
            onTap: () => widget.onOpen(2)),
        fact(Icons.dns_outlined, s.node == 'auto' ? 'Сервер выбирается автоматически' : 'Выбран сервер: ${s.findPinned(app.nodes)?.name ?? s.node}',
            onTap: () => widget.onOpen(3)),
        if (app.isAndroid)
          fact(Icons.apps, s.apps.isEmpty ? 'Все приложения идут по общим правилам' : 'Правил для приложений: ${s.apps.length}', onTap: () => widget.onOpen(1)),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon});
  final String label, value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PanelCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Icon(icon, size: 18, color: p.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Hint(label, size: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, maxLines: 1, style: TextStyle(color: p.text, fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _BigButton extends StatefulWidget {
  const _BigButton({required this.state, required this.onTap});
  final VpnState state;
  final Future<void> Function()? onTap;

  @override
  State<_BigButton> createState() => _BigButtonState();
}

class _BigButtonState extends State<_BigButton> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didUpdateWidget(covariant _BigButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  void _sync() {
    if (widget.state == VpnState.connecting) {
      if (!_spin.isAnimating) unawaited(_spin.repeat());
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = widget.state == VpnState.on;
    final busy = widget.state == VpnState.connecting;
    final ring = on ? p.ok : busy ? p.warn : widget.state == VpnState.error ? p.bad : p.accent;
    final fill = on ? p.okSoft : busy ? p.warnSoft : p.panel;
    return GestureDetector(
      onTap: widget.onTap == null ? null : () => widget.onTap!(),
      child: SizedBox(
        width: 190,
        height: 190,
        child: Stack(alignment: Alignment.center, children: [
          if (busy)
            RotationTransition(
              turns: _spin,
              child: SizedBox(width: 190, height: 190, child: CircularProgressIndicator(strokeWidth: 4, color: ring, value: 0.25)),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: busy ? 2 : 4),
              boxShadow: on ? [BoxShadow(color: p.ok.withValues(alpha: 0.25), blurRadius: 30, spreadRadius: 4)] : null,
            ),
            child: Icon(Icons.power_settings_new, size: 72, color: ring),
          ),
        ]),
      ),
    );
  }
}

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/settings.dart';
import '../core/traffic.dart';
import '../platform/vpn.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Приложения": per-app rules (Android) and the traffic monitor of the Windows window's "Процессы" table.
class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.app});
  final AppState app;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

enum _Sort { speed, total, conns, vpn, fail }

class _AppsPageState extends State<AppsPage> {
  Map<String, InstalledApp> _installed = {};
  bool _loadingApps = false;
  String _search = '';
  bool _onlyBad = false;
  _Sort _sort = _Sort.speed;
  final Set<String> _open = {};

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    if (!app.ready || !app.isAndroid || _loadingApps) return;
    _loadingApps = true;
    try {
      final list = await app.vpn.apps();
      if (mounted) setState(() => _installed = {for (final a in list) a.package: a});
    } catch (_) {
    } finally {
      _loadingApps = false;
    }
  }

  String _label(String key) {
    if (key == TrafficMonitor.unknown) return app.isAndroid ? 'Приложение не определено' : 'Все приложения';
    if (key.startsWith('uid:')) return 'Системный процесс (${key.substring(4)})';
    return _installed[key]?.label ?? key;
  }

  double _sortValue(ProcData d) => switch (_sort) {
        _Sort.speed => d.rDown + d.rUp,
        _Sort.total => (d.down + d.up).toDouble(),
        _Sort.conns => d.active * 100000.0 + d.total,
        _Sort.vpn => d.pBytes.toDouble(),
        _Sort.fail => d.fail * 1000.0 + d.udp,
      };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final snap = app.snapshot;
        var rows = snap.rows.where((r) => r.total > 0 || app.settings.ruleFor(r.key) != null).toList();
        if (_onlyBad) rows = rows.where((r) => r.fail + r.udp > 0).toList();
        if (_search.isNotEmpty) {
          final q = _search.toLowerCase();
          rows = rows.where((r) => r.key.toLowerCase().contains(q) || _label(r.key).toLowerCase().contains(q)).toList();
        }
        rows.sort((a, b) {
          final c = _sortValue(b).compareTo(_sortValue(a));
          return c != 0 ? c : _label(a.key).compareTo(_label(b.key));
        });
        var tDown = 0.0, tUp = 0.0, tP = 0.0, tD = 0.0;
        for (final r in snap.rows) {
          tDown += r.rDown;
          tUp += r.rUp;
          tP += r.rP;
          tD += r.rD;
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(app.isAndroid ? 'Приложения' : 'Трафик', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            if (app.isAndroid) _rulesCard(p),
            PanelCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                H2('Активность',
                    trailing: IconButton(
                      tooltip: 'Сбросить статистику',
                      icon: Icon(Icons.restart_alt, color: p.muted),
                      onPressed: () {
                        app.monitor.reset();
                        setState(_open.clear);
                      },
                    )),
                TextField(
                  decoration: const InputDecoration(hintText: 'Поиск', prefixIcon: Icon(Icons.search, size: 20)),
                  onChanged: (v) => setState(() => _search = v.trim()),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    FilterChip(
                      label: const Text('Только с проблемами'),
                      selected: _onlyBad,
                      onSelected: (v) => setState(() => _onlyBad = v),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<_Sort>(
                      initialValue: _sort,
                      onSelected: (v) => setState(() => _sort = v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: _Sort.speed, child: Text('По скорости')),
                        PopupMenuItem(value: _Sort.total, child: Text('По объёму')),
                        PopupMenuItem(value: _Sort.conns, child: Text('По соединениям')),
                        PopupMenuItem(value: _Sort.vpn, child: Text('По трафику через VPN')),
                        PopupMenuItem(value: _Sort.fail, child: Text('По проблемам')),
                      ],
                      child: Chip(
                        avatar: Icon(Icons.sort, size: 16, color: p.muted),
                        label: Text(switch (_sort) {
                          _Sort.speed => 'По скорости',
                          _Sort.total => 'По объёму',
                          _Sort.conns => 'По соединениям',
                          _Sort.vpn => 'Через VPN',
                          _Sort.fail => 'По проблемам',
                        }),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                if (!app.running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Hint('VPN выключен — статистика появится, когда он заработает.', color: p.muted),
                  )
                else if (!snap.apiOk)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Hint('Нет связи с sing-box — VPN ещё подключается. Статистика соединений сейчас недоступна.', color: p.warn),
                  )
                else if (rows.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Hint('Пока нет соединений.'))
                else
                  for (final r in rows) _row(p, r),
                if (app.running && snap.apiOk) ...[
                  const SizedBox(height: 10),
                  Hint('Сейчас всего: ↓ ${Fmt.rate(tDown)} · ↑ ${Fmt.rate(tUp)}  —  через VPN ${Fmt.rate(tP)}, напрямую ${Fmt.rate(tD)}',
                      size: 12, color: p.text),
                  const SizedBox(height: 6),
                  Hint(
                      'Скорость и объёмы считаются с открытия приложения. Нажмите на строку, чтобы увидеть адреса и сбои; '
                      'долгое нажатие — коротко, куда приложение ходит. «Без ответа» — приложение отправило данные и не получило ни байта, либо соединение не установилось.',
                      size: 12),
                  if (!app.isAndroid) ...[
                    const SizedBox(height: 6),
                    const Hint('iOS не сообщает, какое приложение открыло соединение, поэтому весь трафик собран в одну строку.', size: 12),
                  ],
                ],
              ]),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------------ rules

  Widget _rulesCard(Palette p) {
    final rules = app.settings.apps;
    return PanelCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const H2('Правила для приложений'),
        const Hint('Выбранные приложения всегда идут через VPN или всегда напрямую — что бы ни было указано для сайтов.'),
        const SizedBox(height: 8),
        if (rules.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Hint('Правил пока нет.')),
        for (final r in rules)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              _AppIcon(app: app, package: r.packages.first),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_ruleTitle(r), style: TextStyle(color: p.text, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  Hint(r.vpn ? 'через VPN' : 'напрямую', size: 12, color: r.vpn ? p.accent : p.ok),
                ]),
              ),
              Switch(value: r.vpn, onChanged: (v) => app.setAppRoute(r.name, r.packages, v)),
              IconButton(icon: Icon(Icons.close, size: 18, color: p.muted), tooltip: 'Убрать правило', onPressed: () => app.removeApp(r)),
            ]),
          ),
        const SizedBox(height: 6),
        OutlinedButton.icon(onPressed: _pickApp, icon: const Icon(Icons.add, size: 18), label: const Text('Добавить приложение')),
      ]),
    );
  }

  String _ruleTitle(AppRule r) {
    if (r.packages.length == 1) return _label(r.packages.first);
    return r.name;
  }

  Future<void> _pickApp() async {
    if (_installed.isEmpty) await _loadApps();
    if (!mounted) return;
    final picked = await showModalBottomSheet<InstalledApp>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AppPicker(app: app, apps: _installed.values.toList()),
    );
    if (picked == null || !mounted) return;
    final vpn = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Как пускать «${picked.label}»?', style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Через VPN'))),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Напрямую'))),
            ]),
          ),
        );
      },
    );
    if (vpn == null) return;
    await app.setAppRoute(picked.label, [picked.package], vpn);
  }

  // ------------------------------------------------------------------ monitor rows

  Widget _row(Palette p, ProcData d) {
    final open = _open.contains(d.key);
    final canOpen = d.hosts.isNotEmpty || d.fails.isNotEmpty;
    final rule = app.settings.ruleFor(d.key);
    final sum = d.pBytes + d.dBytes;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: open ? p.hover : Colors.transparent, borderRadius: BorderRadius.circular(10), border: Border.all(color: p.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: canOpen ? () => setState(() => open ? _open.remove(d.key) : _open.add(d.key)) : null,
        onLongPress: canOpen ? () => _quickHosts(p, d) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (app.isAndroid) ...[_AppIcon(app: app, package: d.key), const SizedBox(width: 10)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_label(d.key), style: TextStyle(color: p.text, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  if (app.isAndroid && _installed.containsKey(d.key))
                    Text(d.key, style: TextStyle(color: p.muted, fontSize: 11, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(d.rDown + d.rUp > 0 ? '↓ ${Fmt.rate(d.rDown)}' : '—',
                    style: TextStyle(color: d.rDown + d.rUp > 125000 ? p.accent : p.text, fontWeight: FontWeight.w600, fontSize: 13)),
                if (d.rDown + d.rUp > 0) Hint('↑ ${Fmt.rate(d.rUp)}', size: 11),
              ]),
              if (canOpen) Icon(open ? Icons.expand_less : Icons.expand_more, color: p.muted, size: 20),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Hint(d.down + d.up > 0 ? 'всего ↓ ${Fmt.bytes(d.down)} · ↑ ${Fmt.bytes(d.up)}' : 'всего —', size: 12),
              Hint(d.total > 0 ? 'соединений ${d.active} / ${d.total}' : 'соединений —', size: 12),
              if (d.fail > 0) Pill('${d.fail} без ответа', kind: PillKind.bad, dot: false),
              if (d.udp > 0) Pill('UDP: ${d.udp}', kind: PillKind.warn, dot: false),
              if (rule != null) Pill(rule.vpn ? 'правило: VPN' : 'правило: напрямую', kind: rule.vpn ? PillKind.accent : PillKind.ok, dot: false),
            ]),
            if (sum > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 5,
                  child: Row(children: [
                    if (d.pBytes > 0) Expanded(flex: (1000 * d.pBytes / sum).round().clamp(1, 1000), child: Container(color: p.accent)),
                    if (d.dBytes > 0) Expanded(flex: (1000 * d.dBytes / sum).round().clamp(1, 1000), child: Container(color: p.ok)),
                  ]),
                ),
              ),
              const SizedBox(height: 4),
              Hint(
                  [if (d.pBytes > 0) 'VPN ${Fmt.bytes(d.pBytes)}', if (d.dBytes > 0) 'напрямую ${Fmt.bytes(d.dBytes)}'].join(' · '),
                  size: 11),
            ],
            if (open) _details(p, d, rule),
          ]),
        ),
      ),
    );
  }

  Widget _routeTag(Palette p, bool vpn) => Text(vpn ? 'VPN' : 'напрямую',
      style: TextStyle(color: vpn ? p.accent : p.ok, fontSize: 11, fontWeight: FontWeight.w700));

  Widget _details(Palette p, ProcData d, AppRule? rule) {
    final advice = Fmt.advice(d);
    final canRule = app.isAndroid && d.key != TrafficMonitor.unknown && !d.key.startsWith('uid:');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (d.hosts.isNotEmpty) ...[
          Hint(d.nHosts > d.hosts.length ? 'Куда ходит (первые ${d.hosts.length} из ${d.nHosts} адресов по скорости и объёму)' : 'Куда ходит',
              size: 12, color: p.text),
          const SizedBox(height: 4),
          for (final h in d.hosts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(h.host, style: TextStyle(color: p.text, fontSize: 12, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                _routeTag(p, h.out != 'direct'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 112,
                  child: Text(
                    h.rDown + h.rUp > 0 ? '↓ ${Fmt.rate(h.rDown)}' : '↓ ${Fmt.bytes(h.down)} · ↑ ${Fmt.bytes(h.up)}',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ),
              ]),
            ),
        ],
        if (d.fails.isNotEmpty) ...[
          const SizedBox(height: 10),
          Hint('Соединения без ответа', size: 12, color: p.bad),
          const SizedBox(height: 4),
          for (final f in d.fails)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(f.time, style: TextStyle(color: p.muted, fontSize: 11, fontFamily: 'monospace')),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('${f.dest}${f.n > 1 ? ' ×${f.n}' : ''}',
                          style: TextStyle(color: p.text, fontSize: 12, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                ]),
                Padding(
                  padding: const EdgeInsets.only(left: 62),
                  child: Hint('${f.out == 'direct' ? 'напрямую' : 'через VPN'} · ${f.udp ? 'UDP, ' : ''}${Fmt.reasons[f.reason] ?? f.reason}', size: 11),
                ),
              ]),
            ),
        ],
        if (advice.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.warnSoft, borderRadius: BorderRadius.circular(8)),
            child: Hint(advice, size: 12, color: p.warn),
          ),
        ],
        if (canRule) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              onPressed: rule?.vpn == true ? null : () => app.setAppRoute(_label(d.key), [d.key], true),
              child: const Text('Всегда через VPN'),
            ),
            OutlinedButton(
              onPressed: rule != null && !rule.vpn ? null : () => app.setAppRoute(_label(d.key), [d.key], false),
              child: const Text('Всегда напрямую'),
            ),
            if (rule != null) TextButton(onPressed: () => app.removeApp(rule), child: const Text('Убрать правило')),
          ]),
        ],
      ]),
    );
  }

  /// The Windows window shows this on hover; on a phone it is a long press.
  void _quickHosts(Palette p, ProcData d) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_label(d.key), style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            for (final h in d.hosts.take(8))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(h.host, style: TextStyle(color: p.text, fontFamily: 'monospace', fontSize: 13), overflow: TextOverflow.ellipsis)),
                  _routeTag(p, h.out != 'direct'),
                  const SizedBox(width: 8),
                  Hint(Fmt.bytes(h.up + h.down), size: 12),
                ]),
              ),
            if (d.fail + d.udp > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Hint('Без ответа: ${d.fail}${d.udp > 0 ? ', UDP: ${d.udp}' : ''}', color: p.bad),
              ),
          ]),
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.app, required this.package});
  final AppState app;
  final String package;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fallback = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(8)),
      child: Icon(Icons.android, size: 18, color: p.muted),
    );
    if (!app.isAndroid || package == TrafficMonitor.unknown || package.startsWith('uid:')) return fallback;
    return FutureBuilder<Uint8List?>(
      future: app.vpn.icon(package),
      builder: (context, snap) => snap.data == null
          ? fallback
          : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(snap.data!, width: 32, height: 32, gaplessPlayback: true)),
    );
  }
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.app, required this.apps});
  final AppState app;
  final List<InstalledApp> apps;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  String _q = '';
  bool _system = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final q = _q.toLowerCase();
    final list = widget.apps
        .where((a) => (_system || !a.system) && (q.isEmpty || a.label.toLowerCase().contains(q) || a.package.contains(q)))
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Найти приложение', prefixIcon: Icon(Icons.search, size: 20)),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        CheckboxListTile(
          dense: true,
          value: _system,
          onChanged: (v) => setState(() => _system = v ?? false),
          title: Text('Показывать системные', style: TextStyle(color: p.text)),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Hint('Ничего не найдено'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final a = list[i];
                    return ListTile(
                      leading: _AppIcon(app: widget.app, package: a.package),
                      title: Text(a.label, style: TextStyle(color: p.text)),
                      subtitle: Text(a.package, style: TextStyle(color: p.muted, fontSize: 11)),
                      onTap: () => Navigator.pop(context, a),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

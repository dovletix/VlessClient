import 'package:flutter/material.dart';

import 'core/engine.dart';
import 'ui/apps_page.dart';
import 'ui/home_page.dart';
import 'ui/servers_page.dart';
import 'ui/settings_page.dart';
import 'ui/sites_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  runApp(VlessClientApp(app: app));
  app.init();
}

class VlessClientApp extends StatelessWidget {
  const VlessClientApp({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final dark = !app.ready || app.settings.theme != 'light';
        final p = dark ? Palette.dark : Palette.light;
        return MaterialApp(
          title: 'VlessClient',
          debugShowCheckedModeBanner: false,
          theme: p.theme(dark),
          home: app.ready ? Shell(app: app) : const _Splash(),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.app});
  final AppState app;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLink();
  }

  /// vlessclient://add/... from a browser or a messenger: import at once on a fresh install, ask before replacing.
  Future<void> _checkLink() async {
    final app = widget.app;
    final link = await app.vpn.takeLink();
    if (link == null || !mounted) return;
    if (app.settings.hasSubscription) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Заменить подписку?'),
          content: const Text('Ссылка из другого приложения заменит текущую подписку и её серверы.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Заменить')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final err = await app.setSubscription(link);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    setState(() => index = 0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.app.resume();
      _checkLink();
    } else if (state == AppLifecycleState.paused) {
      widget.app.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = <(IconData, IconData, String, Widget)>[
      (Icons.shield_outlined, Icons.shield, 'VPN', HomePage(app: app, onOpen: (i) => setState(() => index = i))),
      (Icons.apps_outlined, Icons.apps, app.isAndroid ? 'Программы' : 'Трафик', AppsPage(app: app)),
      (Icons.public_outlined, Icons.public, 'Сайты', SitesPage(app: app)),
      (Icons.dns_outlined, Icons.dns, 'Серверы', ServersPage(app: app)),
      (Icons.settings_outlined, Icons.settings, 'Настройки', SettingsPage(app: app)),
    ];
    return Scaffold(
      body: SafeArea(bottom: false, child: IndexedStack(index: index, children: [for (final pg in pages) pg.$4])),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: [for (final pg in pages) NavigationDestination(icon: Icon(pg.$1), selectedIcon: Icon(pg.$2), label: pg.$3)],
      ),
    );
  }
}

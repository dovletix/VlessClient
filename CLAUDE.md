# VlessClient — notes for Claude

Windows VPN client for VLESS subscriptions, aimed at non-technical users (one big button) with an "advanced" section for power users. Native C# (.NET Framework 4.8, WPF + WinForms tray), shipped as an MSI. This repository is public: never commit subscription links, server addresses, API secrets or anything from a user's machine. User-facing docs: `README.md`.

## Layout

- `src/VlessClient/` — one exe, several modes:
  - `--service`: the Windows service "VlessClient" (LocalSystem). `Service/Engine.cs` owns everything: subscription, node choice, cores, supervision. `Service/PipeServer.cs` exposes it on the named pipe `VlessClient.Control.v2` (one JSON request per line; any authenticated user may connect).
  - no args / `--tray`: the window and the tray icon (`Ui/`), non-elevated, talks to the service only through the pipe (`Ui/ServiceClient.cs`). One instance per session; a second start just shows the window.
  - `--cleanup`: run by the uninstaller (not on upgrade); deletes `C:\ProgramData\VlessClient`.
  - `--console`: development — engine + pipe inside this process (stop by creating `console.stop` in the data dir). With `VLESSCLIENT_DATA` / `VLESSCLIENT_BIN` it runs without installing anything; not elevated -> proxy-only mode.
  - `--snapshot <dir>`: development — renders every page off-screen to PNG (needs a running engine). Use it to check the UI without disturbing the user's desktop.
- `src/VlessClient/Core/` — settings, subscription parsing, xray / sing-box config builders (ported from the PowerShell edition), geo rule-sets (parser for Xray's geoip.dat / geosite.dat), network facts.
- `installer/` — WiX 4 package (`Package.wxs`), `build-msi.ps1` (cores from `cores.ps1`, pinned versions + SHA-256), `THIRD-PARTY.txt`.
- `.github/workflows/windows-msi.yml` — builds the MSI on every push; a `v*` tag also publishes a GitHub Release, which the in-app updater reads (`Service/Updater.cs`: releases/latest, the `.msi` asset and its `digest`).
- `legacy/` — the old PowerShell edition (`vpn.ps1`). Independent of the MSI; do not run both (two TUNs).
- `mobile/` — the phone app (Flutter, Android + iOS, GPL-3.0 because it links sing-box's libbox); see "Phone app" below.

## Phone app (mobile/)

- One Dart code base: `lib/core/` ports the Windows logic (subscription and node parsing, settings, the sing-box config builder, the traffic monitor of `Ui/Traffic.cs`), `lib/ui/` the screens with the same palette (`ui/theme.dart` = `Ui/Theme.cs`). `flutter analyze` and `flutter test` (test/core_test.dart) need no Android SDK.
- sing-box is the main core: the VLESS outbounds are built in `config.dart`. Nodes it cannot carry (XHTTP, VLESS encryption / mlkem) go through Xray on Android: the official Xray-core Android build is bundled as `jniLibs/<abi>/libxray.so` (arm64-v8a, x86_64; downloaded with pinned SHA-256 in CI, git-ignored) and run as a child process by `XrayProcess.kt` with `files/xray.json` from `xray.dart` (one SOCKS inbound per node on 12200 + index; sing-box reaches them with `socks` outbounds). A child process cannot `protect()` its sockets, so Xray dials the servers through sing-box's `mixed` inbound `xray-in` (127.0.0.1:12079, `sockopt.dialerProxy`), routed straight to `direct` by the first rule; the monitor skips those connections. iOS and armeabi-v7a have no Xray: such nodes stay greyed out (`Node.xrayAvailable`). Reality nodes go through Xray too (`Node.viaXray`): Xray servers since v26.9.8 refuse sing-box's Reality handshake (no X25519MLKEM768 key share, SagerNet/sing-box#4520); 3x-ui updates its Xray by itself, so assume every server is that new. Re-check when sing-box fixes it.
- "Проверить" (`AppState.testNodes`) measures through the tunnel's Clash API while it is on. While it is off it runs a probe: `SingBoxConfig.buildProbe` (only the node outbounds, plus `xray-in` when needed; no tun inbound; Clash API on `apiPort + 1`) and `files/xray-probe.json`. On Android that is `BoxVpnService` ACTION_PROBE (a plain started service, no foreground notification, no VPN; `startTunnel` stops a probe first); on iOS `Runner/Prober.swift` runs libbox inside the app (Libbox is linked into Runner as well). `connect()` waits for a running probe. Results go to `files/last-check.json` (the e2e test reads it).
- Node choice runs inside sing-box: one `urltest` group named `proxy`. "auto" lists the pool with the last good node first and tolerance 300 ms; a pinned node is followed by one spare with tolerance 60000 ms, so it only fails over when the pinned node is dead. urltest keeps the current pick unless another node beats it by more than the tolerance, which is why this does not hop like Xray's leastPing. Never use a selector over all nodes with a short tolerance.
- The app talks to the tunnel only through the Clash API on 127.0.0.1:12090 (delay tests, current node, `/connections` for the monitor, closing connections after a rule change). Rules are local rule-set files in `<data>/rules/` that sing-box hot-reloads; structural changes rebuild the config and call `reload`.
- Android (`android/app/src/main/kotlin/...`): `BoxVpnService` is a VpnService that implements libbox's PlatformInterface (modelled on SFA, the official sing-box app; most methods are stubs). sing-box's sockets are protected via `autoDetectInterfaceControl`; per-app rules use `package_name` with `find_process` (`getConnectionOwnerUid`). The Flutter channel is `vlessclient/vpn` in `MainActivity`.
- iOS (`ios/PacketTunnel/`, `ios/Runner/VpnChannel.swift`): a Packet Tunnel extension with libbox; the config goes in the start options and as a provider message on reload. The Xcode target is added in CI by `tools/add_tunnel_target.rb` (the committed project has no extension target). Data lives in the app group `group.io.github.dovletix.vlessclient`. Installing needs a paid Apple developer account (Network Extension entitlement); CI produces an unsigned IPA only.
- CI (`.github/workflows/mobile.yml`): libbox via `gomobile bind` (sagernet fork, tags in `LIBBOX_TAGS`, cached by `LIBBOX_CACHE`), the RU geo rule-sets from the Xray databases of `cores.ps1` (`tools/geo_rules.py` + `sing-box rule-set compile`), APKs per ABI plus universal, the unsigned IPA. A `mobile-v*` tag publishes a release with `--latest=false`, because the Windows updater reads releases/latest. The in-app Android updater lists releases, takes the newest `mobile-v*` and checks the APK's SHA-256 digest.
- Android release signing: repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them CI signs with a throw-away debug key and refuses to publish a tag. Never commit a keystore: anyone with it could ship "updates".

## Behaviour that matters

- Data: `C:\ProgramData\VlessClient` (settings.json, runtime\ configs and rule-sets, logs\). The service resets its ACL to SYSTEM + Administrators full, Users read: the service runs downloaded MSIs and generated configs as SYSTEM.
- The client never touches the Windows proxy settings. The window switches off a Windows proxy that points to a dead 127.0.0.1 port (`Ui/ProxyFix.cs`) — the classic leftover of Happ and similar apps.
- Cores run in a job object with KILL_ON_JOB_CLOSE: when the service dies, xray / sing-box die too and the Wintun adapter with its routes disappears. Verified by killing the engine process.
- Node choice: `node: "auto"` probes every node of the pool (separate xray, one SOCKS port per node, HTTP through each) and pins the fastest working one; the last good node is kept unless another is much faster. Never put several nodes into one balancer: new flows (a voice call) would hop to slow relays. The pinned node gets a spare via a one-candidate balancer with `fallbackTag`.
- Backup subscriptions (`subscription.backups`, Settings → "Запасные подписки", pipe `add_backup` / `remove_backup`): each is cached in `runtime\backup-<fnv of url>.txt`. `Subscription.LoadCached(settings)` lists the main nodes (Group 0) and then each backup's (Group 1..), numbered on; a server already in the list (same uuid@host:port — the query is ignored, 3x-ui hands out a random short id per download) is skipped, so a mirror of the main subscription adds nothing but still helps when the main link does not download. "auto" probes one group at a time and falls back to the next only when nothing in the earlier ones answers; a pinned node's spares come from its own group. Connect downloads when the main cache or any backup cache is older than `update_hours` (a backup that was never downloaded counts). The phone app (`mobile/lib/core/engine.dart`) does the same.
- Rule changes (apps, domains) are written to rule-set files that sing-box hot-reloads; default route / node / Russia switch reconnect.
- The tunnel is the only mode. The mixed proxy on 12080 always runs next to it (the connect check goes through it, and apps that support a proxy may use it); only a non-elevated `--console` run has no TUN.
- IPv6 on the tunnel only when a physical adapter has a real global IPv6 address. Teredo (2001:0::/32 on a Tunnel-type interface) and 6to4 do not count: an IPv6 route on the tunnel without real IPv6 makes direct IPv6 connections hang.
- Updates: manual by default (button in Settings); `auto_update` makes the service check every 12 h and install. The service downloads the MSI from this repo's releases only, checks the SHA-256 digest and runs `msiexec /qn`; the window notices status "installing", schedules its own restart and exits; the MSI closes running copies (util:CloseApplication) so no reboot is needed.
- Ports (localhost): mixed proxy 12080, xray SOCKS 12081, Clash API 12090 (secret in settings), probe ports 12200+.

## Window look and the "Процессы" monitor

- The design follows the web UI of the PowerShell edition (`ui/index.html` of that edition): same palette, pills, switches, chips, process table. `Ui/Theme.cs` holds the dark (default) and light palettes and puts them into `Application.Resources`; the choice is stored in `HKCU\Software\VlessClient\Theme`. Every colour in XAML is a `DynamicResource` with those keys (Bg, Panel, Text, Muted, Line, Accent, Ok, Bad, Warn, their *Soft variants, Chip, Track, Hover, Overlay); never hard-code colours, and never give a style a key that is also a colour key (a `Panel` style once shadowed the `Panel` brush and crashed the window).
- A TabItem's content inherits the TabItem's own Foreground / FontWeight (logical tree), so the tab style sets them to normal text and styles only the header's ContentPresenter.
- `Ui/Traffic.cs` is a port of the web UI's `Update-ConnStats` / `Read-NewLogErrors`: polls the Clash API `/connections` every second (off the UI thread), keeps per-exe and per-host byte counters and speeds, flags a connection that sent data but got no byte back as "no answer" (UDP counted apart), and attributes `ERROR ... open connection to X using outbound/...[tag]: reason` lines of `logs\sing-box.log` to the exe that last connected to X. Polling misses connections that open and close between two samples (short direct requests), like the web UI did.
- `Ui/ProcRow.cs` is one table row; rows are updated in place and reordered with `ObservableCollection.Move`, so expanded rows and tooltips survive the 1 s refresh.
- Snapshots: `VLESSCLIENT_THEME=light` renders the light theme; the snapshot mode never shows message boxes.

## Smart App Control

- Windows 11 Smart App Control (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy` `VerifiedAndReputablePolicyState`: 0 off, 1 on, 2 evaluation) blocks our unsigned VlessClient.exe: SCM error 7000 "application control policy has blocked this file", CodeIntegrity 3077, and Windows Installer reports the misleading error 1920 ("insufficient privileges to start system services") and rolls back with 1603.
- `installer/Package.wxs` has a launch condition that refuses to install while the state is 1 and tells the user how to switch it off. The only real fix is code signing — and xray / sing-box are unsigned upstream, so signing only our exe may not be enough.

## Removed modes (history)

- 2.0 had a "local proxy only" mode and 2.1.0 a "selected programs only" mode without TUN (ProxiFyre, wiresock, AGPL, on the Windows Packet Filter NDIS driver `NDISRD`). Both were removed in 2.2.0: they existed because the tunnel looked like a speed bottleneck, and it was not — the cap was the line. sing-box carries ~670 Mbit/s of direct traffic through the TUN on about one core of a desktop CPU. Do not bring them back for speed reasons.
- `Service/OldComponents.cs` cleans up after 2.1.0: on service start (and on uninstall, detached) it stops `ProxiFyreService`, disables it and runs `msiexec /x` for the product codes recorded in `components\installed-by-vlessclient.json` (ProxiFyre first, then the driver; retries while our own upgrade transaction holds the installer, error 1618). Only those products, never a copy the user installed. Remove this class once 2.1.0 is long gone.
- An old `settings.json` with `"mode": "apps"` / `"proxy"` or `ports.apps` loads fine; the keys are ignored and dropped on the next save.
- WinDivert was rejected for packet interception: Microsoft Defender (PUA protection) deletes even the official release as `Misleading:Win32/Malgent!AMTB`; bundling it would get the whole MSI quarantined.

## Testing on the developer's machine

- The developer's own VPN client must keep running during tests: the Claude app reaches the API only through it. Run the new engine side by side with `--console`, `VLESSCLIENT_DATA` / `VLESSCLIENT_BIN` and its own ports, and tell test traffic apart through the test engine's Clash API (`metadata.type`, e.g. `mixed/mixed-in`), not by exit IP.
- When the installed service runs on the same machine, also set `VLESSCLIENT_PIPE` (any other pipe name) for the `--console` engine and for a `--snapshot` / window started against it: otherwise both serve `VlessClient.Control.v2` and the tray window may talk to the test engine. Point `VLESSCLIENT_BIN` at a copy of the cores: the engine kills "orphan" xray / sing-box started from its bin folder.
- Speed baselines: `curl --interface <LAN IP>` bypasses the TUN. Before blaming the tunnel for a speed cap, compare with that baseline and with a phone on the same Wi-Fi.

## Constraints

- Keep the UI text Russian and plain: the main audience cannot read technical messages.
- `legacy/*.ps1` must stay ASCII-only (Windows PowerShell 5.1).
- Build check before committing: `dotnet build src/VlessClient/VlessClient.csproj -c Release`; installer: `installer/build-msi.ps1`.
- Commits use the noreply identity configured in the repo; never the personal e-mail.

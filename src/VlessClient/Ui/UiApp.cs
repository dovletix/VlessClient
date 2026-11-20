using System;
using System.Threading;
using System.Windows;
using Microsoft.Win32;

namespace VlessClient.Ui
{
    /// <summary>Starts the window and the tray icon; one instance per user session.</summary>
    public static class UiApp
    {
        private const string UserKey = @"Software\VlessClient";

        public static bool TrayAtLogon
        {
            get { using (var k = Registry.CurrentUser.OpenSubKey(UserKey)) return !(k?.GetValue("TrayAtLogon") is int v) || v != 0; }
            set { using (var k = Registry.CurrentUser.CreateSubKey(UserKey)) k.SetValue("TrayAtLogon", value ? 1 : 0, RegistryValueKind.DWord); }
        }

        public static bool HintShown
        {
            get { using (var k = Registry.CurrentUser.OpenSubKey(UserKey)) return k?.GetValue("TrayHintShown") is int v && v != 0; }
            set { using (var k = Registry.CurrentUser.CreateSubKey(UserKey)) k.SetValue("TrayHintShown", value ? 1 : 0, RegistryValueKind.DWord); }
        }

        /// <summary>Development aid: renders every page off-screen to PNG files and exits.</summary>
        public static int Snapshot(string dir)
        {
            System.IO.Directory.CreateDirectory(dir);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using (var client = new ServiceClient())
            {
                var w = new MainWindow(client) { ShowActivated = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000 };
                w.Start();
                w.Show();
                var steps = new System.Collections.Generic.Queue<Action>(w.SnapshotSteps(dir));
                var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
                t.Tick += (s, e) =>
                {
                    if (steps.Count == 0) { t.Stop(); app.Shutdown(); return; }
                    steps.Dequeue()();
                };
                t.Start();
                app.Run();
            }
            return 0;
        }

        public static int Run(bool startInTray)
        {
            using (var mutex = new Mutex(true, @"Local\VlessClient.UI", out var created))
            using (var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\VlessClient.UI.Show"))
            {
                if (!created)
                {
                    if (!startInTray) showEvent.Set();
                    return 0;
                }
                if (startInTray && !TrayAtLogon) return 0;

                var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                using (var client = new ServiceClient())
                {
                    var window = new MainWindow(client);
                    using (var tray = new TrayIcon(window))
                    {
                        var stop = new ManualResetEvent(false);
                        var waiter = new Thread(() =>
                        {
                            var handles = new WaitHandle[] { showEvent, stop };
                            while (WaitHandle.WaitAny(handles) == 0)
                                app.Dispatcher.BeginInvoke(new Action(window.ShowFromTray));
                        }) { IsBackground = true };
                        waiter.Start();

                        window.Start();
                        if (!startInTray) window.ShowFromTray();
                        app.Run();
                        stop.Set();
                    }
                }
                return 0;
            }
        }
    }
}

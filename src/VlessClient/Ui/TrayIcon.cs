using System;
using System.Drawing;
using System.Windows;
using Forms = System.Windows.Forms;

namespace VlessClient.Ui
{
    /// <summary>Notification-area icon: shows the state, opens the window, switches the VPN.</summary>
    public sealed class TrayIcon : IDisposable
    {
        private readonly MainWindow window;
        private readonly Forms.NotifyIcon icon;
        private readonly Forms.ToolStripMenuItem toggle;
        private readonly Icon on = Icons.Shield(Icons.On, true), off = Icons.Shield(Icons.Off, false), busy = Icons.Shield(Icons.Busy, false), bad = Icons.Shield(Icons.Bad, false);
        private string lastState = "";

        public TrayIcon(MainWindow window)
        {
            this.window = window;
            var menu = new Forms.ContextMenuStrip { Font = new Font("Segoe UI", 10f) };
            menu.Items.Add("Открыть VlessClient", null, (s, e) => window.ShowFromTray()).Font = new Font("Segoe UI", 10f, System.Drawing.FontStyle.Bold);
            toggle = new Forms.ToolStripMenuItem("Включить VPN", null, (s, e) => window.ToggleFromTray());
            menu.Items.Add(toggle);
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("Закрыть окно и значок (VPN продолжит работать)", null, (s, e) => window.ExitUi());
            icon = new Forms.NotifyIcon { Icon = off, Text = "VlessClient", Visible = true, ContextMenuStrip = menu };
            icon.MouseClick += (s, e) => { if (e.Button == Forms.MouseButtons.Left) window.ShowFromTray(); };
            window.StatusChanged += OnStatus;
            window.Notify += (title, text) => icon.ShowBalloonTip(5000, title, text, Forms.ToolTipIcon.Info);
        }

        private void OnStatus(string state, bool enabled, string text)
        {
            icon.Icon = state == "on" ? on : state == "connecting" ? busy : state == "error" ? bad : off;
            var tip = "VlessClient — " + text;
            icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            toggle.Text = enabled ? "Выключить VPN" : "Включить VPN";
            if (lastState == "on" && state == "error") icon.ShowBalloonTip(5000, "VlessClient", "Связь с VPN прервалась. Переподключаюсь…", Forms.ToolTipIcon.Warning);
            lastState = state;
        }

        public void Dispose()
        {
            icon.Visible = false;
            icon.Dispose();
        }
    }
}

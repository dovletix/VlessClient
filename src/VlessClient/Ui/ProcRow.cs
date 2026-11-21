using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Windows;

namespace VlessClient.Ui
{
    public sealed class HostVm
    {
        public string Host { get; set; }
        public bool Vpn { get; set; }
        public string RouteText => Vpn ? "VPN" : "напрямую";
        public string Now { get; set; }
        public string Totals { get; set; }
    }

    public sealed class FailVm
    {
        public string Time { get; set; }
        public string Dest { get; set; }
        public string Count { get; set; }
        public string RouteText { get; set; }
        public string Reason { get; set; }
    }

    /// <summary>A row of the "Процессы" table (the web UI's process row). Updated in place every second.</summary>
    public sealed class ProcRow : INotifyPropertyChanged
    {
        private static readonly CultureInfo Ru = CultureInfo.GetCultureInfo("ru-RU");
        private static readonly Dictionary<string, string> Reasons = new Dictionary<string, string>
        {
            ["no-answer"] = "нет ответа", ["timeout"] = "таймаут соединения", ["refused"] = "соединение отклонено", ["reset"] = "соединение сброшено",
            ["unreachable"] = "сеть недоступна", ["dns"] = "адрес не найден", ["error"] = "ошибка соединения",
        };

        public ProcData D { get; private set; } = new ProcData();
        public string Key { get; }
        public string AppName { get; private set; } = "";
        public bool Vpn { get; private set; }
        private bool expanded;

        public ProcRow(string key) { Key = key; }

        public event PropertyChangedEventHandler PropertyChanged;

        public void Update(ProcData d, string appName, bool vpn)
        {
            D = d; AppName = appName ?? ""; Vpn = vpn;
            if (!CanOpen) expanded = false;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        }

        public bool IsExpanded
        {
            get => expanded;
            set { expanded = value && CanOpen; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); }
        }

        // ---- name
        public bool IsUnknown => Key == TrafficMonitor.Unknown;
        public string Name => IsUnknown ? "Процесс не определён" : D.Name;
        public string AppSuffix => AppName.Length > 0 && !string.Equals(AppName + ".exe", Key, StringComparison.OrdinalIgnoreCase) ? " · " + AppName : "";
        public string Path => D.Path;
        public Visibility PathVisibility => D.Path.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        public bool Running => D.Running;
        public bool CanOpen => D.Hosts.Count > 0 || D.Fails.Count > 0;
        public string Chevron => CanOpen ? (expanded ? "▾" : "▸") : "";

        // ---- speed / totals / connections
        public string SpeedDown => D.RDown + D.RUp > 0 ? "↓ " + Rate(D.RDown) : "—";
        public string SpeedUp => D.RDown + D.RUp > 0 ? "↑ " + Rate(D.RUp) : "";
        public bool Hot => D.RDown + D.RUp > 125000;
        public string TotalDown => D.Down + D.Up > 0 ? "↓ " + Bytes(D.Down) : "—";
        public string TotalUp => D.Down + D.Up > 0 ? "↑ " + Bytes(D.Up) : "";
        public string ConnsActive => D.Total > 0 ? D.Active.ToString() : "—";
        public string ConnsTotal => D.Total > 0 ? " / " + D.Total : "";

        // ---- where the traffic goes
        private long Sum => D.PBytes + D.DBytes;
        public string VpnPart => Sum > 0 ? (D.PBytes > 0 ? "VPN " + Bytes(D.PBytes) : "") : D.Total > 0 && D.ProxyN > 0 ? "VPN" : "";
        public string DirectPart => Sum > 0 ? (D.DBytes > 0 ? "напрямую " + Bytes(D.DBytes) : "") : D.Total > 0 && D.DirectN > 0 ? "напрямую" : "";
        public string RouteSep => VpnPart.Length > 0 && DirectPart.Length > 0 ? " · " : "";
        public Visibility RouteNoneVisibility => VpnPart.Length + DirectPart.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        public Visibility BarVisibility => Sum > 0 ? Visibility.Visible : Visibility.Collapsed;
        public GridLength BarVpn => new GridLength(Sum > 0 ? Math.Max(0.0001, (double)D.PBytes / Sum) : 0.5, GridUnitType.Star);
        public GridLength BarDirect => new GridLength(Sum > 0 ? Math.Max(0.0001, (double)D.DBytes / Sum) : 0.5, GridUnitType.Star);
        public string BarTip => Sum > 0 ? $"VPN {Math.Round(100.0 * D.PBytes / Sum)}%, напрямую {100 - Math.Round(100.0 * D.PBytes / Sum)}%" : "";

        // ---- problems
        public string FailText => D.Fail + " без ответа";
        public Visibility FailVisibility => D.Fail > 0 ? Visibility.Visible : Visibility.Collapsed;
        public string UdpText => "UDP: " + D.Udp;
        public Visibility UdpVisibility => D.Udp > 0 ? Visibility.Visible : Visibility.Collapsed;
        public string NoProblems => D.Fail > 0 || D.Udp > 0 ? "" : D.Total > 0 ? "нет" : "—";

        // ---- rule
        public Visibility SwitchVisibility => !IsUnknown && AppName.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        public Visibility ButtonsVisibility => !IsUnknown && AppName.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        public Visibility UnknownVisibility => IsUnknown ? Visibility.Visible : Visibility.Collapsed;

        // ---- details (click) and tooltip (hover)
        public Visibility DetailsVisibility => expanded && CanOpen ? Visibility.Visible : Visibility.Collapsed;
        public Visibility HostsVisibility => D.Hosts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        public Visibility FailsVisibility => D.Fails.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        public string HostsHeader => "Куда ходит" + (D.NHosts > D.Hosts.Count ? $" (первые {D.Hosts.Count} из {D.NHosts} адресов по скорости и объёму)" : "");
        public List<HostVm> Hosts => D.Hosts.Select(h => new HostVm
        {
            Host = h.Host, Vpn = h.Out != "direct",
            Now = h.RDown + h.RUp > 0 ? "↓ " + Rate(h.RDown) + " · ↑ " + Rate(h.RUp) : "—",
            Totals = "↓ " + Bytes(h.Down) + " · ↑ " + Bytes(h.Up),
        }).ToList();
        public List<HostVm> TipHosts => Hosts.Take(8).ToList();
        public List<FailVm> Fails => D.Fails.Select(f => new FailVm
        {
            Time = f.Time, Dest = f.Dest, Count = f.N > 1 ? " ×" + f.N : "",
            RouteText = f.Out == "direct" ? "напрямую" : "через VPN",
            Reason = (f.Udp ? "UDP, " : "") + (Reasons.TryGetValue(f.Reason, out var r) ? r : f.Reason),
        }).ToList();
        public string Advice
        {
            get
            {
                if (D.Fails.Count == 0) return "";
                if (D.Fail < 3 || D.Fail < 0.15 * D.Total) return "Единичные сбои на фоне работающих соединений — обычно это норма.";
                if (D.FProxy > D.FDirect) return "Сбои в основном через VPN — попробуйте пустить программу напрямую.";
                if (D.FDirect > 0) return "Сбои в основном при прямом соединении — попробуйте пустить программу через VPN.";
                return "";
            }
        }
        public Visibility AdviceVisibility => Advice.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        public string TipTitle => CanOpen ? "Щёлкните, чтобы раскрыть" + (D.Fails.Count > 0 ? " — там же соединения без ответа" : "") : "Пока нет адресов";
        public string TipFails => D.Fail + D.Udp > 0 ? $"Без ответа: {D.Fail}" + (D.Udp > 0 ? $", UDP: {D.Udp}" : "") : "";
        public Visibility TipFailsVisibility => D.Fail + D.Udp > 0 ? Visibility.Visible : Visibility.Collapsed;

        // ---- sorting
        public double SortSpeed => D.RDown + D.RUp;
        public double SortTotal => D.Down + D.Up;
        public double SortConns => D.Active * 100000.0 + D.Total;
        public double SortVpn => D.PBytes;
        public double SortFail => D.Fail * 1000.0 + D.Udp;

        // ---- formatting (the web UI's rate() and bytes())
        public static string Rate(double bytesPerSec)
        {
            var b = bytesPerSec * 8;
            if (b < 1000) return "0";
            if (b < 1e6) return Math.Round(b / 1e3) + " Кбит/с";
            return (b / 1e6).ToString("0.0", Ru) + " Мбит/с";
        }

        public static string Bytes(long n)
        {
            if (n < 1024) return n + " Б";
            string[] u = { "КБ", "МБ", "ГБ", "ТБ" };
            double v = n; var i = -1;
            do { v /= 1024; i++; } while (v >= 1024 && i < u.Length - 1);
            return v.ToString(v < 10 ? "0.0" : "0", Ru) + " " + u[i];
        }
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace VlessClient.Core
{
    /// <summary>Facts about the local network that the configs depend on.</summary>
    public static class NetInfo
    {
        private static readonly Regex VirtualAdapter = new Regex(
            "happ|check point|wintun|sing-tun|sing-box|xray|radmin|virtualbox|wireguard|vmware|hyper-v|loopback|bluetooth|tap-windows|openvpn|tailscale|zerotier|vlessclient|vless-tun",
            RegexOptions.IgnoreCase);

        private static IEnumerable<NetworkInterface> PhysicalUp(Settings s) =>
            NetworkInterface.GetAllNetworkInterfaces().Where(i =>
                i.OperationalStatus == OperationalStatus.Up &&
                i.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                i.NetworkInterfaceType != NetworkInterfaceType.Tunnel &&       // Teredo, 6to4, IP-HTTPS: not real IPv6 uplinks
                i.Description.IndexOf("Teredo", StringComparison.OrdinalIgnoreCase) < 0 &&
                !VirtualAdapter.IsMatch(i.Description) && !VirtualAdapter.IsMatch(i.Name) &&
                !i.Name.Equals(s.TunName, StringComparison.OrdinalIgnoreCase));

        /// <summary>True when a real adapter has a global IPv6 address, i.e. the uplink provides IPv6.</summary>
        public static bool HasNativeIPv6(Settings s)
        {
            try
            {
                foreach (var i in PhysicalUp(s))
                    foreach (var a in i.GetIPProperties().UnicastAddresses)
                        if (a.Address.AddressFamily == AddressFamily.InterNetworkV6 && !a.Address.IsIPv6LinkLocal && !a.Address.IsIPv6SiteLocal && !a.Address.IsIPv6Teredo)
                        {
                            var b = a.Address.GetAddressBytes();
                            if ((b[0] & 0xE0) != 0x20) continue;                 // only global unicast 2000::/3
                            if (b[0] == 0x20 && b[1] == 0x02) continue;          // 6to4
                            if (a.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                            return true;
                        }
            }
            catch { }
            return false;
        }

        /// <summary>DNS server of the real uplink (used for direct lookups while the tunnel is up).</summary>
        public static string DirectDns(Settings s)
        {
            if (!string.IsNullOrWhiteSpace(s.DnsDirect) && s.DnsDirect != "auto") return s.DnsDirect;
            try
            {
                foreach (var i in PhysicalUp(s).Where(i => i.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork)))
                {
                    var dns = i.GetIPProperties().DnsAddresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                    if (dns != null) return dns.ToString();
                }
            }
            catch { }
            return "77.88.8.8";
        }

        /// <summary>/32 routes for every server address, so that the connection to the VPN server itself never enters the tunnel.</summary>
        public static List<string> ServerRoutes(Settings s, IEnumerable<Node> nodes)
        {
            var hosts = nodes.Select(n => n.Address).ToList();
            try { hosts.Add(new Uri(s.SubscriptionUrl).Host); } catch { }
            var res = new List<string>();
            foreach (var h in hosts.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (IPAddress.TryParse(h, out var ip)) { res.Add(ip + (ip.AddressFamily == AddressFamily.InterNetworkV6 ? "/128" : "/32")); continue; }
                try { foreach (var a in Dns.GetHostAddresses(h)) res.Add(a + (a.AddressFamily == AddressFamily.InterNetworkV6 ? "/128" : "/32")); } catch { }
            }
            return res.Distinct().ToList();
        }

        /// <summary>Gateways of Check Point Endpoint VPN (from "trac info") plus the configured addresses.</summary>
        public static List<string> CheckpointRoutes(Settings s)
        {
            var res = new List<string>();
            if (!s.CheckpointEnabled) return res;
            res.AddRange(s.CheckpointExcludeIps);
            try
            {
                var trac = Path.Combine(s.CheckpointPath, @"Endpoint Connect\trac.exe");
                if (File.Exists(trac))
                {
                    var psi = new ProcessStartInfo(trac, "info") { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
                    using (var p = Process.Start(psi))
                    {
                        var outText = p.StandardOutput.ReadToEnd();
                        p.WaitForExit(6000);
                        foreach (Match m in Regex.Matches(outText, @"gw:\s*(\d+\.\d+\.\d+\.\d+)")) res.Add(m.Groups[1].Value + "/32");
                    }
                }
            }
            catch { }
            return res.Distinct().ToList();
        }

        /// <summary>Other tunnels that take the default route (Happ, an old client...). They break our tunnel.</summary>
        public static List<string> ForeignTunnels(Settings s)
        {
            var res = new List<string>();
            try
            {
                foreach (var i in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (i.OperationalStatus != OperationalStatus.Up) continue;
                    if (i.Name.Equals(s.TunName, StringComparison.OrdinalIgnoreCase)) continue;
                    var d = i.Description + " " + i.Name;
                    if (Regex.IsMatch(d, "happ|wintun|sing-tun|vless-tun|hiddify|v2ray|nekoray|clash|outline", RegexOptions.IgnoreCase)) res.Add(i.Name);
                }
            }
            catch { }
            return res;
        }

        public static bool IsPortFree(int port)
        {
            try
            {
                var l = new TcpListener(IPAddress.Loopback, port);
                l.Start(); l.Stop();
                return true;
            }
            catch { return false; }
        }
    }
}

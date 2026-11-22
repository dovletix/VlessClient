using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Service
{
    public sealed class ProbeResult
    {
        public Node Node;
        public bool Ok;
        public int Ms;
        public string Error = "";
    }

    /// <summary>Checks nodes for real: a separate xray with one SOCKS port per node, then an HTTP request through each.</summary>
    public static class Prober
    {
        public const int BasePort = 12200;

        /// <summary>The engine's job object (kill on close): a probe xray dies with the engine instead of holding the ports.</summary>
        internal static JobObject Job;

        /// <summary>HTTP GET http://www.gstatic.com/generate_204 through a local SOCKS5 port. Returns milliseconds or throws.</summary>
        public static async Task<int> HttpThroughSocks(int port, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            using (var tcp = new TcpClient())
            {
                var work = Run(tcp, port);
                if (await Task.WhenAny(work, Task.Delay(timeoutMs)).ConfigureAwait(false) != work) throw new TimeoutException("нет ответа за " + timeoutMs / 1000 + " с");
                await work.ConfigureAwait(false);
                return (int)sw.ElapsedMilliseconds;
            }
        }

        private static async Task Run(TcpClient tcp, int port)
        {
            await tcp.ConnectAsync("127.0.0.1", port).ConfigureAwait(false);
            var s = tcp.GetStream();
            await s.WriteAsync(new byte[] { 5, 1, 0 }, 0, 3).ConfigureAwait(false);
            var b = new byte[512];
            await ReadExactly(s, b, 2).ConfigureAwait(false);
            if (b[0] != 5 || b[1] != 0) throw new IOException("SOCKS: метод не принят");
            const string host = "www.gstatic.com";
            var req = new List<byte> { 5, 1, 0, 3, (byte)host.Length };
            req.AddRange(Encoding.ASCII.GetBytes(host));
            req.Add(0); req.Add(80);
            await s.WriteAsync(req.ToArray(), 0, req.Count).ConfigureAwait(false);
            await ReadExactly(s, b, 4).ConfigureAwait(false);
            if (b[1] != 0) throw new IOException("SOCKS: сервер отказал (код " + b[1] + ")");
            var rest = b[3] == 1 ? 6 : b[3] == 4 ? 18 : -1;
            if (rest < 0) { await ReadExactly(s, b, 1).ConfigureAwait(false); rest = b[0] + 2; }
            await ReadExactly(s, b, rest).ConfigureAwait(false);
            var http = Encoding.ASCII.GetBytes("GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n");
            await s.WriteAsync(http, 0, http.Length).ConfigureAwait(false);
            var n = await s.ReadAsync(b, 0, b.Length).ConfigureAwait(false);
            var line = Encoding.ASCII.GetString(b, 0, n);
            if (!line.StartsWith("HTTP/1.", StringComparison.Ordinal)) throw new IOException("нет ответа через сервер");
            if (!line.Contains(" 204") && !line.Contains(" 200")) throw new IOException("неожиданный ответ: " + line.Split('\r')[0]);
        }

        private static async Task ReadExactly(Stream s, byte[] b, int count)
        {
            var got = 0;
            while (got < count)
            {
                var n = await s.ReadAsync(b, got, count - got).ConfigureAwait(false);
                if (n <= 0) throw new IOException("соединение закрыто");
                got += n;
            }
        }

        /// <summary>Probes all given nodes in parallel. Results sorted: working first, by latency.</summary>
        public static async Task<List<ProbeResult>> ProbeAsync(IList<Node> nodes, int timeoutMs = 10000)
        {
            var results = nodes.Select(n => new ProbeResult { Node = n, Error = "не проверен" }).ToList();
            if (nodes.Count == 0) return results;
            // Every probe port must be free. A port held by another program (once: a leftover probe xray) answers instead
            // of ours, our xray cannot listen and exits, and every node looks dead.
            var basePort = FreeBase(nodes);
            if (basePort < 0) { foreach (var r in results) r.Error = "нет свободных портов для проверки"; return results; }
            var cfgPath = Path.Combine(Paths.RuntimeDir, "xray-probe.json");
            File.WriteAllText(cfgPath, Json.Serialize(XrayConfig.Probe(nodes, basePort, Path.Combine(Paths.LogsDir, "xray-probe.log")), true), Paths.Utf8);
            Process p = null;
            try
            {
                p = Process.Start(new ProcessStartInfo(Paths.XrayExe, "run -c \"" + cfgPath + "\"")
                {
                    UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Paths.RuntimeDir
                });
                try { Job?.Add(p); } catch (Exception e) { Log.Write("job: cannot add probe: " + e.Message); }
                // wait until the last port listens (xray opens the inbounds in order)
                var last = basePort + nodes.Max(n => n.Index);
                for (var i = 0; i < 40 && !p.HasExited && NetInfo.IsPortFree(last); i++) await Task.Delay(100).ConfigureAwait(false);
                if (p.HasExited) { foreach (var r in results) r.Error = "xray не запустился (код " + p.ExitCode + ")"; return results; }
                await Task.WhenAll(results.Select(async r =>
                {
                    try { r.Ms = await HttpThroughSocks(basePort + r.Node.Index, timeoutMs).ConfigureAwait(false); r.Ok = true; r.Error = ""; }
                    catch (Exception e) { r.Ok = false; r.Error = e.Message; }
                })).ConfigureAwait(false);
            }
            finally
            {
                try { if (p != null && !p.HasExited) p.Kill(); } catch { }
                p?.Dispose();
            }
            return results.OrderByDescending(r => r.Ok).ThenBy(r => r.Ok ? r.Ms : int.MaxValue).ThenBy(r => r.Node.Index).ToList();
        }

        /// <summary>The first of 12200, 13200, … 19200 at which every node's probe port (base + index) is free; -1 if none.</summary>
        private static int FreeBase(IList<Node> nodes)
        {
            for (var k = 0; k < 8; k++)
            {
                var b = BasePort + 1000 * k;
                if (nodes.All(n => NetInfo.IsPortFree(b + n.Index))) return b;
            }
            return -1;
        }
    }
}

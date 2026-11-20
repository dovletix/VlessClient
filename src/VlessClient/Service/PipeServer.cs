using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>Named pipe through which the window controls the service. One JSON request per line, one JSON reply per line.</summary>
    public sealed class PipeServer : IDisposable
    {
        private readonly Engine engine;
        private readonly CancellationTokenSource cts = new CancellationTokenSource();

        public PipeServer(Engine engine) { this.engine = engine; }

        public void Start() => Task.Run(AcceptLoop);

        public void Dispose() => cts.Cancel();

        private static PipeSecurity Security()
        {
            var ps = new PipeSecurity();
            ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            // Any signed-in user may switch the VPN on/off and change its rules (home PC; the window runs without admin rights).
            ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
            using (var me = WindowsIdentity.GetCurrent())
                ps.AddAccessRule(new PipeAccessRule(me.User, PipeAccessRights.FullControl, AccessControlType.Allow));
            return ps;
        }

        private async Task AcceptLoop()
        {
            while (!cts.IsCancellationRequested)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    pipe = new NamedPipeServerStream(Paths.PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 64 * 1024, 64 * 1024, Security());
                    await pipe.WaitForConnectionAsync(cts.Token).ConfigureAwait(false);
                    var p = pipe; pipe = null;
                    _ = Task.Run(() => Serve(p));
                }
                catch (OperationCanceledException) { pipe?.Dispose(); return; }
                catch (Exception e) { pipe?.Dispose(); Log.Write("pipe: " + e.Message); await Task.Delay(1000).ConfigureAwait(false); }
            }
        }

        private async Task Serve(NamedPipeServerStream pipe)
        {
            using (pipe)
            using (var reader = new StreamReader(pipe, Paths.Utf8, false, 4096, true))
            using (var writer = new StreamWriter(pipe, Paths.Utf8, 4096, true) { AutoFlush = true, NewLine = "\n" })
            {
                try
                {
                    while (pipe.IsConnected && !cts.IsCancellationRequested)
                    {
                        var line = await reader.ReadLineAsync().ConfigureAwait(false);
                        if (line == null) break;
                        JObj reply;
                        try { reply = await Handle(Json.ParseObject(line)).ConfigureAwait(false); }
                        catch (Exception e) { reply = new JObj().Set("ok", false).Set("error", e.Message); }
                        await writer.WriteLineAsync(Json.Serialize(reply)).ConfigureAwait(false);
                    }
                }
                catch (IOException) { }
                catch (Exception e) { Log.Write("pipe: " + e.Message); }
            }
        }

        private static JObj Ok() => new JObj().Set("ok", true);
        private static JObj Result(string err) => err == null ? Ok() : new JObj().Set("ok", false).Set("error", err);

        private async Task<JObj> Handle(Dictionary<string, object> r)
        {
            switch (r.Str("cmd"))
            {
                case "status": return Ok().Set("status", engine.Status());
                case "settings": return Ok().Set("settings", engine.SettingsView());
                case "connect": engine.Connect(); return Ok();
                case "disconnect": await Task.Run(() => engine.Disconnect()).ConfigureAwait(false); return Ok();
                case "set_subscription": return Result(await engine.SetSubscriptionAsync(r.Str("url"), r.Bool("insecure")).ConfigureAwait(false));
                case "refresh_subscription": return Result(await engine.RefreshSubscriptionAsync().ConfigureAwait(false));
                case "set_node":
                    {
                        var node = r.Str("node", "auto");
                        return Result(engine.Change(s => s.Node = node, true));
                    }
                case "set_option": return Result(SetOption(r.Str("key"), r));
                case "set_app":
                    {
                        var name = r.Str("name").Trim();
                        var procs = r.Strings("processes");
                        if (name.Length == 0 || name.Length > 80) return Result("Некорректное название программы");
                        foreach (var p in procs) if (!System.Text.RegularExpressions.Regex.IsMatch(p, @"^[^\\/:*?""<>|\r\n]{1,120}\.exe$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                                return Result("Нужно имя файла вида program.exe");
                        var vpn = r.Bool("vpn");
                        return Result(engine.Change(s => s.SetApp(name, procs, vpn), false));
                    }
                case "remove_app":
                    {
                        var name = r.Str("name");
                        return Result(engine.Change(s => s.Apps.RemoveAll(a => a.Name == name), false));
                    }
                case "set_domain":
                    {
                        var list = r.Str("list"); var value = r.Str("value").Trim(); var add = r.Str("op") != "remove";
                        if (list != "direct" && list != "proxy") return Result("Неизвестный список");
                        if (!value.StartsWith("regex:", StringComparison.OrdinalIgnoreCase))
                            value = System.Text.RegularExpressions.Regex.Replace(value.ToLowerInvariant(), "^https?://", "").Split('/')[0];
                        if (value.Length == 0 || value.Length > 200 || value.IndexOfAny(new[] { ' ', '"', '\\', '<', '>' }) >= 0 && !value.StartsWith("regex:")) return Result("Некорректный адрес");
                        var isIp = System.Text.RegularExpressions.Regex.IsMatch(value, @"^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$|^[0-9a-f:]+:[0-9a-f:]*(/\d{1,3})?$");
                        return Result(engine.Change(s =>
                        {
                            var target = list == "direct" ? (isIp ? s.DirectIps : s.DirectDomains) : (isIp ? s.ProxyIps : s.ProxyDomains);
                            target.RemoveAll(x => x.Equals(value, StringComparison.OrdinalIgnoreCase));
                            if (add) target.Add(value);
                        }, false));
                    }
                case "test_nodes":
                    {
                        var res = await engine.TestNodesAsync().ConfigureAwait(false);
                        return Ok().Set("results", res.Select(x => (object)new JObj().Set("index", x.Node.Index).Set("name", x.Node.Name).Set("kind", x.Node.Kind)
                            .Set("ok", x.Ok).Set("ms", x.Ms).Set("error", x.Error)).ToList());
                    }
                case "report": return Ok().Set("text", engine.Report());
                case "update_check": return Result(await engine.Updater.CheckAsync().ConfigureAwait(false)).Set("update", engine.Updater.StatusJson());
                case "update_install": return Result(await engine.Updater.InstallAsync().ConfigureAwait(false));
                default: return Result("Неизвестная команда");
            }
        }

        private string SetOption(string key, Dictionary<string, object> r)
        {
            switch (key)
            {
                case "mode":
                    {
                        var raw = r.Str("value");
                        var v = raw == "proxy" || raw == "apps" ? raw : "tun";
                        return engine.Change(s => s.Mode = v, true);
                    }
                case "default":
                    {
                        var v = r.Str("value") == "direct" ? "direct" : "proxy";
                        return engine.Change(s => s.Default = v, true);
                    }
                case "ru_direct":
                    {
                        var v = r.Bool("value");
                        return engine.Change(s => s.RuDirect = v, true);
                    }
                case "auto_update":
                    {
                        var v = r.Bool("value");
                        return engine.Change(s => s.AutoUpdate = v, false);
                    }
                case "auto_exclude":
                    {
                        var v = r.Str("value").Trim();
                        try { if (v.Length > 0) new System.Text.RegularExpressions.Regex(v); } catch { return "Некорректный фильтр"; }
                        return engine.Change(s => s.AutoExclude = v, true);
                    }
                default: return "Неизвестная настройка";
            }
        }
    }
}

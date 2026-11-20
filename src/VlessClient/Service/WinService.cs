using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>The Windows service "VlessClient" (LocalSystem): keeps the VPN running regardless of who is signed in.</summary>
    public sealed class WinService : ServiceBase
    {
        private Engine engine;
        private PipeServer pipe;

        public WinService()
        {
            ServiceName = Paths.ServiceName;
            CanShutdown = true;
            CanStop = true;
            AutoLog = false;
        }

        protected override void OnStart(string[] args)
        {
            HardenDataDir();
            engine = new Engine();
            pipe = new PipeServer(engine);
            pipe.Start();
            engine.Start();
        }

        protected override void OnStop() => StopAll();
        protected override void OnShutdown() => StopAll();

        private void StopAll()
        {
            pipe?.Dispose();
            engine?.Shutdown();
        }

        /// <summary>Settings and downloaded updates must not be writable by ordinary users: the service runs them as SYSTEM.</summary>
        public static void HardenDataDir()
        {
            try
            {
                var dir = new DirectoryInfo(Paths.DataDir);
                var sec = new DirectorySecurity();
                sec.SetAccessRuleProtection(true, false);
                const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
                sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
                sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
                sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
                dir.SetAccessControl(sec);
            }
            catch (Exception e) { Log.Write("data dir ACL: " + e.Message); }
        }
    }
}

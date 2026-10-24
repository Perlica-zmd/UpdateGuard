using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Xml;
using Microsoft.Win32;

namespace LiquidWU
{
    public enum LogLevel { Info, Ok, Warn, Err }

    public delegate void LogHandler(string message, LogLevel level);

    /// <summary>进度回调: 百分比 0-100 + 阶段说明。</summary>
    public delegate void ProgressHandler(int percent, string stage);

    public class SvcInfo
    {
        public string Name;
        public bool Running;
        public int Start = -1;     // 2=自动 3=手动 4=禁用 -1=未知

        public string StartText
        {
            get
            {
                if (Start == 2) return "自动";
                if (Start == 3) return "手动";
                if (Start == 4) return "已禁用";
                return "未知";
            }
        }
        public bool IsDisabled { get { return Start == 4; } }
    }

    public class TaskInfo
    {
        public string FilePath;
        public string TaskPath;
        public string TaskName;
        public bool Enabled = true;    // 读不到时按启用处理(保守)
        public bool Readable;
    }

    /// <summary>
    /// 全部功能性逻辑: 与 Disable-WindowsUpdate-Tool v1.3 等价, 但用原生 .NET 实现。
    /// </summary>
    public static class WuCore
    {
        public static readonly string[] SvcCore = { "wuauserv", "usosvc", "dosvc", "WaaSMedicSvc", "bits" };
        public static readonly string[] StopOrder = { "usosvc", "WaaSMedicSvc", "wuauserv", "dosvc", "bits" };
        public static readonly string[] ProcNames = { "MoUsoCoreWorker", "TiWorker", "wuauclt", "usoclient" };

        public static readonly string[] TaskFolders = {
            @"C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator",
            @"C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic",
            @"C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate",
            @"C:\Windows\System32\Tasks\Microsoft\Windows\InstallService"
        };

        public const string TasksRoot = @"C:\Windows\System32\Tasks";
        public const string PolicyAU = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";
        public const string TaskNs = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        public const string SddlBaNoStop = "CCLCSWRPDTLOCRRCWDWO;;;BA";
        public const string SddlBaWithStop = "CCLCSWRPWPDTLOCRRCWDWO;;;BA";

        // 系统默认启动类型 (依据实机 7040 日志里系统自己恢复到的值)
        private static readonly Dictionary<string, int> DefaultStart = new Dictionary<string, int>();
        private static readonly Dictionary<string, int> DefaultDelayed = new Dictionary<string, int>();

        static WuCore()
        {
            DefaultStart["wuauserv"] = 3; DefaultDelayed["wuauserv"] = 0;
            DefaultStart["WaaSMedicSvc"] = 3; DefaultDelayed["WaaSMedicSvc"] = 0;
            DefaultStart["usosvc"] = 2; DefaultDelayed["usosvc"] = 1;
            DefaultStart["dosvc"] = 2; DefaultDelayed["dosvc"] = 1;
            DefaultStart["bits"] = 2; DefaultDelayed["bits"] = 1;
        }

        public static string DataDir
        {
            get
            {
                string root = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                if (string.IsNullOrEmpty(root)) root = Path.GetTempPath();
                return Path.Combine(root, "UpdateGuard");
            }
        }
        public static string BackupDir { get { return Path.Combine(DataDir, "tasks"); } }
        public static string BaselineFile { get { return Path.Combine(DataDir, "services.txt"); } }

        // ---------------------------------------------------------------- 基础

        public static bool IsAdmin()
        {
            try
            {
                WindowsIdentity id = WindowsIdentity.GetCurrent();
                WindowsPrincipal p = new WindowsPrincipal(id);
                return p.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        public static void EnsureDirs()
        {
            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
                if (!Directory.Exists(BackupDir)) Directory.CreateDirectory(BackupDir);
            }
            catch { }
        }

        public static int ReadSvcStart(string name)
        {
            // 先读注册表; 读不到(键权限被旧版 ACL 锁改坏)就退回问 SCM ——
            // SCM 有自己的一份配置副本, 不受键 ACL 影响, 是权威视图。
            int v = ReadSvcStartReg(name);
            if (v >= 0) return v;
            return ReadSvcStartScm(name);
        }

        private static int ReadSvcStartReg(string name)
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + name))
                {
                    if (k == null) return -1;
                    object v = k.GetValue("Start");
                    if (v == null) return -1;
                    return Convert.ToInt32(v);
                }
            }
            catch { return -1; }
        }

        private static int ReadSvcStartScm(string name)
        {
            try
            {
                string outp = RunCapture("sc.exe", "qc " + name);
                int idx = outp.IndexOf("START_TYPE", StringComparison.OrdinalIgnoreCase);
                if (idx < 0) return -1;
                int colon = outp.IndexOf(':', idx);
                if (colon < 0) return -1;
                for (int i = colon + 1; i < outp.Length; i++)
                {
                    if (outp[i] >= '0' && outp[i] <= '9') return outp[i] - '0';
                    if (outp[i] != ' ' && outp[i] != '\t') return -1;
                }
            }
            catch { }
            return -1;
        }

        private static void Report(ProgressHandler prog, int pct, string stage)
        {
            if (prog != null) prog(pct, stage);
        }

        public static List<SvcInfo> GetServices()
        {
            List<SvcInfo> list = new List<SvcInfo>();
            foreach (string n in SvcCore)
            {
                SvcInfo s = new SvcInfo();
                s.Name = n;
                s.Start = ReadSvcStart(n);
                s.Running = false;
                try
                {
                    using (ServiceController sc = new ServiceController(n))
                    {
                        s.Running = (sc.Status != ServiceControllerStatus.Stopped);
                    }
                }
                catch { }
                list.Add(s);
            }
            return list;
        }

        public static bool IsPolicyOn()
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(PolicyAU))
                {
                    if (k == null) return false;
                    object v = k.GetValue("NoAutoUpdate");
                    return v != null && Convert.ToInt32(v) == 1;
                }
            }
            catch { return false; }
        }

        public static List<TaskInfo> GetTasks()
        {
            List<TaskInfo> list = new List<TaskInfo>();
            foreach (string folder in TaskFolders)
            {
                if (!Directory.Exists(folder)) continue;
                string[] files;
                try { files = Directory.GetFiles(folder, "*", SearchOption.AllDirectories); }
                catch { continue; }
                foreach (string f in files)
                {
                    try { if ((File.GetAttributes(f) & FileAttributes.Directory) != 0) continue; }
                    catch { continue; }
                    TaskInfo t = new TaskInfo();
                    t.FilePath = f;
                    string rel = f.Substring(TasksRoot.Length);
                    int i = rel.LastIndexOf('\\');
                    t.TaskPath = rel.Substring(0, i + 1);
                    t.TaskName = rel.Substring(i + 1);
                    t.Enabled = ReadTaskEnabled(f, out t.Readable);
                    list.Add(t);
                }
            }
            return list;
        }

        private static bool ReadTaskEnabled(string file, out bool readable)
        {
            readable = false;
            try
            {
                XmlDocument doc = new XmlDocument();
                doc.PreserveWhitespace = true;
                doc.Load(file);
                XmlNamespaceManager nsm = new XmlNamespaceManager(doc.NameTable);
                nsm.AddNamespace("t", TaskNs);
                XmlNode settings = doc.SelectSingleNode("/t:Task/t:Settings", nsm);
                if (settings == null) { readable = true; return true; }
                XmlNode en = settings.SelectSingleNode("t:Enabled", nsm);
                readable = true;
                if (en == null) return true;
                return !string.Equals(en.InnerText.Trim(), "false", StringComparison.OrdinalIgnoreCase);
            }
            catch { return true; }
        }

        // ---------------------------------------------------------------- 工具

        public static string RunCapture(string exe, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    string outp = p.StandardOutput.ReadToEnd();
                    string errp = p.StandardError.ReadToEnd();
                    p.WaitForExit(30000);
                    return outp + errp;
                }
            }
            catch { return ""; }
        }

        private static int RunExit(string exe, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    p.StandardOutput.ReadToEnd();
                    p.StandardError.ReadToEnd();
                    p.WaitForExit(60000);
                    return p.ExitCode;
                }
            }
            catch { return -1; }
        }

        private static void TakeOwnership(string file)
        {
            RunCapture("takeown.exe", "/F \"" + file + "\" /A");
            RunCapture("icacls.exe", "\"" + file + "\" /grant \"*S-1-5-32-544:(F)\"");
        }

        // ---------------------------------------------------------------- 服务

        public static bool SetSvcStart(string name, string mode)
        {
            // mode: disabled / demand / auto / delayed-auto
            int code = RunExit("sc.exe", "config " + name + " start= " + mode);
            if (code == 0) return true;

            int v;
            if (mode == "disabled") v = 4;
            else if (mode == "demand") v = 3;
            else v = 2;
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + name, true))
                {
                    if (k == null) return false;
                    k.SetValue("Start", v, RegistryValueKind.DWord);
                    k.SetValue("DelayedAutoStart", (mode == "delayed-auto") ? 1 : 0, RegistryValueKind.DWord);
                    return true;
                }
            }
            catch { return false; }
        }

        public static bool StopService(string name, int timeoutMs)
        {
            try
            {
                using (ServiceController sc = new ServiceController(name))
                {
                    if (sc.Status == ServiceControllerStatus.Stopped) return true;
                    sc.Stop();
                    sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromMilliseconds(timeoutMs));
                    return true;
                }
            }
            catch { }
            // 兜底: sc.exe stop
            RunCapture("sc.exe", "stop " + name);
            int waited = 0;
            while (waited < timeoutMs)
            {
                try
                {
                    using (ServiceController sc = new ServiceController(name))
                    {
                        if (sc.Status == ServiceControllerStatus.Stopped) return true;
                    }
                }
                catch { return true; }
                System.Threading.Thread.Sleep(500);
                waited += 500;
            }
            return false;
        }

        public static void KillUpdateProcesses(LogHandler log)
        {
            foreach (string n in ProcNames)
            {
                try
                {
                    Process[] ps = Process.GetProcessesByName(n);
                    foreach (Process p in ps)
                    {
                        try { p.Kill(); } catch { }
                        try { p.Dispose(); } catch { }
                    }
                }
                catch { }
            }
            if (log != null) log("已结束残留更新进程(如有)", LogLevel.Ok);
        }

        // ---------------------------------------------------------------- 组策略

        public const string PolicyWU = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";
        public const string FakeWsus = "http://127.0.0.1:8530";

        public static void SetPolicy(bool on, LogHandler log)
        {
            try
            {
                if (on)
                {
                    // 关键: 用"策略"而不是"改配置"。
                    // 把更新源指向一个不存在的内网 WSUS, 并禁止连接微软的更新服务器 ——
                    // 这是 Windows 支持的正常企业配置, 服务栈不会去"修复"它(与 ACL 锁不同)。
                    using (RegistryKey k = Registry.LocalMachine.CreateSubKey(PolicyWU))
                    {
                        k.SetValue("WUServer", FakeWsus, RegistryValueKind.String);
                        k.SetValue("WUStatusServer", FakeWsus, RegistryValueKind.String);
                        k.SetValue("DoNotConnectToWindowsUpdateInternetLocations", 1, RegistryValueKind.DWord);
                    }
                    using (RegistryKey k = Registry.LocalMachine.CreateSubKey(PolicyAU))
                    {
                        k.SetValue("NoAutoUpdate", 1, RegistryValueKind.DWord);
                        k.SetValue("UseWUServer", 1, RegistryValueKind.DWord);
                    }
                    if (log != null) log("组策略: NoAutoUpdate=1, 更新源-> " + FakeWsus + ", 禁止连接微软更新服务器", LogLevel.Ok);
                }
                else
                {
                    try
                    {
                        Registry.LocalMachine.DeleteSubKeyTree(PolicyWU, false);
                    }
                    catch { }
                    if (log != null) log("组策略: 已删除全部 WindowsUpdate 策略(含 WSUS 指向)", LogLevel.Ok);
                }
            }
            catch (Exception ex)
            {
                if (log != null) log("组策略写入失败: " + ex.Message, LogLevel.Err);
            }
        }

        // ---------------------------------------------------------------- Store 应用自动更新
        // ADMX(本机 C:\Windows\PolicyDefinitions\WindowsStore.admx) 的权威定义:
        //   策略 DisableAutoDownloadWin8 -> 值名 AutoDownload, 启用=2, 禁用=3
        // 注意: NoAutoUpdate 只管 Windows 更新, 挡不住 Microsoft Store 应用自动更新,
        // 后者是独立通道(实测 10/7 装了 YourPhone / Clipchamp / GamingApp / WindowsStore)。
        public const string PolicyStore = @"SOFTWARE\Policies\Microsoft\WindowsStore";

        public static bool IsStorePolicyOn()
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(PolicyStore))
                {
                    if (k == null) return false;
                    object v = k.GetValue("AutoDownload");
                    return v != null && Convert.ToInt32(v) == 2;
                }
            }
            catch { return false; }
        }

        public static void SetStorePolicy(bool on, LogHandler log)
        {
            try
            {
                if (on)
                {
                    using (RegistryKey k = Registry.LocalMachine.CreateSubKey(PolicyStore))
                    {
                        k.SetValue("AutoDownload", 2, RegistryValueKind.DWord);
                    }
                    if (log != null) log("组策略: 已关闭 Store 应用自动更新 (WindowsStore\\AutoDownload=2)", LogLevel.Ok);
                }
                else
                {
                    try
                    {
                        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(PolicyStore, true))
                        {
                            if (k != null) k.DeleteValue("AutoDownload", false);
                        }
                        // 只在键已空时删除, 避免误删别人写的 RemoveWindowsStore 等策略
                        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(PolicyStore))
                        {
                            if (k != null && k.ValueCount == 0 && k.SubKeyCount == 0)
                                Registry.LocalMachine.DeleteSubKey(PolicyStore, false);
                        }
                    }
                    catch { }
                    if (log != null) log("组策略: 已恢复 Store 应用自动更新设置", LogLevel.Ok);
                }
            }
            catch (Exception ex)
            {
                if (log != null) log("Store 策略写入失败: " + ex.Message, LogLevel.Err);
            }
        }

        // ---------------------------------------------------------------- 计划任务

        private static string BackupName(TaskInfo t)
        {
            string p = t.TaskPath.Trim('\\').Replace('\\', '_');
            return p + "_" + t.TaskName + ".xml";
        }

        public static bool SetTaskEnabled(TaskInfo t, bool enabled, LogHandler log)
        {
            if (!File.Exists(t.FilePath)) return false;
            EnsureDirs();
            string bak = Path.Combine(BackupDir, BackupName(t));
            try
            {
                if (!File.Exists(bak)) File.Copy(t.FilePath, bak, true);
            }
            catch (Exception ex)
            {
                if (log != null) log("  备份失败(继续改写): " + t.TaskName + " - " + ex.Message, LogLevel.Warn);
            }

            TakeOwnership(t.FilePath);
            try
            {
                XmlDocument doc = new XmlDocument();
                doc.PreserveWhitespace = true;
                doc.Load(t.FilePath);

                XmlNamespaceManager nsm = new XmlNamespaceManager(doc.NameTable);
                nsm.AddNamespace("t", TaskNs);
                XmlNode settings = doc.SelectSingleNode("/t:Task/t:Settings", nsm);
                if (settings == null) return false;

                XmlNode en = settings.SelectSingleNode("t:Enabled", nsm);
                if (en == null)
                {
                    en = doc.CreateElement("Enabled", TaskNs);
                    settings.AppendChild(en);
                }
                string want = enabled ? "true" : "false";
                if (en.InnerText.Trim().ToLower() != want)
                {
                    en.InnerText = want;
                    doc.Save(t.FilePath);
                }
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static bool RestoreTaskFromBackup(TaskInfo t)
        {
            EnsureDirs();
            string bak = Path.Combine(BackupDir, BackupName(t));
            if (!File.Exists(bak) || !File.Exists(t.FilePath)) return false;
            try
            {
                TakeOwnership(t.FilePath);
                File.Copy(bak, t.FilePath, true);
                return true;
            }
            catch { return false; }
        }

        private static bool TryRestartScm(string name)
        {
            try
            {
                using (ServiceController sc = new ServiceController(name))
                {
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
                    }
                    sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20));
                    return true;
                }
            }
            catch { return false; }
        }

        /// <summary>
        /// 让"任务计划程序"重新加载磁盘上的任务 XML。
        /// 本机 Schedule 的 DACL 只给 SYSTEM SERVICE_STOP, 管理员没有 WP;
        /// 但管理员有 WD(WRITE_DAC): 临时加 WP, 重载后立刻还原。
        /// </summary>
        public static bool ReloadTaskScheduler(LogHandler log)
        {
            if (TryRestartScm("Schedule"))
            {
                if (log != null) log("已重载任务计划程序, 任务改动立即生效", LogLevel.Ok);
                return true;
            }
            if (log != null) log("直接重启任务计划程序失败, 尝试临时授权...", LogLevel.Warn);

            string orig = RunCapture("sc.exe", "sdshow Schedule").Trim();
            if (orig.IndexOf(SddlBaNoStop, StringComparison.OrdinalIgnoreCase) < 0)
            {
                if (log != null) log("Schedule 的 SDDL 与预期不同, 为安全起见不自动改动", LogLevel.Warn);
                return false;
            }
            string patched = ReplaceNoCase(orig, SddlBaNoStop, SddlBaWithStop);
            RunCapture("sc.exe", "sdset Schedule \"" + patched + "\"");
            bool ok = false;
            try
            {
                ok = TryRestartScm("Schedule");
            }
            finally
            {
                RunCapture("sc.exe", "sdset Schedule \"" + orig + "\"");
                if (log != null) log("已还原 Schedule 服务的原始 SDDL", LogLevel.Ok);
            }
            if (ok && log != null) log("已重载任务计划程序(临时授权), 任务改动立即生效", LogLevel.Ok);
            return ok;
        }

        private static string ReplaceNoCase(string src, string find, string repl)
        {
            int i = src.IndexOf(find, StringComparison.OrdinalIgnoreCase);
            if (i < 0) return src;
            return src.Substring(0, i) + repl + src.Substring(i + find.Length);
        }

        // ---------------------------------------------------------------- 基线

        public static void SaveBaseline(LogHandler log)
        {
            EnsureDirs();
            if (File.Exists(BaselineFile)) return;
            StringBuilder sb = new StringBuilder();
            foreach (string n in SvcCore)
            {
                int st = ReadSvcStart(n);
                if (st == 4) st = -1;      // 本来就是禁用 -> 视为未知, 避免把"禁用"当原始配置
                int dl = -1;
                try
                {
                    using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + n))
                    {
                        if (k != null)
                        {
                            object v = k.GetValue("DelayedAutoStart");
                            if (v != null) dl = Convert.ToInt32(v);
                        }
                    }
                }
                catch { }
                sb.AppendLine(n + "=" + st + "," + dl);
            }
            try
            {
                File.WriteAllText(BaselineFile, sb.ToString(), Encoding.UTF8);
                if (log != null) log("已记录服务启动类型基线", LogLevel.Ok);
            }
            catch (Exception ex)
            {
                if (log != null) log("基线写入失败: " + ex.Message, LogLevel.Warn);
            }
        }

        public static Dictionary<string, int[]> LoadBaseline()
        {
            Dictionary<string, int[]> map = new Dictionary<string, int[]>();
            try
            {
                if (File.Exists(BaselineFile))
                {
                    foreach (string line in File.ReadAllLines(BaselineFile))
                    {
                        int eq = line.IndexOf('=');
                        if (eq <= 0) continue;
                        string n = line.Substring(0, eq).Trim();
                        string[] parts = line.Substring(eq + 1).Split(',');
                        if (parts.Length < 1) continue;
                        int st, dl = -1;
                        if (!int.TryParse(parts[0].Trim(), out st)) continue;
                        if (parts.Length > 1) int.TryParse(parts[1].Trim(), out dl);
                        if (st == 4 || st <= 0) continue;   // 未知 -> 用默认值
                        map[n] = new int[] { st, dl };
                    }
                }
            }
            catch { }
            foreach (string n in SvcCore)
            {
                if (!map.ContainsKey(n))
                {
                    int dl = DefaultDelayed.ContainsKey(n) ? DefaultDelayed[n] : 0;
                    map[n] = new int[] { DefaultStart[n], dl };
                }
            }
            return map;
        }

        // ---------------------------------------------------------------- 操作日志
        public static string LogFile { get { return Path.Combine(DataDir, "log.txt"); } }

        public static void WriteFileLog(string msg, LogLevel lv)
        {
            try
            {
                EnsureDirs();
                File.AppendAllText(LogFile,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  [" + lv.ToString().PadRight(4) + "] " + msg + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }
        }

        private static LogHandler Wrap(LogHandler log)
        {
            return delegate(string m, LogLevel l)
            {
                WriteFileLog(m, l);
                if (log != null) log(m, l);
            };
        }

        // ---------------------------------------------------------------- 服务键 ACL 修复
        // 只有旧版(给服务键加 Deny ACE 的那版)会在这里留 *.sddl 备份。
        // 现在不再加锁, 这个目录只用于"解锁历史遗留"。
        public static string AclBackupDir { get { return Path.Combine(DataDir, "acl"); } }

        private static string SvcKeyPath(string name)
        {
            return @"SYSTEM\CurrentControlSet\Services\" + name;
        }

        public static bool UnprotectServiceKey(string name, LogHandler log)
        {
            string bak = Path.Combine(AclBackupDir, name + ".sddl");
            if (!File.Exists(bak)) return true;      // 没锁过
            string sddl = "";
            try { sddl = File.ReadAllText(bak, Encoding.UTF8).Trim(); }
            catch (Exception ex)
            {
                if (log != null) log("  读备份失败 " + name + ": " + ex.Message, LogLevel.Warn);
                return false;
            }

            string sub = SvcKeyPath(name);
            string err = "";

            // 1) 常规路径: 直接把备份的 DACL 写回去
            if (AclFix.SetDacl(sub, sddl, out err))
            {
                try { File.Delete(bak); } catch { }
                if (log != null) log("  已解锁 " + name, LogLevel.Ok);
                return true;
            }

            // 2) 旧版锁定把 DACL 弄坏时, 连管理员都打不开 —— 先抢所有权再写
            if (log != null) log("  直接解锁失败(" + err + "), 尝试取得所有权...", LogLevel.Warn);
            if (!AclFix.TakeOwnership(sub, out err) || !AclFix.SetDacl(sub, sddl, out err))
            {
                if (log != null) log("  解锁失败 " + name + ": " + err, LogLevel.Warn);
                return false;
            }
            try { File.Delete(bak); } catch { }
            if (log != null) log("  已解锁(经取得所有权) " + name, LogLevel.Ok);
            return true;
        }

        // ---------------------------------------------------------------- 任务 XML 写保护
        // 旧版会给任务 XML 加 Deny-Write ACE。现在不再加, 这里只用于解除历史遗留。
        public static string AclTaskDir { get { return Path.Combine(AclBackupDir, "tasks"); } }

        private static string TaskAclName(TaskInfo t)
        {
            return (t.TaskPath.Trim('\\').Replace('\\', '_')) + "_" + t.TaskName + ".sddl";
        }

        public static bool UnprotectTaskFile(TaskInfo t, LogHandler log)
        {
            try
            {
                string bak = Path.Combine(AclTaskDir, TaskAclName(t));
                if (!File.Exists(bak)) return true;                // 没保护过
                if (!File.Exists(t.FilePath)) return false;

                string sddl = File.ReadAllText(bak, Encoding.UTF8).Trim();
                FileSecurity sec = new FileSecurity();
                sec.SetSecurityDescriptorSddlForm(sddl, AccessControlSections.Access);
                File.SetAccessControl(t.FilePath, sec);
                File.Delete(bak);
                return true;
            }
            catch (Exception ex)
            {
                log("  解除写保护失败 " + t.TaskName + ": " + ex.Message, LogLevel.Warn);
                return false;
            }
        }

        private static void StopAllServices(LogHandler log, int timeoutSec, int rounds)
        {
            for (int round = 1; round <= rounds; round++)
            {
                List<string> running = new List<string>();
                foreach (string n in StopOrder)
                {
                    try
                    {
                        using (ServiceController sc = new ServiceController(n))
                            if (sc.Status != ServiceControllerStatus.Stopped) running.Add(n);
                    }
                    catch { }
                }
                if (running.Count == 0) { log("  所有更新相关服务均已停止", LogLevel.Ok); return; }
                log("  第 " + round + " 轮停止: " + string.Join(", ", running.ToArray()), LogLevel.Info);
                foreach (string n in running)
                {
                    if (StopService(n, timeoutSec * 1000)) log("    " + n + " : 已停止", LogLevel.Ok);
                    else log("    " + n + " : 未能停止", LogLevel.Warn);
                }
                System.Threading.Thread.Sleep(2000);
            }
        }

        // ---------------------------------------------------------------- 主流程

        public static void DisableAll(LogHandler raw) { DisableAll(raw, null); }

        public static void DisableAll(LogHandler raw, ProgressHandler prog)
        {
            LogHandler log = Wrap(raw);
            EnsureDirs();
            Report(prog, 2, "准备");
            log("========== 开始禁用 Windows 更新 ==========", LogLevel.Info);
            SaveBaseline(log);

            Report(prog, 8, "写入组策略");
            log("写入组策略: 禁止自动更新", LogLevel.Info);
            SetPolicy(true, log);
            SetStorePolicy(true, log);

            // 幂等: 如果上次已经锁过, 先全部解锁, 走完流程再重新锁上
            Report(prog, 14, "清理上次的锁定");
            log("解除上次的配置锁定(若有)", LogLevel.Info);
            foreach (string n in SvcCore) UnprotectServiceKey(n, log);

            // 第 1 步: 先把"修复者"停掉。顺序很关键 —— 之前是"先改配置再停服务",
            // 结果服务还在运行, 几秒内就把启动类型改了回去。
            Report(prog, 20, "停止更新服务");
            log("第 1 步: 先停止更新服务与修复进程", LogLevel.Info);
            StopAllServices(log, 20, 3);
            KillUpdateProcesses(log);
            System.Threading.Thread.Sleep(1500);

            // 第 2 步: 禁用计划任务
            Report(prog, 26, "禁用计划任务");
            log("第 2 步: 禁用更新相关计划任务", LogLevel.Info);
            int okT = 0, failT = 0, xmlT = 0;
            List<TaskInfo> tasks = GetTasks();
            int taskIdx = 0;
            foreach (TaskInfo t in tasks)
            {
                taskIdx++;
                if (tasks.Count > 0)
                    Report(prog, 26 + (int)(24.0 * taskIdx / tasks.Count),
                           "禁用计划任务 " + taskIdx + "/" + tasks.Count);
                UnprotectTaskFile(t, log);      // 先解除上次的写保护, 否则这轮改不动
                if (!t.Enabled) { okT++; continue; }
                bool done = false;
                if (t.Readable)
                {
                    int code = RunExit("schtasks.exe", "/change /tn \"" + t.TaskPath + t.TaskName + "\" /disable");
                    if (code == 0) done = true;
                }
                if (!done)
                {
                    if (SetTaskEnabled(t, false, log)) { xmlT++; done = true; }
                }
                if (done) okT++; else { failT++; log("  无法禁用: " + t.TaskPath + t.TaskName, LogLevel.Warn); }
            }
            log("  任务: 成功 " + okT + " / XML改写 " + xmlT + " / 失败 " + failT, LogLevel.Ok);

            bool reloaded = true;
            if (xmlT > 0)
            {
                Report(prog, 52, "重载任务计划程序");
                reloaded = ReloadTaskScheduler(log);
                if (!reloaded) log("  !! 受保护任务的 XML 改动要等重启才生效, 重启前它们仍会运行", LogLevel.Err);
            }

            // 第 3 步: 服务启动类型设为禁用
            Report(prog, 58, "设置服务启动类型");
            log("第 3 步: 将服务启动类型设为禁用", LogLevel.Info);
            foreach (string n in SvcCore)
            {
                if (SetSvcStart(n, "disabled")) log("  " + n + " : 已禁用", LogLevel.Ok);
                else log("  " + n + " : 修改失败(受系统保护)", LogLevel.Warn);
            }

            // 第 4 步: 盯着看 60 秒, 记录是谁在什么时候被改回去
            log("第 4 步: 持续盯 60 秒, 检查是否被系统改回", LogLevel.Info);
            int revertCount = 0;
            for (int i = 1; i <= 20; i++)
            {
                Report(prog, 62 + i, "复核中 " + (i * 3) + "/60 秒");
                System.Threading.Thread.Sleep(3000);
                List<string> bad = GetNonDisabled();
                if (bad.Count == 0) continue;
                revertCount++;
                log("  第 " + (i * 3) + " 秒被改回: " + string.Join(", ", bad.ToArray()) +
                    "  (第 " + revertCount + " 次)", LogLevel.Warn);
                foreach (string n in SvcCore) SetSvcStart(n, "disabled");
            }
            if (revertCount == 0) log("  60 秒内没有被改回", LogLevel.Ok);
            else log("  !! 60 秒内共被改回 " + revertCount + " 次 —— 确认 Windows 在主动修复", LogLevel.Err);

            // 第 5 步: 不再锁 ACL。
            // 实测 Deny SetValue 挡不住持有 WRITE_DAC 的 SYSTEM/TrustedInstaller,
            // 三次都被绕过(9/30、10/8、10/14), 还把这几个服务键的 DACL 改坏,
            // 最后连本工具自己都写不进 Start。真正长期有效的是上面的策略。
            Report(prog, 88, "收尾");
            log("第 5 步: 跳过 ACL 锁定(实测无效, 且会弄坏服务键权限)", LogLevel.Info);

            // 第 6 步: 最后再停一次并复核
            StopAllServices(log, 20, 3);
            KillUpdateProcesses(log);
            System.Threading.Thread.Sleep(3000);
            List<string> still = GetNonDisabled();
            if (still.Count == 0) log("完成: 5 个更新服务均为禁用", LogLevel.Ok);
            else
            {
                log("注意: 以下服务仍不是禁用: " + string.Join(", ", still.ToArray()), LogLevel.Err);
                log("更新服务可能被系统改回; 更新策略仍然生效, 详见 " + LogFile, LogLevel.Warn);
            }
            log("========== 禁用流程结束 ==========", LogLevel.Info);
            Report(prog, 100, "完成");
        }

        public static void RestoreAll(LogHandler raw) { RestoreAll(raw, null); }

        public static void RestoreAll(LogHandler raw, ProgressHandler prog)
        {
            LogHandler log = Wrap(raw);
            EnsureDirs();
            Report(prog, 2, "准备");
            log("========== 开始恢复 Windows 更新 ==========", LogLevel.Info);

            Report(prog, 8, "解除旧锁定");
            log("第 1 步: 解锁服务配置与任务 XML 写保护", LogLevel.Info);
            foreach (string n in SvcCore) UnprotectServiceKey(n, log);
            foreach (TaskInfo t in GetTasks()) UnprotectTaskFile(t, log);

            Dictionary<string, int[]> baseMap = LoadBaseline();
            Report(prog, 18, "还原服务启动类型");
            log("第 2 步: 按基线还原服务启动类型", LogLevel.Info);
            foreach (string n in SvcCore)
            {
                int st = baseMap[n][0];
                int dl = baseMap[n][1];
                string mode;
                if (st == 2) mode = (dl == 1) ? "delayed-auto" : "auto";
                else if (st == 4) mode = "disabled";
                else mode = "demand";
                if (SetSvcStart(n, mode)) log("  " + n + " : 还原为 " + mode, LogLevel.Ok);
                else log("  " + n + " : 修改失败", LogLevel.Warn);
            }

            Report(prog, 32, "删除组策略");
            log("第 3 步: 删除禁止自动更新组策略", LogLevel.Info);
            SetPolicy(false, log);
            SetStorePolicy(false, log);

            Report(prog, 40, "恢复计划任务");
            log("第 4 步: 恢复计划任务", LogLevel.Info);
            int okT = 0, failT = 0, bakT = 0;
            List<TaskInfo> tasks = GetTasks();
            int taskIdx = 0;
            foreach (TaskInfo t in tasks)
            {
                taskIdx++;
                if (tasks.Count > 0)
                    Report(prog, 40 + (int)(45.0 * taskIdx / tasks.Count),
                           "恢复计划任务 " + taskIdx + "/" + tasks.Count);
                if (t.Enabled) { okT++; continue; }
                bool done = false;
                int code = RunExit("schtasks.exe", "/change /tn \"" + t.TaskPath + t.TaskName + "\" /enable");
                if (code == 0) done = true;
                if (!done && RestoreTaskFromBackup(t)) { bakT++; done = true; }
                if (!done && SetTaskEnabled(t, true, log)) done = true;
                if (done) okT++; else { failT++; }
            }
            log("  任务恢复: 成功 " + okT + " / 其中备份还原 " + bakT + " / 失败 " + failT, LogLevel.Ok);
            if (bakT > 0) ReloadTaskScheduler(log);

            Report(prog, 90, "刷新策略");
            RunCapture("gpupdate.exe", "/force");
            log("gpupdate /force 完成", LogLevel.Ok);
            log("========== 恢复流程结束 ==========", LogLevel.Info);
            Report(prog, 100, "完成");
        }

        public static List<string> GetNonDisabled()
        {
            List<string> bad = new List<string>();
            foreach (string n in SvcCore)
            {
                int st = ReadSvcStart(n);
                if (st != 4) bad.Add(n + "(" + (st == 2 ? "自动" : st == 3 ? "手动" : "未知") + ")");
            }
            return bad;
        }
    }
}

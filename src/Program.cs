using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace LiquidWU
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
            {
                LogCrash(e.ExceptionObject as Exception);
            };
            Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e)
            {
                LogCrash(e.Exception);
            };

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string auto = "";
            bool selfTest = false;
            foreach (string a in args)
            {
                if (a.StartsWith("--auto=", StringComparison.OrdinalIgnoreCase))
                    auto = a.Substring("--auto=".Length);
                if (string.Equals(a, "--selftest", StringComparison.OrdinalIgnoreCase))
                    selfTest = true;
            }

            if (selfTest) { RunSelfTest(); return; }

            try
            {
                MainForm f = new MainForm(auto);
                if (auto.Length > 0) f.AutoRun(auto);
                Application.Run(f);
            }
            catch (Exception ex)
            {
                LogCrash(ex);
                MessageBox.Show("程序启动失败: " + ex.Message + "\r\n\r\n详细信息已写入日志:\r\n" + LogPath,
                    "更新守卫", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public static string LogPath
        {
            get
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "UpdateGuard");
                try { if (!Directory.Exists(dir)) Directory.CreateDirectory(dir); }
                catch { dir = Path.GetTempPath(); }
                return Path.Combine(dir, "error.log");
            }
        }

        private static void LogCrash(Exception ex)
        {
            try
            {
                string text = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " +
                              (ex == null ? "(unknown exception)" : ex.ToString()) +
                              Environment.NewLine + new string('-', 70) + Environment.NewLine;
                File.AppendAllText(LogPath, text);
            }
            catch { }
        }

        /// <summary>
        /// 只读自检: 枚举/解析全部计划任务, 检查服务与策略, 不修改任何东西。
        /// 用法: UpdateGuard.exe --selftest
        /// </summary>
        private static void RunSelfTest()
        {
            StringBuilder sb = new StringBuilder();
            try
            {
                sb.AppendLine("管理员: " + WuCore.IsAdmin());
                sb.AppendLine("数据目录: " + WuCore.DataDir);
                sb.AppendLine("基线文件存在: " + File.Exists(WuCore.BaselineFile));
                sb.AppendLine();
                sb.AppendLine("--- 服务 ---");
                foreach (SvcInfo s in WuCore.GetServices())
                    sb.AppendLine("  " + s.Name.PadRight(16) + " Start=" + s.Start + " (" + s.StartText + ")  Running=" + s.Running);
                sb.AppendLine("组策略 NoAutoUpdate=1: " + WuCore.IsPolicyOn());
                sb.AppendLine();
                sb.AppendLine("--- 计划任务 ---");
                List<TaskInfo> tasks = WuCore.GetTasks();
                sb.AppendLine("枚举到 " + tasks.Count + " 个任务");
                int readable = 0, enabled = 0;
                foreach (TaskInfo t in tasks)
                {
                    if (t.Readable) readable++;
                    if (t.Enabled) enabled++;
                }
                sb.AppendLine("可读 " + readable + " / 不可读(受保护) " + (tasks.Count - readable));
                sb.AppendLine("启用中 " + enabled + " / 已禁用 " + (tasks.Count - enabled));
                sb.AppendLine();
                foreach (TaskInfo t in tasks)
                    sb.AppendLine("  [" + (t.Enabled ? "启用" : "禁用") + "]" + (t.Readable ? " " : "*") +
                                  " " + t.TaskPath + t.TaskName);
                sb.AppendLine();
                sb.AppendLine("--- 基线解析结果 ---");
                Dictionary<string, int[]> b = WuCore.LoadBaseline();
                foreach (string k in WuCore.SvcCore)
                    sb.AppendLine("  " + k.PadRight(16) + " Start=" + b[k][0] + " Delayed=" + b[k][1]);
                sb.AppendLine();
                sb.AppendLine("自检完成, 未修改任何系统设置。");
            }
            catch (Exception ex)
            {
                sb.AppendLine("自检异常: " + ex);
            }

            string outFile = Path.Combine(Path.GetDirectoryName(LogPath), "selftest.txt");
            try { File.WriteAllText(outFile, sb.ToString(), Encoding.UTF8); }
            catch { }
        }
    }
}

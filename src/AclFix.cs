using System;
using System.Runtime.InteropServices;

namespace LiquidWU
{
    /// <summary>
    /// 修复被旧版 ACL 锁定弄坏的服务注册表键。
    /// 常规路径打不开时, 先抢所有权(SeTakeOwnershipPrivilege), 再按备份的 SDDL 写回 DACL。
    /// </summary>
    public static class AclFix
    {
        private const int SE_REGISTRY_KEY = 4;
        private const int OWNER_SECURITY_INFORMATION = 1;
        private const int DACL_SECURITY_INFORMATION = 4;
        private const int WRITE_OWNER = 0x00080000;
        private const int WRITE_DAC = 0x00040000;

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int RegOpenKeyEx(IntPtr hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern int RegCloseKey(IntPtr hKey);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern int SetSecurityInfo(IntPtr handle, int ObjectType, int SecurityInfo,
            IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
            string StringSecurityDescriptor, int StringSDRevision, out IntPtr SecurityDescriptor, IntPtr SecurityDescriptorSize);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetSecurityDescriptorDacl(IntPtr pSecurityDescriptor,
            out bool lpbDaclPresent, out IntPtr pDacl, out bool lpbDaclDefaulted);

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
            ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr hObject);

        private static readonly IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));

        private static void EnablePrivilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return;
            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, name, out luid)) return;
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privilege.Luid = luid;
                tp.Privilege.Attributes = 0x00000002;   // SE_PRIVILEGE_ENABLED
                AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            }
            finally { CloseHandle(token); }
        }

        /// <summary>把键的属主改成 BUILTIN\Administrators (S-1-5-32-544)。</summary>
        public static bool TakeOwnership(string subKey, out string error)
        {
            error = "";
            try
            {
                EnablePrivilege("SeTakeOwnershipPrivilege");
                EnablePrivilege("SeRestorePrivilege");

                IntPtr h;
                int rc = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, WRITE_OWNER, out h);
                if (rc != 0) { error = "RegOpenKeyEx(WRITE_OWNER) rc=" + rc; return false; }
                try
                {
                    byte[] sid = new byte[] { 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 32, 2, 0, 0 };
                    IntPtr pSid = Marshal.AllocHGlobal(sid.Length);
                    try
                    {
                        Marshal.Copy(sid, 0, pSid, sid.Length);
                        rc = SetSecurityInfo(h, SE_REGISTRY_KEY, OWNER_SECURITY_INFORMATION,
                                             pSid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        if (rc != 0) { error = "SetSecurityInfo(owner) rc=" + rc; return false; }
                    }
                    finally { Marshal.FreeHGlobal(pSid); }
                }
                finally { RegCloseKey(h); }
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }

        /// <summary>按 SDDL 还原 DACL。</summary>
        public static bool SetDacl(string subKey, string sddl, out string error)
        {
            error = "";
            try
            {
                EnablePrivilege("SeRestorePrivilege");

                IntPtr sd;
                if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out sd, IntPtr.Zero))
                { error = "SDDL 解析失败 err=" + Marshal.GetLastWin32Error(); return false; }
                try
                {
                    bool present, defaulted;
                    IntPtr dacl;
                    if (!GetSecurityDescriptorDacl(sd, out present, out dacl, out defaulted) || !present)
                    { error = "SDDL 中没有 DACL"; return false; }

                    IntPtr h;
                    int rc = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, WRITE_DAC, out h);
                    if (rc != 0) { error = "RegOpenKeyEx(WRITE_DAC) rc=" + rc; return false; }
                    try
                    {
                        rc = SetSecurityInfo(h, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION,
                                             IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
                        if (rc != 0) { error = "SetSecurityInfo(dacl) rc=" + rc; return false; }
                    }
                    finally { RegCloseKey(h); }
                }
                finally { LocalFree(sd); }
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}

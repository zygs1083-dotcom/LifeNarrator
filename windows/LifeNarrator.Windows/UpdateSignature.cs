using System.Runtime.InteropServices;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography.X509Certificates;

namespace LifeNarrator.Windows;

internal static class UpdateSignature
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FileInfo
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Path;
        public nint Handle, Subject;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct TrustData
    {
        public uint Size;
        public nint Policy, Sip;
        public uint UI, Revocation, Choice;
        public nint File;
        public uint Action;
        public nint State, URL;
        public uint Flags, Context;
        public nint SignatureSettings;
    }
    [DllImport("wintrust.dll", ExactSpelling = true)]
    static extern int WinVerifyTrust(nint window, ref Guid action, ref TrustData data);

    static int Verify(string path)
    {
        var file = new FileInfo { Size = (uint)Marshal.SizeOf<FileInfo>(), Path = path };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfo>());
        Marshal.StructureToPtr(file, pointer, false);
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
        var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UI = 2, Choice = 1, File = pointer, Action = 1 };
        try { return WinVerifyTrust(new nint(-1), ref action, ref data); }
        finally
        {
            data.Action = 2;
            WinVerifyTrust(new nint(-1), ref action, ref data);
            Marshal.DestroyStructure<FileInfo>(pointer);
            Marshal.FreeHGlobal(pointer);
        }
    }

    public static void Check(string installer, string currentExecutable, Action<string> log)
    {
        var status = Verify(installer);
        using var stream = File.OpenRead(installer);
        using var pe = new PEReader(stream);
        if (status == unchecked((int)0x800B0100) && pe.PEHeaders.PEHeader!.CertificateTableDirectory.Size == 0)
        {
            log("Installer is unsigned; skipping signer comparison.");
            return;
        }
        if (status != 0) throw new InvalidDataException($"Installer WinVerifyTrust failed: 0x{status:X8}");
        status = Verify(currentExecutable);
        if (status != 0) throw new InvalidDataException($"Current application WinVerifyTrust failed: 0x{status:X8}");
        using var candidate = new X509Certificate2(X509Certificate.CreateFromSignedFile(installer));
        using var current = new X509Certificate2(X509Certificate.CreateFromSignedFile(currentExecutable));
        if (!candidate.RawData.AsSpan().SequenceEqual(current.RawData))
            throw new InvalidDataException("Installer signer does not match the current application.");
        log("Installer signature verified; signer matches the current application.");
    }
}

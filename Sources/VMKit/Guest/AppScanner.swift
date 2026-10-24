import Foundation

/// Una app encontrada en el menú Inicio de Windows.
public struct DiscoveredApp: Equatable, Identifiable, Sendable {
    public var name: String
    /// AppUserModelID: identifica la app en shell:AppsFolder (también las de la Microsoft Store).
    public var appUserModelID: String
    public var program: String
    public var arguments: String
    /// Icono en PNG (normalmente 256×256), si Windows lo entregó.
    public var iconPNG: Data?

    public var id: String { appUserModelID }

    public init(name: String, appUserModelID: String, program: String, arguments: String = "", iconPNG: Data? = nil) {
        self.name = name
        self.appUserModelID = appUserModelID
        self.program = program
        self.arguments = arguments
        self.iconPNG = iconPNG
    }

    /// Las apps de la Microsoft Store no tienen un .exe que se pueda lanzar: se abren con el Explorador.
    public var isStoreApp: Bool { arguments.lowercased().hasPrefix(#"shell:appsfolder\"#) }

    public func makeRemoteApp() -> RemoteApp {
        RemoteApp(name: name, program: program, arguments: arguments, appUserModelID: appUserModelID)
    }

    /// Si corresponde a una app ya añadida (para no duplicarla y para darle su icono).
    public func matches(_ app: RemoteApp) -> Bool {
        if let aumid = app.appUserModelID, aumid.caseInsensitiveCompare(appUserModelID) == .orderedSame { return true }
        if app.program.caseInsensitiveCompare(program) == .orderedSame
            && app.arguments.caseInsensitiveCompare(arguments) == .orderedSame { return true }
        return app.name.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// Lista las apps instaladas en Windows (con sus iconos) a través del canal SSH.
public enum AppScanner {
    /// Interpreta la salida del script: una línea "APP<tab>nombre<tab>aumid<tab>programa<tab>argumentos<tab>png-base64".
    public static func parse(_ output: String) -> [DiscoveredApp] {
        var seen = Set<String>()
        var apps: [DiscoveredApp] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, fields[0] == "APP" else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !fields[3].isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            let icon = Data(base64Encoded: fields[5].trimmingCharacters(in: .whitespaces))
            apps.append(DiscoveredApp(
                name: name, appUserModelID: fields[2], program: fields[3], arguments: fields[4],
                iconPNG: icon?.isEmpty == false ? icon : nil))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Script de PowerShell 5.1 que se ejecuta en Windows. Solo ASCII: llega por la entrada estándar.
    /// Recorre shell:AppsFolder (lo mismo que muestra "Todas las apps" del menú Inicio), resuelve el .exe
    /// de cada app de escritorio y saca su icono a 256 px con IShellItemImageFactory.
    public static let script = #"""
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Drawing

$shellIcons = $true
try {
Add-Type -ErrorAction Stop -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace Paralelo {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItemImageFactory {
        [PreserveSig] int GetImage(NativeSize size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeSize { public int cx; public int cy; }

    public static class Icons {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr pbc,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
            [MarshalAs(UnmanagedType.Interface, IidParameterIndex = 2)] out IShellItemImageFactory item);

        [DllImport("gdi32.dll")]
        static extern bool DeleteObject(IntPtr handle);

        public static string Png(string parsingName, int size) {
            IntPtr hbm = IntPtr.Zero;
            try {
                IShellItemImageFactory factory;
                SHCreateItemFromParsingName(parsingName, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory);
                NativeSize s;
                s.cx = size;
                s.cy = size;
                if (factory.GetImage(s, 0x4, out hbm) != 0) return null;
                using (Bitmap bmp = Image.FromHbitmap(hbm))
                using (Bitmap png = WithAlpha(bmp))
                using (MemoryStream ms = new MemoryStream()) {
                    png.Save(ms, ImageFormat.Png);
                    return Convert.ToBase64String(ms.ToArray());
                }
            } catch {
                return null;
            } finally {
                if (hbm != IntPtr.Zero) DeleteObject(hbm);
            }
        }

        // FromHbitmap marca la imagen como RGB pero conserva los bytes de alfa (premultiplicado).
        static Bitmap WithAlpha(Bitmap src) {
            int w = src.Width, h = src.Height;
            Rectangle rect = new Rectangle(0, 0, w, h);
            byte[] px = new byte[w * h * 4];
            BitmapData read = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
            try {
                for (int y = 0; y < h; y++)
                    Marshal.Copy(new IntPtr(read.Scan0.ToInt64() + (long)y * read.Stride), px, y * w * 4, w * 4);
            } finally {
                src.UnlockBits(read);
            }
            bool hasAlpha = false;
            for (int i = 3; i < px.Length; i += 4) { if (px[i] != 0) { hasAlpha = true; break; } }
            for (int i = 0; i < px.Length; i += 4) {
                int a = hasAlpha ? px[i + 3] : 255;
                if (hasAlpha && a > 0 && a < 255) {
                    px[i] = (byte)Math.Min(255, px[i] * 255 / a);
                    px[i + 1] = (byte)Math.Min(255, px[i + 1] * 255 / a);
                    px[i + 2] = (byte)Math.Min(255, px[i + 2] * 255 / a);
                }
                px[i + 3] = (byte)a;
            }
            Bitmap result = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            BitmapData write = result.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try {
                for (int y = 0; y < h; y++)
                    Marshal.Copy(px, y * w * 4, new IntPtr(write.Scan0.ToInt64() + (long)y * write.Stride), w * 4);
            } finally {
                result.UnlockBits(write);
            }
            return result;
        }
    }
}
'@
} catch {
    $shellIcons = $false
    "WARN`t" + $_.Exception.Message
}

function Get-IconPng([string]$appId, [string]$program) {
    if ($shellIcons) {
        $png = [Paralelo.Icons]::Png("shell:AppsFolder\$appId", 256)
        if ($png) { return $png }
    }
    if ($program -and (Test-Path -LiteralPath $program)) {
        try {
            $bmp = ([System.Drawing.Icon]::ExtractAssociatedIcon($program)).ToBitmap()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            return [Convert]::ToBase64String($ms.ToArray())
        } catch { }
    }
    return ''
}

function Clean([string]$text) { return ($text -replace "[`t`r`n]", ' ').Trim() }

$knownFolders = @{
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = [Environment]::GetFolderPath('System')
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:windir
    '{6D809377-6AF0-444B-8957-A3773F02200E}' = $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles })
    '{905E63B6-C1BF-494E-B29C-65B732D3D21A}' = $env:ProgramFiles
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
    '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = "$env:windir\SysWOW64"
}

$wsh = New-Object -ComObject WScript.Shell
$links = @{}
foreach ($dir in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")) {
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Recurse -Filter *.lnk)) {
        if ($links.ContainsKey($file.BaseName)) { continue }
        $link = $wsh.CreateShortcut($file.FullName)
        if ($link.TargetPath -match '\.exe$') { $links[$file.BaseName] = $link }
    }
}

$explorer = Join-Path $env:windir 'explorer.exe'
$items = (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items()
foreach ($item in $items) {
    $name = Clean $item.Name
    $appId = Clean $item.Path
    if (-not $name -or -not $appId) { continue }
    if ($name -match '(?i)uninstall|desinstal|readme') { continue }

    $program = ''
    $arguments = ''
    $target = [string]$item.ExtendedProperty('System.Link.TargetParsingPath')
    if ($target -match '\.exe$') {
        $program = $target
        $arguments = [string]$item.ExtendedProperty('System.Link.Arguments')
    } elseif ($links.ContainsKey($name)) {
        $program = $links[$name].TargetPath
        $arguments = $links[$name].Arguments
    } elseif ($appId -match '^(\{[0-9A-Fa-f-]+\})\\(.+\.exe)$' -and $knownFolders.ContainsKey($Matches[1].ToUpper())) {
        $program = Join-Path $knownFolders[$Matches[1].ToUpper()] $Matches[2]
    } elseif ($appId -match '^[A-Za-z]:\\.+\.exe$') {
        $program = $appId
    } elseif ($appId -eq 'Microsoft.Windows.Explorer') {
        $program = $explorer
    } elseif ($appId -match '!') {
        $program = $explorer
        $arguments = "shell:AppsFolder\$appId"
    }
    if (-not $program -or -not (Test-Path -LiteralPath $program)) { continue }

    $icon = Get-IconPng $appId $program
    "APP`t$name`t$appId`t$(Clean $program)`t$(Clean $arguments)`t$icon"
}
"""#

    /// Busca las apps instaladas (la VM debe estar encendida y con setup-windows.ps1 ejecutado).
    public static func scan(bundle: VMBundle) throws -> [DiscoveredApp] {
        parse(try GuestShell(bundle: bundle).runPowerShell(script))
    }
}

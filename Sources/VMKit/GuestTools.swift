import Foundation

/// "Herramientas de invitado": una ISO pequeña (unidad PARALELO en Windows) con el script que activa
/// RDP y RemoteApp. Así no hace falta red ni carpetas compartidas para preparar Windows.
public enum GuestTools {
    /// Súbelo cuando cambie el contenido de la ISO (las VMs existentes la regeneran al arrancar).
    public static let version = 5
    public static let setupScriptName = "setup-windows.ps1"
    /// Clave pública SSH de la VM; setup-windows.ps1 la autoriza para el canal de control.
    public static let publicKeyName = "paralelo.pub"

    /// El instalador de Windows lee Autounattend.xml de cualquier unidad extraíble. Solo añade comandos:
    /// salta las comprobaciones de TPM/Secure Boot/RAM (no hay TPM con HVF) y permite configurar
    /// Windows sin internet (BypassNRO). El resto de la instalación sigue siendo interactiva.
    public static let autounattend = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>

    """

    public static let setupScript = #"""
# Prepara Windows 11 para Paralelo: escritorio remoto + RemoteApp (modo Coherence).
# Paralelo lo copia a la unidad "PARALELO" de Windows. Ejecutar UNA vez, en PowerShell como Administrador:
#   powershell -ExecutionPolicy Bypass -File D:\setup-windows.ps1   (cambia D: por la letra de la unidad)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Abre PowerShell como Administrador y vuelve a ejecutar este script.'
}

$edition = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Host "Edición detectada: $edition"
if ($edition -match 'Home') {
    Write-Warning 'Windows Home no incluye servidor de escritorio remoto: Coherence no funcionará. Usa la edición Pro.'
}

# 1. Activar escritorio remoto.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0

# 2. Abrir el firewall (los nombres internos de las reglas no dependen del idioma).
Get-NetFirewallRule -Name 'RemoteDesktop-*' | Enable-NetFirewallRule

# 3. Permitir RemoteApp de cualquier programa, no solo los publicados en un servidor RDS.
$allowList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
New-Item -Path $allowList -Force | Out-Null
Set-ItemProperty -Path $allowList -Name 'fDisabledAllowList' -Value 1 -Type DWord

$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
New-Item -Path $policy -Force | Out-Null
Set-ItemProperty -Path $policy -Name 'fAllowUnlistedRemotePrograms' -Value 1 -Type DWord

# 4. Que la VM no se suspenda sola (Paralelo ya la pausa cuando quieras).
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off

# 5. Canal de control de Paralelo (lista de apps e iconos): OpenSSH Server, solo con la clave de este Mac.
#    El puerto solo se publica en 127.0.0.1 del Mac, no en tu red.
$pub = Join-Path $PSScriptRoot 'paralelo.pub'
if (Test-Path $pub) {
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap -and $cap.State -ne 'Installed') {
            Write-Host 'Instalando OpenSSH Server (necesita internet; puede tardar unos minutos)...'
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        }
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd

        $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        if ($rule) {
            $rule | Set-NetFirewallRule -Enabled True -Profile Any
        } else {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound `
                -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
        }

        # Los administradores usan este archivo en lugar de ~\.ssh\authorized_keys; sshd exige que solo
        # Administradores y SYSTEM puedan tocarlo.
        $keys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $key = (Get-Content $pub -Raw).Trim()
        $existing = if (Test-Path $keys) { Get-Content $keys } else { @() }
        if ($existing -notcontains $key) { Add-Content -Path $keys -Value $key -Encoding ascii }
        icacls $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        Write-Host "Canal de control activo. Usuario para Paralelo: $env:USERNAME" -ForegroundColor Green
    } catch {
        Write-Warning "No se pudo activar OpenSSH (sin él no hay lista de apps ni iconos): $($_.Exception.Message)"
    }
}

# 6. Agente de Paralelo al iniciar sesión: monta la carpeta del Mac como unidad Z: y comparte el
#    portapapeles con la ventana de pantalla de Paralelo.
#    La carpeta del Mac llega por el SMB interno de QEMU, que solo admite invitados: hay que permitir
#    esas conexiones (solo existen dentro de la red privada de la VM).
try {
    Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Confirm:$false
    $lanman = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
    New-Item -Path $lanman -Force | Out-Null
    Set-ItemProperty -Path $lanman -Name 'AllowInsecureGuestAuth' -Value 1 -Type DWord

    $agentDir = Join-Path $env:ProgramData 'Paralelo'
    $clipDir = Join-Path $agentDir 'clipboard'
    New-Item -ItemType Directory -Path $clipDir -Force | Out-Null
    icacls $clipDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'paralelo-agent.ps1') $agentDir -Force
    $launcher = Join-Path $agentDir 'paralelo-agent.vbs'
    Copy-Item (Join-Path $PSScriptRoot 'paralelo-agent.vbs') $launcher -Force
    $startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
    Copy-Item $launcher (Join-Path $startup 'Paralelo.vbs') -Force
    # Se cierra el agente anterior y se arranca el nuevo sin permisos de administrador (a través del
    # Explorador), en la sesión del usuario.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*paralelo-agent.ps1*' } |
        Invoke-CimMethod -MethodName Terminate | Out-Null
    Start-Process explorer.exe -ArgumentList "`"$launcher`""
    Write-Host 'Agente de Paralelo instalado (unidad Z: con tu carpeta del Mac, portapapeles y archivos).' -ForegroundColor Green
} catch {
    Write-Warning "No se pudo instalar el agente de Paralelo: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Listo. Notas:' -ForegroundColor Green
Write-Host ' - Tu usuario de Windows necesita contraseña (RDP no acepta PIN ni cuentas sin contraseña).'
Write-Host ' - Con cuenta Microsoft, el usuario para RDP es tu correo y la contraseña de la cuenta.'
Write-Host ' - Reinicia Windows para aplicar todos los cambios.'
"""#

    /// Versión del agente; Paralelo lo actualiza por SSH cuando la de Windows es otra.
    public static let agentVersion = 5

    /// Agente que se ejecuta oculto al iniciar sesión en Windows. Solo ASCII (Windows PowerShell 5.1).
    /// Intercambia con el Mac, por archivos en C:\ProgramData\Paralelo\clipboard:
    /// - from-mac.kind ("text image files") y from-mac.txt/.png/-files.txt: portapapeles del Mac.
    /// - to-mac.kind ("<id> text image files size=<bytes>") y to-mac.txt/.png/-files.txt: el de Windows.
    /// - drop.txt ("x y" y una ruta por línea): archivos soltados sobre la pantalla.
    public static let agentScript = #"""
# Agente de Paralelo: se ejecuta oculto al iniciar sesion.
$ErrorActionPreference = 'SilentlyContinue'
$mutex = New-Object System.Threading.Mutex($false, 'Local\ParaleloAgent')
if (-not $mutex.WaitOne(0)) { exit }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Paralelo {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);

        // Ventana principal bajo un punto de la pantalla (en pixeles reales).
        public static long RootAt(int x, int y) {
            POINT p;
            p.X = x;
            p.Y = y;
            return GetAncestor(WindowFromPoint(p), 2).ToInt64();
        }
    }
}
'@
[Paralelo.Native]::SetProcessDPIAware() | Out-Null

$dir = Join-Path $env:ProgramData 'Paralelo\clipboard'
$utf8 = New-Object System.Text.UTF8Encoding $false
function P([string]$name) { Join-Path $dir $name }
[IO.File]::WriteAllText((P 'agent-version.txt'), 'AGENT_VERSION', $utf8)

# 1. Carpeta del Mac (SMB interno de QEMU) como unidad Z:, cuando la red este lista.
#    Se marca como intranet para que copiar desde ella no muestre avisos de seguridad.
$zone = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Ranges\Paralelo'
New-Item -Path $zone -Force | Out-Null
Set-ItemProperty -Path $zone -Name ':Range' -Value '10.0.2.4'
Set-ItemProperty -Path $zone -Name 'file' -Value 1 -Type DWord
for ($i = 0; $i -lt 30 -and -not (Test-Path 'Z:\'); $i++) {
    net use Z: \\10.0.2.4\qemu /persistent:no 2>&1 | Out-Null
    if (-not (Test-Path 'Z:\')) { Start-Sleep -Seconds 2 }
}
if (Test-Path 'Z:\') { (New-Object -ComObject Shell.Application).NameSpace('Z:\').Self.Name = 'Mac' }

# 2. Portapapeles (texto, imagenes y archivos) y archivos soltados desde el Mac.
function Stamp([string]$path) {
    if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).LastWriteTimeUtc } else { [DateTime]::MinValue }
}
function Read-Lines([string]$path) { @([IO.File]::ReadAllLines($path, $utf8) | Where-Object { $_ }) }

function Export-Clipboard {
    $kinds = @()
    $size = 0
    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
        [IO.File]::WriteAllLines((P 'to-mac-files.txt'), [string[]]$files, $utf8)
        foreach ($file in $files) {
            $item = Get-Item -LiteralPath $file
            if ($item.PSIsContainer) {
                $size += (Get-ChildItem -LiteralPath $file -Recurse -File | Measure-Object -Property Length -Sum).Sum
            } else {
                $size += $item.Length
            }
        }
        $kinds += 'files'
    }
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        [IO.File]::WriteAllText((P 'to-mac.txt'), [System.Windows.Forms.Clipboard]::GetText(), $utf8)
        $kinds += 'text'
    }
    if ($kinds -notcontains 'files' -and [System.Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if ($image) {
            $image.Save((P 'to-mac.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            $image.Dispose()
            $kinds += 'image'
        }
    }
    if ($kinds.Count -gt 0) {
        $line = "$([DateTime]::UtcNow.Ticks) $($kinds -join ' ') size=$size"
        [IO.File]::WriteAllText((P 'to-mac.kind'), $line, $utf8)
    }
}

function Import-Clipboard([string[]]$kinds) {
    $data = New-Object System.Windows.Forms.DataObject
    $any = $false
    if ($kinds -contains 'files') {
        $list = New-Object System.Collections.Specialized.StringCollection
        foreach ($line in (Read-Lines (P 'from-mac-files.txt'))) { [void]$list.Add($line) }
        if ($list.Count -gt 0) { $data.SetFileDropList($list); $any = $true }
    }
    if ($kinds -contains 'text') {
        $text = [IO.File]::ReadAllText((P 'from-mac.txt'), $utf8)
        if ($text) { $data.SetText($text); $any = $true }
    }
    if ($kinds -contains 'image') {
        $bytes = [IO.File]::ReadAllBytes((P 'from-mac.png'))
        $image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,$bytes)))
        if ($image) { $data.SetImage($image); $any = $true }
    }
    if ($any) {
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
        $script:ourSeq = [Paralelo.Native]::GetClipboardSequenceNumber()
    }
}

# Sobre una carpeta abierta del Explorador los archivos van a esa carpeta; si no, al Escritorio.
function Invoke-Drop {
    $lines = Read-Lines (P 'drop.txt')
    if ($lines.Count -lt 2) { return }
    $point = $lines[0] -split ' '
    $root = [Paralelo.Native]::RootAt([int]$point[0], [int]$point[1])
    $shell = New-Object -ComObject Shell.Application
    $target = ''
    foreach ($window in $shell.Windows()) {
        if ([int64]$window.HWND -eq $root) {
            $path = $window.Document.Folder.Self.Path
            if ($path -and (Test-Path -LiteralPath $path)) { $target = $path; break }
        }
    }
    if (-not $target) { $target = [Environment]::GetFolderPath('Desktop') }
    $folder = $shell.NameSpace($target)
    foreach ($source in ($lines | Select-Object -Skip 1)) { $folder.CopyHere($source, 0) }
}

$fromKind = P 'from-mac.kind'
$dropFile = P 'drop.txt'
Remove-Item (P 'to-mac.kind') -Force
$lastFrom = Stamp $fromKind
$lastDrop = Stamp $dropFile
$lastSeq = 0
$ourSeq = 0
while ($true) {
    $stamp = Stamp $fromKind
    if ($stamp -ne $lastFrom) {
        $lastFrom = $stamp
        try { Import-Clipboard (([IO.File]::ReadAllText($fromKind, $utf8)).Trim() -split ' ') } catch { }
    }
    $stamp = Stamp $dropFile
    if ($stamp -ne $lastDrop) {
        $lastDrop = $stamp
        try { Invoke-Drop } catch { }
    }
    $seq = [Paralelo.Native]::GetClipboardSequenceNumber()
    if ($seq -ne $lastSeq) {
        $lastSeq = $seq
        if ($seq -ne $ourSeq) { try { Export-Clipboard } catch { } }
    }
    Start-Sleep -Milliseconds 400
}
"""#.replacingOccurrences(of: "AGENT_VERSION", with: "\(agentVersion)")

    /// Lanza el agente sin ninguna ventana (PowerShell con -WindowStyle Hidden aún parpadea).
    public static let agentLauncher = #"""
    CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\Paralelo\paralelo-agent.ps1""", 0, False

    """#

    /// Carpetas del agente dentro de Windows.
    public static let clipboardDirectory = #"C:\ProgramData\Paralelo\clipboard"#
    /// Archivos que el Mac copia a Windows (portapapeles y arrastrar) cuando no están en la carpeta compartida.
    public static let transferDirectory = #"C:\ProgramData\Paralelo\transfer"#
    /// La carpeta compartida del Mac, tal como la ve Windows.
    public static let sharedFolderUNC = #"\\10.0.2.4\qemu"#

    /// Cierra el agente que esté en marcha (aunque sea de otra versión).
    static let stopAgent = #"""
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*paralelo-agent.ps1*' } |
    Invoke-CimMethod -MethodName Terminate | Out-Null
"""#

    /// Instala el agente actual desde el Mac por SSH y lo arranca en la sesión del usuario
    /// (con una tarea programada: un proceso lanzado desde SSH no tiene escritorio).
    public static var agentInstallScript: String {
        let ps1 = Data(agentScript.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString()
        let vbs = Data(agentLauncher.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString()
        return #"""
$ErrorActionPreference = 'Stop'
$base = Join-Path $env:ProgramData 'Paralelo'
$clip = Join-Path $base 'clipboard'
New-Item -ItemType Directory -Path $clip -Force | Out-Null
icacls $clip /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
[IO.File]::WriteAllBytes((Join-Path $base 'paralelo-agent.ps1'), [Convert]::FromBase64String('PS1'))
[IO.File]::WriteAllBytes((Join-Path $base 'paralelo-agent.vbs'), [Convert]::FromBase64String('VBS'))
$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
Copy-Item (Join-Path $base 'paralelo-agent.vbs') (Join-Path $startup 'Paralelo.vbs') -Force
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + (Join-Path $base 'paralelo-agent.vbs') + '"')
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName 'Paralelo agente' -Action $action -Principal $principal -Force | Out-Null
Remove-Item (Join-Path $clip 'agent-version.txt') -Force -ErrorAction SilentlyContinue
"""#.replacingOccurrences(of: "'PS1'", with: "'\(ps1)'").replacingOccurrences(of: "'VBS'", with: "'\(vbs)'")
            + stopAgent + "Start-ScheduledTask -TaskName 'Paralelo agente'\n"
    }

    /// Crea la ISO con hdiutil (incluido en macOS). Devuelve false si hdiutil no está disponible.
    @discardableResult
    public static func buildISO(at destination: URL, publicKey: String? = nil) throws -> Bool {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        guard FileManager.default.isExecutableFile(atPath: hdiutil.path) else { return false }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("paralelo-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // BOM + CRLF para que Windows PowerShell 5.1 lea bien los acentos.
        let text = setupScript.replacingOccurrences(of: "\n", with: "\r\n")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: staging.appendingPathComponent(setupScriptName))
        if let publicKey {
            try (publicKey + "\n").write(to: staging.appendingPathComponent(publicKeyName), atomically: true, encoding: .utf8)
        }
        try autounattend.write(to: staging.appendingPathComponent("Autounattend.xml"), atomically: true, encoding: .utf8)
        try Data(agentScript.replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .write(to: staging.appendingPathComponent("paralelo-agent.ps1"))
        try Data(agentLauncher.replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .write(to: staging.appendingPathComponent("paralelo-agent.vbs"))

        try? FileManager.default.removeItem(at: destination)
        try ProcessRunner.check(hdiutil, [
            "makehybrid", "-iso", "-joliet", "-default-volume-name", "PARALELO",
            "-o", destination.path, staging.path,
        ])
        return true
    }
}

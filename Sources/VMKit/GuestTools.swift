import Foundation

/// "Herramientas de invitado": una ISO pequeña (unidad PARALELO en Windows) con el script que activa
/// RDP y RemoteApp. Así no hace falta red ni carpetas compartidas para preparar Windows.
public enum GuestTools {
    /// Súbelo cuando cambie el contenido de la ISO (las VMs existentes la regeneran al arrancar).
    public static let version = 2
    public static let setupScriptName = "setup-windows.ps1"

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

Write-Host ''
Write-Host 'Listo. Notas:' -ForegroundColor Green
Write-Host ' - Tu usuario de Windows necesita contraseña (RDP no acepta PIN ni cuentas sin contraseña).'
Write-Host ' - Con cuenta Microsoft, el usuario para RDP es tu correo y la contraseña de la cuenta.'
Write-Host ' - Reinicia Windows para aplicar todos los cambios.'
"""#

    /// Crea la ISO con hdiutil (incluido en macOS). Devuelve false si hdiutil no está disponible.
    @discardableResult
    public static func buildISO(at destination: URL) throws -> Bool {
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
        try autounattend.write(to: staging.appendingPathComponent("Autounattend.xml"), atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: destination)
        try ProcessRunner.check(hdiutil, [
            "makehybrid", "-iso", "-joliet", "-default-volume-name", "PARALELO",
            "-o", destination.path, staging.path,
        ])
        return true
    }
}

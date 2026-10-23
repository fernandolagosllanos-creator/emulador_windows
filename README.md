# Paralelo

Gestor de máquinas virtuales Windows 11 para Mac con Apple Silicon, al estilo Parallels Desktop, con un modo **Coherence** que muestra las apps de Windows como ventanas sueltas del Mac.

No es un emulador escrito desde cero. Paralelo es una app nativa (SwiftUI) y un CLI que controlan **QEMU con aceleración HVF**, el hipervisor de macOS. Windows 11 ARM corre a velocidad casi nativa y ejecuta apps x86/x64 con la emulación propia de Windows.

> Estado: MVP. Pensado para ofimática. Sin aceleración 3D (ver [Limitaciones](#limitaciones)).

## Qué hace

| Función | Cómo |
|---|---|
| Crear VM desde una ISO | Disco qcow2 que crece según se usa, UEFI (edk2). Las comprobaciones de TPM y Secure Boot se saltan solas con un `Autounattend.xml` |
| Iniciar, pausar, reanudar, apagar, forzar | QMP (protocolo de control de QEMU) |
| Snapshots | Con la VM encendida guardan disco y memoria (`savevm`). Con la VM apagada, solo disco (`qemu-img snapshot`) |
| Ajustes de CPU, RAM y disco | Editables con la VM apagada. El disco solo crece |
| Escritorio completo | RDP a `127.0.0.1:<puerto>`, con resolución dinámica y portapapeles |
| **Coherence** | RDP RemoteApp: cada app de Windows se abre en su propia ventana del Mac |
| Apps de Windows en el Dock | Mini-apps en `~/Applications/Paralelo Apps` que arrancan la VM sin ventana y abren la app |
| Menú en la barra superior | Acceso rápido a las apps de cada VM |
| Herramientas de invitado | Unidad `PARALELO` en Windows con `setup-windows.ps1`, que activa RDP y RemoteApp, y `Autounattend.xml`, que salta las comprobaciones de TPM y permite instalar sin internet |

## Requisitos

- Mac con Apple Silicon y macOS 14 o superior.
- Xcode o Command Line Tools (para compilar).
- Homebrew. Después, `scripts/install-deps.sh`, que instala `qemu`.
- Para Coherence: **Windows App** de Microsoft (App Store) o FreeRDP (`scripts/install-deps.sh --freerdp`).
- ISO de **Windows 11 ARM64**: <https://www.microsoft.com/software-download/windows11arm64>
- Recomendado: ISO de drivers **virtio-win**, necesaria para la red: <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>

## Compilar

```sh
scripts/install-deps.sh
swift test                 # pruebas de VMKit
scripts/build-app.sh       # genera build/Paralelo.app (incluye el CLI)
open build/Paralelo.app
```

Durante el desarrollo también funcionan `swift run ParaleloApp` y `swift run paralelo <comando>`.

## Instalar Windows

Consulta la guía paso a paso en [docs/instalar-windows.md](docs/instalar-windows.md). En resumen:

1. Crea la VM con el botón **+** (o `paralelo create "Windows 11" --iso ~/Downloads/Win11_ARM64.iso --drivers ~/Downloads/virtio-win.iso`).
2. Pulsa **Iniciar** y pulsa una tecla cuando aparezca *Press any key to boot from CD or DVD*.
3. Elige **"No tengo clave de producto"** y **Windows 11 Pro**. Funciona sin activar, con marca de agua.
4. Ya en Windows: instala los drivers de red desde la unidad virtio-win y ejecuta `setup-windows.ps1` desde la unidad **PARALELO**.
5. Apaga la VM, pulsa **Expulsar ISO** y crea un snapshot `limpio`.

## Coherence

1. En la sección Coherence de la VM, escribe tu usuario de Windows y elige el cliente RDP.
2. Pulsa **Abrir** junto a una app, o **Crear apps en el Dock / Launchpad**.
3. Si la VM está apagada, Paralelo la arranca sin ventana, espera a que Windows acepte RDP y abre la app.

Puedes añadir cualquier programa por su ruta en Windows (p. ej. `C:\Program Files\Mozilla Firefox\firefox.exe`).

## CLI

```text
paralelo list
paralelo create <nombre> --iso <ruta.iso> [--cpus 4] [--ram 8192] [--disk 64] [--drivers <virtio-win.iso>]
paralelo start <vm> [--headless] [--no-installer]
paralelo status|pause|resume|shutdown|kill <vm>
paralelo set <vm> [--cpus N] [--ram MB] [--disk GB] [--user USUARIO] [--client windowsApp|freeRDP] [--eject-iso]
paralelo snapshot list|create|restore|delete <vm> [nombre]
paralelo desktop <vm>
paralelo apps <vm>
paralelo app <vm> <app>
paralelo add-app <vm> <nombre> <ruta.exe>
paralelo dock <vm>
paralelo delete <vm>
paralelo log <vm>
```

## Arquitectura

```
Sources/
  VMKit/                 núcleo, sin interfaz
    VMConfiguration      modelo persistente (config.json)
    VMLibrary / VMBundle  ~/Library/Application Support/Paralelo/VMs/<id>.paralelovm
    QEMUCommandBuilder   línea de comandos de qemu-system-aarch64 (función pura, con pruebas)
    QMPClient            control de QEMU por socket Unix
    VMController         ciclo de vida, snapshots, ajustes
    GuestTools           ISO con setup-windows.ps1
    Coherence/           RemoteApp, archivos .rdp, FreeRDP, apps del Dock, llavero
  paralelo/              CLI
  ParaleloApp/           app SwiftUI y menú de la barra superior
```

Hardware virtual: máquina `virt` + HVF, `-cpu host`, disco NVMe, USB XHCI (teclado, tablet e ISOs como memorias USB), pantalla `ramfb` y red `virtio-net` con NAT. El RDP de Windows queda publicado **solo** en `127.0.0.1` del Mac.

## Limitaciones

- **Sin aceleración 3D.** No hay drivers gráficos 3D de QEMU para Windows ARM, así que los juegos y las apps 3D no van bien. Para juegos en Mac conviene usar CrossOver, Whisky o el Game Porting Toolkit de Apple.
- **La consola de QEMU (`ramfb`) es de baja resolución.** Sirve para instalar Windows. Para el día a día usa **Escritorio** (RDP) o Coherence.
- **Coherence muestra ventanas RDP.** Las apps no tienen icono propio en el Dock mientras están abiertas (el icono es el del cliente RDP), no hay arrastrar y soltar entre Mac y Windows, y puede haber algún parpadeo al mover ventanas.
- **Coherence exige Windows Pro** (Home no incluye servidor RDP) y un usuario con contraseña.
- **Sin TPM.** El TPM emulado (`tpm-tis-device`) hace fallar a QEMU con HVF, así que Paralelo no lo usa: Windows 11 se instala igual porque la unidad PARALELO incluye un `Autounattend.xml` que salta esa comprobación. BitLocker y Windows Hello con TPM no están disponibles.
- **Sin carpetas compartidas por virtio-fs.** La carpeta de inicio del Mac se comparte a través de RDP.
- **Pendiente de verificar en hardware real:** snapshots con memoria (`savevm`) sobre HVF, y RemoteApp con Windows App en macOS. Si Windows App no abre la app suelta, usa FreeRDP.

## Hoja de ruta

- Consola integrada en la ventana de la app (VNC/SPICE) en lugar de la ventana de QEMU.
- Agente de invitado: lista automática de apps instaladas con sus iconos, y apagado o suspensión limpios.
- Iconos reales en las apps del Dock.
- Carpetas compartidas con virtio-fs.

# Paralelo

Gestor de máquinas virtuales Windows 11 para Mac con Apple Silicon, al estilo Parallels Desktop, con un modo **Coherence** que muestra las apps de Windows como ventanas sueltas del Mac.

No es un emulador escrito desde cero. Paralelo es una app nativa (SwiftUI) y un CLI que controlan **QEMU con aceleración HVF**, el hipervisor de macOS. Windows 11 ARM corre a velocidad casi nativa y ejecuta apps x86/x64 con la emulación propia de Windows.

> Estado: MVP. Pensado para ofimática. Sin aceleración 3D (ver [Limitaciones](#limitaciones)).

## Qué hace

| Función | Cómo |
|---|---|
| Crear VM desde una ISO | Disco qcow2 que crece según se usa, UEFI (edk2). Las comprobaciones de TPM y Secure Boot se saltan solas con un `Autounattend.xml` |
| Iniciar, pausar, reanudar, apagar, forzar | QMP (protocolo de control de QEMU). **Apagar** le pide a Windows que se apague por el canal de control |
| Suspender | Guarda el estado de Windows (memoria incluida) en el disco y cierra la VM; **Reanudar** sigue donde estaba |
| Carpeta del Mac en Windows | Tu carpeta de inicio aparece como unidad **Z: (Mac)** en Windows, por el SMB integrado de QEMU (necesita `brew install samba`) |
| Portapapeles | En la ventana de pantalla: lo copiado en el Mac se pega en Windows y al revés (texto) |
| Snapshots | Con la VM encendida guardan disco y memoria (`savevm`). Con la VM apagada, solo disco (`qemu-img snapshot`) |
| Ajustes de CPU, RAM y disco | Editables con la VM apagada. El disco solo crece |
| Pantalla de Windows en Paralelo | Ventana propia de Paralelo (VNC por un socket privado), con teclado español y ratón. Sirve también para instalar Windows |
| Escritorio completo por RDP | RDP a `127.0.0.1:<puerto>`, con resolución dinámica y portapapeles |
| **Coherence** | RDP RemoteApp: cada app de Windows se abre en su propia ventana del Mac |
| Apps de Windows en el Dock | Mini-apps en `~/Applications/Paralelo Apps`, con el icono real de cada app, que arrancan la VM sin ventana y abren la app |
| Lista automática de apps | Busca en Windows todo lo del menú Inicio (también apps de la Microsoft Store) con sus iconos, sin escribir rutas |
| Menú en la barra superior | Acceso rápido a las apps de cada VM |
| Herramientas de invitado | Unidad `PARALELO` en Windows con `setup-windows.ps1`, que activa RDP, RemoteApp y el canal de control (OpenSSH con una clave propia de la VM), y `Autounattend.xml`, que salta las comprobaciones de TPM y permite instalar sin internet |

## Requisitos

- Mac con Apple Silicon y macOS 14 o superior.
- Xcode o Command Line Tools (para compilar).
- Homebrew. Después, `scripts/install-deps.sh`, que instala `qemu` y `samba` (para la carpeta compartida).
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

Pulsa **Buscar apps instaladas en Windows…** para elegir de la lista de apps del menú Inicio, con sus iconos. También puedes añadir cualquier programa por su ruta en Windows (p. ej. `C:\Program Files\Mozilla Firefox\firefox.exe`).

La búsqueda usa un canal de control por SSH: `setup-windows.ps1` (versión 3 o posterior) instala OpenSSH Server en Windows y solo autoriza la clave de esa VM, que Paralelo crea en el Mac. El puerto (el de RDP + 1000) solo se publica en `127.0.0.1`. El usuario de Coherence debe ser una cuenta administradora de Windows: el script muestra el nombre exacto al terminar.

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
paralelo scan <vm> [--add todas|<nombre>]
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
- **La pantalla de la VM (`ramfb`) es básica:** resolución fija y sin portapapeles. Sirve para instalar y administrar Windows. Para el día a día usa **Escritorio RDP** o Coherence. En la pantalla, Comando es la tecla Windows: usa Control para los atajos de Windows (Control+C, Control+V…).
- **Coherence muestra ventanas RDP.** Mientras están abiertas, las apps muestran en el Dock el icono del cliente RDP, no el suyo, no hay arrastrar y soltar entre Mac y Windows, y puede haber algún parpadeo al mover ventanas.
- **Coherence exige Windows Pro** (Home no incluye servidor RDP) y un usuario con contraseña.
- **Sin TPM.** El TPM emulado (`tpm-tis-device`) hace fallar a QEMU con HVF, así que Paralelo no lo usa: Windows 11 se instala igual porque la unidad PARALELO incluye un `Autounattend.xml` que salta esa comprobación. BitLocker y Windows Hello con TPM no están disponibles.
- **La carpeta del Mac llega por SMB, no por virtio-fs** (virtio-fs no existe en QEMU para macOS). Para el SMB interno de QEMU, `setup-windows.ps1` permite en Windows conexiones SMB de invitado sin firma; solo existen dentro de la red privada de la VM.
- **El portapapeles de la ventana de pantalla solo copia texto** y se sincroniza al entrar y salir de la ventana. En Coherence y en el escritorio RDP el portapapeles lo gestiona RDP.

## Hoja de ruta


- Portapapeles con imágenes y archivos en la ventana de pantalla.
- Arrastrar y soltar archivos del Mac a Windows.

# Instalar Windows 11 ARM en Paralelo

## 1. Descargas

- **Windows 11 ARM64 (ISO):** <https://www.microsoft.com/software-download/windows11arm64>
- **Drivers virtio-win (ISO):** <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>. El instalador de Windows ARM no trae driver para la tarjeta de red virtual, y esta ISO sí lo incluye.

## 2. Crear la VM

En la app, pulsa **+**, elige las dos ISOs y deja 4 CPU, 8 GB de RAM y 64 GB de disco (o más).

Desde la terminal:

```sh
paralelo create "Windows 11" --iso ~/Downloads/Win11_ARM64.iso --drivers ~/Downloads/virtio-win.iso
```

## 3. Instalación

1. Pulsa **Iniciar**. Se abre una ventana de Paralelo con la pantalla de la VM (haz clic dentro para usar el teclado).
2. Cuando aparezca *Press any key to boot from CD or DVD...*, pulsa una tecla. Si se te pasa, apaga con **Forzar** y vuelve a iniciar.
3. Elige idioma y, en la clave de producto, **"No tengo clave de producto"**.
4. Elige **Windows 11 Pro**. Home no sirve para Coherence.
5. Elige **Personalizada** y selecciona el disco vacío.

### Si el instalador dice "Este equipo no puede ejecutar Windows 11"

No debería pasar: la unidad PARALELO trae un `Autounattend.xml` que salta las comprobaciones de TPM, Secure Boot y RAM. Si aun así aparece, pulsa `Shift+F10` y escribe lo siguiente:

```bat
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
```

Cierra la consola, vuelve un paso atrás en el instalador y continúa.

### Configuración inicial sin red

Como aún no hay driver de red, Windows puede pedir conexión a internet. El `Autounattend.xml` ya activa la opción **"No tengo internet"**. Si no aparece, pulsa `Shift+F10` y escribe:

```bat
OOBE\BYPASSNRO
```

La VM se reinicia y aparece la opción **"No tengo internet"**, que permite crear una **cuenta local**. Ponle contraseña, porque RDP no funciona sin ella.

## 4. Drivers y herramientas

Ya en el escritorio de Windows:

1. Abre el Explorador, entra en la unidad **virtio-win** y luego en `NetKVM\w11\ARM64`. Haz clic derecho sobre `netkvm.inf` y elige **Instalar**. Con eso ya hay red.
2. Abre **PowerShell como Administrador** y ejecuta lo siguiente (cambia `E:` por la letra de la unidad **PARALELO**):

   ```powershell
   powershell -ExecutionPolicy Bypass -File E:\setup-windows.ps1
   ```

3. Si te pide instalar OpenSSH Server, deja que termine (necesita internet; puede tardar 10 minutos). No hagas clic dentro de la consola mientras tanto: el título cambia a "Seleccionar" y el script se queda en pausa (pulsa Esc para seguir). Al final muestra tu **usuario para Paralelo**: apúntalo.
4. Reinicia Windows. Tras iniciar sesión aparece la unidad **Z: (Mac)** con tu carpeta del Mac (si instalaste Samba en el Mac).

Cuando Paralelo se actualice con una nueva versión de la unidad PARALELO, vuelve a ejecutar el script: no repite lo que ya está hecho.

## 5. Dejarla lista

1. Apaga Windows desde el menú Inicio o con **Apagar** en Paralelo.
2. Pulsa **Expulsar ISO** para quitar el instalador.
3. Crea un snapshot llamado `limpio`.
4. En **Coherence**, escribe tu usuario de Windows (el que mostró el script) y pulsa **Guardar**.
5. Pulsa **Buscar apps instaladas en Windows…** y elige las apps que quieras.
6. Pulsa **Abrir** junto a una app, o **Crear apps en el Dock / Launchpad**.

A partir de aquí puedes usar **Iniciar sin ventana** (en el menú de **Iniciar**) y trabajar solo con Coherence o con **Escritorio RDP**. **Pantalla** vuelve a mostrar la pantalla de la VM cuando la necesites.

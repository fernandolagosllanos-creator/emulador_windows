import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VMKit

struct NewVMSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Windows 11"
    @State private var isoPath = ""
    @State private var driversPath = ""
    @State private var cpus = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memoryMB = 8192
    @State private var diskGB = 64
    @State private var useTPM = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva máquina virtual").font(.title2)
            Form {
                TextField("Nombre", text: $name)
                FilePickerRow(title: "ISO de Windows 11 ARM", path: $isoPath)
                FilePickerRow(title: "ISO de drivers virtio-win (opcional, para la red)", path: $driversPath)
                Stepper("CPU: \(cpus)", value: $cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                MemoryPicker(memoryMB: $memoryMB)
                Stepper("Disco: \(diskGB) GB", value: $diskGB, in: 32...2048, step: 16)
                Toggle("TPM 2.0 emulado (requerido por Windows 11)", isOn: $useTPM)
            }
            Text("Durante la instalación elige \"No tengo clave de producto\" y la edición Windows 11 Pro.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Crear") {
                    let config = VMConfiguration(
                        name: name, cpuCount: cpus, memoryMB: memoryMB, diskSizeGB: diskGB,
                        installerISO: isoPath.isEmpty ? nil : isoPath,
                        driversISO: driversPath.isEmpty ? nil : driversPath,
                        rdpPort: model.library.nextFreeRDPPort(),
                        useTPM: useTPM)
                    model.create(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || isoPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct FilePickerRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(path.isEmpty ? "Ninguna" : URL(fileURLWithPath: path).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Elegir…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
            if !path.isEmpty {
                Button { path = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
        }
    }
}

struct MemoryPicker: View {
    @Binding var memoryMB: Int
    static let options = [4096, 6144, 8192, 12288, 16384, 24576, 32768]

    var body: some View {
        Picker("Memoria", selection: $memoryMB) {
            ForEach(Self.options.filter { $0 <= Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }, id: \.self) {
                Text("\($0 / 1024) GB").tag($0)
            }
        }
    }
}

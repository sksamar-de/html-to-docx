import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("HTML → DOCX Converter")
                .font(.title2).bold()

            folderField(
                title: "Observer",
                subtitle: "New .html files dropped here are converted automatically.",
                path: $vm.observerPath,
                action: vm.chooseObserver
            )

            folderField(
                title: "Target",
                subtitle: "Generated .docx files are written here.",
                path: $vm.targetPath,
                action: vm.chooseTarget
            )

            HStack(spacing: 12) {
                Button(vm.isWatching ? "Stop Watching" : "Start Watching") {
                    vm.toggleWatching()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.observerPath.isEmpty || vm.targetPath.isEmpty)

                Button("Convert Existing Files") {
                    vm.reconvertAll()
                }
                .disabled(vm.observerPath.isEmpty || vm.targetPath.isEmpty)

                Spacer()

                Toggle("Launch at Login", isOn: $vm.launchAtLogin)
                    .toggleStyle(.switch)
            }

            Divider()

            HStack(spacing: 16) {
                statusBadge(title: "Status",
                            value: vm.isWatching ? "Watching" : "Idle",
                            color: vm.isWatching ? .green : .secondary)
                statusBadge(title: "Converted", value: "\(vm.converted)", color: .primary)
                statusBadge(title: "Failed",
                            value: "\(vm.failed)",
                            color: vm.failed > 0 ? .red : .secondary)
                Spacer()
            }

            Text(vm.lastEvent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    private func folderField(title: String,
                             subtitle: String,
                             path: Binding<String>,
                             action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                TextField("Pick a folder…", text: path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…", action: action)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusBadge(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
        }
    }
}

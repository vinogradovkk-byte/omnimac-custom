import SwiftUI

struct VSCodeTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var monitor: VSCodeWindowMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(Brand.accentLight)
                Text("Visual Studio Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(monitor.windows.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Button(action: openNewWindow) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help(L("Открыть новое окно VS Code", "Open a new VS Code window"))
            }

            if monitor.windows.isEmpty {
                Button(action: openNewWindow) {
                    VStack(spacing: 7) {
                        Image(systemName: "plus.app")
                            .font(.system(size: 20, weight: .medium))
                        Text(L("Открыть новое окно VS Code", "Open a new VS Code window"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.vertical, showsIndicators: monitor.windows.count > 3) {
                    VStack(spacing: 6) {
                        ForEach(monitor.windows) { window in
                            Button {
                                if VSCodeWindowProvider.focus(window) {
                                    model.onCollapseRequest?()
                                } else {
                                    monitor.refresh()
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: window.isMinimized ? "macwindow.badge.minus" : "macwindow")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .frame(width: 18)
                                    Text(window.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(.white.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { monitor.refresh() }
    }

    private func openNewWindow() {
        guard VSCodeWindowProvider.openNewWindow() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            monitor.refresh()
        }
    }
}

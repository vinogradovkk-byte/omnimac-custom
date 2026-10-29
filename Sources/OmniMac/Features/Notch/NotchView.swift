import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Símbolos SF que usa el notch (pestañas y zonas).
enum NotchSymbols {
    /// El símbolo "airdrop" existe desde SF Symbols 6; si no está, usamos uno parecido.
    static let airdrop: String =
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
        ? "airdrop"
        : "dot.radiowaves.left.and.right"
}

/// Forma del notch expandido, como el notch físico: arriba las esquinas se abren
/// HACIA FUERA (el negro se ensancha al llegar al techo con una curva cóncava) y
/// abajo van redondeadas. El cuerpo ocupa `rect` menos `flare` a cada lado; las
/// "alas" de arriba usan ese margen.
struct NotchExpandedShape: Shape {
    static let flare: CGFloat = 14
    var bottomCorner: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        let W = rect.width, H = rect.height
        let r = min(Self.flare, W / 4, H / 2)
        let rb = min(bottomCorner, (W - 2 * r) / 2, max(0, H - r))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: W, y: 0))
        p.addQuadCurve(to: CGPoint(x: W - r, y: r), control: CGPoint(x: W - r, y: 0))      // ala sup. der
        p.addLine(to: CGPoint(x: W - r, y: H - rb))
        p.addQuadCurve(to: CGPoint(x: W - r - rb, y: H), control: CGPoint(x: W - r, y: H))  // inf. der
        p.addLine(to: CGPoint(x: r + rb, y: H))
        p.addQuadCurve(to: CGPoint(x: r, y: H - rb), control: CGPoint(x: r, y: H))          // inf. izq
        p.addLine(to: CGPoint(x: r, y: r))
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: r, y: 0))                // ala sup. izq
        p.closeSubpath()
        return p
    }
}

/// Marcos de los iconos de la izquierda, que la vista publica hacia arriba para que
/// el arrastre se pueda llevar en AppKit (ver `NotchWindowController`): los eventos
/// de la franja bajo la barra de menús llegan por un tap y SwiftUI no puede seguir
/// un arrastre con ellos.
struct TabFramesKey: PreferenceKey {
    static var defaultValue: [NotchTab: CGRect] = [:]
    static func reduce(value: inout [NotchTab: CGRect], nextValue: () -> [NotchTab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: MediaBridge
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var keepAwake: KeepAwakeFeature
    @ObservedObject var calendar: CalendarBridge
    @ObservedObject var sound: SoundFeature
    @ObservedObject var stats: SystemStats
    @ObservedObject var vscode: VSCodeWindowMonitor
    @ObservedObject var ai: AIChatCoordinator
    @ObservedObject var gitlab: GitLabStore
    @ObservedObject var asana: AsanaStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var mail: MailLauncher
    @ObservedObject var vpn: VPNMonitor
    /// Marco de la zona AirDrop en coordenadas del notch (para decidir dónde cae la suelta).
    @State private var airDropFrame: CGRect = .zero
    @State private var showVPN = false

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            // La misma forma en ambos estados: así el paso plegado→expandido es una
            // sola animación continua del marco, que crece desde el centro del notch.
            // Con notch físico, plegado no se dibuja nada (el notch ya es negro); el
            // negro aparece sin animación justo al empezar a abrir. En pantallas sin
            // notch, la "isla" sí se ve siempre.
            NotchExpandedShape()
                .fill(Color.black.opacity(model.blackVisible || !model.hasNotch ? 1 : 0))
                .overlay(NotchExpandedShape().stroke(.white.opacity(model.expanded ? 0.08 : 0), lineWidth: 1))

            if !model.expanded, let peek = model.peek {
                // Vistazo rápido: una línea bajo el notch, dentro del negro.
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notchSize.height + 4)
                    HStack(spacing: 6) {
                        if let tint = peek.tint {
                            Circle()
                                .fill(Color(nsColor: tint))
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                .frame(width: 14, height: 14)
                        }
                        Image(systemName: peek.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(peek.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !peek.subtitle.isEmpty {
                            Text("· \(peek.subtitle)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, NotchExpandedShape.flare + 12)
                }
                .transition(.opacity)
            }

            if model.showContent {
                VStack(spacing: 0) {
                    // La barra de control sube a la altura de la barra de menús; sus
                    // clics los reenvía el forwardTap (si no, el sistema se los traga).
                    Color.clear.frame(height: max(2, model.notchSize.height - 28))
                    if let card = model.deviceCard {
                        HeadphonesCard(info: card)
                            .padding(.top, 28)   // debajo del notch físico
                            .transition(.opacity)
                    } else {
                        controlBar
                        content
                    }
                }
                .padding(.horizontal, NotchExpandedShape.flare) // el contenido va en el cuerpo, no en las alas
                // El contenido emerge escalando desde el centro-arriba (el notch).
                .transition(.scale(scale: 0.86, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: shapeSize.width, height: shapeSize.height)
        .clipShape(NotchExpandedShape()) // nada asoma fuera del negro durante la animación
        // Un solo plano antes de la sombra: así la sombra se calcula del conjunto y no
        // de cada subvista (con contenido semitransparente animándose, se «rompía»).
        .compositingGroup()
        // Sombra exterior en dos capas: una pegada al borde (marca hasta dónde llega
        // el notch) y otra amplia y suave (le da peso). Solo expandido (o en el vistazo).
        .shadow(color: .black.opacity(model.expanded ? 0.55 : (model.peek != nil ? 0.4 : 0)),
                radius: model.expanded || model.peek != nil ? 3 : 0,
                y: model.expanded || model.peek != nil ? 1 : 0)
        .shadow(color: .black.opacity(model.expanded ? 0.38 : 0),
                radius: model.expanded ? 16 : 0,
                y: model.expanded ? 8 : 0)
        .onHover { hovering in
            model.onHoverChange?(hovering)
        }
        .onTapGesture {
            if !model.expanded { model.onExpandRequest?() }
        }
        // Un único destino de arrastre para todo el notch: SwiftUI entrega la suelta al
        // destino exterior aunque haya otros dentro, así que aquí decidimos por
        // posición si el archivo va a la bandeja o a AirDrop.
        .coordinateSpace(name: "notch")
        .onDrop(of: [.fileURL], delegate: NotchDropDelegate(model: model, airDropFrame: { airDropFrame }))
        .onPreferenceChange(AirDropFrameKey.self) { airDropFrame = $0 }
        // Опрос только пока notch раскрыт: в свёрнутом виде ничего не просыпается.
        .task(id: model.expanded) {
            guard model.expanded else { return }
            var tick = 0
            while !Task.isCancelled {
                vpn.refresh()
                if tick % 10 == 0 { mail.refresh() }
                tick += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }


    /// Plegado = el notch exacto; con vistazo rápido crece un poco; expandido, todo.
    private var shapeSize: CGSize {
        if model.expanded {
            let size = model.deviceCard != nil ? model.cardSize : model.expandedSize
            return CGSize(width: size.width + NotchExpandedShape.flare * 2,
                          height: size.height)
        }
        if model.peek != nil {
            return model.peekSize
        }
        return model.notchSize
    }

    /// Una pestaña se ve si está activada en Ajustes y, en el caso de Sonido, si el
    /// módulo Sonido también lo está.
    private func isTabVisible(_ tab: NotchTab) -> Bool {
        if tab == .vscode {
            return VSCodeWindowProvider.shouldShowNotchTab(windowCount: vscode.windows.count)
        }
        guard model.enabledTabs.contains(tab) else { return false }
        if tab == .sound { return sound.isEnabled }
        return true
    }

    // MARK: - Barra de control (debajo de la barra de menús → clicable)

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryControlBar

            HStack(spacing: 6) {
                ForEach(NotchTab.secondRowTabs, id: \.self) { tab in
                    tabButton(tab, symbol: tab.symbol, help: tab.title, draggable: false)
                }
                Spacer(minLength: 0)
                // Не вкладки, а быстрые запуски: почта и статус VPN.
                launcherButton(symbol: "envelope", badge: mail.unread, tint: nil, help: mail.helpText) { mail.open() }
                if vpn.status != .unavailable {
                    launcherButton(symbol: vpn.status == .connected ? "lock.shield.fill" : "lock.shield", badge: 0, tint: vpnTint, help: vpn.helpText) { showVPN.toggle() }
                        .popover(isPresented: $showVPN, arrowEdge: .bottom) { VPNPanel(vpn: vpn) }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        // Dónde ha quedado cada icono reordenable de la primera fila.
        .onPreferenceChange(TabFramesKey.self) { frames in
            model.tabFrames = frames
        }
    }

    private var primaryControlBar: some View {
        HStack(spacing: 6) {
            // Solo las pestañas activadas en Ajustes (y Sonido solo si su módulo está activo).
            ForEach(model.tabOrder.filter { isTabVisible($0) }, id: \.self) { tab in
                tabButton(tab, symbol: tab.symbol, help: tab.title)
            }

            Spacer(minLength: 8)

            // A la derecha: el quinto botón a la izquierda quedaba bajo el notch físico.
            if isTabVisible(.performance) {
                tabButton(.performance, symbol: NotchTab.performance.symbol, help: NotchTab.performance.title)
            }

            if model.showCoffee, keepAwake.isEnabled {
                // Si la última sesión se paró sola, el icono lo dice: era la única
                // pista que faltaba para no tener que adivinarlo.
                let stoppedItself = keepAwake.lastEnding?.worthTelling == true && !keepAwake.isActive
                quickButton(symbol: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                            active: keepAwake.isActive,
                            warning: stoppedItself,
                            help: keepAwake.isActive
                                ? L("Mantener despierto: activado", "Keep awake: on")
                                : (keepAwake.lastEnding?.worthTelling == true
                                   ? keepAwake.lastEnding!.explanation
                                   : L("Mantener despierto", "Keep awake"))) {
                    keepAwake.toggle()
                }
            }
            if model.showSettings {
                quickButton(symbol: "gearshape.fill", active: false, help: L("Ajustes de OmniMac", "OmniMac settings")) {
                    model.onCollapseRequest?()
                    SettingsWindowController.shared.show()
                }
            }
            if model.showBattery {
                BatteryBadge(state: battery.state) {
                    // Ajustes del Sistema › Batería (modo de bajo consumo, etc.). Ojo al
                    // punto de «.extension»: con guion ese panel no existe, y Ajustes del
                    // Sistema abre General —o se queda donde estaba— sin dar ningún error.
                    model.onCollapseRequest?()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    /// Ancho de un icono más su separación: lo que hay que recorrer para adelantar a
    /// otro mientras se arrastra.
    private static let tabStep: CGFloat = 38

    private func tabButton(_ tab: NotchTab, symbol: String, help: String,
                           draggable: Bool = true) -> some View {
        let isDragging = draggable && model.draggingTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { model.tab = tab }
        } label: {
            Group {
                if tab == .gitlab { GitLabLogoView().frame(width: 14, height: 14) }
                else { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            }
                .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.4))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(isDragging ? 0.28 : (model.tab == tab ? 0.16 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(draggable
              ? L("\(help) · ⌘ y arrastra para cambiarlo de sitio",
                  "\(help) · ⌘-drag to move it")
              : help)
        // El arrastre lo lleva el controlador (ver `NotchWindowController`), porque
        // los eventos de esta franja llegan por un tap y SwiftUI no puede seguir un
        // arrastre con ellos. Aquí solo se publica dónde está cada icono y se pinta
        // el que se esté moviendo.
        .offset(x: isDragging ? model.tabDragOffset : 0)
        .scaleEffect(isDragging ? 1.12 : 1)
        .zIndex(isDragging ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TabFramesKey.self,
                    value: draggable ? [tab: geometry.frame(in: .global)] : [:]
                )
            }
        )
    }

    private var vpnTint: Color? {
        switch vpn.status {
        case .connected: return .green
        case .connecting, .disconnecting: return .yellow
        default: return nil
        }
    }

    /// Кнопка-запуск второй строки: как вкладка, но не переключает панель; со значком-счётчиком при необходимости.
    private func launcherButton(symbol: String, badge: Int, tint: Color?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? Color.white.opacity(0.4))
                .frame(width: 32, height: 26)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color(red: 0.0, green: 0.47, blue: 0.84)))
                            .offset(x: -1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func quickButton(symbol: String, active: Bool, warning: Bool = false,
                             help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.yellow : (warning ? Color.orange : .white.opacity(0.8)))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(active ? 0.18 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Contenido

    private var content: some View {
        Group {
            if !isTabVisible(model.tab) {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(L("Sin pestañas activas", "No tabs enabled"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(L("Actívalas en Ajustes › Notch dinámico", "Enable them in Settings › Dynamic notch"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.tab {
                case .media: MediaTab(media: media, hover: model.hover)
                case .tray: TrayTab(model: model)
                case .calendar: CalendarTab(calendar: calendar)
                case .sound: SoundTab(sound: sound, mixer: sound.mixer)
                case .timer: TimerTab(timer: NotchTimer.shared, hover: model.hover)
                case .vscode: VSCodeTab(model: model, monitor: vscode)
                case .ai: AIChatTab(coordinator: ai)
                case .gitlab: GitLabTab(store: gitlab)
                case .asana: AsanaTab(store: asana)
                case .notes: NotesTab(store: notes)
                case .performance: PerformanceTab(stats: stats)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }
}

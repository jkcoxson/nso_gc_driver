import AppKit
import Combine
import CoreBluetooth
import CoreGraphics
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ControlProfile: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var name: String
  var buttonMap: [String: String] = [:]
  var invertLeftX = false
  var invertLeftY = false
  var invertRightX = false
  var invertRightY = false
  var cStickSensitivity = 1.0

  static let controls = [
    "A", "B", "X", "Y", "L", "R", "Z", "ZL", "Start", "Home", "Capture",
    "Dpad_Up", "Dpad_Down", "Dpad_Left", "Dpad_Right",
  ]

  static let automatic = ControlProfile(name: "Automatic")
  static let dolphin = ControlProfile(name: "Dolphin")
  static let retroArch = ControlProfile(name: "RetroArch", buttonMap: ["A": "B", "B": "A"])

  func applying(to state: ControllerState) -> ControllerState {
    var result = state
    var buttons = Dictionary(uniqueKeysWithValues: Self.controls.map { ($0, false) })
    for source in Self.controls where state.buttons[source] == true {
      let target = buttonMap[source] ?? source
      if target != "Disabled" { buttons[target] = true }
    }
    result.buttons = buttons
    result.leftX = invertLeftX ? -state.leftX : state.leftX
    result.leftY = invertLeftY ? -state.leftY : state.leftY
    let scaledX = Int((Double(state.rightX) * cStickSensitivity).rounded())
    let scaledY = Int((Double(state.rightY) * cStickSensitivity).rounded())
    result.rightX = max(-2048, min(2047, invertRightX ? -scaledX : scaledX))
    result.rightY = max(-2048, min(2047, invertRightY ? -scaledY : scaledY))
    return result
  }
}

@MainActor final class ProfileStore: ObservableObject {
  @Published private(set) var profiles: [ControlProfile]
  @Published var activeID: UUID {
    didSet { persist(); onActiveProfileChanged?(activeProfile) }
  }
  var onActiveProfileChanged: ((ControlProfile) -> Void)?
  private let defaultsKey = "controllerProfiles.v1"
  private let activeKey = "activeControllerProfile.v1"

  init() {
    let defaults = UserDefaults.standard
    let loadedProfiles: [ControlProfile]
    if let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([ControlProfile].self, from: data), !decoded.isEmpty
    {
      loadedProfiles = decoded
    } else {
      loadedProfiles = [.automatic, .dolphin, .retroArch]
    }
    profiles = loadedProfiles
    if let raw = defaults.string(forKey: activeKey), let id = UUID(uuidString: raw),
      loadedProfiles.contains(where: { $0.id == id })
    {
      activeID = id
    } else {
      activeID = loadedProfiles[0].id
    }
  }

  var activeProfile: ControlProfile {
    profiles.first(where: { $0.id == activeID }) ?? profiles[0]
  }

  func select(_ id: UUID) { activeID = id }

  func updateActive(_ edit: (inout ControlProfile) -> Void) {
    guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
    edit(&profiles[index])
    persist()
    onActiveProfileChanged?(profiles[index])
  }

  func create(name: String = "New Profile") {
    let profile = ControlProfile(name: uniqueName(name))
    profiles.append(profile)
    activeID = profile.id
    persist()
  }

  func duplicateActive() {
    var copy = activeProfile
    copy.id = UUID()
    copy.name = uniqueName("\(copy.name) Copy")
    profiles.append(copy)
    activeID = copy.id
    persist()
  }

  func deleteActive() {
    guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == activeID }) else {
      return
    }
    profiles.remove(at: index)
    activeID = profiles[min(index, profiles.count - 1)].id
    persist()
  }

  func importProfile(from data: Data) throws {
    var profile = try JSONDecoder().decode(ControlProfile.self, from: data)
    profile.id = UUID()
    let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.name = uniqueName(trimmedName.isEmpty ? "Imported Profile" : trimmedName)
    profile.cStickSensitivity = max(0.25, min(2, profile.cStickSensitivity))
    let validControls = Set(ControlProfile.controls)
    profile.buttonMap = profile.buttonMap.filter { source, target in
      validControls.contains(source) && (validControls.contains(target) || target == "Disabled")
    }
    profiles.append(profile)
    activeID = profile.id
    persist()
  }

  func exportData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(activeProfile)
  }

  private func uniqueName(_ proposed: String) -> String {
    guard profiles.contains(where: { $0.name == proposed }) else { return proposed }
    var suffix = 2
    while profiles.contains(where: { $0.name == "\(proposed) \(suffix)" }) { suffix += 1 }
    return "\(proposed) \(suffix)"
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(profiles) {
      UserDefaults.standard.set(data, forKey: defaultsKey)
    }
    UserDefaults.standard.set(activeID.uuidString, forKey: activeKey)
  }
}

struct ControllerDiagnostics: Equatable, Sendable {
  var reportsPerSecond = 0
  var totalReports = 0
  var malformedReports = 0
  var lastActivity: Date?
}

struct JSONFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

enum AppPage: String, CaseIterable, Identifiable {
  case dashboard = "Dashboard"
  case lab = "Controller Lab"
  case profiles = "Profiles"
  case integrations = "Integrations"
  case diagnostics = "Diagnostics"
  var id: String { rawValue }
  var systemIcon: String? {
    switch self {
    case .dashboard: return "square.grid.2x2"
    case .lab: return nil
    case .profiles: return "slider.horizontal.3"
    case .integrations: return "point.3.connected.trianglepath.dotted"
    case .diagnostics: return "stethoscope"
    }
  }
}

struct GameCubeControllerIcon: View {
  var body: some View {
    Image("GameCubeController")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .accessibilityHidden(true)
  }
}

struct ContentView: View {
  @ObservedObject var model: BridgeModel
  var body: some View { MainNavigationView(model: model) }
}

struct MenuBarDriverView: View {
  private struct ControllerSummary: Equatable, Identifiable {
    let id: String
    let kind: ConnectionKind
    let batteryPercentage: Int?
  }

  let model: BridgeModel
  @ObservedObject private var store: ProfileStore
  @State private var isRunning: Bool
  @State private var controllers: [ControllerSummary]
  @Environment(\.openWindow) private var openWindow

  init(model: BridgeModel) {
    self.model = model
    self.store = model.profileStore
    self._isRunning = State(initialValue: model.isRunning)
    self._controllers = State(initialValue: Self.summaries(for: model.controllers))
  }

  var body: some View {
    Text(isRunning ? "Driver Running" : "Driver Stopped")
    Text("\(controllers.count) controller\(controllers.count == 1 ? "" : "s")")
    ForEach(Array(controllers.enumerated()), id: \.element.id) { index, controller in
      let battery = controller.batteryPercentage.map { " • \($0)%" } ?? ""
      Text("Player \(index + 1) • \(controller.kind.label)\(battery)")
    }
    Divider()
    Menu("Profile: \(store.activeProfile.name)") {
      ForEach(store.profiles) { profile in
        Button { store.select(profile.id) } label: {
          if profile.id == store.activeID { Label(profile.name, systemImage: "checkmark") }
          else { Text(profile.name) }
        }
      }
    }
    Menu("Identify Controller") {
      if controllers.isEmpty { Text("No controllers") }
      ForEach(Array(controllers.enumerated()), id: \.element.id) { index, _ in
        Button("Player \(index + 1)") { model.tapRumble(slot: index) }
      }
    }
    Button(isRunning ? "Stop Driver" : "Start Driver") {
      isRunning ? model.stop() : model.start()
    }
    Button("Open NSO GC Driver") {
      openWindow(id: "main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    Divider()
    Button("Quit") { NSApplication.shared.terminate(nil) }
    // BridgeModel also publishes high-frequency controller input and a
    // once-per-second diagnostics snapshot. Observing the whole object here
    // rebuilds the native menu while AppKit is tracking an open submenu,
    // which dismisses it before the user can make a selection. Subscribe to
    // only the stable values displayed by this menu instead.
    .onReceive(model.$isRunning.removeDuplicates()) { isRunning = $0 }
    .onReceive(
      model.$controllers
        .map(Self.summaries)
        .removeDuplicates()
    ) { controllers = $0 }
  }

  private static func summaries(for controllers: [ConnectedController]) -> [ControllerSummary] {
    controllers.map {
      ControllerSummary(
        id: $0.id, kind: $0.kind, batteryPercentage: $0.state.battery?.percentage)
    }
  }
}

struct MainNavigationView: View {
  @ObservedObject var model: BridgeModel
  @State private var selection: AppPage? = .dashboard
  @State private var showSetup = !UserDefaults.standard.bool(forKey: "completedFirstRunSetup")

  var body: some View {
    NavigationSplitView {
      List(AppPage.allCases, selection: $selection) { page in
        Label {
          Text(page.rawValue)
        } icon: {
          if let systemIcon = page.systemIcon {
            Image(systemName: systemIcon)
          } else {
            GameCubeControllerIcon().frame(width: 18, height: 16)
          }
        }
        .tag(page)
      }
      .navigationTitle("NSO GC Driver")
      .safeAreaInset(edge: .bottom) {
        DriverSidebarStatus(model: model).padding(10)
      }
    } detail: {
      Group {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView(model: model, showSetup: $showSetup)
        case .lab: ControllerLabView(model: model)
        case .profiles: ProfilesView(model: model)
        case .integrations: IntegrationsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .sheet(isPresented: $showSetup, onDismiss: {
      UserDefaults.standard.set(true, forKey: "completedFirstRunSetup")
    }) {
      FirstRunSetupView(model: model, isPresented: $showSetup)
    }
  }
}

private struct DriverSidebarStatus: View {
  @ObservedObject var model: BridgeModel
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(model.isRunning ? "Driver running" : "Driver stopped", systemImage: model.isRunning ? "checkmark.circle.fill" : "stop.circle")
        .foregroundStyle(model.isRunning ? .green : .secondary)
      Text("\(model.controllers.count) controller\(model.controllers.count == 1 ? "" : "s")")
        .foregroundStyle(.secondary)
      Text(model.profileStore.activeProfile.name).foregroundStyle(.secondary).lineLimit(1)
    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DashboardView: View {
  @ObservedObject var model: BridgeModel
  @Binding var showSetup: Bool
  @State private var draggingID: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageTitle("Dashboard", subtitle: "Controller routing at a glance")
        HStack(spacing: 12) {
          MetricCard(title: "Driver", value: model.isRunning ? "Running" : "Stopped", icon: "power", color: model.isRunning ? .green : .secondary)
          MetricCard(title: "Controllers", value: "\(model.controllers.count)", icon: nil, color: .blue, usesGameCubeIcon: true)
          MetricCard(title: "Profile", value: model.profileStore.activeProfile.name, icon: "slider.horizontal.3", color: .purple)
          MetricCard(title: "DSU", value: model.dsuStatus.isListening ? ":\(model.dsuStatus.port)" : "Off", icon: "network", color: model.dsuStatus.isListening ? .green : .secondary)
        }
        HStack {
          Button(model.isRunning ? "Stop Driver" : "Start Driver") {
            model.isRunning ? model.stop() : model.start()
          }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          Button("Run Setup Assistant", systemImage: "checklist") { showSetup = true }
          Spacer()
          Toggle("DSU", isOn: $model.dsuEnabled).toggleStyle(.switch)
        }
        GroupBox("Connected controllers") {
          if model.controllers.isEmpty {
            EmptyState(title: "No Controllers", detail: "Connect over USB or pair in System Settings. The driver scans automatically.")
              .frame(maxWidth: .infinity, minHeight: 190)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(model.controllers.enumerated()), id: \.element.id) { index, controller in
                ControllerRow(controller: controller, player: index + 1, diagnostics: model.controllerDiagnostics[controller.id], onRumble: { model.tapRumble(slot: index) })
                  .contentShape(Rectangle())
                  .onDrag {
                    model.beginControllerDrag(); draggingID = controller.id
                    return NSItemProvider(object: controller.id as NSString)
                  }
                  .onDrop(of: [UTType.text], delegate: ControllerDropDelegate(targetID: controller.id, model: model, draggingID: $draggingID))
                if index < model.controllers.count - 1 { Divider() }
              }
            }
          }
        }
      }.padding(24).frame(maxWidth: 1050, alignment: .leading)
    }
  }
}

private struct PageTitle: View {
  let title: String
  let subtitle: String
  init(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.largeTitle.bold())
      Text(subtitle).foregroundStyle(.secondary)
    }
  }
}

private struct EmptyState: View {
  let title: String, detail: String
  var body: some View {
    VStack(spacing: 10) {
      GameCubeControllerIcon().frame(width: 54, height: 38).foregroundStyle(.secondary)
      Text(title).font(.title3.bold())
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.padding()
  }
}

private struct MetricCard: View {
  let title: String, value: String, icon: String?
  let color: Color
  var usesGameCubeIcon = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(title)
      } icon: {
        if usesGameCubeIcon {
          GameCubeControllerIcon().frame(width: 14, height: 11)
        } else if let icon {
          Image(systemName: icon)
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
      .overlay(alignment: .topTrailing) { Circle().fill(color).frame(width: 8, height: 8).padding(12) }
  }
}

struct ControllerDropDelegate: DropDelegate {
  let targetID: String
  let model: BridgeModel
  @Binding var draggingID: String?
  func dropEntered(info: DropInfo) {
    guard let draggingID, draggingID != targetID else { return }
    model.moveController(id: draggingID, before: targetID)
  }
  func performDrop(info: DropInfo) -> Bool {
    draggingID = nil; model.endControllerDrag(); return true
  }
}

private struct ControllerRow: View {
  let controller: ConnectedController
  let player: Int
  let diagnostics: ControllerDiagnostics?
  let onRumble: () -> Void
  var body: some View {
    HStack(spacing: 13) {
      GameCubeControllerIcon().frame(width: 30, height: 21).foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("Player \(player)").font(.headline)
          Text(controller.kind.label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
          if let battery = controller.state.battery { BatteryIndicator(battery: battery) }
        }
        Text("\(diagnostics?.reportsPerSecond ?? 0) reports/s • \(modelPressed(controller.state))")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Identify", systemImage: "waveform.path", action: onRumble).controlSize(.small)
    }.padding(.vertical, 10).padding(.horizontal, 6)
  }
  private func modelPressed(_ state: ControllerState) -> String {
    let pressed = state.buttons.filter(\.value).map(\.key).sorted()
    return pressed.isEmpty ? "Idle" : pressed.joined(separator: ", ")
  }
}

struct ControllerLabView: View {
  @ObservedObject var model: BridgeModel
  @State private var selectedID: String?
  private var selected: ConnectedController? {
    model.controllers.first(where: { $0.id == selectedID }) ?? model.controllers.first
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageTitle("Controller Lab", subtitle: "Live inputs, drift, triggers, battery, and rumble")
        if model.controllers.isEmpty {
          EmptyState(title: "Connect a Controller", detail: "Input visualization starts as soon as a supported controller connects.")
            .frame(maxWidth: .infinity, minHeight: 420)
        } else if let controller = selected {
          Picker("Controller", selection: Binding(get: { selectedID ?? controller.id }, set: { selectedID = $0 })) {
            ForEach(Array(model.controllers.enumerated()), id: \.element.id) { index, item in Text("Player \(index + 1) — \(item.kind.label)").tag(item.id) }
          }.frame(maxWidth: 320)
          GameCubeControllerView(state: controller.state).frame(height: 330)
          let diagnostics = model.controllerDiagnostics[controller.id] ?? ControllerDiagnostics()
          HStack(spacing: 12) {
            MetricCard(title: "Polling", value: "\(diagnostics.reportsPerSecond) Hz", icon: "waveform.path.ecg", color: diagnostics.reportsPerSecond > 0 ? .green : .secondary)
            MetricCard(title: "Stick drift", value: driftLabel(controller.state), icon: "scope", color: drift(controller.state) > 30 ? .orange : .green)
            MetricCard(title: "Connection", value: controller.kind.label, icon: controller.kind == .usb ? "cable.connector" : "antenna.radiowaves.left.and.right", color: .blue)
            MetricCard(title: "Battery", value: controller.state.battery.map { "\($0.percentage)%" } ?? "—", icon: "battery.75", color: .green)
          }
          HStack {
            Button("Test Rumble", systemImage: "waveform.path") {
              if let index = model.controllers.firstIndex(where: { $0.id == controller.id }) { model.tapRumble(slot: index) }
            }.buttonStyle(.borderedProminent)
            Text("Moves the physical controller’s rumble motor briefly.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }.padding(24).frame(maxWidth: 1050, alignment: .leading)
    }
  }
  private func drift(_ state: ControllerState) -> Int { Int(hypot(Double(state.leftX), Double(state.leftY)).rounded()) }
  private func driftLabel(_ state: ControllerState) -> String { "\(drift(state)) units" }
}

private struct GameCubeControllerView: View {
  let state: ControllerState
  var body: some View {
    GeometryReader { geo in
      let scale = min(geo.size.width / 580, geo.size.height / 360)
      GameCubeControllerArtwork(state: state)
        .frame(width: 580, height: 360)
        .scaleEffect(scale)
        .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }
  }
}

private struct GameCubeControllerArtwork: View {
  let state: ControllerState
  private func pressed(_ key: String) -> Bool { state.buttons[key] == true }

  var body: some View {
    ZStack {
      GameCubeShell()
        .fill(
          LinearGradient(
            colors: [Color(red: 0.48, green: 0.46, blue: 0.61),
              Color(red: 0.25, green: 0.24, blue: 0.35)],
            startPoint: .top, endPoint: .bottom))
        .overlay(GameCubeShell().stroke(.white.opacity(0.24), lineWidth: 2))
        .shadow(color: .black.opacity(0.34), radius: 10, y: 6)

      // The shoulder controls sit on the controller itself, matching the
      // front edge of a GameCube pad instead of floating above a generic box.
      ShoulderGauge(label: "L", value: state.leftTrigger, pressed: pressed("L"))
        .frame(width: 142, height: 32).position(x: 154, y: 61)
      ShoulderGauge(label: "R", value: state.rightTrigger, pressed: pressed("R"))
        .frame(width: 142, height: 32).position(x: 426, y: 61)
      SmallShoulderButton(label: "ZL", pressed: pressed("ZL"))
        .frame(width: 46, height: 23).position(x: 72, y: 88)
      SmallShoulderButton(label: "Z", pressed: pressed("Z"))
        .frame(width: 46, height: 23).position(x: 522, y: 82)

      GameCubeStickVisual(x: state.leftX, y: state.leftY, accent: .blue, isCStick: false)
        .frame(width: 108, height: 108).position(x: 132, y: 157)
      GameCubeDPad(state: state)
        .frame(width: 84, height: 84).position(x: 202, y: 273)
      GameCubeStickVisual(x: state.rightX, y: state.rightY, accent: .yellow, isCStick: true)
        .frame(width: 78, height: 78).position(x: 382, y: 275)

      FaceButton(label: "A", pressed: pressed("A"), color: .green, width: 70, height: 70)
        .position(x: 462, y: 164)
      FaceButton(label: "B", pressed: pressed("B"), color: .red, width: 42, height: 42)
        .position(x: 402, y: 199)
      FaceButton(label: "X", pressed: pressed("X"), color: .gray, width: 34, height: 68)
        .position(x: 520, y: 148)
      FaceButton(label: "Y", pressed: pressed("Y"), color: .gray, width: 68, height: 34)
        .position(x: 454, y: 105)
      FaceButton(label: "START", pressed: pressed("Start"), color: .gray, width: 40, height: 40)
        .position(x: 290, y: 153)

      CaptureButton(pressed: pressed("Capture"))
        .frame(width: 24, height: 24).position(x: 258, y: 101)
      AuxiliaryButton(systemName: "house.fill", pressed: pressed("Home"))
        .frame(width: 24, height: 24).position(x: 322, y: 101)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct GameCubeShell: Shape {
  func path(in rect: CGRect) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + rect.width * x / 580, y: rect.minY + rect.height * y / 360)
    }
    var path = Path()
    // This contour is adapted from the bundled GameCube controller SVG. Its
    // deep outer grips and two rounded lower lobes preserve the pad's compact,
    // instantly recognizable silhouette while leaving room for live controls.
    path.move(to: p(290, 28))
    path.addCurve(to: p(115, 52), control1: p(238, 28), control2: p(182, 34))
    path.addCurve(to: p(28, 99), control1: p(70, 42), control2: p(36, 61))
    path.addCurve(to: p(14, 183), control1: p(5, 118), control2: p(14, 158))
    path.addCurve(to: p(56, 354), control1: p(9, 241), control2: p(5, 351))
    path.addCurve(to: p(110, 230), control1: p(107, 357), control2: p(110, 230))
    path.addCurve(to: p(133, 281), control1: p(120, 244), control2: p(127, 260))
    path.addCurve(to: p(235, 299), control1: p(140, 303), control2: p(187, 348))
    path.addCurve(to: p(217, 202), control1: p(283, 250), control2: p(217, 202))
    path.addLine(to: p(217, 194))
    path.addCurve(to: p(290, 188), control1: p(235, 190), control2: p(264, 188))
    path.addCurve(to: p(363, 194), control1: p(316, 188), control2: p(345, 190))
    path.addLine(to: p(363, 202))
    path.addCurve(to: p(345, 299), control1: p(363, 202), control2: p(297, 250))
    path.addCurve(to: p(447, 281), control1: p(393, 348), control2: p(440, 303))
    path.addCurve(to: p(470, 230), control1: p(453, 260), control2: p(460, 244))
    path.addCurve(to: p(524, 354), control1: p(470, 230), control2: p(473, 357))
    path.addCurve(to: p(566, 183), control1: p(575, 351), control2: p(571, 241))
    path.addCurve(to: p(552, 99), control1: p(566, 158), control2: p(575, 118))
    path.addCurve(to: p(465, 52), control1: p(544, 61), control2: p(510, 42))
    path.addCurve(to: p(290, 28), control1: p(398, 34), control2: p(342, 28))
    path.closeSubpath()
    return path
  }
}

private struct FaceButton: View {
  let label: String
  let pressed: Bool
  let color: Color
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    Capsule()
      .fill(pressed ? color : color.opacity(color == .gray ? 0.62 : 0.72))
      .overlay(Capsule().stroke(.white.opacity(pressed ? 0.9 : 0.32), lineWidth: pressed ? 3 : 1.5))
      .overlay(
        Text(label)
          .font(.system(size: label == "START" ? 7 : 15, weight: .black, design: .rounded))
          .foregroundStyle(.white.opacity(pressed ? 1 : 0.8)))
      .frame(width: width, height: height)
      .shadow(color: pressed ? color.opacity(0.9) : .black.opacity(0.28), radius: pressed ? 9 : 2, y: 2)
      .scaleEffect(pressed ? 0.94 : 1)
      .accessibilityLabel(label)
      .accessibilityValue(pressed ? "Pressed" : "Released")
  }
}

private struct OctagonalGate: Shape {
  func path(in rect: CGRect) -> Path {
    let inset = min(rect.width, rect.height) * 0.27
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + inset))
    path.closeSubpath()
    return path
  }
}

private struct GameCubeStickVisual: View {
  let x: Int, y: Int
  let accent: Color
  let isCStick: Bool
  var body: some View {
    GeometryReader { geo in
      let dx = CGFloat(max(-1, min(1, Double(x) / 1900))) * geo.size.width * 0.24
      let dy = CGFloat(max(-1, min(1, Double(y) / 1900))) * geo.size.height * -0.24
      ZStack {
        OctagonalGate().fill(.black.opacity(0.46))
          .overlay(OctagonalGate().stroke(.white.opacity(0.22), lineWidth: 2))
        Circle()
          .fill(isCStick ? accent.opacity(0.88) : Color(red: 0.25, green: 0.27, blue: 0.32))
          .overlay(Circle().stroke(accent.opacity(0.8), lineWidth: 2.5))
          .overlay {
            if isCStick {
              Text("C").font(.system(size: geo.size.width * 0.2, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.55))
            } else {
              Circle().stroke(.white.opacity(0.18), lineWidth: 1).padding(7)
            }
          }
          .frame(width: geo.size.width * 0.58, height: geo.size.height * 0.58)
          .offset(x: dx, y: dy)
          .shadow(color: (x == 0 && y == 0) ? .clear : accent.opacity(0.75), radius: 7)
      }
    }
    .accessibilityLabel(isCStick ? "C stick" : "Control stick")
    .accessibilityValue("X \(x), Y \(y)")
  }
}

private struct GameCubeDPad: View {
  let state: ControllerState
  private func pressed(_ key: String) -> Bool { state.buttons[key] == true }
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.58)).frame(width: 29, height: 82)
      RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.58)).frame(width: 82, height: 29)
      DPadArrow(direction: "arrowtriangle.up.fill", active: pressed("Dpad_Up")).offset(y: -27)
      DPadArrow(direction: "arrowtriangle.down.fill", active: pressed("Dpad_Down")).offset(y: 27)
      DPadArrow(direction: "arrowtriangle.left.fill", active: pressed("Dpad_Left")).offset(x: -27)
      DPadArrow(direction: "arrowtriangle.right.fill", active: pressed("Dpad_Right")).offset(x: 27)
      Circle().fill(.black.opacity(0.7)).frame(width: 18, height: 18)
    }
  }
}

private struct DPadArrow: View {
  let direction: String
  let active: Bool
  var body: some View {
    Image(systemName: direction)
      .font(.system(size: 11, weight: .black))
      .foregroundStyle(active ? Color.cyan : .white.opacity(0.42))
      .shadow(color: active ? .cyan : .clear, radius: 5)
  }
}

private struct ShoulderGauge: View {
  let label: String
  let value: UInt8
  let pressed: Bool
  var body: some View {
    GeometryReader { geo in
      let progress = CGFloat(value) / 255
      ZStack(alignment: .leading) {
        Capsule().fill(.black.opacity(0.48))
        Capsule().fill(pressed ? Color.cyan : Color.white.opacity(0.28))
          .frame(width: max(0, geo.size.width * progress))
        Capsule().stroke(pressed ? Color.cyan : .white.opacity(0.32), lineWidth: 1.5)
        HStack {
          Text(label).font(.system(size: 15, weight: .black, design: .rounded))
          Spacer()
          Text("\(value)").font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 12)
      }
    }
    .accessibilityLabel("\(label) trigger")
    .accessibilityValue("\(value) of 255\(pressed ? ", clicked" : "")")
  }
}

private struct SmallShoulderButton: View {
  let label: String
  let pressed: Bool
  var body: some View {
    Capsule().fill(pressed ? Color.cyan : Color(red: 0.34, green: 0.21, blue: 0.48))
      .overlay(Capsule().stroke(.white.opacity(pressed ? 0.85 : 0.3), lineWidth: 1.5))
      .overlay(Text(label).font(.system(size: 10, weight: .black)).foregroundStyle(.white))
      .shadow(color: pressed ? .cyan.opacity(0.75) : .clear, radius: 6)
  }
}

private struct AuxiliaryButton: View {
  let systemName: String
  let pressed: Bool
  var body: some View {
    Circle().fill(pressed ? Color.cyan : .black.opacity(0.48))
      .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
      .overlay(Image(systemName: systemName).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.85)))
      .shadow(color: pressed ? .cyan.opacity(0.75) : .clear, radius: 5)
  }
}

private struct CaptureButton: View {
  let pressed: Bool
  var body: some View {
    Circle().fill(pressed ? Color.cyan : .black.opacity(0.48))
      .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
      .overlay {
        ZStack {
          RoundedRectangle(cornerRadius: 1.5)
            .stroke(.white.opacity(0.9), lineWidth: 1.3)
            .frame(width: 11, height: 11)
          Circle().fill(.white.opacity(0.9)).frame(width: 5, height: 5)
        }
      }
      .shadow(color: pressed ? .cyan.opacity(0.75) : .clear, radius: 5)
      .accessibilityLabel("Capture")
      .accessibilityValue(pressed ? "Pressed" : "Released")
  }
}

struct ProfilesView: View {
  @ObservedObject var model: BridgeModel
  @ObservedObject private var store: ProfileStore
  @State private var importing = false
  @State private var exporting = false
  @State private var exportDocument = JSONFileDocument()
  @State private var alertMessage: String?

  init(model: BridgeModel) {
    self.model = model
    self.store = model.profileStore
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageTitle("Profiles", subtitle: "Optional remapping between physical controls and virtual output")
        HStack {
          Picker("Active profile", selection: Binding(get: { store.activeID }, set: { store.select($0) })) {
            ForEach(store.profiles) { Text($0.name).tag($0.id) }
          }.frame(maxWidth: 330)
          Button("New", systemImage: "plus") { store.create() }
          Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateActive() }
          Button("Delete", systemImage: "trash") { store.deleteActive() }.disabled(store.profiles.count <= 1)
          Spacer()
          Button("Import…") { importing = true }
          Button("Export…") {
            do { exportDocument = JSONFileDocument(data: try store.exportData()); exporting = true }
            catch { alertMessage = error.localizedDescription }
          }
        }
        GroupBox("Profile details") {
          VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Name") {
              TextField("Profile name", text: activeBinding(\.name)).frame(width: 260)
            }
            Divider()
            Text("Axes").font(.headline)
            HStack {
              Toggle("Invert left X", isOn: activeBinding(\.invertLeftX))
              Toggle("Invert left Y", isOn: activeBinding(\.invertLeftY))
              Toggle("Invert C-stick X", isOn: activeBinding(\.invertRightX))
              Toggle("Invert C-stick Y", isOn: activeBinding(\.invertRightY))
            }
            HStack {
              Text("C-stick sensitivity")
              Slider(value: activeBinding(\.cStickSensitivity), in: 0.25...2, step: 0.05).frame(maxWidth: 330)
              Text(store.activeProfile.cStickSensitivity.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit().frame(width: 42)
            }
          }.padding(6)
        }
        GroupBox("Button mapping") {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 10) {
            ForEach(ControlProfile.controls, id: \.self) { source in
              HStack {
                Text(source.replacingOccurrences(of: "Dpad_", with: "D-pad ")).frame(width: 78, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: buttonBinding(source)) {
                  ForEach(ControlProfile.controls + ["Disabled"], id: \.self) { Text($0.replacingOccurrences(of: "Dpad_", with: "D-pad ")).tag($0) }
                }.labelsHidden()
              }
            }
          }.padding(6)
        }
        Text("Automatic is the default pass-through profile. Changes apply immediately to the virtual gamepad and DSU output.")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(maxWidth: 1050, alignment: .leading)
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try store.importProfile(from: Data(contentsOf: url)) }
      catch { alertMessage = error.localizedDescription }
    }
    .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: store.activeProfile.name) { result in
      if case .failure(let error) = result { alertMessage = error.localizedDescription }
    }
    .alert("Profile", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) { Button("OK") {} } message: { Text(alertMessage ?? "") }
  }

  private func activeBinding<T>(_ keyPath: WritableKeyPath<ControlProfile, T>) -> Binding<T> {
    Binding(get: { store.activeProfile[keyPath: keyPath] }, set: { value in store.updateActive { $0[keyPath: keyPath] = value } })
  }
  private func buttonBinding(_ source: String) -> Binding<String> {
    Binding(get: { store.activeProfile.buttonMap[source] ?? source }, set: { target in store.updateActive { profile in
      if target == source { profile.buttonMap.removeValue(forKey: source) } else { profile.buttonMap[source] = target }
    } })
  }
}

struct IntegrationsView: View {
  @ObservedObject var model: BridgeModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageTitle("Integrations", subtitle: "Follow input from hardware to your game")
        HStack(spacing: 8) {
          PipelineStage(title: "Physical controller", detail: "\(model.controllers.count) connected", healthy: !model.controllers.isEmpty, icon: nil, usesGameCubeIcon: true)
          Image(systemName: "arrow.right").foregroundStyle(.secondary)
          PipelineStage(title: "Virtual HID", detail: "\(model.virtualDeviceCount) visible", healthy: model.virtualDeviceCount == model.controllers.count && !model.controllers.isEmpty, icon: "cpu")
          Image(systemName: "arrow.right").foregroundStyle(.secondary)
          PipelineStage(title: "Consuming app", detail: model.dsuStatus.clientCount == 0 ? "Waiting for client" : "\(model.dsuStatus.clientCount) DSU client(s)", healthy: model.dsuStatus.clientCount > 0, icon: "macwindow")
        }
        GroupBox("Virtual controller compatibility") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
              Toggle(
                "Compatibility mode",
                isOn: Binding(
                  get: { model.virtualGamepadMode == .standardHID },
                  set: { model.virtualGamepadMode = $0 ? .standardHID : .dolphinSInput }
                )
              )
              .toggleStyle(.switch)
              Spacer()
            }
            HStack(spacing: 5) {
              Text("Current mode:").foregroundStyle(.secondary)
              Text(model.virtualGamepadMode.title).fontWeight(.medium)
            }
            Text(model.virtualGamepadMode.helpText)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Changing modes reconnects the virtual controllers. Reopen the consuming app if it does not refresh its controller list.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }.padding(6)
        }
        GroupBox("DSU server") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: model.dsuStatus.isListening ? "Listening" : "Stopped")
            LabeledContent("Address", value: model.dsuAddress)
            LabeledContent("Clients", value: "\(model.dsuStatus.clientCount)")
            LabeledContent("Traffic", value: "\(model.dsuStatus.packetsPerSecond) packets/s")
            LabeledContent("Last activity", value: model.dsuStatus.lastActivity?.formatted(.relative(presentation: .named)) ?? "None")
            HStack {
              Toggle("Enable DSU server", isOn: $model.dsuEnabled).toggleStyle(.switch)
              Button("Copy DSU Address", systemImage: "doc.on.doc") { model.copyDSUAddress() }
            }
          }.padding(6)
        }
        GroupBox("Dolphin setup") {
          VStack(alignment: .leading, spacing: 9) {
            SetupStep(number: 1, text: "Start the driver and connect the controller.")
            SetupStep(number: 2, text: "In Dolphin, open Controllers, then Alternate Input Sources.")
            SetupStep(number: 3, text: "Enable DSU Client, click Add, and enter \(model.dsuHost) as the server IP and \(model.dsuStatus.port) as the port.")
            SetupStep(number: 4, text: "Set the GameCube port to Standard Controller, click Configure, and choose the DSUClient device.")
            SetupStep(number: 5, text: "Map the controls. Pressing a button should update the client count and traffic above.")
          }.padding(6)
        }
      }.padding(24).frame(maxWidth: 1050, alignment: .leading)
    }
  }
}

private struct PipelineStage: View {
  let title, detail: String
  let healthy: Bool
  let icon: String?
  var usesGameCubeIcon = false
  var body: some View {
    VStack(spacing: 8) {
      if usesGameCubeIcon {
        GameCubeControllerIcon().frame(width: 38, height: 27)
      } else if let icon {
        Image(systemName: icon).font(.title)
      }
      Text(title).font(.headline)
      Label(detail, systemImage: healthy ? "checkmark.circle.fill" : "circle.dashed").font(.caption).foregroundStyle(healthy ? .green : .secondary)
    }.frame(maxWidth: .infinity, minHeight: 105).padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct SetupStep: View {
  let number: Int, text: String
  var body: some View { HStack(alignment: .top) { Text("\(number)").font(.caption.bold()).frame(width: 22, height: 22).background(.blue, in: Circle()).foregroundStyle(.white); Text(text) } }
}

struct DiagnosticsView: View {
  @ObservedObject var model: BridgeModel
  @State private var showingLogs = false
  @State private var exporting = false
  @State private var supportDocument = JSONFileDocument()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageTitle("Diagnostics", subtitle: "Health information suitable for troubleshooting and support")
        HStack(spacing: 12) {
          MetricCard(title: "Input reports", value: "\(model.totalReports)", icon: "arrow.down.circle", color: .blue)
          MetricCard(title: "Malformed", value: "\(model.totalMalformedReports)", icon: "exclamationmark.triangle", color: model.totalMalformedReports == 0 ? .green : .orange)
          MetricCard(title: "Virtual devices", value: "\(model.virtualDeviceCount)/\(model.controllers.count)", icon: "cpu", color: model.virtualDeviceCount == model.controllers.count ? .green : .orange)
          MetricCard(title: "DSU traffic", value: "\(model.dsuStatus.packetsPerSecond)/s", icon: "network", color: model.dsuStatus.isListening ? .green : .secondary)
        }
        GroupBox("Controller quality") {
          if model.controllers.isEmpty { Text("No connected controllers.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding() }
          else {
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
              GridRow { Text("Controller").bold(); Text("Connection").bold(); Text("Rate").bold(); Text("Malformed").bold(); Text("Last report").bold() }
              Divider()
              ForEach(Array(model.controllers.enumerated()), id: \.element.id) { index, controller in
                let stats = model.controllerDiagnostics[controller.id] ?? ControllerDiagnostics()
                GridRow { Text("Player \(index + 1)"); Text(controller.kind.label); Text("\(stats.reportsPerSecond) Hz"); Text("\(stats.malformedReports)"); Text(stats.lastActivity?.formatted(.relative(presentation: .named)) ?? "Never") }
              }
            }.padding(6)
          }
        }
        HStack {
          Button("Export Support Bundle…", systemImage: "square.and.arrow.up") {
            supportDocument = JSONFileDocument(data: model.supportBundleData()); exporting = true
          }.buttonStyle(.borderedProminent)
          Text("Controller identifiers are removed. Raw reports are never included.").font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Advanced: raw logs", isExpanded: $showingLogs) {
          ScrollView {
            Text(model.logs.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }.frame(height: 210).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
          HStack { Button("Copy Logs", systemImage: "doc.on.doc") { model.copyLogs() }; Spacer() }
        }
      }.padding(24).frame(maxWidth: 1050, alignment: .leading)
    }
    .fileExporter(isPresented: $exporting, document: supportDocument, contentType: .json, defaultFilename: "NSOGCDriver-Support") { _ in }
  }
}

struct FirstRunSetupView: View {
  @ObservedObject var model: BridgeModel
  @Binding var isPresented: Bool
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      PageTitle("Let’s get your controller ready", subtitle: "The driver can use USB or Bluetooth. These checks do not collect any data.")
      SetupCheckRow(title: "USB controller", detail: model.controllers.contains(where: { $0.kind == .usb }) ? "A USB controller is connected." : "Plug the controller directly into the Mac. The driver detects it automatically.", status: model.controllers.contains(where: { $0.kind == .usb }) ? .ready : .attention)
      SetupCheckRow(title: "Bluetooth", detail: bluetoothDetail, status: CBManager.authorization == .denied || CBManager.authorization == .restricted ? .blocked : .ready, actionTitle: "Bluetooth Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
      }
      SetupCheckRow(title: "Virtual gamepad", detail: model.virtualDeviceCount > 0 ? "macOS can see \(model.virtualDeviceCount) virtual gamepad(s)." : "A virtual gamepad is created after a controller connects. If creation fails, restart the signed app.", status: model.controllers.isEmpty ? .attention : (model.virtualDeviceCount > 0 ? .ready : .blocked), actionTitle: "Privacy & Security") { openSettings("Privacy") }
      SetupCheckRow(title: "DSU server", detail: model.dsuStatus.isListening ? "Ready for Dolphin or another DSU client at \(model.dsuAddress)." : "Enable DSU and start the driver, then add its address in your DSU client.", status: model.dsuStatus.isListening ? .ready : .attention, actionTitle: "Copy Address") { model.copyDSUAddress() }
      Toggle("Launch NSO GC Driver at login", isOn: Binding(get: { launchAtLogin }, set: { value in launchAtLogin = value; model.setLaunchAtLogin(value) })).toggleStyle(.switch)
      HStack {
        Button("Done") { UserDefaults.standard.set(true, forKey: "completedFirstRunSetup"); isPresented = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        Spacer()
        Text("You can reopen this assistant from Dashboard.").font(.caption).foregroundStyle(.secondary)
      }
    }.padding(28).frame(width: 680)
  }
  private var bluetoothDetail: String {
    switch CBManager.authorization {
    case .denied, .restricted: return "Bluetooth access is blocked. Allow it in Privacy & Security, then restart the driver."
    case .notDetermined: return "macOS will ask for Bluetooth access when scanning begins."
    case .allowedAlways: return "Bluetooth access is allowed; pair the controller in System Settings."
    @unknown default: return "Check Bluetooth access in System Settings."
    }
  }
  private func openSettings(_ pane: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
}

private enum SetupStatus { case ready, attention, blocked }
private struct SetupCheckRow: View {
  let title, detail: String
  let status: SetupStatus
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: status == .ready ? "checkmark.circle.fill" : status == .blocked ? "xmark.octagon.fill" : "exclamationmark.circle.fill")
        .font(.title2).foregroundStyle(status == .ready ? .green : status == .blocked ? .red : .orange)
      VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
      Spacer()
      if let actionTitle, let action { Button(actionTitle, action: action) }
    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct BatteryIndicator: View {
  let battery: ControllerBattery
  var body: some View {
    Label("\(battery.percentage)%", systemImage: battery.isCharging ? "battery.100.bolt" : battery.percentage < 25 ? "battery.25" : "battery.100")
      .font(.caption).foregroundStyle(battery.percentage <= 20 && !battery.isCharging ? .red : .secondary)
  }
}

extension ConnectionKind {
  var label: String { self == .usb ? "USB" : "Bluetooth LE" }
}

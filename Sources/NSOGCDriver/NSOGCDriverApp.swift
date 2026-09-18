import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct NSOGCDriverApp: App {
  @StateObject private var model = BridgeModel()
  var body: some Scene {
    WindowGroup { ContentView(model: model).frame(minWidth: 560, minHeight: 620) }
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button("About NSO GC Driver") {
            NSApplication.shared.orderFrontStandardAboutPanel()
          }
        }
      }
  }
}

struct ConnectedController: Identifiable, Equatable {
  let id: String
  var name: String
  var kind: ConnectionKind
  var state = ControllerState()
}

/// Decodes and forwards controller reports without depending on the UI thread.
/// AppKit can hold its main event loop inside mouse tracking during a drag;
/// gameplay output must continue independently while that happens.
final class InputPipeline: @unchecked Sendable {
  struct Route {
    let id: String
    let slot: Int
    let kind: ConnectionKind
    let gamepad: VirtualGamepad?
  }

  private let queue = DispatchQueue(label: "com.nso-gc-driver.input", qos: .userInteractive)
  private let pendingLock = NSLock()
  private var pendingReports: [String: (report: [UInt8], kind: ConnectionKind)] = [:]
  private var flushScheduled = false
  private var decoders: [String: InputDecoder] = [:]
  private var states: [String: ControllerState] = [:]
  private var routes: [String: Route] = [:]
  private var dsuEnabled = true
  private var uiSnapshotScheduled = false
  private let dsu: DSUServer
  var onStateSnapshot: (([String: ControllerState]) -> Void)?

  init(dsu: DSUServer) {
    self.dsu = dsu
  }

  func receive(id: String, report: [UInt8], kind: ConnectionKind) {
    pendingLock.lock()
    pendingReports[id] = (report, kind)
    let shouldSchedule = !flushScheduled
    if shouldSchedule { flushScheduled = true }
    pendingLock.unlock()
    guard shouldSchedule else { return }
    queue.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
      self?.flushReports()
    }
  }

  func setRoutes(_ newRoutes: [Route]) {
    queue.async { [weak self] in
      guard let self else { return }
      self.routes = Dictionary(uniqueKeysWithValues: newRoutes.map { ($0.id, $0) })
      for route in newRoutes {
        if let state = self.states[route.id] { route.gamepad?.update(state) }
      }
    }
  }

  func remove(id: String) {
    pendingLock.lock()
    pendingReports.removeValue(forKey: id)
    pendingLock.unlock()
    queue.async { [weak self] in
      self?.decoders.removeValue(forKey: id)
      self?.states.removeValue(forKey: id)
      self?.routes.removeValue(forKey: id)
    }
  }

  func setDSUEnabled(_ enabled: Bool) {
    queue.async { [weak self] in self?.dsuEnabled = enabled }
  }

  func reset() {
    pendingLock.lock()
    pendingReports.removeAll()
    flushScheduled = false
    pendingLock.unlock()
    queue.async { [weak self] in
      self?.decoders.removeAll()
      self?.states.removeAll()
      self?.routes.removeAll()
      self?.uiSnapshotScheduled = false
    }
  }

  private func flushReports() {
    pendingLock.lock()
    let reports = pendingReports
    pendingReports.removeAll(keepingCapacity: true)
    flushScheduled = false
    pendingLock.unlock()

    var changed = false
    for (id, item) in reports {
      let decoder = decoders[id] ?? InputDecoder()
      decoders[id] = decoder
      guard let state = decoder.decode(item.report, bluetooth: item.kind == .bluetooth) else {
        continue
      }
      if let route = routes[id], dsuEnabled {
        dsu.update(state, slot: route.slot, kind: route.kind)
      }
      guard states[id] != state else { continue }
      states[id] = state
      routes[id]?.gamepad?.update(state)
      changed = true
    }
    if changed { scheduleUISnapshot() }
  }

  private func scheduleUISnapshot() {
    guard !uiSnapshotScheduled else { return }
    uiSnapshotScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(67)) { [weak self] in
      guard let self else { return }
      self.uiSnapshotScheduled = false
      self.onStateSnapshot?(self.states)
    }
  }
}

@MainActor final class BridgeModel: ObservableObject {
  @Published var isRunning = false
  @Published var dsuEnabled = true {
    didSet { updateDSUState() }
  }
  @Published var controllers: [ConnectedController] = []
  @Published var logs: [String] = []

  private let usb = HIDTransport()
  private let ble = BluetoothTransport()
  private let dsu = DSUServer()
  private lazy var inputPipeline = InputPipeline(dsu: dsu)
  // Virtual HID devices represent player slots, not physical controllers.
  // This keeps SDL's /0, /1, … identities aligned with Player 1, Player 2,
  // even when controllers are reordered or a lower slot disconnects.
  private var virtualGamepads: [VirtualGamepad] = []
  // Gameplay consumers need the newest state immediately, but publishing the
  // controller array makes SwiftUI re-evaluate the entire window. Keep the
  // real-time state separate and only copy it into the UI at a human-visible
  // refresh rate. This prevents rendering work from starving input delivery.
  private var latestStates: [String: ControllerState] = [:]
  private var uiRefreshScheduled = false
  private let uiRefreshInterval: DispatchTimeInterval = .milliseconds(67)
  private var playerAssignmentRefreshWorkItem: DispatchWorkItem?
  private var controllerDragActive = false

  init() {
    // Remembered-device reconnection is intentionally disabled on macOS.
    // Remove values written by versions that exposed the non-working feature.
    UserDefaults.standard.removeObject(forKey: "rememberedBLEControllers")
    UserDefaults.standard.removeObject(forKey: "savedBLEAddresses")
    usb.onLog = { [weak self] message in self?.log(message) }
    ble.onLog = { [weak self] message in self?.log(message) }
    dsu.onLog = { [weak self] message in self?.log(message) }
    inputPipeline.onStateSnapshot = { [weak self] states in
      DispatchQueue.main.async { [weak self] in self?.applyStateSnapshot(states) }
    }
    let pipeline = inputPipeline
    usb.onReport = { id, report in
      pipeline.receive(id: id, report: report, kind: .usb)
    }
    ble.onReport = { id, report in
      pipeline.receive(id: id, report: report, kind: .bluetooth)
    }
    usb.onConnected = { [weak self] id, name, kind in
      self?.connected(id: id, name: name, kind: kind)
    }
    ble.onConnected = { [weak self] id, name, kind in
      self?.connected(id: id, name: name, kind: kind)
    }
    usb.onDisconnected = { [weak self] id in self?.disconnected(id: id) }
    ble.onDisconnected = { [weak self] id in self?.disconnected(id: id) }
    start()
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    log("NSO GameCube Controller Driver")
    if dsuEnabled {
      startDSU()
    }
    _ = usb.start()
    ble.start()
  }
  func stop() {
    isRunning = false
    inputPipeline.reset()
    latestStates.removeAll()
    uiRefreshScheduled = false
    controllerDragActive = false
    playerAssignmentRefreshWorkItem?.cancel()
    playerAssignmentRefreshWorkItem = nil
    for gamepad in virtualGamepads { gamepad.stop() }
    virtualGamepads.removeAll()
    usb.stop()
    ble.stop()
    dsu.stop()
    controllers.removeAll()
    dsu.reset()
    log("Driver stopped")
  }

  private func updateDSUState() {
    guard isRunning else { return }
    if dsuEnabled {
      inputPipeline.setDSUEnabled(true)
      startDSU()
    } else {
      inputPipeline.setDSUEnabled(false)
      // Never leave a controller rumbling after its command channel is
      // disabled, and close the listener immediately.
      for slot in controllers.indices { rumble(slot: slot, active: false) }
      dsu.stop()
    }
  }

  private func startDSU() {
    guard dsu.start() else { return }
    for slot in 0..<4 { registerDSUSlot(slot) }
    for (slot, controller) in controllers.prefix(4).enumerated() {
      let state = latestStates[controller.id] ?? controller.state
      dsu.update(state, slot: slot, kind: controller.kind)
    }
  }
  func moveControllers(from source: IndexSet, to destination: Int) {
    controllers.move(fromOffsets: source, toOffset: destination)
    refreshPlayerAssignments()
  }
  func beginControllerDrag() {
    controllerDragActive = true
  }
  func endControllerDrag() {
    guard controllerDragActive else { return }
    controllerDragActive = false
    refreshPlayerAssignments()
    scheduleUIRefresh()
  }
  func moveController(id: String, before targetID: String) {
    guard let source = controllers.firstIndex(where: { $0.id == id }),
      let target = controllers.firstIndex(where: { $0.id == targetID }), source != target
    else { return }
    var reordered = controllers
    let item = reordered.remove(at: source)
    // When moving downward, removing the source shifts the hovered target
    // left by one. Inserting at its original index places the dragged item
    // after that target, which is the expected List drag behavior.
    reordered.insert(item, at: target)
    guard reordered != controllers else { return }
    controllers = reordered

    // Input routing should follow the UI immediately. LED writes and DSU
    // callback registration can wait until rapid dropEntered events settle.
    syncVirtualGamepads()
    schedulePlayerAssignmentRefresh()
  }
  func rumble(slot: Int, active: Bool) {
    guard controllers.indices.contains(slot) else { return }
    let controller = controllers[slot]
    if controller.kind == .usb {
      usb.sendRumble(active, for: controller.id)
    } else {
      ble.sendRumble(active, for: bleUUID(controller.id))
    }
  }
  func tapRumble(slot: Int) {
    rumble(slot: slot, active: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.rumble(slot: slot, active: false)
    }
  }

  private func applyStateSnapshot(_ states: [String: ControllerState]) {
    latestStates = states
    scheduleUIRefresh()
  }

  private func scheduleUIRefresh() {
    guard !controllerDragActive, !uiRefreshScheduled else { return }
    uiRefreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + uiRefreshInterval) { [weak self] in
      guard let self else { return }
      self.uiRefreshScheduled = false
      guard self.isRunning, !self.controllerDragActive else { return }

      var displayControllers = self.controllers
      for index in displayControllers.indices {
        if let state = self.latestStates[displayControllers[index].id] {
          displayControllers[index].state = state
        }
      }
      if displayControllers != self.controllers {
        // One publication refreshes every card, rather than one
        // publication for every controller report.
        self.controllers = displayControllers
      }
    }
  }
  private func connected(id: String, name: String, kind: ConnectionKind) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.controllers.contains(where: { $0.id == id }) else { return }
      self.controllers.append(ConnectedController(id: id, name: name, kind: kind))
      self.latestStates[id] = ControllerState()
      self.refreshPlayerAssignments()
      let slot = self.controllers.count - 1
      self.log("Connected \(name) as player \(slot + 1)")
      self.tapRumble(slot: slot)
    }
  }
  private func disconnected(id: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let index = self.controllers.firstIndex(where: { $0.id == id }) else {
        return
      }
      let name = self.controllers.remove(at: index).name
      self.inputPipeline.remove(id: id)
      self.latestStates.removeValue(forKey: id)
      self.dsu.reset()
      self.refreshPlayerAssignments()
      for (slot, controller) in self.controllers.enumerated() {
        let state = self.latestStates[controller.id] ?? controller.state
        self.dsu.update(state, slot: slot, kind: controller.kind)
      }
      self.log("Disconnected \(name)")
    }
  }
  private func refreshPlayerAssignments() {
    playerAssignmentRefreshWorkItem?.cancel()
    playerAssignmentRefreshWorkItem = nil
    syncVirtualGamepads()
    for (slot, controller) in controllers.enumerated() {
      if controller.kind == .usb {
        usb.setPlayerSlot(slot, for: controller.id)
      } else {
        ble.setPlayerSlot(slot, for: bleUUID(controller.id))
      }
      if dsuEnabled { registerDSUSlot(slot) }
    }
  }
  private func schedulePlayerAssignmentRefresh() {
    playerAssignmentRefreshWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.refreshPlayerAssignments()
    }
    playerAssignmentRefreshWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(75), execute: work)
  }
  private func syncVirtualGamepads() {
    while virtualGamepads.count < controllers.count {
      let slot = virtualGamepads.count
      let gamepad = VirtualGamepad(identifier: "player-\(slot)")
      gamepad.onLog = { [weak self] message in self?.log(message) }
      gamepad.onRumble = { [weak self] active in
        Task { @MainActor [weak self] in self?.rumble(slot: slot, active: active) }
      }
      guard gamepad.start() else { break }
      virtualGamepads.append(gamepad)
    }
    while virtualGamepads.count > controllers.count {
      virtualGamepads.removeLast().stop()
    }
    for (slot, controller) in controllers.enumerated()
    where virtualGamepads.indices.contains(slot) {
      virtualGamepads[slot].update(latestStates[controller.id] ?? controller.state)
    }
    inputPipeline.setRoutes(
      controllers.enumerated().map { slot, controller in
        InputPipeline.Route(
          id: controller.id, slot: slot, kind: controller.kind,
          gamepad: virtualGamepads.indices.contains(slot) ? virtualGamepads[slot] : nil)
      })
  }
  private func registerDSUSlot(_ slot: Int) {
    dsu.register(slot: slot) { [weak self] intensity in
      DispatchQueue.main.async { self?.rumble(slot: slot, active: intensity > 0) }
    }
  }
  private func bleUUID(_ id: String) -> String { String(id.dropFirst(4)) }
  private nonisolated func log(_ message: String) {
    print(message)
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.logs.append(message)
      if self.logs.count > 300 { self.logs.removeFirst(50) }
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: BridgeModel
  @State private var draggingID: String?
  @State private var showingLogs = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("NSO GC Driver").font(.largeTitle.bold())
      GroupBox("Connections") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Label("USB and Bluetooth LE", systemImage: "cable.connector")
            Spacer()
            Text("Bluetooth discovers in the background").font(.caption)
              .foregroundStyle(.secondary)
          }
          Toggle(
            "DSU server for Dolphin (127.0.0.1:26760–26764)",
            isOn: $model.dsuEnabled)
        }.padding(4)
      }
      HStack {
        Button(model.isRunning ? "Stop Driver" : "Start Driver") {
          model.isRunning ? model.stop() : model.start()
        }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        Spacer()
        Text(model.isRunning ? "Running" : "Stopped").foregroundStyle(
          model.isRunning ? .green : .secondary)
      }
      GroupBox("Connected controllers") {
        if model.controllers.isEmpty {
          Text("No controllers connected. Start the driver to scan USB and Bluetooth.")
            .foregroundStyle(.secondary).padding(8)
        } else {
          HStack {
            Text("Connected: \(model.controllers.count)").font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
          }
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(model.controllers.enumerated()), id: \.element.id) {
                index, controller in
                ControllerCard(
                  controller: controller, player: index + 1,
                  onRumble: { model.tapRumble(slot: index) }
                )
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onDrag {
                  model.beginControllerDrag()
                  draggingID = controller.id
                  return NSItemProvider(object: controller.id as NSString)
                }
                .onDrop(
                  of: [UTType.text],
                  delegate: ControllerDropDelegate(
                    targetID: controller.id, model: model, draggingID: $draggingID))
                if index < model.controllers.count - 1 { Divider() }
              }
            }
          }
          .background(.background.opacity(0.5))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .frame(minHeight: 210, maxHeight: 330)
          Text("Drag controllers to change their player number and LED assignment.").font(
            .caption
          ).foregroundStyle(.secondary)
        }
      }
      DisclosureGroup(isExpanded: $showingLogs) {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading) {
              ForEach(Array(model.logs.enumerated()), id: \.offset) { i, line in
                Text(line).font(.system(.caption, design: .monospaced)).id(i)
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
          }.onChange(of: model.logs.count) { _ in
            if let last = model.logs.indices.last { proxy.scrollTo(last) }
          }
        }
        .frame(height: 150)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(.quaternary, lineWidth: 1)
        }
      } label: {
        HStack {
          Text("Logs")
          Spacer()
          Button("Copy", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string)
          }
          .buttonStyle(.borderless)
          .disabled(model.logs.isEmpty)
        }
      }
    }.padding(18)
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
    draggingID = nil
    model.endControllerDrag()
    return true
  }
}

struct ControllerCard: View {
  let controller: ConnectedController
  let player: Int
  let onRumble: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Player \(player)").font(.headline)
          Text(controller.kind == .usb ? "USB" : "Bluetooth LE").font(.caption).padding(
            .horizontal, 6
          ).padding(.vertical, 2).background(.quaternary).clipShape(Capsule())
          if let battery = controller.state.battery {
            BatteryIndicator(battery: battery)
          }
          Spacer()
          Button("Vibrate", systemImage: "waveform.path") { onRumble() }.buttonStyle(
            .bordered
          ).controlSize(.small)
        }
        Text(controller.name).font(.caption).foregroundStyle(.secondary)
        let pressed = controller.state.buttons.filter { $0.value }.map(\.key).sorted()
        Text(pressed.isEmpty ? "No buttons pressed" : pressed.joined(separator: ", ")).font(
          .caption)
        Text(
          "L \(controller.state.leftX), \(controller.state.leftY)   C \(controller.state.rightX), \(controller.state.rightY)   L2 \(controller.state.leftTrigger)   R2 \(controller.state.rightTrigger)"
        ).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 4)
  }
}

private struct BatteryIndicator: View {
  let battery: ControllerBattery

  private var symbolName: String {
    if battery.isCharging { return "battery.100.bolt" }
    switch battery.percentage {
    case ...10: return "battery.0"
    case ...35: return "battery.25"
    case ...60: return "battery.50"
    case ...85: return "battery.75"
    default: return "battery.100"
    }
  }

  private var color: Color {
    if battery.isCharging { return .green }
    return battery.percentage <= 20 ? .red : .secondary
  }

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbolName)
      Text("\(battery.percentage)%")
    }
    .font(.caption)
    .foregroundStyle(color)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      battery.isCharging
        ? "Battery \(battery.percentage) percent, charging"
        : "Battery \(battery.percentage) percent")
    .help("Approximate battery level (the controller reports 10 levels)")
  }
}

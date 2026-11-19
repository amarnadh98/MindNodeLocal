import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The Shortcuts recorder (F-SET): shows the current Quick Entry
/// hotkey; clicking Record captures the next modifier-combination key
/// press through a local event monitor and hands the spec up. Esc or a
/// bare (modifier-less) key cancels; ⌘-only combos are refused so the
/// recorder can never shadow an app menu command.
struct HotkeyRecorder: NSViewRepresentable {
    let current: HotkeySpec
    let onRecord: (HotkeySpec) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.show(spec: current)
        view.onRecord = onRecord
    }

    /// The capture view: a live label plus the Record button.
    @MainActor
    final class RecorderView: NSView {
        var onRecord: ((HotkeySpec) -> Void)?

        private let label = NSTextField(labelWithString: "")
        private let button = NSButton(title: "Record…", target: nil, action: nil)
        private var monitor: Any?
        private var spec: HotkeySpec = .quickEntryDefault

        init() {
            let containerFrame = NSRect(x: 0, y: 0, width: 220, height: 24)
            super.init(frame: containerFrame)
            label.font = .controlContentFont(ofSize: NSFont.systemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            button.bezelStyle = .rounded
            button.action = #selector(RecorderView.recordAction(_:))
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)

            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
                button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            ])
            show(spec: .quickEntryDefault)
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// Renders `spec` (the settings-side current value).
        func show(spec: HotkeySpec) {
            self.spec = spec
            label.stringValue = spec.symbolRepresentation
        }

        /// Start capturing; the monitor lives until a usable key or Esc.
        @objc private func recordAction(_ sender: Any?) {
            guard monitor == nil else { return }
            button.title = "Press keys…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.stopRecording()
                    return nil
                }
                let spec = HotkeySpec(keyCode: UInt32(event.keyCode), eventModifiers: event.modifierFlags)
                // A global hotkey must carry a modifier, and never the
                // command flag (that space belongs to menu commands).
                guard spec.hasModifier, event.modifierFlags.contains(.command) == false else {
                    NSSound.beep()
                    return event
                }
                self.stopRecording()
                self.show(spec: spec)
                self.onRecord?(spec)
                return nil
            }
        }

        private func stopRecording() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            button.title = "Record…"
        }
    }
}

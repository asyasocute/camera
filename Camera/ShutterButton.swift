import SwiftUI
import UIKit

/// Fires on touch-down, where a SwiftUI Button fires on release: the press is the moment to capture
/// (Apple's advice for the least shutter lag), and the length of the tap would add to the delay.
struct ShutterButton: View {
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
            Circle().fill(.white).frame(width: 66, height: 66)
                .scaleEffect(isBusy ? 0.86 : 1)
        }
        .overlay { TouchDownArea(isEnabled: isEnabled, action: action) }
        .animation(.easeOut(duration: 0.1), value: isBusy)
    }
}

/// UIKit's touch-down event: sent synchronously from touchesBegan, with no gesture disambiguation.
private struct TouchDownArea: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> TouchDownControl {
        let control = TouchDownControl()
        control.accessibilityLabel = String(localized: "Take photo")
        return control
    }

    func updateUIView(_ control: TouchDownControl, context: Context) {
        control.isEnabled = isEnabled
        control.action = action
    }
}

private final class TouchDownControl: UIControl {
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        addTarget(self, action: #selector(touchedDown), for: .touchDown)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { isEnabled ? .button : [.button, .notEnabled] }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    @objc private func touchedDown() {
        action?()
    }
}

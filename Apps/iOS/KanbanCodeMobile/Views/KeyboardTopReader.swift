import SwiftUI
import UIKit

/// The top of the keyboard, suggestion bar included, in window
/// coordinates (the window's bottom when there is no keyboard), read from
/// UIKit's keyboard layout guide.
///
/// SwiftUI's keyboard avoidance is set from the keyboard's show and hide
/// notifications; when the suggestion bar comes up after the keyboard it
/// can keep the shorter frame, and the bottom of the composer ends up under
/// the bar. The layout guide follows every change of the keyboard frame, in
/// any order, so the chat can make up what SwiftUI left out.
struct KeyboardTopReader: UIViewRepresentable {
    let onChange: (CGFloat, TimeInterval) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat, TimeInterval) -> Void)?
        private let marker = UIView()
        private var reported: CGFloat = -1

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            marker.isHidden = true
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            keyboardLayoutGuide.usesBottomSafeArea = false
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                marker.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let top = convert(keyboardLayoutGuide.layoutFrame, to: window).minY.rounded()
            guard top != reported else { return }
            reported = top
            let duration = UIView.inheritedAnimationDuration
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(top, duration)
            }
        }
    }
}

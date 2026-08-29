import AppKit

/// Mission Control의 활성 Space 변경 알림을 후행 debounce로 한 번만 전달한다.
/// 알림에는 Space 정보가 없으므로 callback도 무페이로드다.
@MainActor
final class ActiveSpaceWatcher {
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    init(debounceInterval: TimeInterval, onChange: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.spaceChanged() }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    // internal — 테스트가 Mission Control 없이 직접 발화시킨다.
    func spaceChanged() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fire() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func fire() {
        pending = nil
        onChange()
    }
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox

extension KeyboardShortcuts {
	/**
	A `NSView` that lets the user record a keyboard shortcut.

	You would usually put this in your settings window.

	It automatically prevents choosing a keyboard shortcut that is already taken by the system or by the app's main menu by showing a user-friendly alert to the user.

	It takes care of storing the keyboard shortcut in `UserDefaults` for you.

	```swift
	import AppKit
	import KeyboardShortcuts

	final class SettingsViewController: NSViewController {
		override func loadView() {
			view = NSView()

			let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleUnicornMode)
			view.addSubview(recorder)
		}
	}
	```
	*/
	public final class RecorderCocoa: NSView {
		private let minimumWidth = 130.0
		private let onChange: ((_ shortcut: Shortcut?) -> Void)?
		private var canBecomeKey = false
		private var eventMonitor: LocalEventMonitor?
//		private var globalEventMonitor: Any?
		private var shortcutsNameChangeObserver: NSObjectProtocol?
		private var windowDidResignKeyObserver: NSObjectProtocol?
		private var windowDidBecomeKeyObserver: NSObjectProtocol?
		private var isRecording = false

		/**
		The shortcut name for the recorder.

		Can be dynamically changed at any time.
		*/
		public var shortcutName: Name {
			didSet {
				guard shortcutName != oldValue else {
					return
				}
			}
		}

		/// :nodoc:
		override public var canBecomeKeyView: Bool { canBecomeKey }

		/// :nodoc:
		override public var intrinsicContentSize: CGSize {
			return CGSize(width: minimumWidth, height: 26)
		}

		/// :nodoc:
		override public var acceptsFirstResponder: Bool { true }

		public required init(
			for name: Name,
			onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
		) {
			self.shortcutName = name
			self.onChange = onChange

			super.init(frame: .zero)
			
			// 设置基本属性 - 完全透明
			self.wantsLayer = true
			self.layer?.backgroundColor = NSColor.clear.cgColor
			
			// 修改内容压缩优先级，允许视图拉伸
			setContentHuggingPriority(.defaultLow, for: .vertical)
			setContentHuggingPriority(.defaultHigh, for: .horizontal)
			
			// 设置内容压缩阻力，防止视图被压缩
			setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
			
			setUpEvents()
		}

		@available(*, unavailable)
		public required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		private func setUpEvents() {
			shortcutsNameChangeObserver = NotificationCenter.default.addObserver(forName: .shortcutByNameDidChange, object: nil, queue: nil) { [weak self] notification in
				guard
					let self,
					let nameInNotification = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
					nameInNotification == shortcutName
				else {
					return
				}
			}
			
			// 监听窗口状态变化
			NotificationCenter.default.addObserver(
				self,
				selector: #selector(windowDidResignKey),
				name: NSWindow.didResignKeyNotification,
				object: nil
			)
		}
		
		@objc private func windowDidResignKey(_ notification: Notification) {
			// 当窗口失去焦点时结束录制
			if isRecording {
				endRecording()
			}
		}

		private func startRecording() {
			isRecording = true
			
			KeyboardShortcuts.isPaused = true
			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": true])
			
			// 监听键盘事件
			eventMonitor = LocalEventMonitor(events: [.keyDown]) { [weak self] event in
				guard let self else {
					return nil
				}
				
				// Tab键 - 结束录制并允许事件继续传递以便聚焦下一个控件
				if
					event.modifiers.isEmpty,
					event.specialKey == .tab
				{
					self.endRecording()
					return event
				}

				// Esc键 - 取消录制
				if
					event.modifiers.isEmpty,
					event.keyCode == kVK_Escape
				{
					self.endRecording()
					return nil
				}

				// Delete/Backspace键 - 清除当前快捷键
				if
					event.modifiers.isEmpty,
					event.specialKey == .delete
						|| event.specialKey == .deleteForward
						|| event.specialKey == .backspace
				{
					self.saveShortcut(nil)
					self.endRecording()
					return nil
				}

				// "shift" 键不允许单独使用，因为它实际上不起作用
				guard
					!event.modifiers.subtracting([.shift, .function]).isEmpty
						|| event.specialKey?.isFunctionKey == true,
					let shortcut = Shortcut(event: event)
				else {
					NSSound.beep()
					return nil
				}
				
				// 检查是否与当前设置的快捷键相同
				let currentShortcut = KeyboardShortcuts.getShortcut(for: shortcutName)
				print("oldKeyshortcut: \(String(describing: currentShortcut))")
				print("shortcut: \(shortcut)")
				if shortcut == currentShortcut {
					// 如果用户选择了与当前相同的快捷键，直接接受并结束录制
					self.endRecording()
					return nil
				}
				
				// 检查快捷键冲突
				if let menuItem = shortcut.takenByMainMenu {
					self.endRecording()

					NSAlert.showModal(
						for: self.window,
						title: String.localizedStringWithFormat("keyboard_shortcut_used_by_menu_item".localized, menuItem.title)
					)

					self.startRecording()
					return nil
				}

				if shortcut.isDisallowed {
					self.endRecording()

					NSAlert.showModal(
						for: self.window,
						title: "keyboard_shortcut_disallowed".localized
					)

					self.startRecording()
					return nil
				}

				if shortcut.isTakenBySystem {
					self.endRecording()

					let modalResponse = NSAlert.showModal(
						for: self.window,
						title: "keyboard_shortcut_used_by_system".localized,
						message: "keyboard_shortcuts_can_be_changed".localized,
						buttonTitles: [
							"ok".localized,
							"force_use_shortcut".localized
						]
					)

					self.startRecording()

					guard modalResponse == .alertSecondButtonReturn else {
						return nil
					}
				}

				self.saveShortcut(shortcut)
				self.endRecording()
				return nil
			}.start()
			
			// 添加全局事件监听器，用于检测点击视图外部
//			globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
//				guard let self = self, self.isRecording else { return }
//				
//				// 检查点击是否在视图外部
//				if let window = self.window {
//					let clickPoint = window.convertPoint(fromScreen: event.locationInWindow)
//					let viewFrameInWindow = self.convert(self.bounds, to: nil)
//					
//					if !viewFrameInWindow.contains(clickPoint) {
//						// 点击在视图外部，结束录制
//						DispatchQueue.main.async {
//							self.endRecording()
//						}
//					}
//				}
//			}
			
			// 更新视图状态
			needsDisplay = true
		}

		private func endRecording() {
			isRecording = false
			eventMonitor = nil
			
//			if let globalMonitor = globalEventMonitor {
//				NSEvent.removeMonitor(globalMonitor)
//				globalEventMonitor = nil
//			}
			
			window?.makeFirstResponder(nil)
			KeyboardShortcuts.isPaused = false
			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": false])
		}

		private func preventBecomingKey() {
			canBecomeKey = false

			// 防止控件接收初始焦点
			DispatchQueue.main.async { [self] in
				canBecomeKey = true
			}
		}

		/// :nodoc:
		override public func draw(_ dirtyRect: NSRect) {
			// 完全透明，不绘制任何内容
			NSColor.clear.set()
			dirtyRect.fill()
		}

		/// :nodoc:
		override public func viewDidMoveToWindow() {
			guard let window else {
				windowDidResignKeyObserver = nil
				windowDidBecomeKeyObserver = nil
				endRecording()
				return
			}

			// 确保当窗口隐藏时录制器停止
			windowDidResignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
				guard
					let self
				else {
					return
				}

				self.endRecording()
			}

			// 确保录制器在隐藏的窗口变为可见时不会接收初始焦点
			windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
				self?.preventBecomingKey()
			}
			preventBecomingKey()
		}

		/// :nodoc:
		override public func mouseDown(with event: NSEvent) {
			super.mouseDown(with: event)
			
			if !isRecording {
				window?.makeFirstResponder(self)
				startRecording()
			}
		}

		/// :nodoc:
		override public func becomeFirstResponder() -> Bool {
			let shouldBecomeFirstResponder = super.becomeFirstResponder()

			guard shouldBecomeFirstResponder else {
				return shouldBecomeFirstResponder
			}
			
			if !isRecording {
				startRecording()
			}
			
			return shouldBecomeFirstResponder
		}

		private func saveShortcut(_ shortcut: Shortcut?) {
			setShortcut(shortcut, for: shortcutName)
			onChange?(shortcut)
		}

		/// :nodoc:
		override public func viewDidMoveToSuperview() {
			super.viewDidMoveToSuperview()
			
			// 如果有父视图，设置高度约束以撑满父视图
			if let superview = self.superview {
				self.translatesAutoresizingMaskIntoConstraints = false
				NSLayoutConstraint.activate([
					self.heightAnchor.constraint(equalTo: superview.heightAnchor),
					self.centerYAnchor.constraint(equalTo: superview.centerYAnchor)
				])
			}
		}
	}
}

extension Notification.Name {
	public static let shortcutByNameDidChange = Self("KeyboardShortcuts_shortcutByNameDidChange")
	public static let recorderActiveStatusDidChange = Self("KeyboardShortcuts_recorderActiveStatusDidChange")
}
#endif

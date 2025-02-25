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
	public final class RecorderCocoa: NSSearchField, NSSearchFieldDelegate {
		private let minimumWidth = 130.0
		private let onChange: ((_ shortcut: Shortcut?) -> Void)?
		private var canBecomeKey = false
		private var eventMonitor: LocalEventMonitor?
		private var shortcutsNameChangeObserver: NSObjectProtocol?
		private var windowDidResignKeyObserver: NSObjectProtocol?
		private var windowDidBecomeKeyObserver: NSObjectProtocol?

		/**
		The shortcut name for the recorder.

		Can be dynamically changed at any time.
		*/
		public var shortcutName: Name {
			didSet {
				guard shortcutName != oldValue else {
					return
				}

				setStringValue(name: shortcutName)

				// This doesn't seem to be needed anymore, but I cannot test on older OS versions, so keeping it just in case.
				if #unavailable(macOS 12) {
					DispatchQueue.main.async { [self] in
						// Prevents the placeholder from being cut off.
						blur()
					}
				}
			}
		}

		/// :nodoc:
		override public var canBecomeKeyView: Bool { canBecomeKey }

		/// :nodoc:
		override public var intrinsicContentSize: CGSize {
			var size = super.intrinsicContentSize
			size.width = minimumWidth
			return size
		}

		private var cancelButton: NSButtonCell?

		private var showsCancelButton: Bool {
			get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
			set {
				(cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil
			}
		}

		/**
		- Parameter name: Strongly-typed keyboard shortcut name.
		- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
		*/
		public required init(
			for name: Name,
			onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
		) {
			self.shortcutName = name
			self.onChange = onChange

			super.init(frame: .zero)
			self.delegate = self
			// 不显示任何占位符文本
			self.placeholderString = ""
			self.alignment = .center
			(cell as? NSSearchFieldCell)?.searchButtonCell = nil
			// 完全禁用取消按钮
			(cell as? NSSearchFieldCell)?.cancelButtonCell = nil

			self.wantsLayer = true
			setContentHuggingPriority(.defaultHigh, for: .vertical)
			setContentHuggingPriority(.defaultHigh, for: .horizontal)
			
			// 隐藏选中时的视觉效果
			self.focusRingType = .none
			
			// 自定义外观，移除选中效果和所有可能的颜色
			if let cell = self.cell as? NSSearchFieldCell {
				cell.bezelStyle = .roundedBezel
				cell.isBordered = false  // 设置为 false 以移除边框
				cell.drawsBackground = false  // 不绘制背景
				cell.textColor = .clear  // 文本颜色设为透明
				cell.backgroundColor = .clear  // 背景颜色设为透明
			}
			
			// 设置背景为透明
			self.backgroundColor = .clear
			self.layer?.backgroundColor = CGColor.clear
			
			// 不设置任何文本内容
			self.stringValue = ""

			setUpEvents()
		}

		@available(*, unavailable)
		public required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		private func setStringValue(name: Name) {
			// 保持文本为空，不显示任何内容
			stringValue = ""
			showsCancelButton = false
			
			// 确保不显示任何占位符
			placeholderString = ""
			
			// 确保文本颜色为透明
			if let cell = self.cell as? NSSearchFieldCell {
				cell.textColor = .clear
			}
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

				setStringValue(name: nameInNotification)
			}
		}

		private func endRecording() {
			eventMonitor = nil
			// 不显示任何占位符文本
			placeholderString = ""
			showsCancelButton = false
			restoreCaret()
			KeyboardShortcuts.isPaused = false
			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": false])
		}

		private func preventBecomingKey() {
			canBecomeKey = false

			// Prevent the control from receiving the initial focus.
			DispatchQueue.main.async { [self] in
				canBecomeKey = true
			}
		}

		/// :nodoc:
		public func controlTextDidChange(_ notification: Notification) {
			if stringValue.isEmpty {
				saveShortcut(nil)
			}

			// 保持文本不可见
			stringValue = ""
			showsCancelButton = false
		}

		/// :nodoc:
		public func controlTextDidEndEditing(_ object: Notification) {
			// 确保文本保持为空
			stringValue = ""
			placeholderString = ""
			
			// 确保文本颜色为透明
			if let cell = self.cell as? NSSearchFieldCell {
				cell.textColor = .clear
			}
			
			endRecording()
		}

		/// :nodoc:
		override public func viewDidMoveToWindow() {
			guard let window else {
				windowDidResignKeyObserver = nil
				windowDidBecomeKeyObserver = nil
				endRecording()
				return
			}

			// Ensures the recorder stops when the window is hidden.
			// This is especially important for Settings windows, which as of macOS 13.5, only hides instead of closes when you click the close button.
			windowDidResignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
				guard
					let self,
					let window = self.window
				else {
					return
				}

				endRecording()
				window.makeFirstResponder(nil)
			}

			// Ensures the recorder does not receive initial focus when a hidden window becomes unhidden.
			windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
				self?.preventBecomingKey()
			}

			preventBecomingKey()
		}

		/// :nodoc:
		override public func becomeFirstResponder() -> Bool {
			let shouldBecomeFirstResponder = super.becomeFirstResponder()

			guard shouldBecomeFirstResponder else {
				return shouldBecomeFirstResponder
			}
			
			// 隐藏选中时的视觉效果
			self.layer?.borderWidth = 0
			self.layer?.shadowOpacity = 0
			self.layer?.backgroundColor = CGColor.clear
			
			// 保存当前背景色和边框样式
			if let cell = self.cell as? NSSearchFieldCell {
				cell.isBordered = false
				cell.drawsBackground = false
				cell.textColor = .clear
				cell.backgroundColor = .clear
			}
			
			// 确保背景为透明
			self.backgroundColor = .clear

			// 不显示占位符
			placeholderString = ""
			showsCancelButton = false
			hideCaret()
			KeyboardShortcuts.isPaused = true // The position here matters.
			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": true])

			eventMonitor = LocalEventMonitor(events: [.keyDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
				guard let self else {
					return nil
				}

				let clickPoint = convert(event.locationInWindow, from: nil)
				let clickMargin = 3.0

				if
					event.type == .leftMouseUp || event.type == .rightMouseUp,
					!bounds.insetBy(dx: -clickMargin, dy: -clickMargin).contains(clickPoint)
				{
					blur()
					return event
				}

				guard event.isKeyEvent else {
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .tab
				{
					blur()

					// We intentionally bubble up the event so it can focus the next responder.
					return event
				}

				if
					event.modifiers.isEmpty,
					event.keyCode == kVK_Escape // TODO: Make this strongly typed.
				{
					blur()
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .delete
						|| event.specialKey == .deleteForward
						|| event.specialKey == .backspace
				{
					clear()
					return nil
				}

				// The "shift" key is not allowed without other modifiers or a function key, since it doesn't actually work.
				guard
					!event.modifiers.subtracting([.shift, .function]).isEmpty
						|| event.specialKey?.isFunctionKey == true,
					let shortcut = Shortcut(event: event)
				else {
					NSSound.beep()
					return nil
				}
				
				if let menuItem = shortcut.takenByMainMenu {
									// TODO: Find a better way to make it possible to dismiss the alert by pressing "Enter". How can we make the input automatically temporarily lose focus while the alert is open?
									blur()

									NSAlert.showModal(
										for: window,
										title: String.localizedStringWithFormat("keyboard_shortcut_used_by_menu_item".localized, menuItem.title)
									)

									focus()

									return nil
								}

								// See: https://developer.apple.com/forums/thread/763878?answerId=804374022#804374022
								if shortcut.isDisallowed {
									blur()

									NSAlert.showModal(
										for: window,
										title: "keyboard_shortcut_disallowed".localized
									)

									focus()
									return nil
								}

								if shortcut.isTakenBySystem {
									blur()
//
									let modalResponse = NSAlert.showModal(
										for: window,
										title: "keyboard_shortcut_used_by_system".localized,
										// TODO: Add button to offer to open the relevant system settings pane for the user.
										message: "keyboard_shortcuts_can_be_changed".localized,
										buttonTitles: [
											"ok".localized,
											"force_use_shortcut".localized
										]
									)
//
									focus()

									 // If the user has selected "Use Anyway" in the dialog (the second option), we'll continue setting the keyboard shorcut even though it's reserved by the system.
									guard modalResponse == .alertSecondButtonReturn else {
										return nil
									}
									return nil
								}



				stringValue = "\(shortcut)"
				showsCancelButton = true

				saveShortcut(shortcut)
				blur()

				return nil
			}.start()

			return shouldBecomeFirstResponder
		}

		private func saveShortcut(_ shortcut: Shortcut?) {
			setShortcut(shortcut, for: shortcutName)
			onChange?(shortcut)
		}

		/// :nodoc:
		override public func draw(_ dirtyRect: NSRect) {
			// 完全覆盖默认绘制行为
			// 绘制一个完全透明的背景
			NSColor.clear.set()
			dirtyRect.fill()
		}

		/// :nodoc:
		override public func drawFocusRingMask() {
			// 不绘制任何内容，完全隐藏焦点环
		}
		
		/// :nodoc:
		override public var focusRingMaskBounds: NSRect {
			// 返回零大小的矩形，确保不会绘制焦点环
			return .zero
		}

		/// :nodoc:
		override public func viewDidMoveToSuperview() {
			super.viewDidMoveToSuperview()
			
			// 确保视图层次结构中的所有相关属性都设置为透明
			self.wantsLayer = true
			self.layer?.backgroundColor = NSColor.clear.cgColor
			self.layer?.borderWidth = 0
			self.layer?.shadowOpacity = 0
			
			// 禁用所有可能导致背景变色的属性
			if let cell = self.cell as? NSSearchFieldCell {
				cell.isBordered = false
				cell.drawsBackground = false
				cell.textColor = .clear
				cell.backgroundColor = .clear
			}
		}

		/// :nodoc:
		override public func updateLayer() {
			super.updateLayer()
			// 确保层的背景为透明
			self.layer?.backgroundColor = NSColor.clear.cgColor
		}

		/// :nodoc:
		override public func textDidBeginEditing(_ notification: Notification) {
			super.textDidBeginEditing(notification)
			
			// 当文本编辑开始时，确保文本和背景保持透明
			if let textView = currentEditor() as? NSTextView {
				textView.backgroundColor = .clear
				textView.insertionPointColor = .clear
				textView.textColor = .clear
			}
		}

		/// :nodoc:
		override public func textDidChange(_ notification: Notification) {
			super.textDidChange(notification)
			
			// 当文本变化时，确保文本保持透明
			if let textView = currentEditor() as? NSTextView {
				textView.backgroundColor = .clear
				textView.textColor = .clear
			}
		}
	}
}

extension Notification.Name {
	public static let recorderActiveStatusDidChange = Self("KeyboardShortcuts_recorderActiveStatusDidChange")
}
#endif

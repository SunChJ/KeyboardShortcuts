//
//  temp.swift
//  KeyboardShortcutsExample
//
//  Created by jingxing on 2025/2/25.
//

import Foundation
import SwiftUI
import KeyboardShortcuts


extension KeyboardShortcuts.Name {
	static let collect = Self("collect", default: .init(.c, modifiers: [.shift, .command]))
}


@MainActor
class CollectShortcutViewModel: ObservableObject {
	@Published var isRecording = false
	
	var hotkey: String {
		if isRecording {
			return "请输入按键"  // 当处于录制状态时显示提示文字
		}
		
		if let shortcut = KeyboardShortcuts.getShortcut(for: .collect) {
			return shortcut.description
		} else {
			KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.shift, .command]), for: .collect)
			return "⇧⌘C"
		}
	}
	
	func clearShortcut() {
		KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.shift, .command]), for: .collect)
		isRecording = false  // 确保清除后退出录制状态
	}
}


struct CollectShortcut: View {
  @ObservedObject private var vm = CollectShortcutViewModel()
  @State private var isActive = false  // 使用 isActive 替代 isRecording，直接反映 Recorder 的状态

	init() {
		
		KeyboardShortcuts.onKeyUp(for: .collect) {
			print("handle - collect")
		}
	}
	
  var body: some View {
	HStack {
	  Spacer()
		
	  HStack {
		ZStack {
		  // 始终显示文本
		  Text(vm.hotkey)
			.frame(width: 130, height: 26)
			.contentShape(Rectangle())
			.onTapGesture {
			  // 点击文本时尝试激活 Recorder
			  vm.isRecording = true  // 更新 ViewModel 的状态
//			  KeyboardShortcuts.setRecorderActive(true)
			}
			
		  // Recorder 始终存在
		  KeyboardShortcuts.Recorder(for: .collect)
			.frame(width: 130, height: 26)
			.onReceive(NotificationCenter.default.publisher(for: .recorderActiveStatusDidChange)) { notification in
			  if let isActive = notification.userInfo?["isActive"] as? Bool {
				// 直接使用 Recorder 的活动状态更新我们的 isActive 状态
				self.isActive = isActive
				vm.isRecording = isActive  // 同步更新 ViewModel 的状态
			  }
			}
		}
		.frame(width: 130, height: 26)
		
		Spacer()

		Button {
		  vm.clearShortcut()
		} label: {
		  Circle().frame(width: 20, height: 20)
		}
		.buttonStyle(.plain)
		.frame(width: 16, height: 16)
	  }
	  .frame(minWidth: 120, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
	  .padding(.horizontal, 8)
	  .background(
		RoundedRectangle(cornerRadius: 6)
		  .strokeBorder(Color.blue, lineWidth: isActive ? 1 : 0)  // 使用 isActive 控制边框
		  .background(
			RoundedRectangle(cornerRadius: 6).fill(Color.orange)
		  )
	  )
	  .fixedSize()
	  .onTapGesture {}
	}
	.frame(height: 100)
  }
}

#Preview {
  CollectShortcut()
}

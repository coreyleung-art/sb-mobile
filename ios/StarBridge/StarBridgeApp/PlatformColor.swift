import SwiftUI

#if os(iOS)
import UIKit
extension Color {
    static var chatSystemBackground: Color { Color(UIColor.systemBackground) }
    static var chatSystemGray5: Color { Color(UIColor.systemGray5) }
}
#else
import AppKit
extension Color {
    static var chatSystemBackground: Color { Color(NSColor.windowBackgroundColor) }
    static var chatSystemGray5: Color { Color(NSColor.controlBackgroundColor) }
}
#endif

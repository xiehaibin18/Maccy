import AppKit.NSEvent
import ApplicationServices
import Defaults
import Foundation

enum PopupPosition: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case cursor
  case caret
  case statusItem
  case window
  case center
  case lastPosition

  var id: Self { self }

  var description: String {
    switch self {
    case .cursor:
      return NSLocalizedString("PopupAtCursor", tableName: "AppearanceSettings", comment: "")
    case .caret:
      return NSLocalizedString("PopupAtCaret", tableName: "AppearanceSettings", comment: "")
    case .statusItem:
      return NSLocalizedString("PopupAtMenuBarIcon", tableName: "AppearanceSettings", comment: "")
    case .window:
      return NSLocalizedString("PopupAtWindowCenter", tableName: "AppearanceSettings", comment: "")
    case .center:
      return NSLocalizedString("PopupAtScreenCenter", tableName: "AppearanceSettings", comment: "")
    case .lastPosition:
      return NSLocalizedString("PopupAtLastPosition", tableName: "AppearanceSettings", comment: "")
    }
  }

  func origin(size: NSSize, statusBarButton: NSStatusBarButton?) -> NSPoint {
    switch self {
    case .center:
      if let frame = NSScreen.forPopup?.visibleFrame {
        return NSRect.centered(ofSize: size, in: frame).origin
      }
    case .window:
      if let frame = NSWorkspace.shared.frontmostApplication?.windowFrame {
        return NSRect.centered(ofSize: size, in: frame).origin
      }
    case .statusItem:
      if let statusBarButton, let point = statusItemOrigin(size: size, statusBarButton: statusBarButton) {
        return point
      }
    case .caret:
      // Prefer the caret of the focused text input in the frontmost application.
      if let caret = FocusedTextCaret.rect() {
        let screen = NSScreen.screens.first { NSMouseInRect(caret.origin, $0.frame, false) }
        let point = NSPoint(x: caret.midX - size.width / 2, y: caret.minY - size.height)
        return constrained(point, ofSize: size, to: screen)
      }
      // Fall back to the menu bar icon position when there is no text caret.
      if let statusBarButton, let point = statusItemOrigin(size: size, statusBarButton: statusBarButton) {
        return point
      }
    case .lastPosition:
      if let frame = NSScreen.forPopup?.visibleFrame {
        let relativePos = Defaults[.windowPosition]
        let anchorX = frame.minX + frame.width * relativePos.x
        let anchorY = frame.minY + frame.height * relativePos.y
        // Anchor is top middle of frame
        return NSPoint(x: anchorX - size.width / 2, y: anchorY - size.height)
      }
    default:
      break
    }

    let mouseLocation = NSEvent.mouseLocation
    let point = NSPoint(x: mouseLocation.x, y: mouseLocation.y - size.height)
    let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    return constrained(point, ofSize: size, to: screen)
  }

  private func statusItemOrigin(size: NSSize, statusBarButton: NSStatusBarButton) -> NSPoint? {
    let rectInWindow = statusBarButton.convert(statusBarButton.bounds, to: nil)
    guard let screenRect = statusBarButton.window?.convertToScreen(rectInWindow) else {
      return nil
    }

    let topLeftPoint = NSPoint(x: screenRect.minX, y: screenRect.minY - size.height)
    let screen = statusBarButton.window?.screen ?? NSScreen.main
    return constrained(topLeftPoint, ofSize: size, to: screen)
  }

  // Ensure that window doesn't spill over to an adjacent screen.
  private func constrained(_ origin: NSPoint, ofSize size: NSSize, to screen: NSScreen?) -> NSPoint {
    guard let frame = screen?.visibleFrame else {
      return origin
    }

    return NSPoint(
      x: min(max(origin.x, frame.minX), frame.maxX - size.width),
      y: min(max(origin.y, frame.minY), frame.maxY - size.height)
    )
  }
}

/// Rect of the caret (text insertion point) inside the focused text element
/// of the frontmost application, in AppKit screen coordinates.
private enum FocusedTextCaret {
  static func rect() -> NSRect? {
    let systemWideElement = AXUIElementCreateSystemWide()

    var focusedElementValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElementValue
    ) == .success,
      let focusedElementValue else {
      return nil
    }
    // swiftlint:disable:next force_cast
    let focusedElement = focusedElementValue as! AXUIElement

    var selectedRangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      focusedElement,
      kAXSelectedTextRangeAttribute as CFString,
      &selectedRangeValue
    ) == .success,
      let selectedRangeValue else {
      return nil
    }
    // swiftlint:disable:next force_cast
    let selectedRangeAX = selectedRangeValue as! AXValue

    var selectedRange = CFRange()
    guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
      return nil
    }

    var boundsValue: CFTypeRef?
    guard let rangeAX = AXValueCreate(.cfRange, &selectedRange),
          AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAX,
            &boundsValue
          ) == .success,
          let boundsValue else {
      return nil
    }
    // swiftlint:disable:next force_cast
    let boundsAX = boundsValue as! AXValue

    var bounds = CGRect()
    guard AXValueGetValue(boundsAX, .cgRect, &bounds),
          !bounds.isNull,
          bounds.width.isFinite,
          bounds.height.isFinite else {
      return nil
    }

    // AX uses global coordinates with a top-left origin on the primary screen,
    // while AppKit uses a bottom-left origin; flip vertically.
    guard let primaryFrame = NSScreen.screens.first?.frame else {
      return nil
    }

    return NSRect(
      x: bounds.minX,
      y: primaryFrame.maxY - bounds.maxY,
      width: bounds.width,
      height: bounds.height
    )
  }
}

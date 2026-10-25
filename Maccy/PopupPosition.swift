import AppKit.NSEvent
import ApplicationServices
import Defaults
import Foundation
import OSLog

private let caretLogger = Logger(subsystem: "org.p0deje.Maccy", category: "caret")

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
        let point = caretOrigin(caret, ofSize: size, in: screen)
        caretLogger.notice("caret \(String(describing: caret), privacy: .public)")
        caretLogger.notice("popup origin \(String(describing: point), privacy: .public)")
        return constrained(point, ofSize: size, to: screen)
      }
      // Fall back to the menu bar icon position when there is no text caret.
      caretLogger.notice("caret unavailable, falling back to status item")
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

  // Place the popup like an inline completion popup: its bottom-left corner
  // sits just right of and above the caret. When there is not enough room
  // above, flip to below the caret line instead.
  private func caretOrigin(_ caret: NSRect, ofSize size: NSSize, in screen: NSScreen?) -> NSPoint {
    let visibleFrame = screen?.visibleFrame ?? .zero

    let point = NSPoint(x: caret.maxX, y: caret.maxY)
    if point.y + size.height > visibleFrame.maxY {
      return NSPoint(x: caret.minX, y: caret.minY - size.height)
    }

    return point
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
/// of the frontmost application, in AppKit screen coordinates. When the exact
/// caret bounds are unavailable (some applications report a zero rect for
/// caret-only selections), the frame of the focused element is used instead.
private enum FocusedTextCaret {
  static func rect() -> NSRect? {
    let systemWideElement = AXUIElementCreateSystemWide()

    var focusedElementValue: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedElementValue
    )
    guard focusedError == .success, let focusedElementValue else {
      caretLogger.notice("focused element unavailable: \(focusedError.rawValue)")
      return nil
    }
    // swiftlint:disable:next force_cast
    let focusedElement = focusedElementValue as! AXUIElement

    var elementPid = pid_t(0)
    AXUIElementGetPid(focusedElement, &elementPid)
    guard elementPid != ProcessInfo.processInfo.processIdentifier else {
      caretLogger.notice("focused element belongs to Maccy itself")
      return nil
    }

    var roleValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let roleValue {
      // swiftlint:disable:next force_cast
      let role = roleValue as! String
      caretLogger.notice("focused pid \(elementPid) role \(role, privacy: .public)")
    }

    if let caret = caretRect(of: focusedElement) {
      return flipToAppKit(caret)
    }

    // Chromium/WebKit applications expose stub text metrics until someone
    // explicitly requests accessibility. Wake the focused application once
    // and retry — after that its bounds queries return real values.
    if wakeAccessibilityIfNeeded(for: focusedElement) {
      usleep(200_000)
      if let caret = caretRect(of: focusedElement) {
        caretLogger.notice("caret resolved after waking accessibility")
        return flipToAppKit(caret)
      }
    }

    if let estimated = estimatedCaretRect(of: focusedElement) {
      caretLogger.notice("using estimated caret position")
      return flipToAppKit(estimated)
    }

    if let frame = focusedElementFrame(focusedElement) {
      caretLogger.notice("using focused element frame")
      return flipToAppKit(frame)
    }

    return nil
  }

  // Chromium- and WebKit-based applications keep their accessibility tree
  // disabled until a client sets AXEnhancedUserInterface on the application
  // element. Doing so once enables full text metrics (including caret bounds)
  // for the lifetime of that application.
  private nonisolated(unsafe) static var accessibilityWokenPids: Set<pid_t> = []

  private static func wakeAccessibilityIfNeeded(for element: AXUIElement) -> Bool {
    var pid = pid_t(0)
    AXUIElementGetPid(element, &pid)
    guard pid != 0, !accessibilityWokenPids.contains(pid) else {
      return false
    }
    accessibilityWokenPids.insert(pid)

    let systemWideElement = AXUIElementCreateSystemWide()
    var appValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      systemWideElement,
      kAXFocusedApplicationAttribute as CFString,
      &appValue
    ) == .success, let appValue else {
      return false
    }
    // swiftlint:disable:next force_cast
    let appElement = appValue as! AXUIElement

    let result = AXUIElementSetAttributeValue(
      appElement,
      "AXEnhancedUserInterface" as CFString,
      kCFBooleanTrue
    )
    caretLogger.notice("wake accessibility for pid \(pid): \(result.rawValue)")

    return result == .success
  }

  // Last resort before falling back to the whole element frame: estimate the
  // caret position proportionally from the selection location and the total
  // number of characters. Reasonable for single-line fields whose
  // parameterized bounds are permanently unavailable.
  private static func estimatedCaretRect(of element: AXUIElement) -> CGRect? {
    guard let frame = focusedElementFrame(element) else {
      return nil
    }

    var charsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXNumberOfCharactersAttribute as CFString,
      &charsValue
    ) == .success, let charsValue,
      let numberOfCharacters = (charsValue as? NSNumber)?.intValue,
      numberOfCharacters > 0 else {
      return nil
    }

    var selectedRangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &selectedRangeValue
    ) == .success, let selectedRangeValue else {
      return nil
    }
    // swiftlint:disable:next force_cast
    let selectedRangeAX = selectedRangeValue as! AXValue
    var selectedRange = CFRange()
    guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
      return nil
    }

    let location = min(max(0, selectedRange.location), numberOfCharacters)
    let ratio = Double(location) / Double(numberOfCharacters)
    let x = frame.minX + frame.width * ratio
    caretLogger.notice(
      "estimated caret x \(x) from location \(location) of \(numberOfCharacters) chars"
    )

    let lineHeight = min(frame.height, 28)
    return CGRect(x: x, y: frame.maxY - lineHeight, width: 0, height: lineHeight)
  }

  private static func caretRect(of element: AXUIElement) -> CGRect? {
    var selectedRangeValue: CFTypeRef?
    let rangeError = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &selectedRangeValue
    )
    guard rangeError == .success, let selectedRangeValue else {
      caretLogger.notice("selected range unavailable: \(rangeError.rawValue)")
      return nil
    }
    // swiftlint:disable:next force_cast
    let selectedRangeAX = selectedRangeValue as! AXValue

    var selectedRange = CFRange()
    guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
      return nil
    }
    caretLogger.notice("selected range loc \(selectedRange.location) len \(selectedRange.length)")

    if selectedRange.length > 0,
       let bounds = bounds(of: element, forRange: selectedRange),
       bounds.width > 0,
       bounds.height > 0 {
      caretLogger.notice("caret axRect \(String(describing: bounds), privacy: .public)")
      return bounds
    }

    // Empty selection (pure caret) or degenerate bounds: many applications
    // cannot resolve bounds for an empty range (kAXErrorNoValue or a zero
    // rect). Probe the character right after and right before the caret and
    // anchor the caret at the probed character's edge.
    let probes: [(range: CFRange, anchorAtMaxX: Bool)] = [
      (CFRange(location: selectedRange.location, length: 1), false),
      (CFRange(location: max(0, selectedRange.location - 1), length: 1), true)
    ]
    for probe in probes {
      guard let bounds = bounds(of: element, forRange: probe.range),
            bounds.width > 0,
            bounds.height > 0 else {
        continue
      }

      let anchorX = probe.anchorAtMaxX ? bounds.maxX : bounds.minX
      caretLogger.notice(
        "caret probed at loc \(probe.range.location), anchor x \(anchorX), height \(bounds.height)"
      )
      return CGRect(x: anchorX, y: bounds.minY, width: 0, height: bounds.height)
    }

    caretLogger.notice("caret bounds unavailable for all probes")
    return nil
  }

  private static func bounds(of element: AXUIElement, forRange range: CFRange) -> CGRect? {
    var rangeCopy = range
    guard let rangeAX = AXValueCreate(.cfRange, &rangeCopy) else {
      return nil
    }

    var boundsValue: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXBoundsForRangeParameterizedAttribute as CFString,
      rangeAX,
      &boundsValue
    )
    guard error == .success, let boundsValue else {
      caretLogger.notice("bounds(\(range.location),\(range.length)) error \(error.rawValue)")
      return nil
    }
    // swiftlint:disable:next force_cast
    let boundsAX = boundsValue as! AXValue

    var rect = CGRect()
    guard AXValueGetValue(boundsAX, .cgRect, &rect),
          !rect.isNull,
          rect.width.isFinite,
          rect.height.isFinite else {
      return nil
    }

    return rect
  }

  private static func focusedElementFrame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          let positionValue,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let sizeValue else {
      caretLogger.notice("focused element frame unavailable")
      return nil
    }
    // swiftlint:disable:next force_cast
    let positionAX = positionValue as! AXValue
    // swiftlint:disable:next force_cast
    let sizeAX = sizeValue as! AXValue

    var position = CGPoint()
    var size = CGSize()
    guard AXValueGetValue(positionAX, .cgPoint, &position),
          AXValueGetValue(sizeAX, .cgSize, &size),
          size.width.isFinite,
          size.height.isFinite,
          size.width > 0,
          size.height > 0 else {
      return nil
    }

    return CGRect(origin: position, size: size)
  }

  // AX uses global coordinates with a top-left origin on the primary screen,
  // while AppKit uses a bottom-left origin; flip vertically.
  private static func flipToAppKit(_ rect: CGRect) -> NSRect? {
    guard let primaryFrame = NSScreen.screens.first?.frame else {
      return nil
    }

    return NSRect(
      x: rect.minX,
      y: primaryFrame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }
}

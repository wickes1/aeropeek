import ApplicationServices

/// Typed readers over the accessibility API. An attribute that is missing, of another type, or not
/// answered within the messaging timeout reads as `nil`.
enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var point = CGPoint.zero
        guard let boxed = boxed(element, attribute), AXValueGetValue(boxed, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var size = CGSize.zero
        guard let boxed = boxed(element, attribute), AXValueGetValue(boxed, .cgSize, &size) else { return nil }
        return size
    }

    /// Any app can answer an accessibility query with whatever it likes, so the type is checked
    /// before the value is treated as an `AXValue`.
    private static func boxed(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}

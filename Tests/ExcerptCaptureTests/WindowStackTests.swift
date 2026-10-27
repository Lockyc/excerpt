import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct WindowStackTests {
    private let window = StackedWindow(
        id: 1, pid: 10, layer: 0, frame: CGRect(x: 100, y: 100, width: 400, height: 300))

    @Test func takesItsAppsMenuOverIt() {
        let menu = StackedWindow(
            id: 2, pid: 10, layer: 101, frame: CGRect(x: 150, y: 150, width: 120, height: 200))
        #expect(WindowStack.overlays(of: window, in: [menu, window]) == [menu])
    }

    @Test func leavesOtherAppsAndItsOwnNormalWindows() {
        let otherMenu = StackedWindow(
            id: 2, pid: 11, layer: 101, frame: CGRect(x: 150, y: 150, width: 120, height: 200))
        let sibling = StackedWindow(
            id: 3, pid: 10, layer: 0, frame: CGRect(x: 120, y: 120, width: 400, height: 300))
        #expect(WindowStack.overlays(of: window, in: [otherMenu, sibling, window]).isEmpty)
    }

    @Test func leavesItsAppsPopupsElsewhere() {
        let away = StackedWindow(
            id: 2, pid: 10, layer: 101, frame: CGRect(x: 900, y: 900, width: 120, height: 200))
        #expect(WindowStack.overlays(of: window, in: [away, window]).isEmpty)
    }

    /// A submenu that opens past the window's edge touches only its parent menu.
    @Test func followsASubmenuOffTheWindow() {
        let menu = StackedWindow(
            id: 2, pid: 10, layer: 101, frame: CGRect(x: 400, y: 150, width: 200, height: 200))
        let submenu = StackedWindow(
            id: 3, pid: 10, layer: 101, frame: CGRect(x: 590, y: 180, width: 150, height: 100))
        #expect(WindowStack.overlays(of: window, in: [submenu, menu, window]) == [submenu, menu])
        #expect(
            WindowStack.frame(of: window, with: [submenu, menu])
                == CGRect(x: 100, y: 100, width: 640, height: 300))
    }

    @Test func leavesPopupsBehindIt() {
        let behind = StackedWindow(
            id: 2, pid: 10, layer: 101, frame: CGRect(x: 150, y: 150, width: 120, height: 200))
        #expect(WindowStack.overlays(of: window, in: [window, behind]).isEmpty)
    }
}

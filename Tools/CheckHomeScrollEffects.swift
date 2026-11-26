import Foundation

@main
struct CheckHomeScrollEffects {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // Scroll effects change contrast and artwork only. Settings has a
        // fixed icon and app-settings action, independent of scroll geometry.
        let effects = OathHomeScrollEffects()
        expect(effects.pullProgress == 0 && effects.toolbarForegroundProgress == 0,
               "Start with unblurred artwork and its white toolbar foreground")
        for origin: CGFloat in [0, 25, 80, 180, 60, 0] {
            effects.update(origin: origin)
            expect(effects.toolbarForegroundProgress == 0, "Pulling keeps the artwork foreground")
        }
        expect(effects.pullProgress == 0, "Pull blur resets after native rebound")
        effects.update(origin: 55)
        expect(effects.pullProgress == 0.5, "Blur follows a partial downward pull")
        effects.update(origin: 220)
        expect(effects.pullProgress == 1, "Deep pulls have a bounded blur radius")
        effects.update(origin: 22)
        expect(effects.pullProgress == 0.2, "Blur decreases with the native rebound")
        effects.update(origin: -25)
        expect(effects.pullProgress == 0, "Scrolling into assets never blurs the artwork")
        expect(effects.toolbarForegroundProgress == 0.25, "Contrast follows upward scroll")
        effects.update(origin: -50)
        expect(effects.toolbarForegroundProgress == 0.5, "Toolbar contrast follows partial scrolling")
        effects.update(origin: -500)
        expect(effects.toolbarForegroundProgress == 1,
               "Fast deep scrolls clamp contrast to the asset content")
        for invalid: CGFloat in [.nan, .infinity, -.infinity] {
            effects.update(origin: invalid)
            expect(effects.toolbarForegroundProgress == 1 && effects.pullProgress == 0,
                   "Invalid geometry preserves valid state")
        }
        effects.update(origin: -49)
        expect(effects.toolbarForegroundProgress == 0.49, "Reverse scrolling reduces toolbar contrast")
        effects.update(origin: 0)
        expect(effects.pullProgress == 0 && effects.toolbarForegroundProgress == 0,
               "Scroll-to-top restores all visual effects")
        print("Passed \(checks) home scroll checks")
    }
}

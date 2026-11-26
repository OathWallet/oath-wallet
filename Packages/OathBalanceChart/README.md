# OathBalanceChart

Current release: [5.1.1 (111)](../../releases/5.1.1.md).

Native SwiftUI balance ribbon for iOS 17+, with UIKit horizontal pan recognition and Core Haptics. Home places it in the shared summary's detail slot, between the balance and Send/Receive actions. It uses the app's existing period picker, typography and light/dark canvas.

The reference's narrow, rounded vertical ticks fade downward. A bright selected tick and nearby lighting follow a horizontal scrub. Tick tops show displacement from the period's opening value: neutral gray at exactly zero change, green above it, red below it. Changes animate once; Reduce Motion disables geometry animation. There is no perpetual animation or background rendering loop.

## Data and privacy

`BalanceChartSeries` contains Decimal observations. It holds the last recorded value at each time, never inventing a price curve or interpolating money. The selection keeps cursor time separate from observation time. Time before the first observation remains unknown. This is a portfolio balance chart, including deposits and withdrawals, not an investment-return chart.

`OathDatabase.balanceChartHistory` reads a maximum of 129 samples through indexed time buckets. It excludes initial discovery, uses settled display valuations (including portfolios with unpriced tokens), and applies current account and hidden-asset selection to historical per-asset evidence before currency conversion. A period's opening balance carries across midnight when available. All means retained local history (currently a rolling year); there is no backfilled history before observations began.

Home guards wallet, accounts, hidden assets, currency and exchange-rate identity before using a result. Period/wallet changes cancel the observation. Live balances update the last point while the database's coalesced write catches up. A scrub freezes its visual series until release; no background update moves a tick under the finger. Concealment removes both value-dependent geometry and colors and disables selection/haptics. VoiceOver can adjust time and escape to the current balance.

Created, imported and restored wallets display a neutral zero change and 0.00% while the first settled comparison loads. This is a presentation fallback only; it does not persist a zero baseline or alter a real gain/loss. A real change from a zero opening balance still omits its undefined percentage.

## Haptics and lifecycle

Transient Core Haptics detents vary intensity and sharpness with displacement; crossings get a stronger, crisper detent. Feedback occurs only when the user moves to a new tick, capped at 25 Hz. It respects Oath's haptic setting, active-scene state and hardware capabilities. These are tactile textures, not spatial/directional vibrations (iPhone does not expose a directional 3D haptic array).

Engine creation/playback/stop/system errors use OathDiagnostics and the shared outbox. Reports contain no balance, account, wallet or selected timestamp. Unsupported hardware, normal interruptions, cancellation, empty history and gesture frames are expected and are not errors. The chart still works when haptics are unavailable.

Apple references checked against the installed SDK:
- https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics
- https://developer.apple.com/documentation/corehaptics/playing-a-single-tap-haptic-pattern
- https://developer.apple.com/documentation/swiftui/uiviewrepresentable
- https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizershouldbegin(_:)
- https://developer.apple.com/documentation/swiftui/view/accessibilityadjustableaction(_:)

## Code-first validation

```sh
swift test --package-path Packages/OathBalanceChart --scratch-path /tmp/oath-balance-chart-host-build --build-system native
swift test --package-path Packages/OathDatabase --scratch-path /tmp/oath-database-host-build --build-system native --filter 'BalanceHistoryTests|HiddenAssetValuationTests'
swiftc Packages/OathBalanceChart/Sources/OathBalanceChart/BalanceChartSeries.swift Packages/OathBalanceChart/Sources/OathBalanceChart/BalanceChartView.swift Tools/CheckBalanceChart.swift -o /tmp/check-oath-balance-chart
/tmp/check-oath-balance-chart
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics --scratch-path /tmp/oath-diagnostics-host-build --build-system native
python3 Tools/BuildiOS.py --configuration Release
```

The host renderer checks the production chart's colors, size and concealed output at three widths in both appearances. Its surrounding balance/buttons are illustrative, not a screenshot of the iOS app. Host tests cannot validate physical tactile feel or actual UIKit gesture arbitration on an iPhone.

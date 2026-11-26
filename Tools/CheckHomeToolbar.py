#!/usr/bin/env python3
"""Host regression for the production Home toolbar's measured scroll boundary."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'OathAtmosphere/Home/OathHomeHeaderSurface.swift').read_text()
state = source[source.index('@MainActor @Observable final class OathHomeToolbarBalanceState'):]
tests = r'''
import Foundation
import Observation
import os

@main struct Check {
    @MainActor static func main() {
        let state = OathHomeToolbarBalanceState()
        precondition(!state.showsBalance)
        state.scroll(to: -70)
        precondition(!state.showsBalance, "Do not guess the boundary before layout")
        state.measureBalanceBottom(70)
        precondition(state.showsBalance, "Late layout must use the latest scroll position")
        state.reset()
        precondition(!state.showsBalance, "A wallet/account switch restores its name")

        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = state.showsBalance } onChange: {
            changes.withLock { $0 += 1 }
        }
        for tick in 0..<10_000 {
            state.scroll(to: -CGFloat(tick) / 10_000 * 70)
            precondition(!state.showsBalance, "Partially visible balances retain the wallet name")
        }
        precondition(changes.withLock { $0 } == 0, "Scrolling must not invalidate the toolbar each frame")
        state.scroll(to: -70)
        precondition(state.showsBalance && changes.withLock { $0 } == 1)
        state.scroll(to: -3000)
        precondition(state.showsBalance, "Keep the amount when the native cell is recycled")
        state.scroll(to: -69.9)
        precondition(!state.showsBalance, "Restore the wallet name when any balance returns")
        state.scroll(to: 90)
        precondition(!state.showsBalance, "Pull-to-refresh must never show the compact balance")

        state.scroll(to: -80)
        precondition(state.showsBalance)
        state.measureBalanceBottom(95)
        precondition(!state.showsBalance, "Layout changes must update the real boundary")
        state.measureBalanceBottom(75)
        precondition(state.showsBalance)
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            state.scroll(to: invalid)
            state.measureBalanceBottom(invalid)
            precondition(state.showsBalance)
        }
        state.measureBalanceBottom(0)
        state.measureBalanceBottom(-1)
        precondition(state.showsBalance, "Ignore transient empty layout")
        state.reset()
        state.scroll(to: -74.9)
        precondition(!state.showsBalance)
        state.scroll(to: -75)
        precondition(state.showsBalance, "Reset must retain a valid unchanged layout measurement")
        print("PASS: complete/partial visibility, refresh, resize, recycled cells, wallet reset and 10,000 non-invalidating scroll updates")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='oath-home-toolbar-') as temporary:
    work = Path(temporary)
    file = work / 'Check.swift'
    file.write_text(tests + '\n' + state)
    executable = work / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(file), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

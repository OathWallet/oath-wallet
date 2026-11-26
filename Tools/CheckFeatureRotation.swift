import Foundation

@main
struct CheckFeatureRotation {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        let chains = OathFeatureRotation.receiveChains
        check(chains.count == 12, "Receive must showcase 12 chains")
        check(Set(chains).count == 12, "Each chain appears once per Receive sequence")
        check(chains.allSatisfy(\.isEnabled), "Only enabled chains may appear")
        check(Array(chains.prefix(3)) == [.bitcoin, .ethereum, .solana], "Requested first three chains")

        var rotation = OathFeatureRotation()
        let initial = rotation
        for _ in 0..<3 {
            for chain in chains {
                check(rotation.feature == .receive, "Receive stays until all chains finish")
                check(rotation.chain == chain, "Badge and name share the current chain identity")
                check(rotation.feature.title == .receive, "The Receive label remains unchanged")
                check(rotation.feature.dwell == .seconds(2.4), "Each chain gets a full dwell")
                rotation.advance()
            }
            for feature: OathFeatureRotation.Feature in [.send, .pay, .request, .multichain] {
                check(rotation.feature == feature, "Existing features follow Receive in order")
                check(rotation.chain == nil, "Receive badge must not leak into other features")
                check(rotation.feature.dwell > .zero, "Other features remain readable")
                rotation.advance()
            }
            check(rotation == initial, "Every complete cycle restarts with Receive Bitcoin")
        }
        print("PASS: \(checks) welcome feature rotation checks")
    }
}

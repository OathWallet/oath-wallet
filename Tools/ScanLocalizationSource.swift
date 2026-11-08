// Host-only syntax audit. Uses the SwiftSyntax shipped with the active Xcode.
import Foundation
import SwiftParser
import SwiftSyntax

struct SourceText: Codable {
    let file: String, line: Int, text: String, calls: [String], argument: String?, variable: String?
    let debugOnly: Bool, directUI: Bool
}
final class TextVisitor: SyntaxVisitor {
    let file: String, locations: SourceLocationConverter
    var records: [SourceText] = []
    init(file: String, tree: SourceFileSyntax) {
        self.file = file; locations = .init(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let text = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        var parent = node.parent, calls: [String] = [], argument: String?, variable: String?, debug = false
        var nearestCall: FunctionCallExprSyntax?
        var dataLiteral = false
        while let value = parent {
            if let arg = value.as(LabeledExprSyntax.self), nearestCall == nil, argument == nil { argument = arg.label?.text }
            if nearestCall == nil {
                if value.is(SubscriptCallExprSyntax.self) { dataLiteral = true }
                if let sequence = value.as(SequenceExprSyntax.self),
                   let ternary = sequence.elements.compactMap({ $0.as(UnresolvedTernaryExprSyntax.self) }).first,
                   node.endPosition <= ternary.questionMark.position { dataLiteral = true }
            }
            if let call = value.as(FunctionCallExprSyntax.self) {
                if nearestCall == nil { nearestCall = call }
                let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                    ?? call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    ?? String(call.calledExpression.trimmedDescription.prefix(120))
                if calls.count < 4 { calls.append(name) }
            }
            if let binding = value.as(PatternBindingSyntax.self), variable == nil { variable = String(binding.pattern.trimmedDescription.prefix(80)) }
            if let clause = value.as(IfConfigClauseSyntax.self),
               let condition = clause.condition?.trimmedDescription,
               condition == "DEBUG" || condition.hasPrefix("DEBUG &&") { debug = true }
            parent = value.parent
        }
        let name = calls.first ?? ""
        let textCalls: Set<String> = ["Text", "Label", "Button", "Toggle", "TextField", "SecureField", "Section", "navigationTitle", "navigationSubtitle", "accessibilityLabel", "accessibilityHint", "help", "confirmationDialog", "alert"]
        let uiLabel = (textCalls.contains(name) && (argument == nil || argument == "verbatim" || argument == "prompt")) ||
            (["OathSettingsRow", "OathEmptyState", "OathActionButton", "OathWCValue", "UIAlertAction", "UIAlertController", "UIAction"].contains(name) && ["title", "subtitle", "message"].contains(argument ?? ""))
        records.append(.init(file: file, line: locations.location(for: node.positionAfterSkippingLeadingTrivia).line,
            text: text, calls: calls, argument: argument, variable: variable, debugOnly: debug, directUI: uiLabel && !dataLiteral))
        return .visitChildren
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let paths = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n")
var records: [SourceText] = []
for path in paths {
    let file = String(path), tree = Parser.parse(source: try String(contentsOf: root.appendingPathComponent(String(path)), encoding: .utf8))
    let visitor = TextVisitor(file: file, tree: tree); visitor.walk(tree); records += visitor.records
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
try encoder.encode(records).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
print("Parsed \(paths.count) source files and \(records.count) literals")

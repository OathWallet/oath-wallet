import XCTest
@testable import OathAnkr

final class WalletConnectDisplayTests: XCTestCase {
    func testEverySuiInputAndCommandRetainsStructuredData() throws {
        let id = Data(repeating: 1, count: 32)
        let object = id + NearSendCrypto.le(UInt64(9)) + SuiBCS.vector(Data(repeating: 2, count: 32))
        var inputs = [Data([0]) + SuiBCS.vector(Data([42]))]
        inputs.append(Data([1,1]) + id + NearSendCrypto.le(UInt64(9)) + Data([1]))
        inputs.append(Data([1,0]) + object)
        inputs.append(Data([1,2]) + object)
        for source in 0...2 {
            var withdrawal = Data([2,0]) + NearSendCrypto.le(UInt64(17)) + Data([0,2,UInt8(source)])
            if source == 2 { withdrawal += id + id }
            inputs.append(withdrawal)
        }
        let argument = Data([1,0,0]), arguments = Data([1]) + argument
        let publish = Data([1]) + SuiBCS.vector(Data([0,97,115,109])) + Data([1]) + id
        var commands = [Data([0]) + id + SuiBCS.vector(Data("mod".utf8)) + SuiBCS.vector(Data("method".utf8)) + Data([0]) + arguments]
        commands.append(Data([1]) + arguments + argument)
        commands.append(Data([2,0]) + arguments)
        commands.append(Data([3,0]) + arguments)
        commands.append(Data([4]) + publish)
        commands.append(Data([5,0]) + arguments)
        commands.append(Data([6]) + publish + id + Data([0]))
        var bytes = Data([0,0,UInt8(inputs.count)]) + inputs.reduce(Data(), +)
        bytes += Data([UInt8(commands.count)]) + commands.reduce(Data(), +)
        bytes += id + Data([0]) + id + NearSendCrypto.le(UInt64(1)) + NearSendCrypto.le(UInt64(1000)) + Data([0])
        let tx = try WalletConnectSuiTransaction(bytes, network: .mainnet, account: "0x" + String(repeating: "01", count: 32), executing: false)
        let input = try XCTUnwrap(tx.displayData["inputs"].array)
        XCTAssertEqual(input.count, inputs.count)
        XCTAssertEqual(input[0]["Pure"].string, "Kg==")
        XCTAssertEqual(input[1]["SharedObject"]["initialSharedVersion"].string, "9")
        XCTAssertEqual(input[1]["SharedObject"]["mutable"], .bool(true))
        XCTAssertNotNil(input[2]["ImmOrOwnedObject"].string)
        XCTAssertNotNil(input[3]["Receiving"].string)
        for index in 4...6 { XCTAssertEqual(input[index]["FundsWithdrawal"]["amount"].string, "17") }
        XCTAssertEqual(input[4]["FundsWithdrawal"]["source"].string, "Sender")
        XCTAssertEqual(input[5]["FundsWithdrawal"]["source"].string, "Sponsor")
        XCTAssertEqual(input[6]["FundsWithdrawal"]["source"]["allowance"].string, "0x" + String(repeating: "01", count: 32))
        let output = try XCTUnwrap(tx.displayData["commands"].array)
        XCTAssertEqual(output.count, commands.count)
        XCTAssertTrue(output[0]["MoveCall"]["target"].string!.hasSuffix("::mod::method"))
        XCTAssertEqual(output[1]["TransferObjects"]["address"].string, "Input[0]")
        XCTAssertEqual(output[2]["SplitCoins"]["amounts"].string, "Input[0]")
        XCTAssertEqual(output[3]["MergeCoins"]["sources"].string, "Input[0]")
        XCTAssertEqual(output[4]["Publish"]["moduleHashes"].array?.count, 1)
        XCTAssertEqual(output[5]["MakeMoveVec"]["type"], .null)
        XCTAssertEqual(output[6]["Upgrade"]["ticket"].string, "GasCoin")
        XCTAssertEqual(output[6]["Upgrade"]["dependencies"].array?.count, 1)
        let data = try JSONEncoder().encode(tx.displayData)
        XCTAssertEqual(try JSONDecoder().decode(NearJSON.self, from: data), tx.displayData)
    }
}

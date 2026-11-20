import Foundation
import XCTest
@testable import MailMCP

final class MailboxTests: XCTestCase {
    func testCanonicalIDsDistinguishGenuineSameNameFolders() {
        let topLevel = Mailbox(account: "icloud", path: ["Uber"], object: .null())
        let nested = Mailbox(account: "icloud", path: ["Services", "Uber"], object: .null())
        let otherAccount = Mailbox(account: "work", path: ["Services", "Uber"], object: .null())
        let repeated = Mailbox(account: "icloud", path: ["Services", "Uber"], object: .null())
        XCTAssertNotEqual(topLevel.id, nested.id)
        XCTAssertNotEqual(nested.id, otherAccount.id)
        XCTAssertEqual(nested.id, repeated.id)
        XCTAssertEqual(try Arguments(values: ["mailbox": nested.json]).mailboxAddress("mailbox").mailboxID, nested.id)
    }
    func testReceiptMustIdentifyOneMessageByIDUnderExactDestination() {
        func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        func object(_ type: String, _ form: String, _ key: Descriptor, _ parent: Descriptor) -> Descriptor {
            let record = Descriptor.record()
            record.setDescriptor(Descriptor(typeCode: fourCC(type)), forKeyword: fourCC("want"))
            record.setDescriptor(Descriptor(enumCode: fourCC(form)), forKeyword: fourCC("form"))
            record.setDescriptor(key, forKeyword: fourCC("seld"))
            record.setDescriptor(parent, forKeyword: fourCC("from"))
            return record.coerce(toDescriptorType: fourCC("obj "))!
        }
        let box = object("mbxp", "name", Descriptor(string: "Archive"), .null())
        let other = object("mbxp", "name", Descriptor(string: "Inbox"), .null())
        let moved = object("mssg", "ID  ", Descriptor(int32: 71), box)
        let positional = object("mssg", "indx", Descriptor(int32: 1), box)
        XCTAssertEqual(Mail.receiptID(moved, destination: box), 71)
        XCTAssertNil(Mail.receiptID(moved, destination: other))
        XCTAssertNil(Mail.receiptID(positional, destination: box))
        XCTAssertNil(Mail.receiptID(.null(), destination: box))
        let list = Descriptor.list()
        list.insert(moved, at: 1)
        XCTAssertEqual(Mail.receiptID(list, destination: box), 71)
        list.insert(moved, at: 2)
        XCTAssertNil(Mail.receiptID(list, destination: box))
    }

}

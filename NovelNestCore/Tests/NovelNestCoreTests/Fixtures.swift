import Foundation
@testable import NovelNestCore

/// Synthetic sample prose written for these tests (not taken from any site).
enum Fixtures {
    static let simplified =
        "他走进院子的时候，天已经黑了。我们说好明天一起去城里看看，可是他一直没有回来。"
        + "这个问题让大家都很担心，没有人知道他到底去了哪里。"

    static let traditional =
        "他走進院子的時候，天已經黑了。我們說好明天一起去城裡看看，可是他一直沒有回來。"
        + "這個問題讓大家都很擔心，沒有人知道他到底去了哪裡。"

    static func encode(_ text: String, as encoding: TextEncoding) -> Data {
        text.data(using: encoding.stringEncoding)!
    }
}

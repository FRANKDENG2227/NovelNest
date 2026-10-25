import Foundation

public enum WebSourceError: Error, Equatable, LocalizedError {
    case unsupported([String])
    case missingRule(String)
    case invalidURL(String)
    /// A request or redirect left the source's own domains.
    case disallowedHost(String)
    /// 401/403 or a block page: the source is paused, never retried around (§9).
    case blocked(Int)
    case captcha
    /// 429/503; `retryAfter` from the header when given.
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case notText(String)
    case tooLarge
    case undecodable
    case unsafeRegex(String)
    case timedOut
    case emptyContent
    /// A source script threw or couldn't run.
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reasons): "书源不支持：\(reasons.joined(separator: "、"))"
        case .missingRule(let name): "书源缺少规则：\(name)"
        case .invalidURL(let url): "地址无效：\(url)"
        case .disallowedHost(let host): "跳转到了书源以外的网站：\(host)"
        case .blocked(let status): "网站拒绝访问（\(status)），已暂停这个书源"
        case .captcha: "网站要求验证，已暂停这个书源"
        case .rateLimited(let after):
            after.map { "请求太频繁，请 \(Int($0.rounded(.up))) 秒后再试" } ?? "请求太频繁，请稍后再试"
        case .httpStatus(let status): "网站返回错误 \(status)"
        case .notText(let type): "网站返回的不是文字（\(type)）"
        case .tooLarge: "网页太大"
        case .undecodable: "无法识别网页编码"
        case .unsafeRegex: "书源里的正则表达式不安全"
        case .timedOut: "网站响应超时"
        case .emptyContent: "没有找到正文"
        case .script(let message): "书源脚本出错：\(message)"
        }
    }
}

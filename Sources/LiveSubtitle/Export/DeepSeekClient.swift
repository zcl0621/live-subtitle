import Foundation

/// 调 DeepSeek 云 API(OpenAI 兼容)对转录做总结+优化,并自动生成 title。
struct DeepSeekClient {
    let apiKey: String

    struct Result: Sendable {
        let title: String
        let summary: String
    }

    enum DeepSeekError: Error {
        case missingKey
        case http(Int, String)
        case badResponse(String)
    }

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    private static let systemPrompt = """
    你是中文会议纪要助手。你会阅读一段中英混合的实时字幕转录,输出简洁准确的中文纪要,\
    并为这段内容起一个不超过20字的标题。\
    你必须只返回一个 JSON 对象,格式为 {"title":"...","summary":"..."},\
    其中 summary 使用 markdown 要点(bullet points)形式,不要输出 JSON 以外的任何内容。
    """

    // MARK: - Request/Response Codable

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct ResponseFormat: Encodable {
            let type: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let response_format: ResponseFormat
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct SummaryPayload: Decodable {
        let title: String
        let summary: String
    }

    /// 传入整段转录(中英混合),返回 { title, summary }。summary 为中文纪要式总结/优化。
    func summarize(transcript: String) async throws -> Result {
        guard !apiKey.isEmpty else { throw DeepSeekError.missingKey }

        let body = RequestBody(
            model: "deepseek-chat",
            messages: [
                RequestBody.Message(role: "system", content: Self.systemPrompt),
                RequestBody.Message(role: "user", content: transcript),
            ],
            temperature: 0.3,
            response_format: RequestBody.ResponseFormat(type: "json_object")
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30   // 避免半开网络下默认 60s 静默挂起
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.badResponse("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.http(http.statusCode, bodyString)
        }

        let decoder = JSONDecoder()
        let completion: ChatCompletionResponse
        do {
            completion = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.badResponse("顶层响应解析失败: \(raw)")
        }

        guard let content = completion.choices.first?.message.content else {
            throw DeepSeekError.badResponse("choices 为空")
        }

        guard let contentData = content.data(using: .utf8) else {
            throw DeepSeekError.badResponse("content 无法转为数据: \(content)")
        }

        let payload: SummaryPayload
        do {
            payload = try decoder.decode(SummaryPayload.self, from: contentData)
        } catch {
            throw DeepSeekError.badResponse("content JSON 解析失败: \(content)")
        }

        return Result(title: payload.title, summary: payload.summary)
    }
}

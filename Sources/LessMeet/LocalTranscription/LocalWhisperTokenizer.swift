// Word grouping is adapted from WhisperKit's WhisperTokenizerWrapper
// (1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4, Core/Models.swift).
// MIT License
// Copyright (c) 2024 argmax, inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import NaturalLanguage
import WhisperKit

struct LocalWhisperTokenizer: WhisperTokenizer {
    private let base: TokenizerWrapper
    let specialTokens = SpecialTokens(
        endToken: 50257, englishToken: 50259, noSpeechToken: 50363,
        noTimestampsToken: 50364, specialTokenBegin: 50257,
        startOfPreviousToken: 50362, startOfTranscriptToken: 50258,
        timeTokenBegin: 50365, transcribeToken: 50360, translateToken: 50359,
        whitespaceToken: 220
    )
    let allLanguageTokens = Set(50259...50358)

    // Order is the large-v3 vocabulary order, not Constants.languages dictionary order.
    static let languages = ("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi " +
        "he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn " +
        "et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu " +
        "am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue")
        .split(separator: " ").map(String.init)

    static var requiredTokens: [(String, Int)] {
        var pairs = [("Ġ", 220), ("<|endoftext|>", 50257), ("<|startoftranscript|>", 50258)]
        pairs += languages.enumerated().map { ("<|\($0.element)|>", 50259 + $0.offset) }
        pairs += [("<|translate|>", 50359), ("<|transcribe|>", 50360),
                  ("<|startoflm|>", 50361), ("<|startofprev|>", 50362),
                  ("<|nospeech|>", 50363), ("<|notimestamps|>", 50364)]
        for tick in 0...1500 {
            let hundredths = tick * 2
            let fraction = hundredths % 100
            pairs.append(("<|\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)|>", 50365 + tick))
        }
        return pairs
    }

    init(base: TokenizerWrapper) throws {
        try Self.validate(tokenToID: base.convertTokenToId, idToToken: base.convertIdToToken)
        guard base.decode(tokens: [220]) == " " else {
            throw LocalWhisperError.invalidTokenizer("whitespace decoding")
        }
        self.base = base
    }

    static func validate(tokenToID: (String) -> Int?, idToToken: (Int) -> String?) throws {
        for (token, id) in requiredTokens {
            guard tokenToID(token) == id, idToToken(id) == token else {
                throw LocalWhisperError.invalidTokenizer(token)
            }
        }
    }

    static func load(from directory: URL) async throws -> Self {
        try Task.checkCancellation()
        guard directory.isFileURL else { throw LocalWhisperError.localDirectoryRequired }
        // This overload only parses local files. Never use the pretrained overload
        // or ModelUtilities.loadTokenizer, which can fall back to the Hub.
        let parser = HubApiWrapper(downloadBase: directory, hfToken: "", endpoint: "http://127.0.0.1:9")
        let base = try await AutoTokenizerWrapper.from(modelFolder: directory, hubApi: parser)
        try Task.checkCancellation()
        return try Self(base: base)
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let text = decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage.flatMap {
            Locale(identifier: $0.rawValue).language.languageCode?.identifier
        }
        let noSpaces = ["zh", "ja", "th", "lo", "my", "yue"].contains(language)
        let pieces = unicodePieces(tokenIds)
        if noSpaces { return pieces }

        var words: [String] = []
        var groups: [[Int]] = []
        for (piece, tokens) in zip(pieces.words, pieces.wordTokens) {
            let special = tokens.contains { $0 >= specialTokens.specialTokenBegin }
            let beginsWhitespace = piece.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) ?? false
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuation = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            let previousSpecial = groups.last?.contains { $0 >= specialTokens.specialTokenBegin } ?? false
            if words.isEmpty || special || previousSpecial || beginsWhitespace || punctuation {
                words.append(piece)
                groups.append(tokens)
            } else {
                words[words.count - 1] += piece
                groups[groups.count - 1] += tokens
            }
        }
        return (words, groups)
    }

    private func unicodePieces(_ tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let full = Array(decode(tokens: tokens).unicodeScalars)
        var offset = 0
        var pending: [Int] = []
        var words: [String] = []
        var groups: [[Int]] = []
        for (tokenIndex, token) in tokens.enumerated() {
            pending.append(token)
            let decoded = decode(tokens: pending)
            let scalars = Array(decoded.unicodeScalars)
            // U+FFFD can be literal text or an incomplete UTF-8 token. Compare
            // scalar offsets in the full decode, never indices from another String.
            let incomplete = scalars.enumerated().contains { index, scalar in
                scalar.value == 0xfffd && (offset + index >= full.count || full[offset + index].value != 0xfffd)
            }
            // A literal U+FFFD can itself span several byte tokens. A boundary
            // is safe only when separately decoding the suffix preserves it.
            let splitsReplacement = scalars.contains { $0.value == 0xfffd } &&
                Array((decoded + decode(tokens: Array(tokens.dropFirst(tokenIndex + 1)))).unicodeScalars) !=
                Array(full.dropFirst(offset))
            if !incomplete && !splitsReplacement {
                words.append(decoded)
                groups.append(pending)
                pending.removeAll(keepingCapacity: true)
                offset += scalars.count
            }
        }
        if !pending.isEmpty {
            words.append(decode(tokens: pending))
            groups.append(pending)
        }
        return (words, groups)
    }
}

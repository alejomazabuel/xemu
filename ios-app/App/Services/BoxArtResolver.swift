import Foundation

struct BoxArtResolver {
  private static let baseURL = URL(string: "https://raw.githubusercontent.com/izzy2lost/X1_Covers/main/")!
  private static let titleStopWords: Set<String> = ["the", "a", "an", "and", "of", "for", "in", "on", "to"]
  private static let lookupState = LookupState()

  func url(for game: GameEntry, enabled: Bool) -> URL? {
    guard enabled else {
      return nil
    }

    return Self.lookupState.url(for: game.title)
  }
}

private final class LookupState {
  private struct CoverEntry {
    let collapsed: String
    let tokens: Set<String>
    let numericTokens: Set<String>
    let url: URL
  }

  private struct CoverIndex {
    var exact: [String: URL] = [:]
    var collapsed: [String: URL] = [:]
    var entries: [CoverEntry] = []
  }

  private let lock = NSLock()
  private lazy var index: CoverIndex = loadIndex()
  private var resolvedURLs: [String: URL] = [:]
  private var misses = Set<String>()

  func url(for title: String) -> URL? {
    let cleanTitle = normalizeLookupTitle(title)
    let normalizedTitle = normalizeCoverKey(cleanTitle)
    guard !normalizedTitle.isEmpty else {
      return nil
    }

    lock.lock()
    if let cached = resolvedURLs[normalizedTitle] {
      lock.unlock()
      return cached
    }
    if misses.contains(normalizedTitle) {
      lock.unlock()
      return nil
    }
    lock.unlock()

    var candidates = Set<String>()
    addCoverLookupCandidates(&candidates, raw: title)
    addCoverLookupCandidates(&candidates, raw: cleanTitle)
    addCoverLookupCandidates(&candidates, raw: cleanTitle.replacingOccurrences(of: ":", with: ""))
    addCoverLookupCandidates(&candidates, raw: cleanTitle.components(separatedBy: " - ").first ?? cleanTitle)
    addCoverLookupCandidates(&candidates, raw: cleanTitle.components(separatedBy: ":").first ?? cleanTitle)

    let loadedIndex = index
    for key in candidates {
      if let found = loadedIndex.exact[key] {
        remember(found, for: normalizedTitle)
        return found
      }
    }

    for key in candidates {
      let collapsedKey = collapseCoverKey(key)
      guard !collapsedKey.isEmpty else {
        continue
      }
      if let found = loadedIndex.collapsed[collapsedKey] {
        remember(found, for: normalizedTitle)
        return found
      }
    }

    if let fuzzyMatch = findClosestCoverURL(candidates: candidates, entries: loadedIndex.entries) {
      remember(fuzzyMatch, for: normalizedTitle)
      return fuzzyMatch
    }

    lock.lock()
    misses.insert(normalizedTitle)
    lock.unlock()
    return nil
  }

  private func remember(_ url: URL, for normalizedTitle: String) {
    lock.lock()
    resolvedURLs[normalizedTitle] = url
    lock.unlock()
  }

  private func loadIndex() -> CoverIndex {
    guard let sourceURL = Bundle.main.url(forResource: "X1_Covers", withExtension: "txt"),
          let contents = try? String(contentsOf: sourceURL, encoding: .utf8) else {
      return CoverIndex()
    }

    var exactIndex: [String: URL] = [:]
    var collapsedIndex: [String: URL] = [:]
    var entries: [CoverEntry] = []
    var seenEntries = Set<String>()

    for rawLine in contents.components(separatedBy: .newlines) {
      let fileName = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !fileName.isEmpty,
            fileName.lowercased().hasSuffix(".png"),
            let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: BoxArtResolver.baseURL.absoluteString + encodedName) else {
        continue
      }

      let gameName = String(fileName.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
      let exactKey = normalizeCoverKey(gameName)
      let strippedKey = stripTrailingRegion(exactKey)
      if !exactKey.isEmpty {
        exactIndex[exactKey] = exactIndex[exactKey] ?? url
      }
      if !strippedKey.isEmpty {
        exactIndex[strippedKey] = exactIndex[strippedKey] ?? url
      }

      let canonical = strippedKey.isEmpty ? exactKey : strippedKey
      let collapsedKey = collapseCoverKey(canonical)
      if !collapsedKey.isEmpty {
        collapsedIndex[collapsedKey] = collapsedIndex[collapsedKey] ?? url
      }

      if !canonical.isEmpty && seenEntries.insert("\(canonical)|\(url.absoluteString)").inserted {
        let tokens = tokenizeCoverKey(canonical)
        entries.append(
          CoverEntry(
            collapsed: collapsedKey,
            tokens: tokens,
            numericTokens: Set(tokens.filter { token in token.contains(where: { $0.isNumber }) }),
            url: url
          )
        )
      }
    }

    return CoverIndex(exact: exactIndex, collapsed: collapsedIndex, entries: entries)
  }

  private func addCoverLookupCandidates(_ candidates: inout Set<String>, raw: String) {
    let normalized = normalizeCoverKey(raw)
    guard !normalized.isEmpty else {
      return
    }
    candidates.insert(normalized)
    candidates.insert(stripTrailingRegion(normalized))
  }

  private func normalizeLookupTitle(_ input: String) -> String {
    input
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeCoverKey(_ input: String) -> String {
    input
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "Ã¢â‚¬â„¢", with: "'")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  private func stripTrailingRegion(_ input: String) -> String {
    input
      .replacingOccurrences(of: #"\s*\([^\)]*\)\s*$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func collapseCoverKey(_ input: String) -> String {
    normalizeCoverKey(input)
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
  }

  private func tokenizeCoverKey(_ input: String) -> Set<String> {
    Set(
      normalizeCoverKey(input)
        .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)
        .filter { $0.count >= 2 }
        .filter { !BoxArtResolver.titleStopWords.contains($0) }
    )
  }

  private func findClosestCoverURL(candidates: Set<String>, entries: [CoverEntry]) -> URL? {
    var bestURL: URL?
    var bestScore = 0

    for candidate in candidates {
      let collapsedCandidate = collapseCoverKey(candidate)
      let tokens = tokenizeCoverKey(candidate)
      guard !collapsedCandidate.isEmpty, !tokens.isEmpty else {
        continue
      }
      let numericTokens = Set(tokens.filter { token in token.contains(where: { $0.isNumber }) })
      for entry in entries {
        let score = scoreCoverMatch(
          candidateCollapsed: collapsedCandidate,
          candidateTokens: tokens,
          candidateNumericTokens: numericTokens,
          entry: entry
        )
        if score > bestScore {
          bestScore = score
          bestURL = entry.url
        }
      }
    }

    return bestScore >= 55 ? bestURL : nil
  }

  private func scoreCoverMatch(
    candidateCollapsed: String,
    candidateTokens: Set<String>,
    candidateNumericTokens: Set<String>,
    entry: CoverEntry
  ) -> Int {
    if candidateCollapsed == entry.collapsed {
      return 100
    }

    if !candidateNumericTokens.isEmpty,
       !entry.numericTokens.isEmpty,
       candidateNumericTokens != entry.numericTokens {
      return 0
    }

    let overlapCount = candidateTokens.filter { entry.tokens.contains($0) }.count
    if overlapCount == 0 {
      return 0
    }

    let maxTokenCount = max(candidateTokens.count, entry.tokens.count)
    var score = (overlapCount * 70) / maxTokenCount

    if candidateCollapsed.contains(entry.collapsed) || entry.collapsed.contains(candidateCollapsed) {
      score += 20
    }

    let lengthDelta = abs(candidateCollapsed.count - entry.collapsed.count)
    if lengthDelta <= 4 {
      score += 10
    } else if lengthDelta <= 10 {
      score += 5
    }

    return score
  }
}

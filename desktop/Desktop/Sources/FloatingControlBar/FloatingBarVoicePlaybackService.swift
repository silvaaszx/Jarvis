import AVFoundation
import Foundation

@MainActor
final class FloatingBarVoicePlaybackService: NSObject, AVAudioPlayerDelegate {
  static let shared = FloatingBarVoicePlaybackService()

  static let devVoiceIDDefaultsKey = "dev_elevenlabs_voice_id"

  nonisolated private static let defaultVoiceID = "IRHApOXLvnW57QJPQH2P"  // Jarvis
  nonisolated private static let defaultModelID = "eleven_turbo_v2_5"
  static let devFishAudioReferenceIDDefaultsKey = "dev_fish_audio_reference_id"
  nonisolated private static let defaultFishAudioReferenceID = ""  // set via UserDefaults or FISH_AUDIO_REFERENCE_ID env var
  // First chunk stays small so playback starts fast.
  nonisolated private static let firstChunkMinimumLength = 40
  nonisolated private static let firstChunkPreferredLength = 120
  nonisolated private static let firstChunkEmergencyLength = 200
  // Follow-up chunks are much larger so the response is stitched from fewer
  // ElevenLabs MP3s. Each chunk boundary carries leading/trailing silence, so
  // fewer chunks means far less perceived pausing between sentences and
  // paragraphs of a long answer.
  nonisolated private static let followupChunkMinimumLength = 320
  nonisolated private static let followupChunkPreferredLength = 520
  nonisolated private static let followupChunkEmergencyLength = 800
  private var playbackRate: Float { ShortcutSettings.shared.voicePlaybackSpeed }

  nonisolated private static let voiceSampleText = "Hey, how is it going?"

  nonisolated private static let fillerPhrases: [String] = [
    "Let me check.",
    "One moment.",
    "Looking into it.",
    "Let me see.",
    "Checking now.",
    "Hold on.",
    "One sec.",
    "Working on it.",
  ]
  nonisolated private static let fillerPhrasesPT: [String] = [
    "Deixa eu ver.",
    "Um momento.",
    "Verificando.",
    "Já vejo isso.",
    "Aguarde.",
    "Um segundo.",
    "Processando.",
    "Vou verificar.",
  ]

  private var playbackTask: Task<Void, Never>?
  private var fillerTask: Task<Void, Never>?
  private var currentMode: PlaybackMode?
  private var currentResponseID: String?
  private var interruptedResponseID: String?
  private var shouldInterruptNextResponse = false
  private var streamedText = ""
  private var bufferedText = ""
  private var synthesisQueue: [String] = []
  private var audioQueue: [Data] = []
  private var isSynthesizing = false
  private var hasStartedRealPlayback = false
  private var hasEmittedFirstChunk = false
  private var audioPlayer: AVAudioPlayer?
  private let speechSynthesizer = AVSpeechSynthesizer()

  private override init() {}

  var isSpeaking: Bool {
    if audioPlayer?.isPlaying == true { return true }
    if speechSynthesizer.isSpeaking { return true }
    if fillerTask != nil || playbackTask != nil { return true }
    if isSynthesizing { return true }
    return !audioQueue.isEmpty || !synthesisQueue.isEmpty
  }

  func playFillerIfEnabled() {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }

    if currentMode == nil {
      currentMode = resolvePlaybackMode()
    }
    guard let mode = currentMode else { return }
    if case .systemFallback = mode { return }

    hasStartedRealPlayback = false

    switch mode {
    case .elevenLabs(let voiceID):
      let phrase = Self.fillerPhrases.randomElement()!
      fillerTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeSpeech(text: phrase, voiceID: voiceID)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self, !self.hasStartedRealPlayback else { return }
            self.startPlayback(audioData)
          }
        } catch {}
      }
    case .fishAudio(let referenceID):
      let phrase = Self.fillerPhrasesPT.randomElement()!
      fillerTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeSpeechFishAudio(text: phrase, referenceID: referenceID)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self, !self.hasStartedRealPlayback else { return }
            self.startPlayback(audioData)
          }
        } catch {}
      }
    case .systemFallback:
      break
    }
  }

  func playResponseIfEnabled(_ message: ChatMessage?) {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }
    updateStreamingResponseIfEnabled(message, isFinal: true)
  }

  func updateStreamingResponseIfEnabled(_ message: ChatMessage?, isFinal: Bool) {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }
    guard let message else { return }

    if currentResponseID != message.id {
      resetPlaybackPipeline(clearMode: false)
      currentResponseID = message.id
      interruptedResponseID = shouldInterruptNextResponse ? message.id : nil
      shouldInterruptNextResponse = false
    }

    let text = Self.cleanedPlaybackText(from: message)
    guard !text.isEmpty, Self.shouldSpeak(text) else { return }

    if interruptedResponseID == message.id {
      streamedText = text
      bufferedText = ""
      return
    }

    if currentMode == nil {
      currentMode = resolvePlaybackMode()
    }

    guard let mode = currentMode else {
      return
    }

    if !text.hasPrefix(streamedText) {
      streamedText = ""
      bufferedText = ""
      synthesisQueue.removeAll()
      audioQueue.removeAll()
    }

    // Cancel filler and stop filler audio when first real chunk is ready
    if !hasStartedRealPlayback && text.count > 0 {
      hasStartedRealPlayback = true
      fillerTask?.cancel()
      fillerTask = nil
      audioPlayer?.stop()
      audioPlayer = nil
      speechSynthesizer.stopSpeaking(at: .immediate)
    }

    if text.count > streamedText.count {
      let newText = String(text.dropFirst(streamedText.count))
      streamedText = text
      bufferedText += newText
      drainBufferedText(isFinal: isFinal, mode: mode)
    } else if isFinal {
      drainBufferedText(isFinal: true, mode: mode)
    }
  }

  private func resolvePlaybackMode() -> PlaybackMode {
    // TTS is now proxied through the backend — no client-side API key needed.
    // Fall back to system voice only if the backend URL is not configured.
    guard getenv("OMI_API_URL") != nil else {
      return .systemFallback
    }
    // Use Fish Audio whenever key + reference ID are configured (Jarvis default TTS)
    let fishKey = getenv("FISH_AUDIO_API_KEY").flatMap { String(validatingUTF8: $0) } ?? ""
    let fishRefID = UserDefaults.standard.string(forKey: Self.devFishAudioReferenceIDDefaultsKey)
      ?? getenv("FISH_AUDIO_REFERENCE_ID").flatMap { String(validatingUTF8: $0) }
      ?? Self.defaultFishAudioReferenceID
    if !fishKey.isEmpty && !fishRefID.isEmpty {
      return .fishAudio(referenceID: fishRefID)
    }
    let voiceID = ShortcutSettings.shared.selectedVoiceID
    let resolvedVoiceID = voiceID.isEmpty ? Self.defaultVoiceID : voiceID
    return .elevenLabs(voiceID: resolvedVoiceID)
  }

  private func drainBufferedText(isFinal: Bool, mode: PlaybackMode) {
    while let boundary = Self.nextChunkBoundary(
      in: bufferedText, isFinal: isFinal, isFirstChunk: !hasEmittedFirstChunk)
    {
      let chunk = String(bufferedText[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
      bufferedText = String(bufferedText[boundary...]).trimmingCharacters(
        in: .whitespacesAndNewlines)

      guard !chunk.isEmpty, Self.shouldSpeak(chunk) else { continue }
      hasEmittedFirstChunk = true
      enqueueChunk(chunk, mode: mode)
    }
  }

  private func enqueueChunk(_ text: String, mode: PlaybackMode) {
    switch mode {
    case .systemFallback:
      enqueueSystemSpeech(text)
    case .elevenLabs, .fishAudio:
      synthesisQueue.append(text)
      startSynthesisIfNeeded(mode: mode)
    }
  }

  private func startSynthesisIfNeeded(mode: PlaybackMode) {
    guard !isSynthesizing else { return }
    guard !synthesisQueue.isEmpty else { return }

    switch mode {
    case .systemFallback:
      return
    case .elevenLabs(let voiceID):
      let text = synthesisQueue.removeFirst()
      isSynthesizing = true
      playbackTask?.cancel()
      playbackTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeSpeech(text: text, voiceID: voiceID)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            self.audioQueue.append(audioData)
            self.startPlaybackIfNeeded()
            self.startSynthesisIfNeeded(mode: mode)
          }
        } catch is CancellationError {
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            self.startSynthesisIfNeeded(mode: mode)
          }
        } catch {
          if Self.isCancellation(error) {
            await MainActor.run {
              guard let self else { return }
              self.isSynthesizing = false
              self.startSynthesisIfNeeded(mode: mode)
            }
            return
          }
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            log("FloatingBarVoicePlaybackService: ElevenLabs chunk synthesis failed, falling back to system voice: \(error.localizedDescription)")
            self.enqueueSystemSpeech(text)
            self.startSynthesisIfNeeded(mode: mode)
          }
        }
      }
    case .fishAudio(let referenceID):
      let text = synthesisQueue.removeFirst()
      isSynthesizing = true
      playbackTask?.cancel()
      playbackTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeSpeechFishAudio(text: text, referenceID: referenceID)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            self.audioQueue.append(audioData)
            self.startPlaybackIfNeeded()
            self.startSynthesisIfNeeded(mode: mode)
          }
        } catch is CancellationError {
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            self.startSynthesisIfNeeded(mode: mode)
          }
        } catch {
          if Self.isCancellation(error) {
            await MainActor.run {
              guard let self else { return }
              self.isSynthesizing = false
              self.startSynthesisIfNeeded(mode: mode)
            }
            return
          }
          await MainActor.run {
            guard let self else { return }
            self.isSynthesizing = false
            log("FloatingBarVoicePlaybackService: Fish Audio chunk synthesis failed, falling back to system voice: \(error.localizedDescription)")
            self.enqueueSystemSpeech(text)
            self.startSynthesisIfNeeded(mode: mode)
          }
        }
      }
    }
  }

  func stop() {
    resetPlaybackPipeline(clearMode: true)
    currentResponseID = nil
    interruptedResponseID = nil
    shouldInterruptNextResponse = false
  }

  /// Play a short preview of the given ElevenLabs voice so the user can hear it
  /// when switching voices in settings.
  func playVoiceSample(voiceID: String) {
    resetPlaybackPipeline(clearMode: true)
    currentResponseID = nil
    interruptedResponseID = nil
    shouldInterruptNextResponse = false

    let phrase = Self.voiceSampleText

    // Without the backend URL the service falls back to the system voice, which
    // wouldn't demo the ElevenLabs voice anyway.
    guard getenv("OMI_API_URL") != nil else {
      enqueueSystemSpeech(phrase)
      return
    }

    playbackTask = Task { [weak self] in
      do {
        let audioData = try await Self.synthesizeSpeech(text: phrase, voiceID: voiceID)
        try Task.checkCancellation()
        await MainActor.run {
          guard let self else { return }
          self.startPlayback(audioData)
        }
      } catch is CancellationError {
        return
      } catch {
        if Self.isCancellation(error) { return }
        log(
          "FloatingBarVoicePlaybackService: voice sample failed: \(error.localizedDescription)"
        )
      }
    }
  }

  func interruptCurrentResponse() {
    if let currentResponseID {
      interruptedResponseID = currentResponseID
      shouldInterruptNextResponse = false
    } else {
      shouldInterruptNextResponse = true
    }
    resetPlaybackPipeline(clearMode: false)
  }

  private func startPlaybackIfNeeded() {
    guard audioPlayer == nil else { return }
    guard !audioQueue.isEmpty else { return }
    startPlayback(audioQueue.removeFirst())
  }

  private func startPlayback(_ data: Data) {
    do {
      let player = try AVAudioPlayer(data: data)
      player.delegate = self
      player.enableRate = true
      player.rate = playbackRate
      player.prepareToPlay()
      player.play()
      audioPlayer = player
    } catch {
      log(
        "FloatingBarVoicePlaybackService: could not start audio playback: \(error.localizedDescription)"
      )
    }
  }

  private func enqueueSystemSpeech(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = 0.47
    utterance.pitchMultiplier = 1.02
    utterance.volume = 1.0
    utterance.voice = preferredSystemVoice()
    speechSynthesizer.speak(utterance)
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.audioPlayer = nil
      self.startPlaybackIfNeeded()
    }
  }

  private func resetPlaybackPipeline(clearMode: Bool) {
    playbackTask?.cancel()
    playbackTask = nil
    fillerTask?.cancel()
    fillerTask = nil
    if clearMode {
      currentMode = nil
    }
    streamedText = ""
    bufferedText = ""
    synthesisQueue.removeAll()
    audioQueue.removeAll()
    isSynthesizing = false
    hasStartedRealPlayback = false
    hasEmittedFirstChunk = false
    audioPlayer?.stop()
    audioPlayer = nil
    speechSynthesizer.stopSpeaking(at: .immediate)
  }

  private func preferredSystemVoice() -> AVSpeechSynthesisVoice? {
    let preferredNames = ["Ava", "Allison", "Samantha", "Karen", "Moira"]
    for name in preferredNames {
      if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: {
        $0.name.localizedCaseInsensitiveContains(name)
      }) {
        return voice
      }
    }
    return AVSpeechSynthesisVoice(language: "en-US")
  }

  /// Synthesize speech via Fish Audio API (used for Portuguese / PT-BR).
  private nonisolated static func synthesizeSpeechFishAudio(text: String, referenceID: String)
    async throws -> Data
  {
    let apiKey = UserDefaults.standard.string(forKey: "dev_fish_audio_api_key")
      ?? getenv("FISH_AUDIO_API_KEY").flatMap { String(validatingUTF8: $0) }
      ?? ""
    guard !apiKey.isEmpty else {
      throw FloatingBarVoicePlaybackError.requestFailed(statusCode: 0, body: "Fish Audio API key not configured")
    }
    let url = URL(string: "https://api.fish.audio/v1/tts")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/msgpack", forHTTPHeaderField: "Content-Type")
    request.httpBody = encodeMsgpackTTSRequest(text: text, referenceID: referenceID)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      let body = String(data: data, encoding: .utf8) ?? ""
      throw FloatingBarVoicePlaybackError.requestFailed(statusCode: statusCode, body: body)
    }
    return data
  }

  /// Encode a Fish Audio TTS request as MessagePack.
  /// Produces: { "text": text, "reference_id": referenceID, "format": "mp3", "streaming": false }
  private nonisolated static func encodeMsgpackTTSRequest(text: String, referenceID: String) -> Data {
    var buf = Data()
    buf.append(0x84)  // fixmap, 4 fields
    appendMsgpackStr(&buf, "text");           appendMsgpackStr(&buf, text)
    appendMsgpackStr(&buf, "reference_id");   appendMsgpackStr(&buf, referenceID)
    appendMsgpackStr(&buf, "format");         appendMsgpackStr(&buf, "mp3")
    appendMsgpackStr(&buf, "streaming");      buf.append(0xc2)  // false
    return buf
  }

  private nonisolated static func appendMsgpackStr(_ buf: inout Data, _ str: String) {
    let bytes = Array(str.utf8)
    let count = bytes.count
    if count <= 31 {
      buf.append(UInt8(0xa0 | count))
    } else if count <= 255 {
      buf.append(0xd9); buf.append(UInt8(count))
    } else {
      buf.append(0xda); buf.append(UInt8(count >> 8)); buf.append(UInt8(count & 0xff))
    }
    buf.append(contentsOf: bytes)
  }

  /// Synthesize speech via the backend TTS proxy (ElevenLabs key stays server-side).
  private nonisolated static func synthesizeSpeech(text: String, voiceID: String)
    async throws -> Data
  {
    let request = APIClient.TtsSynthesizeRequest(
      text: text,
      voiceId: voiceID,
      modelId: defaultModelID,
      outputFormat: "mp3_44100_128",
      voiceSettings: .init(
        stability: 0.34,
        similarityBoost: 0.88,
        style: 0.12,
        useSpeakerBoost: true
      )
    )
    return try await APIClient.shared.synthesizeSpeech(request: request)
  }

  private nonisolated static func cleanedPlaybackText(from message: ChatMessage?) -> String {
    guard let message else { return "" }

    let baseText: String
    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      baseText = message.text
    } else {
      baseText = message.contentBlocks.compactMap { block in
        switch block {
        case .text(_, let text):
          return text
        case .discoveryCard(_, let title, let summary, _):
          return "\(title). \(summary)"
        case .toolCall, .thinking:
          return nil
        }
      }.joined(separator: "\n\n")
    }

    let collapsedWhitespace = baseText.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private nonisolated static func shouldSpeak(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    if lowercased == "failed to get a response. please try again." {
      return false
    }
    if lowercased.hasPrefix("⚠️") || lowercased.hasPrefix("warning:") {
      return false
    }
    return true
  }

  private nonisolated static func nextChunkBoundary(
    in text: String, isFinal: Bool, isFirstChunk: Bool
  ) -> String.Index? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if isFinal {
      return text.endIndex
    }

    let minLength = isFirstChunk ? firstChunkMinimumLength : followupChunkMinimumLength
    let preferredLength =
      isFirstChunk ? firstChunkPreferredLength : followupChunkPreferredLength
    let emergencyLength =
      isFirstChunk ? firstChunkEmergencyLength : followupChunkEmergencyLength

    guard text.count >= minLength else { return nil }

    let preferredLimit = text.index(
      text.startIndex, offsetBy: min(text.count, preferredLength))
    let preferredSlice = text[..<preferredLimit]

    if let punctuationIndex = preferredSlice.lastIndex(where: { ".!?\n".contains($0) }) {
      return text.index(after: punctuationIndex)
    }

    guard text.count >= preferredLength else { return nil }

    let emergencyLimit = text.index(
      text.startIndex, offsetBy: min(text.count, emergencyLength))
    let emergencySlice = text[..<emergencyLimit]

    if let punctuationIndex = emergencySlice.lastIndex(where: { ".!?\n".contains($0) }) {
      return text.index(after: punctuationIndex)
    }

    guard text.count >= emergencyLength else { return nil }

    if let clauseIndex = emergencySlice.lastIndex(where: { ",;:\n".contains($0) }) {
      return text.index(after: clauseIndex)
    }

    if let whitespaceIndex = emergencySlice.lastIndex(where: \.isWhitespace) {
      return whitespaceIndex
    }

    return emergencyLimit
  }

  private nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return true
    }

    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }

    return false
  }
}

private enum PlaybackMode {
  case elevenLabs(voiceID: String)
  case fishAudio(referenceID: String)
  case systemFallback
}

private enum FloatingBarVoicePlaybackError: LocalizedError {
  case invalidResponse
  case requestFailed(statusCode: Int, body: String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Invalid TTS response"
    case .requestFailed(let statusCode, let body):
      return "TTS request failed (\(statusCode)): \(body)"
  }
}
}

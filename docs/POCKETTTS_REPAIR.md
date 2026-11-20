> Historique : ce document décrit l’intégration ONNX antérieure, remplacée par FluidAudio.

# PocketTTS French repair (#12)

The previous integration passed bundle.json as both tokenizer dictionaries and
omitted french_24l's required BOS row before the reference voice embedding.
Even with the dictionaries corrected, the stock encoder yielded a truncated
1.39-second sample. The French encoder adapter prepends the pinned 1×1×1024
BOS tensor to its output. The original encoder's SHA256 is required before
adaptation; its bytes are preserved. The cache is an atomic, versioned file.
The model and presets remain local; no server synthesis or voice change.

Resources: KevinAHM/pocket-tts-onnx@58a6d00cf13d239b6748cb0769f35c580a8f606c,
onnx/french_24l/tokenizer.model and bos_before_voice.npy. Dictionaries follow
sherpa's convert_tokenizer.py (SentencePiece IDs and scores). Flow uses 8 steps
and 8 frames after EOS, matching the French bundle's tail recommendation.

WAV encoding now declares PCM16 (format 1), not Float32 (format 3). Nonfinite
samples are rejected. The player checks start failures, cancels old playback,
and ignores stale delegate callbacks. Preview uses a playback-only session and
shows errors in a centered alert with an explicit iOS voice action. Assistant
speech falls back to iOS on synthesis failures, but never on cancellation.

Real synthesis probe: sherpa-onnx 2.0.1 on Mac, pinned Estelle reference,
French int8 files, same tokenizer and BOS. Independent Whisper transcription
used only synthetic generated speech, not user recordings. Mac inference is
not proof of iPhone microphone, speaker, Siri or Bluetooth behavior.

Validation: 418 XCTest passed locally, zero failures, including opt-in real
French inference inside the Swift/iOS simulator test host. Set
`TEST_RUNNER_EUDES_POCKET_FIXTURES=/path/to/public/fixtures` before
`tools/test-ios.sh`; other environments explicitly skip that integration test.
Fixtures: the six pinned model files and Estelle's public reference `estelle.wav`.
No fixtures are downloaded by tests. The suite includes an AVFoundation round
trip of encoded PCM16 and packaged tokenizer/BOS validation.

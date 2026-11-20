import CoreML
import Foundation

/// Eudes's offline runner for the pinned v2.1/french_24l IO-cache export.
/// Core ML objects stay on this actor; only PCM crosses to the audio/UI actor.
actor PocketCoreMLEngine {
    enum Variant: Sendable { case french24, french6 }
    enum ExecutionMode: Sendable { case foreground, background }
    private let executionMode: ExecutionMode
    private let directory: URL
    private let variant: Variant
    private var models: Models?
    private var generating = false

    init(directory: URL, variant: Variant = .french24, executionMode: ExecutionMode = .foreground) {
        self.directory = directory
        self.variant = variant
        self.executionMode = executionMode
    }

    private struct Models {
        let prefill: MLModel
        let language: MLModel
        let flow: MLModel
        let mimi: MLModel
        let prefillKeys: PocketCoreMLLayerKeys
        let languageKeys: PocketCoreMLLayerKeys
        let mimiKeys: PocketCoreMLMimiKeys
        let tokenizer: PocketSentencePieceTokenizer
        let embeddings: [Float]
        let bos: [Float]

        init(directory: URL, variant: Variant, executionMode: ExecutionMode) throws {
            func load(_ name: String) throws -> MLModel {
                try Task.checkCancellation()
                let configuration = MLModelConfiguration()
                // The rank-5 export uses a NaN BOS sentinel. Keep it off ANE,
                // whose conversion of NaNs can break the first generation step.
                configuration.computeUnits = executionMode == .background ? .cpuOnly : .cpuAndGPU
                return try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"),
                                   configuration: configuration)
            }
            let isSix = variant == .french6
            prefill = try load(isSix ? "cond_prefill_ane" : "cond_prefill")
            language = try load(isSix ? "flowlm_step_ane" : "flowlm_stepv2")
            flow = try load("flow_decoder_fused")
            mimi = try load("mimi_decoder")
            if isSix {
                prefillKeys = PocketCoreMLLayerKeys.aneKeys(layers: 6, kind: .condStep)
                languageKeys = PocketCoreMLLayerKeys.aneKeys(layers: 6, kind: .flowlmStep)
                for (model, keys) in [(prefill, prefillKeys), (language, languageKeys)] {
                    guard let vs = keys.vCacheKeys,
                          (keys.cacheKeys + vs + keys.positionKeys).allSatisfy({ model.modelDescription.outputDescriptionsByName[$0] != nil }) else {
                        throw PocketCoreMLError.invalidModel
                    }
                }
            } else {
                prefillKeys = try PocketCoreMLLayerKeys.discover(from: prefill, kind: .condStep,
                                                               expectedLayers: 24, modelName: "cond_prefill")
                languageKeys = try PocketCoreMLLayerKeys.discover(from: language, kind: .flowlmStep,
                                                                expectedLayers: 24, modelName: "flowlm_stepv2")
            }
            mimiKeys = try PocketCoreMLMimiKeys.discover(from: mimi)
            guard mimiKeys.stateMapping.count == mimiKeys.stateShapes.count else {
                throw PocketCoreMLError.invalidModel
            }
            let constants = directory.appendingPathComponent("constants_bin")
            tokenizer = try PocketSentencePieceTokenizer(modelData: Data(contentsOf: constants.appendingPathComponent("tokenizer.model")))
            embeddings = try PocketCoreMLTensor.floats(Data(contentsOf: constants.appendingPathComponent("text_embed_table.bin")))
            bos = try PocketCoreMLTensor.floats(Data(contentsOf: constants.appendingPathComponent("bos_emb.bin")))
            guard !embeddings.isEmpty, embeddings.count % 1024 == 0, bos.count == 32 else {
                throw PocketCoreMLError.invalidModel
            }
        }
    }

    func synthesize(text: String, voice: String,
                    onSamples: @Sendable ([Float]) async -> Void) async throws -> PocketTTSAudio {
        guard !generating else { throw PocketCoreMLError.busy }
        generating = true
        defer { generating = false }
        try Task.checkCancellation()
        if models == nil { models = try Models(directory: directory, variant: variant, executionMode: executionMode) }
        guard let models else { throw PocketCoreMLError.invalidModel }
        // Only shipped presets are supported. No voice cloning or network path.
        guard PocketTTSVoices.allowed.contains(where: { $0.id == voice }) else {
            throw PocketCoreMLError.invalidModel
        }
        let voiceURL = directory.appendingPathComponent("constants_bin/" + voice + ".safetensors")
        let snapshot = try PocketCoreMLVoice(data: Data(contentsOf: voiceURL, options: .mappedIfSafe), layerCount: variant == .french6 ? 6 : 24)
        let chunks = try PocketCoreMLText.chunks(text, voicePosition: snapshot.position,
                                                encode: models.tokenizer.encode)
        var mimiState: [String: MLMultiArray] = [:]
        for (name, shape) in models.mimiKeys.stateShapes {
            if variant == .french6 {
                let root = directory.deletingLastPathComponent().deletingLastPathComponent()
                let file = root.appendingPathComponent("constants_bin/mimi_init_state/" + name + ".bin")
                let values = try PocketCoreMLTensor.floats(Data(contentsOf: file))
                mimiState[name] = try PocketCoreMLTensor.array(shape: shape, values: values)
            } else {
                mimiState[name] = try PocketCoreMLTensor.array(shape: shape)
            }
        }
        var audio: [Float] = []
        var rng = SystemRandomNumberGenerator()
        for chunk in chunks {
            try Task.checkCancellation()
            // Voice snapshots already include BOS-before-voice. Do not prepend it twice.
            var cache = try snapshot.makeCache(splitKV: variant == .french6)
            let tokens = models.tokenizer.encode(chunk)
            try prefill(tokens, models: models, cache: &cache)
            let initialPosition = snapshot.position + tokens.count
            var sequence = try PocketCoreMLTensor.array(shape: [1, 1, 32], values: variant == .french6 ? models.bos : Array(repeating: .nan, count: 32))
            let bos = try PocketCoreMLTensor.array(shape: [32], values: models.bos)
            var eos: Int?
            var completed = false
            // No silent truncation: exhaustion before EOS + tail is an error.
            for step in 0..<(512 - initialPosition) {
                try Task.checkCancellation()
                var input = cache
                input["sequence"] = sequence
                if variant == .french24 { input["bos_emb"] = bos }
                let prediction = try predict(models.language, input)
                try updateCache(&cache, from: prediction, keys: models.languageKeys)
                guard let hiddenKey = models.languageKeys.transformerOut, let eosKey = models.languageKeys.eosLogit else {
                    throw PocketCoreMLError.invalidModel
                }
                let eosValue = try tensor(prediction, eosKey)[0].floatValue
                guard eosValue.isFinite else { throw PocketCoreMLError.invalidAudio }
                if eosValue > -4, eos == nil, variant == .french24 || step >= 6 { eos = step }
                if let eos, step >= eos + 8 { completed = true; break }
                let hidden = try PocketCoreMLTensor.values(tensor(prediction, hiddenKey), count: 1024)
                var noise: [Float] = []
                for _ in 0..<32 {
                    let u = Float.random(in: Float.leastNonzeroMagnitude...1, using: &rng)
                    let v = Float.random(in: 0...1, using: &rng)
                    noise.append(sqrt(-2 * log(u)) * cos(2 * .pi * v) * sqrt(variant == .french6 ? 0.3 : 0.7))
                }
                let flow = try predict(models.flow, [
                    "transformer_out": PocketCoreMLTensor.array(shape: [1, 1024], values: hidden),
                    "latent_init": PocketCoreMLTensor.array(shape: [1, 32], values: noise)
                ])
                let latent = try PocketCoreMLTensor.values(tensor(flow, "latent_final"), count: 32)
                var mimiInput = mimiState
                mimiInput["latent"] = try PocketCoreMLTensor.array(shape: [1, 32], values: latent)
                let decoded = try predict(models.mimi, mimiInput)
                let samples = try PocketCoreMLTensor.values(tensor(decoded, models.mimiKeys.audioOutput), count: 1920)
                for pair in models.mimiKeys.stateMapping {
                    mimiState[pair.input] = try tensor(decoded, pair.output)
                }
                try Task.checkCancellation()
                audio.append(contentsOf: samples)
                await onSamples(samples)
                sequence = try PocketCoreMLTensor.array(shape: [1, 1, 32], values: latent)
            }
            guard completed else { throw PocketCoreMLError.incompleteSpeech }
        }
        try Task.checkCancellation()
        guard !audio.isEmpty else { throw PocketCoreMLError.invalidAudio }
        return PocketTTSAudio(samples: audio, sampleRate: 24_000)
    }

    private func prefill(_ tokens: [Int], models: Models, cache: inout [String: MLMultiArray]) throws {
        let shape = models.prefill.modelDescription.inputDescriptionsByName["conditioning"]?.multiArrayConstraint?.shape.map(\.intValue)
        guard let shape, shape.count == 3, shape[0] == 1, shape[2] == 1024, shape[1] > 0 else {
            throw PocketCoreMLError.invalidModel
        }
        for start in stride(from: 0, to: tokens.count, by: shape[1]) {
            try Task.checkCancellation()
            let n = min(shape[1], tokens.count - start)
            var values = [Float](repeating: 0, count: shape[1] * 1024)
            for row in 0..<n {
                let id = tokens[start + row]
                guard id >= 0, id < models.embeddings.count / 1024 else { throw PocketCoreMLError.invalidModel }
                values.replaceSubrange((row * 1024)..<((row + 1) * 1024),
                                       with: models.embeddings[(id * 1024)..<((id + 1) * 1024)])
            }
            var input = cache
            input["conditioning"] = try PocketCoreMLTensor.array(shape: shape, values: values)
            input["valid_len"] = try PocketCoreMLTensor.array(shape: [1], values: [Float(n)])
            try updateCache(&cache, from: predict(models.prefill, input), keys: models.prefillKeys)
        }
    }

    private func predict(_ model: MLModel, _ input: [String: MLMultiArray]) throws -> MLFeatureProvider {
        try Task.checkCancellation()
        return try autoreleasepool {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: input))
        }
    }

    private func tensor(_ output: MLFeatureProvider, _ key: String) throws -> MLMultiArray {
        guard let value = output.featureValue(for: key)?.multiArrayValue else { throw PocketCoreMLError.invalidModel }
        return value
    }

    private func updateCache(_ cache: inout [String: MLMultiArray], from output: MLFeatureProvider,
                             keys: PocketCoreMLLayerKeys) throws {
        for layer in 0..<keys.layerCount {
            if let v = keys.vCacheKeys {
                cache["k_cache\(layer)"] = try tensor(output, keys.cacheKeys[layer])
                cache["v_cache\(layer)"] = try tensor(output, v[layer])
            } else {
                cache["cache\(layer)"] = try tensor(output, keys.cacheKeys[layer])
            }
            cache["position\(layer)"] = try tensor(output, keys.positionKeys[layer])
        }
    }
}

enum PocketCoreMLError: LocalizedError {
    case invalidModel, invalidAudio, incompleteSpeech, textTooLong, busy
    var errorDescription: String? {
        switch self {
        case .invalidModel: "Les fichiers Core ML de PocketTTS sont incomplets ou incompatibles."
        case .invalidAudio: "PocketTTS n’a pas produit de son lisible."
        case .incompleteSpeech: "PocketTTS n’a pas terminé la phrase. Réessaie ou utilise les voix iOS."
        case .textTooLong: "Ce passage est trop long pour PocketTTS. Utilise les voix iOS."
        case .busy: "Une synthèse PocketTTS est déjà en cours."
        }
    }
}

enum PocketCoreMLTensor {
    static func array(shape: [Int], values: [Float]? = nil) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        if let values, values.count != array.count { throw PocketCoreMLError.invalidModel }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        if let values {
            values.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { pointer.update(from: base, count: buffer.count) }
            }
        } else if array.count > 0 { pointer.initialize(repeating: 0, count: array.count) }
        return array
    }

    /// Subscripts honor dtype AND strides; fp16 audio must never be read as Float32 bytes.
    static func values(_ array: MLMultiArray, count: Int) throws -> [Float] {
        guard array.count == count else { throw PocketCoreMLError.invalidModel }
        let result = (0..<count).map { array[$0].floatValue }
        guard result.allSatisfy(\.isFinite) else { throw PocketCoreMLError.invalidAudio }
        return result
    }

    static func floats(_ data: Data) throws -> [Float] {
        guard data.count % 4 == 0 else { throw PocketCoreMLError.invalidModel }
        let result = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        guard result.allSatisfy(\.isFinite) else { throw PocketCoreMLError.invalidModel }
        return result
    }
}

/// Bounded reader for the pinned French preset schema, not an arbitrary tensor loader.
struct PocketCoreMLVoice {
    let position: Int
    private let layers: [[Float]]

    init(data: Data, layerCount: Int = 24) throws {
        guard data.count >= 8 else { throw PocketCoreMLError.invalidModel }
        let length = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length <= UInt64(min(data.count - 8, 1_048_576)) else { throw PocketCoreMLError.invalidModel }
        let start = 8 + Int(length)
        guard let entries = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<start)) as? [String: Any] else {
            throw PocketCoreMLError.invalidModel
        }
        func read(_ key: String, dtype: String, shape: [Int]) throws -> Data {
            guard let entry = entries[key] as? [String: Any], entry["dtype"] as? String == dtype,
                  entry["shape"] as? [Int] == shape, let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0],
                  offsets[1] <= data.count - start,
                  offsets[1] - offsets[0] == shape.reduce(1, *) * (dtype == "I64" ? 8 : 4) else {
                throw PocketCoreMLError.invalidModel
            }
            return data.subdata(in: (start + offsets[0])..<(start + offsets[1]))
        }
        guard let first = entries["transformer.layers.0.self_attn/cache"] as? [String: Any],
              let shape = first["shape"] as? [Int], shape.count == 5,
              shape[0] == 2, shape[1] == 1, shape[2] > 0, shape[2] < 512,
              shape[3] == 16, shape[4] == 64 else { throw PocketCoreMLError.invalidModel }
        var layers: [[Float]] = []
        guard layerCount == 6 || layerCount == 24 else { throw PocketCoreMLError.invalidModel }
        for layer in 0..<layerCount {
            let prefix = "transformer.layers.\(layer).self_attn/"
            let offsetData = try read(prefix + "offset", dtype: "I64", shape: [1])
            let offset = offsetData.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
            guard offset == Int64(shape[2]) else { throw PocketCoreMLError.invalidModel }
            layers.append(try PocketCoreMLTensor.floats(read(prefix + "cache", dtype: "F32", shape: shape)))
        }
        self.position = shape[2]
        self.layers = layers
    }

    func makeCache(splitKV: Bool = false) throws -> [String: MLMultiArray] {
        var result: [String: MLMultiArray] = [:]
        let sourceBlock = position * 1024
        let destinationBlock = 512 * 1024
        for (index, values) in layers.enumerated() {
            try Task.checkCancellation()
            if splitKV {
                let k = try PocketCoreMLTensor.array(shape: [1, 512, 16, 64])
                let v = try PocketCoreMLTensor.array(shape: [1, 512, 16, 64])
                values.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        k.dataPointer.bindMemory(to: Float.self, capacity: destinationBlock).update(from: base, count: sourceBlock)
                        v.dataPointer.bindMemory(to: Float.self, capacity: destinationBlock).update(from: base.advanced(by: sourceBlock), count: sourceBlock)
                    }
                }
                result["k_cache\(index)"] = k
                result["v_cache\(index)"] = v
            } else {
                let cache = try PocketCoreMLTensor.array(shape: [2, 1, 512, 16, 64])
                let pointer = cache.dataPointer.bindMemory(to: Float.self, capacity: cache.count)
                values.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        pointer.update(from: base, count: sourceBlock)
                        pointer.advanced(by: destinationBlock).update(from: base.advanced(by: sourceBlock), count: sourceBlock)
                    }
                }
                result["cache\(index)"] = cache
            }
            result["position\(index)"] = try PocketCoreMLTensor.array(shape: [1], values: [Float(position)])
        }
        return result
    }
}

enum PocketCoreMLText {
    /// Bound each chunk by tokenizer size AND available audio cache. Never drop text.
    static func chunks(_ text: String, voicePosition: Int, encode: (String) -> [Int]) throws -> [String] {
        let clean = PocketTTSFrenchText.normalize(text).precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { throw PocketCoreMLError.invalidAudio }
        guard clean.count <= 20_000, voicePosition > 0, voicePosition < 512 else { throw PocketCoreMLError.textTooLong }
        func fits(_ value: String) -> Bool {
            let tokens = encode(value).count
            let words = value.split(separator: " ").count
            let frames = Int(ceil((Double(words) + 2) * 12.5)) + 9
            return tokens > 0 && tokens <= 128 && voicePosition + tokens + frames <= 512
        }
        var chunks: [String] = []
        var current = ""
        for word in clean.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if fits(candidate) { current = candidate }
            else {
                if !current.isEmpty { chunks.append(current) }
                current = String(word)
                guard fits(current) else { throw PocketCoreMLError.textTooLong }
            }
            if let last = current.last, ".!?".contains(last) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

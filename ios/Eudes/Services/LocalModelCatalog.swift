import Foundation
import os

/// Public model assets are pinned to immutable upstream revisions and SHA-256 digests.
/// Downloading weights does not imply that an inference engine is loaded or usable.
enum LocalModelCatalog {
    /// Context configured for every LFM engine instance, including output tokens.
    static let allocatedContextTokens = 4096
    static let reasoningOptions = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static func reasoningSize(_ value: Int?) -> Int {
        guard let value, reasoningOptions.contains(value) else { return 512 }
        return value
    }
    static let contextOptions = [1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static func contextSize(_ value: Int?) -> Int {
        guard let value, contextOptions.contains(value) else { return allocatedContextTokens }
        return value
    }
    struct Asset: Equatable, Sendable {
        let filename: String
        let size: Int64
        let sha256: String
    }

    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let supportsImages: Bool
        let repository: String
        let revision: String
        let assets: [Asset]
        /// Famille lisible, pour présenter les tailles côte à côte.
        var family: String = ""
        /// Licence du fichier : seules les licences compatibles avec la distribution entrent ici.
        var licence: String = ""
        /// Contexte d'entraînement annoncé par le fichier.
        var nativeContext: Int? = nil
        /// Cache K+V par token, relevé dans l'en-tête du GGUF.
        var kvBytesPerToken: Int? = nil
        /// Vrai quand le fichier porte son gabarit : le rendu passe par llama.cpp.
        var usesEmbeddedTemplate: Bool = false
        /// Point fort, repris de la fiche officielle du modèle : aide à choisir sans benchmark.
        var strength: String = ""

        /// Poids + cache K/V minimal (4 096 tokens), majorés de 15 % : iOS ne laisse jamais
        /// toute la mémoire libre au processus, et llama.cpp a ses propres tampons.
        func compatibility(device: DeviceProfile = .current) -> LocalModelCompatibility {
            let available = max(0, device.physicalMemory - ContextSizing.reserveBytes(device: device))
            let kv = kvBytesPerToken ?? 96_000
            let required = Int(Double(Int(downloadBytes) + kv * ContextSizing.minimumTokens) * 1.15)
            return LocalModelCompatibility(required: required, available: available)
        }

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
        }

        /// Nil quand le modèle tient ; sinon la mention et le besoin chiffré.
        func compatibilityLabel(device: DeviceProfile = .current) -> String? {
            let result = compatibility(device: device)
            guard !result.isSupported else { return nil }
            let required = ByteCountFormatter.string(fromByteCount: Int64(result.required), countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: Int64(result.available), countStyle: .file)
            return "Trop lourd pour cet iPhone (\(required) nécessaires, \(available) disponibles)"
        }

        /// A single source of truth for the settings label and attachment policy.
        var capabilityDescription: String { supportsImages ? "Modèle texte + vision" : "Modèle texte" }
        var imageUnavailableReason: String? {
            supportsImages ? nil : "Ce modèle accepte uniquement du texte. Le brouillon et ses images sont conservés."
        }
        var downloadBytes: Int64 { assets.reduce(0) { $0 + $1.size } }
        func url(for asset: Asset) -> URL? {
            guard assets.contains(asset) else { return nil }
            // `repository` est soit un identifiant complet (« unsloth/… »), soit le nom du
            // dépôt Liquid AI historique, préfixé ici pour ne pas invalider les liens existants.
            let path = repository.contains("/") ? repository : "LiquidAI/\(repository)"
            return URL(string: "https://huggingface.co/\(path)/resolve/\(revision)/\(asset.filename)")
        }
    }

    static let text = Model(id: "lfm3-text", title: "LFM3 1.7B", supportsImages: false,
        repository: "LFM3-1.7B-GGUF", revision: "cd0c74c575b5c416f3011b5b4c298077f26ca8c2", assets: [
            Asset(filename: "LFM3-1.7B-Q4_K_M.gguf", size: 1_099_627_808,
                  sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4")
        ], family: "LFM3", licence: "Liquid AI Open License", nativeContext: 262_144,
        kvBytesPerToken: 12288, usesEmbeddedTemplate: true,
        strength: "Très léger (1 Go) : répond vite et suit de longues discussions.")
    static let vision = Model(id: "lfm3-vision", title: "LFM3 VL 2B", supportsImages: true,
        repository: "LFM3-VL-2B-GGUF", revision: "1add221a5ea6c047fcf1eaaf2d247939d7cf8849", assets: [
            Asset(filename: "LFM3-VL-2B-Q4_K_M.gguf", size: 1_099_627_808,
                  sha256: "56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb"),
            Asset(filename: "mmproj-LFM3-VL-2B-Q8_0.gguf", size: 203_031_872,
                  sha256: "c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab")
        ], family: "LFM3", licence: "Liquid AI Open License", nativeContext: 128_000,
        kvBytesPerToken: 12288, usesEmbeddedTemplate: true,
        strength: "Lit les images, en restant compact.")
    static let qwen35_2b = Model(id: "qwen35_2b", title: "Qwen3.5 2B", supportsImages: false,
        repository: "unsloth/Qwen3.5-2B-GGUF", revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae", assets: [
            Asset(filename: "Qwen3.5-2B-Q4_K_M.gguf", size: 1280835840,
                  sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")
        ], family: "Qwen3.5", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 49152, usesEmbeddedTemplate: true,
        strength: "Comprend plusieurs langues, raisonne bien et répond vite.")
    static let qwen35_4b = Model(id: "qwen35_4b", title: "Qwen3.5 4B", supportsImages: false,
        repository: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523", assets: [
            Asset(filename: "Qwen3.5-4B-Q4_K_M.gguf", size: 2740937888,
                  sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4")
        ], family: "Qwen3.5", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 81920, usesEmbeddedTemplate: true,
        strength: "Le plus capable des trois Qwen3.5 : meilleur raisonnement, un peu plus lent.")
    static let gemma4_e2b = Model(id: "gemma4_e2b", title: "Gemma 4 E2B", supportsImages: false,
        repository: "unsloth/gemma-4-E2B-it-GGUF", revision: "0314792d7f1f7e229411f620751375812bb9faf2", assets: [
            Asset(filename: "gemma-4-E2B-it-Q4_K_M.gguf", size: 3106738272,
                  sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8")
        ], family: "Gemma 4", licence: "Apache-2.0", nativeContext: 131072,
        kvBytesPerToken: 26880, usesEmbeddedTemplate: true,
        strength: "Le compact de la famille : réfléchit avant de répondre, reste vif.")
    static let gemma4_e4b = Model(id: "gemma4_e4b", title: "Gemma 4 E4B", supportsImages: false,
        repository: "unsloth/gemma-4-E4B-it-GGUF", revision: "bfc15c382204943c3a8fff0c750b94ae2364d7a3", assets: [
            Asset(filename: "gemma-4-E4B-it-Q4_K_M.gguf", size: 4977171584,
                  sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87")
        ], family: "Gemma 4", licence: "Apache-2.0", nativeContext: 131072,
        kvBytesPerToken: 107520, usesEmbeddedTemplate: true,
        strength: "Le plus capable de la famille ; demande beaucoup de mémoire vive.")
    static let phi4_mini = Model(id: "phi4_mini", title: "Phi-4 mini", supportsImages: false,
        repository: "unsloth/Phi-4-mini-instruct-GGUF", revision: "78eb92a46fc37e6b524df991ed9aca9bc6aa7b80", assets: [
            Asset(filename: "Phi-4-mini-instruct-Q4_K_M.gguf", size: 2491874272,
                  sha256: "88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a")
        ], family: "Phi-4", licence: "MIT", nativeContext: 131072,
        kvBytesPerToken: 131072, usesEmbeddedTemplate: true,
        strength: "Très bon en maths et en logique pour sa taille.")

    static let qwen35_08b = Model(id: "qwen35_08b", title: "Qwen3.5 0,8B", supportsImages: false,
        repository: "unsloth/Qwen3.5-0.8B-GGUF", revision: "6ab461498e2023f6e3c1baea90a8f0fe38ab64d0", assets: [
            Asset(filename: "Qwen3.5-0.8B-Q4_K_M.gguf", size: 532_517_120,
                  sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517")
        ], family: "Qwen3.5", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 24576, usesEmbeddedTemplate: true,
        strength: "Le plus léger du catalogue : répond vite et tient sur les vieux iPhone.")

    static let bonsai_2b = Model(id: "bonsai_2b", title: "Bonsai 2B", supportsImages: true,
        repository: "prism-ml/Ternary-Bonsai-2-2B-gguf", revision: "a6032a5089ac27e96be3a80c7b42d1ad0bd89887", assets: [
            Asset(filename: "Ternary-Bonsai-2-2B-Q2_0.gguf", size: 546_689_504,
                  sha256: "c2893fa6f951daee8b7263d5f49b455e57989ef56417a22125b03566dc560650"),
            Asset(filename: "Ternary-Bonsai-2-2B-mmproj-Q8_0.gguf", size: 364_664_352,
                  sha256: "ac9934e8d7966d0d62442c202ec8fdad99a045dea79366c1a4a246a46f5c0533")
        ], family: "Bonsai", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 49152, usesEmbeddedTemplate: true,
        strength: "Très léger (0,55 Go) et lit aussi les images.")

    static let bonsai_4b = Model(id: "bonsai_4b", title: "Bonsai 4B", supportsImages: true,
        repository: "prism-ml/Ternary-Bonsai-2-4B-gguf", revision: "50ebba61be85e5be07e8083db468ace0fc1bac43", assets: [
            Asset(filename: "Ternary-Bonsai-2-4B-Q2_0.gguf", size: 1_212_103_520,
                  sha256: "64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4"),
            Asset(filename: "Ternary-Bonsai-2-4B-mmproj-Q8_0.gguf", size: 366_894_624,
                  sha256: "db939d5f9b7014137810205e91d05e5f54afd72b0b3af9d33bd7d82f7906a55d")
        ], family: "Bonsai", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 81920, usesEmbeddedTemplate: true,
        strength: "Léger pour sa puissance (1,2 Go), lit aussi les images.")

    static let bonsai_8b = Model(id: "bonsai_8b", title: "Bonsai 8B", supportsImages: false,
        repository: "prism-ml/Ternary-Bonsai-8B-gguf", revision: "c2aefbeb4b24469cd11579c3384b990404c17a30", assets: [
            Asset(filename: "Ternary-Bonsai-8B-Q2_0.gguf", size: 2_182_184_672,
                  sha256: "3c8d70470a5d97e5a2b9410ddd899cb740116591462626c60cb2fead6448f60b")
        ], family: "Bonsai", licence: "Apache-2.0", nativeContext: 65536,
        kvBytesPerToken: 147456, usesEmbeddedTemplate: true,
        strength: "Le plus capable des modèles légers, déjà éprouvé sur iPhone.")

    static let granite42_3b = Model(id: "granite42_3b", title: "Granite 4.2 3B", supportsImages: false,
        repository: "ibm-granite/granite-4.2-3b-GGUF", revision: "c40945d71cd90f249a56985e8155551a9188dc30", assets: [
            Asset(filename: "granite-4.2-3b-Q4_K_M.gguf", size: 2_244_011_552,
                  sha256: "e0406663965846ae22a403456eb826ccce5f450840491f71952f18a7cb78e7d5")
        ], family: "Granite 4.2", licence: "Apache-2.0", nativeContext: 131072,
        kvBytesPerToken: 81920, usesEmbeddedTemplate: true,
        strength: "Suit les consignes à la lettre, texte seulement.")

    static let ministral3_3b = Model(id: "ministral3_3b", title: "Ministral 3 3B", supportsImages: true,
        repository: "mistralai/Ministral-3-3B-Instruct-2512-GGUF", revision: "eb599d408350ea2bb60452cb86be7c7b2fc28227", assets: [
            Asset(filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", size: 2_147_023_008,
                  sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8"),
            Asset(filename: "Ministral-3-3B-Instruct-2512-BF16-mmproj.gguf", size: 841_501_856,
                  sha256: "70ca26e41ecea9da997e2887462ad68b848fbf64da011ff4107bbe7353519ee0")
        ], family: "Ministral 3", licence: "Apache-2.0", nativeContext: 262144,
        kvBytesPerToken: 79872, usesEmbeddedTemplate: true,
        strength: "Lit les images et suit de longues discussions.")

    static let models = [text, vision] + extended

    /// Modèles ajoutés au catalogue d'origine, dans l'ordre des familles et des tailles.
    static let extended: [Model] = [
        qwen35_08b, qwen35_2b, qwen35_4b,
        gemma4_e2b, gemma4_e4b,
        bonsai_2b, bonsai_4b, bonsai_8b,
        granite42_3b, phi4_mini, ministral3_3b,
    ]

    // MARK: - Catalogue lisible

    /// Une famille telle qu'elle s'affiche : un nom, une phrase compréhensible sans
    /// connaître les modèles, et ses tailles dans l'ordre du catalogue.
    struct Family: Identifiable, Equatable, Sendable {
        let name: String
        let summary: String
        let models: [Model]

        var id: String { name }

        /// Le pictogramme de la carte : `familyIcons[name]`, avec un repli neutre
        /// si une famille future n'a pas encore son symbole.
        var icon: String { LocalModelCatalog.familyIcons[name] ?? "cube.transparent" }

        /// « 532,5 Mo, 1,28 Go et 2,74 Go » : les fichiers réels, sans compteur ni
        /// formule à décoder avant de savoir ce qu'on installe.
        var sizesLabel: String {
            let sizes = models.map(\.sizeLabel)
            guard sizes.count > 1 else { return sizes.first ?? "" }
            return sizes.dropLast().joined(separator: ", ") + " et " + (sizes.last ?? "")
        }
    }

    /// Ordre d'affichage voulu : la famille la plus polyvalente d'abord, puis les plus
    /// spécialisées. Toute famille absente de cette liste passe après, par ordre
    /// alphabétique : ajouter un modèle ne peut pas le faire disparaître du catalogue.
    static let familyOrder = ["Qwen3.5", "LFM3", "Gemma 4", "Bonsai", "Granite 4.2", "Phi-4", "Ministral 3"]

    /// Un pictogramme par famille : l'œil identifie la carte sans lire. Un symbole
    /// simple, pas de marque à copier.
    static let familyIcons = [
        "Qwen3.5": "bubble.left.and.text.bubble.right",
        "LFM3": "eye",
        "Gemma 4": "sparkles",
        "Bonsai": "leaf",
        "Granite 4.2": "doc.text",
        "Phi-4": "brain",
        "Ministral 3": "photo",
    ]

    /// Un nom de famille ne dit rien à qui découvre les modèles : chaque ligne porte
    /// donc une phrase qui décrit l'usage, pas l'architecture. Chaque phrase doit rester
    /// vraie pour **toutes** les tailles de la famille (Bonsai 8B ne lit pas les images).
    static let familySummaries = [
        "Qwen3.5": "Polyvalente et rapide, bon français, trois tailles.",
        "LFM3": "Deux tailles compactes, dont une qui lit les images.",
        "Gemma 4": "Réfléchit avant de répondre, très efficace pour sa taille.",
        "Bonsai": "Beaucoup de capacité dans très peu de mémoire ; deux tailles sur trois lisent les images.",
        "Granite 4.2": "Bon suivi d'instructions, texte seulement.",
        "Phi-4": "Raisonnement dense pour sa taille, précis sur les consignes.",
        "Ministral 3": "Lit les images, compacte pour sa capacité.",
    ]

    static var families: [Family] {
        let grouped = Dictionary(grouping: models, by: \.family)
        let ordered = familyOrder.filter { grouped[$0] != nil }
        let remaining = grouped.keys.filter { !familyOrder.contains($0) }.sorted()
        return (ordered + remaining).map { name in
            Family(name: name, summary: familySummaries[name] ?? "", models: grouped[name] ?? [])
        }
    }

    /// Les trois raccourcis du catalogue : un usage, un modèle. L'ordre de préférence
    /// est fixe, mais le choix dépend de la mémoire de l'appareil — un modèle trop
    /// lourd n'est jamais proposé parce qu'il serait le plus capable.
    enum Role: String, CaseIterable, Sendable {
        case conversation, reasoning, vision

        var headline: String {
            switch self {
            case .conversation: "Discuter tous les jours"
            case .reasoning: "Réfléchir sur un problème"
            case .vision: "Comprendre une image"
            }
        }

        var detail: String {
            switch self {
            case .conversation: "Questions, rédaction, résumés : le modèle à garder par défaut."
            case .reasoning: "Calculs, textes longs, problèmes en plusieurs étapes."
            case .vision: "Captures d’écran, photos, documents photographiés."
            }
        }

        var symbol: String {
            switch self {
            case .conversation: "bubble.left"
            case .reasoning: "sparkles"
            case .vision: "photo"
            }
        }
    }

    struct Recommendation: Identifiable, Equatable, Sendable {
        let role: Role
        let model: Model
        var id: String { role.rawValue }
    }

    /// Ordre de préférence par usage, du plus adapté au plus lourd.
    static func preference(for role: Role) -> [Model] {
        switch role {
        case .conversation: [qwen35_2b, qwen35_08b, phi4_mini, text]
        case .reasoning: [qwen35_4b, gemma4_e2b, granite42_3b, phi4_mini]
        case .vision: [vision, bonsai_2b, bonsai_4b, ministral3_3b]
        }
    }

    /// Un raccourci par usage qui a un candidat sur cet appareil. Un usage sans modèle
    /// assez léger disparaît de l'écran plutôt que d'être proposé en échouant.
    static func recommendations(device: DeviceProfile = .current) -> [Recommendation] {
        Role.allCases.compactMap { role in
            guard let model = preference(for: role).first(where: { $0.compatibility(device: device).isSupported })
            else { return nil }
            return Recommendation(role: role, model: model)
        }
    }
}


// MARK: - Matériel et dimensionnement de la fenêtre de contexte

/// Ce que l'appareil peut offrir au moteur. iOS n'expose pas de nom commercial :
/// l'identifiant matériel brut (`hw.machine`) est la seule information exacte.
struct DeviceProfile: Equatable, Sendable {
    var machineIdentifier: String
    var physicalMemory: Int
    /// Mémoire que le processus peut encore allouer (`os_proc_available_memory`), quand
    /// elle est connue. La RAM totale n'est jamais allouable : sans cette valeur, le
    /// dimensionnement retombe sur une réserve prudente hors de `physicalMemory`.
    var processAvailableMemory: Int? = nil

    static var current: DeviceProfile {
        DeviceProfile(machineIdentifier: machineIdentifier,
                      physicalMemory: Int(ProcessInfo.processInfo.physicalMemory),
                      processAvailableMemory: currentAvailableMemory)
    }

    /// `os_proc_available_memory()` vaut 0 hors application et délire sur certains
    /// appareils : on ne retient une valeur que si elle est plausible.
    static var currentAvailableMemory: Int? {
        let value = Int(os_proc_available_memory())
        guard value > 0, value <= Int(ProcessInfo.processInfo.physicalMemory) else { return nil }
        return value
    }

    static var machineIdentifier: String {
        var system = utsname()
        guard uname(&system) == 0 else { return "inconnu" }
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Exemple : « 8 Go ». Les valeurs sont celles du matériel, jamais une estimation.
    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
    }

    var descriptionLabel: String { "\(machineIdentifier) · \(memoryLabel)" }
}

/// Lecteur d'en-tête GGUF, limité aux métadonnées utiles au dimensionnement.
/// Une lecture incomplète renvoie nil : on ne devine jamais une taille de modèle.
struct GGUFMetadata: Equatable, Sendable {
    var contextLength: Int?
    var blockCount: Int?
    var headCount: Int?
    var headCountKV: Int?
    var embeddingLength: Int?
    /// Gabarit de conversation embarqué (`tokenizer.chat_template`), rendu par llama.cpp.
    var chatTemplate: String?

    /// Octets d'état K et V par token, en f16, sur toutes les couches.
    var kvBytesPerToken: Int? {
        guard let blockCount, blockCount > 0,
              let headCountKV, headCountKV > 0,
              let headCount, headCount > 0,
              let embeddingLength, embeddingLength >= headCount else { return nil }
        return 2 * blockCount * headCountKV * (embeddingLength / headCount) * 2
    }

    /// The header sits at the start of the file; reading a few pages avoids loading gigabytes.
    /// Token arrays push the sizing keys far from the start (Qwen and Gemma store ~30 MB of
    /// tokenizer data), so the window grows until the numbers are found — never the whole file.
    static func read(url: URL, limits: [Int] = [262_144, 4_194_304, 33_554_432]) -> GGUFMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var deepest: GGUFMetadata?
        for limit in limits {
            guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return deepest }
            if let metadata = parse(data) {
                deepest = metadata
                if metadata.kvBytesPerToken != nil, metadata.chatTemplate != nil { return metadata }
            }
            guard data.count == limit else { return deepest }
            do { try handle.seek(toOffset: 0) } catch { return deepest }
        }
        return deepest
    }

    static func parse(_ data: Data) -> GGUFMetadata? {
        var reader = GGUFReader(data: data)
        guard let magic = reader.string(length: 4), magic == "GGUF",
              let version = reader.uint32(), (2...3).contains(version),
              reader.uint64() != nil,
              let count = reader.uint64(), count <= 100_000 else { return nil }
        var result = GGUFMetadata()
        var index: UInt64 = 0
        while index < count {
            index += 1
            guard let nameLength = reader.uint64(), nameLength <= 1_024,
                  let name = reader.string(length: Int(nameLength)),
                  let type = reader.uint32() else { return nil }
            // Keys are prefixed by the architecture (llama.*, qwen3.*, gemma4.*…):
            // suffix matching keeps the reader independent from the model family.
            if name.hasSuffix(".context_length") { result.contextLength = reader.number(type) }
            else if name.hasSuffix(".block_count") { result.blockCount = reader.number(type) }
            else if name.hasSuffix(".attention.head_count") { result.headCount = reader.number(type) }
            else if name.hasSuffix(".attention.head_count_kv") { result.headCountKV = reader.number(type) }
            else if name.hasSuffix(".embedding_length") { result.embeddingLength = reader.number(type) }
            else if name.hasSuffix(".chat_template"), type == 8 {
                guard let length = reader.uint64(), length <= 1_048_576,
                      let value = reader.string(length: Int(length)) else { return nil }
                result.chatTemplate = value
            }
            else { guard reader.skip(type) else { return nil } }
        }
        guard result.contextLength != nil || result.blockCount != nil else { return nil }
        return result
    }
}

private struct GGUFReader {
    let data: Data
    var offset = 0

    init(data: Data) { self.data = data }

    private mutating func byte() -> UInt8? {
        guard offset < data.count else { return nil }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    private mutating func skipBytes(_ count: Int) -> Bool {
        guard count >= 0, offset + count <= data.count else { return false }
        offset += count
        return true
    }

    mutating func uint32() -> UInt32? {
        var value: UInt32 = 0
        for shift in 0..<4 {
            guard let next = byte() else { return nil }
            value |= UInt32(next) << (8 * shift)
        }
        return value
    }

    mutating func uint64() -> UInt64? {
        var value: UInt64 = 0
        for shift in 0..<8 {
            guard let next = byte() else { return nil }
            value |= UInt64(next) << (8 * shift)
        }
        return value
    }

    mutating func string(length: Int) -> String? {
        guard length >= 0, offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += length
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    /// Consomme la valeur d'un type GGUF. Toujours appelée pour garder le flux aligné.
    @discardableResult
    mutating func skip(_ type: UInt32, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        switch type {
        case 0, 1, 7: return byte() != nil
        case 2, 3: return skipBytes(2)
        case 4, 5, 6: return skipBytes(4)
        case 10, 11, 12: return skipBytes(8)
        case 8:
            guard let length = uint64(), length <= UInt64(Int.max) else { return false }
            return string(length: Int(length)) != nil
        case 9:
            guard let elementType = uint32(), let count = uint64(), count <= 1_000_000 else { return false }
            var remaining = count
            while remaining > 0 {
                remaining -= 1
                guard skip(elementType, depth: depth + 1) else { return false }
            }
            return true
        default:
            return false
        }
    }

    /// Reads a numeric value (a scalar or the first element of an array) and always consumes it.
    mutating func number(_ type: UInt32) -> Int? {
        switch type {
        case 4, 5:
            guard let value = uint32() else { return nil }
            return Int(value)
        case 10, 11:
            guard let value = uint64() else { return nil }
            return Int(value)
        case 9:
            guard let elementType = uint32(), let count = uint64(), count <= 1_024 else { return nil }
            var first: Int?
            var remaining = count
            while remaining > 0 {
                remaining -= 1
                if [4, 5, 10, 11].contains(elementType) {
                    guard let value = number(elementType) else { return nil }
                    if first == nil { first = value }
                } else if !skip(elementType, depth: 1) {
                    return nil
                }
            }
            return first
        default:
            skip(type)
            return nil
        }
    }
}

/// Choisit une fenêtre qui laisse de la place aux poids, au cache KV et au système.
/// Viser le maximum atteignable remplissait la mémoire de l'iPhone et ralentissait
/// l'appareil entier, Eudes comprise.
enum ContextSizing {
    static let minimumTokens = 4_096
    static let maximumTokens = 65_536
    /// Part de la mémoire restante après les poids qu'un cache K/V peut occuper.
    static let cacheShare = 0.5
    /// Repli quand la mémoire du processus est inconnue : iOS n'alloue jamais la RAM totale.
    static func reserveBytes(device: DeviceProfile) -> Int {
        max(1_200_000_000, device.physicalMemory / 4)
    }

    /// Mémoire réellement allouable : la mesure du processus quand elle est connue, sinon la
    /// RAM totale amputée de la réserve.
    static func allocatableBytes(device: DeviceProfile) -> Int {
        if let process = device.processAvailableMemory, process > 0, process <= device.physicalMemory {
            return process
        }
        return max(0, device.physicalMemory - reserveBytes(device: device))
    }

    static func recommended(metadata: GGUFMetadata?, weightsBytes: Int, device: DeviceProfile) -> Int {
        let afterWeights = allocatableBytes(device: device) - weightsBytes
        guard afterWeights > 100_000_000 else { return minimumTokens }
        let tokens: Int
        if let kv = metadata?.kvBytesPerToken, kv > 0 {
            tokens = Int(Double(afterWeights) * cacheShare / Double(kv))
        } else {
            tokens = fallbackTokens(for: afterWeights)
        }
        let ceiling = min(metadata?.contextLength ?? maximumTokens, maximumTokens)
        return LocalModelCatalog.contextOptions.last { $0 <= min(tokens, ceiling) && $0 >= minimumTokens }
            ?? minimumTokens
    }

    /// Repli quand l'en-tête du modèle est illisible : paliers prudents calculés sur la
    /// mémoire réellement allouable, jamais sur la RAM totale.
    static func fallbackTokens(for allocatable: Int) -> Int {
        switch allocatable {
        case ..<2_500_000_000: return 4_096
        case ..<4_000_000_000: return 8_192
        case ..<7_000_000_000: return 16_384
        default: return 32_768
        }
    }
}

extension LocalModelCatalog {
    /// Valeur stockée signifiant « laisse Eudes dimensionner la fenêtre ».
    static let automaticContext = 0

    /// Fenêtre calculée à partir de l'appareil et de l'en-tête GGUF du modèle, si présent.
    ///
    /// Les métadonnées sont loin dans le fichier (jusqu'à 32 Mo pour Qwen/Gemma) : le résultat
    /// est mémorisé par (chemin, taille) parce que plusieurs vues relisent cette valeur des
    /// dizaines de fois par rendu — sans cache, chaque frappe relisait l'en-tête du modèle.
    static func automaticTokens(for model: Model?, root: URL = LocalModelDownloads.root,
                                 readMetadata: (URL) -> GGUFMetadata? = { GGUFMetadata.read(url: $0) }) -> Int {
        guard let model, let first = model.assets.first else { return ContextSizing.minimumTokens }
        let url = root.appendingPathComponent(model.id, isDirectory: true).appendingPathComponent(first.filename)
        var size = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let stored = attributes[.size] as? NSNumber {
            size = stored.intValue
        }
        return contextSizingCache.value(for: "\(url.path)|\(size)") {
            ContextSizing.recommended(metadata: readMetadata(url),
                                      weightsBytes: Int(model.downloadBytes), device: .current)
        }
    }

    /// Capacité images d'un modèle du catalogue, sans construire de profil.
    static func supportsImages(_ id: String) -> Bool {
        models.first { $0.id == id }?.supportsImages ?? false
    }

    /// Modèle qui peut prendre la relève quand `removed` disparaît du disque : la même
    /// capacité d'images d'abord, puis n'importe quel modèle installé et compatible.
    /// Nil quand aucun autre modèle utilisable ne reste.
    static func replacement(afterRemoving removed: String, installed: Set<String>,
                            device: DeviceProfile = .current) -> Model? {
        guard let gone = models.first(where: { $0.id == removed }) else { return nil }
        let usable = models.filter {
            $0.id != removed && installed.contains($0.id) && $0.compatibility(device: device).isSupported
        }
        return usable.first { $0.supportsImages == gone.supportsImages } ?? usable.first
    }

    private static let templateCache = LocalChatTemplateCache()

    /// Cache des fenêtres automatiques déjà calculées : une lecture d'en-tête par (fichier, taille).
    private static let contextSizingCache = LocalContextSizingCache()

    /// Gabarit de conversation du fichier déjà téléchargé, s'il en contient un.
    static func chatTemplate(for model: Model?, root: URL = LocalModelDownloads.root) -> String? {
        guard let model, let first = model.assets.first else { return nil }
        let url = root.appendingPathComponent(model.id, isDirectory: true).appendingPathComponent(first.filename)
        var size = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let stored = attributes[.size] as? NSNumber {
            size = stored.intValue
        }
        return templateCache.value(for: "\(model.id)|\(size)") { GGUFMetadata.read(url: url)?.chatTemplate }
    }

    /// Valeur stockée → fenêtre concrète. `automaticContext` est résolu, le reste est tel quel.
    static func resolvedContextSize(_ stored: Int?, modelID: String? = nil,
                                    root: URL = LocalModelDownloads.root) -> Int {
        guard let stored else { return allocatedContextTokens }
        guard stored == automaticContext else { return contextSize(stored) }
        return automaticTokens(for: models.first { $0.id == modelID }, root: root)
    }
}

/// Cache du gabarit par (modèle, taille de fichier) : un rendu de prompt ne doit pas relire
/// l'en-tête de plusieurs centaines de mégaoctets à chaque message.
private final class LocalChatTemplateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var missing: Set<String> = []

    func value(for key: String, load: () -> String?) -> String? {
        lock.lock()
        if let cached = values[key] { lock.unlock(); return cached }
        if missing.contains(key) { lock.unlock(); return nil }
        lock.unlock()
        let loaded = load()
        lock.lock()
        if let loaded { values[key] = loaded } else { missing.insert(key) }
        lock.unlock()
        return loaded
    }
}

/// Cache des fenêtres de contexte calculées depuis l'en-tête GGUF. Le corps de la vue de chat
/// relit la fenêtre à chaque frappe : la lecture de l'en-tête (jusqu'à 32 Mo) ne doit arriver
/// qu'une fois par fichier installé.
private final class LocalContextSizingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func value(for key: String, compute: () -> Int) -> Int {
        lock.lock()
        if let cached = values[key] { lock.unlock(); return cached }
        lock.unlock()
        let value = compute()
        lock.lock()
        values[key] = value
        lock.unlock()
        return value
    }
}

/// Ce qu'un modèle exige de l'appareil, comparé à ce qu'iOS peut lui laisser.
struct LocalModelCompatibility: Equatable {
    let required: Int
    let available: Int
    // Comparaison écrite en différence : le parseur de CI bute sur « <= » en une ligne.
    var isSupported: Bool { available - required >= 0 }
}

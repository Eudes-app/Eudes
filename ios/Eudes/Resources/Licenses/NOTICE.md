# Licences et attributions des composants vocaux

## FluidAudio

Le tokenizer SentencePiece et les helpers de découverte du schéma Core ML sont adaptés des sources de [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.2, par Fluid Inference et ses contributeurs, sous licence Apache-2.0. Le paquet et le moteur FluidAudio ne sont plus liés à Eudes. Les fichiers adaptés portent leur attribution et leurs modifications. Le texte complet se trouve dans `FluidAudio/LICENSE-Apache-2.0.txt`.

## PocketTTS (Kyutai)

Le modèle [PocketTTS](https://huggingface.co/kyutai/pocket-tts), créé par [Kyutai](https://kyutai.org), est distribué sous licence CC-BY-4.0. La conversion Core ML est fournie par [Fluid Inference](https://huggingface.co/FluidInference/pocket-tts-coreml). Voir `PocketTTS/NOTICE.md` pour les attributions et les voix. Les voix sous licence non commerciale Expresso et EARS ne sont ni téléchargées ni proposées.

## Transcription Apple

La transcription locale en français utilise SpeechTranscriber / SpeechAnalyzer d’Apple sur appareils compatibles, sans composant tiers de transcription embarqué par Eudes.


## llama.cpp et LFM3

Le moteur [llama.cpp](https://github.com/ggml-org/llama.cpp), version b12236, est distribué sous licence MIT ; voir `LlamaCpp/LICENSE.txt`. Les modèles [LFM3 1.7B](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF) et [LFM3 VL 2B](https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF) sont proposés sous LFM Open License v1.0 ; voir `LFM3/LICENSE.txt`. Ils sont téléchargés séparément après accord de l’utilisateur.

## Application

Eudes lui-même est distribué sous **GNU General Public License v3** (voir `Application/LICENSE.txt`). Le code source correspondant est publié à l’adresse du dépôt du projet. Une **permission supplémentaire** au titre de la section 7 de la licence autorise la distribution par les magasins d’applications (App Store, TestFlight) ; son texte accompagne la licence dans `Application/LICENSE-EXCEPTIONS.txt` et ne restreint aucun droit accordé par la GPL.

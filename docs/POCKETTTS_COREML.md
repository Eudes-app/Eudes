# PocketTTS avec Core ML directement

Eudes exécute le modèle français PocketTTS via les API Apple Core ML, sans
import ni dépendance Swift Package FluidAudio. `PocketCoreMLEngine` est un acteur
Swift distinct de l’interface. Il charge uniquement les fichiers locaux vérifiés
et n’a aucun accès réseau. AVFoundation conserve la lecture progressive et la
vitesse réglable. L’annulation est contrôlée entre les prédictions ; une
prédiction Core ML synchrone déjà engagée se termine avant l’arrêt.

Le modèle reste la conversion `FluidInference/pocket-tts-coreml`, révision
`c2e998e269e4d4b51f74061faddb8450cd8f9a9a`, export `v2.1/french_24l`.
Supprimer le moteur FluidAudio ne change pas la provenance des modèles.
Les 24 voix autorisées, les empreintes, les confirmations de téléchargement
et la suppression explicite sont conservées. Le chemin historique
`FluidAudio-v1/Models/pocket-tts` est volontairement conservé pour réutiliser les
téléchargements Core ML existants sans migration destructive.

## Exécution

1. Charger le tokenizer SentencePiece et la table d’embeddings français.
2. Charger le cache de voix pré-calculé (`.safetensors`, 24 couches). Il contient
   déjà le préfixe BOS de la voix ; aucun second préfixe n’est ajouté.
3. Préparer le texte avec `cond_prefill` et générer avec `flowlm_stepv2`.
4. Exécuter `flow_decoder_fused`, température 0,7, puis `mimi_decoder`.
5. Livrer les blocs de 1 920 échantillons à 24 kHz à AVFoundation.

Le moteur utilise CPU/GPU. L’export rank-5 signale le premier pas par NaN ;
il n’est pas envoyé à l’ANE. Les caches de texte sont réinitialisés par passage,
le décodeur audio conserve sa continuité entre passages. Les phrases sont
découpées selon les tokens et la capacité de génération restante. Le moteur
conserve huit trames après la détection EOS ; atteindre la limite avant la fin
produit une erreur explicite. L’app ne considère pas une parole tronquée comme
une synthèse réussie. Le repli iOS existant reste disponible avant toute lecture.

Le tokenizer et les helpers de découverte du schéma sont adaptés de FluidAudio
0.18.2 (Apache-2.0), avec attribution dans chaque fichier et dans les crédits.
Le gestionnaire FluidAudio, son téléchargement, ses réglages globaux et les
autres moteurs de la bibliothèque ne sont pas embarqués.

## Validation

Les tests couvrent les caches K/V des voix, les fichiers malformés, la conversion
audio Float16, les strides, la conservation du texte lors du découpage et
l’annulation avant chargement. Le test d’inférence français existant utilise
désormais le moteur direct pour Estelle, Fantine et Alba. Il vérifie le signal
et l’identité entre blocs et résultat complet ; il ne mesure pas la qualité
perçue. Il est ignoré si les modèles publics ne sont pas disponibles.

Sur Mac avec un cache vérifié :

```sh
TEST_RUNNER_EUDES_COREML_FIXTURES=/chemin/vers/PocketTTS bash tools/test-ios.sh
```

La variable historique `EUDES_FLUID_FIXTURES` reste acceptée. Le dossier fourni
contient `FluidAudio-v1/Models/pocket-tts` et le marqueur de validation d'Eudes.
Aucun téléchargement n’est effectué par les tests.

L’environnement de modification est Linux, sans Xcode. La compilation et les
XCTest doivent être vérifiés par le workflow macOS. Les anciens résultats de
FluidAudio ne valident pas ce nouveau moteur. Aucune installation ni écoute
sur iPhone n’est réalisée par cette modification. Latence, mémoire, Bluetooth,
verrouillage et disparition des bruits restent à vérifier sur appareil.

## Variante expérimentale française 6 couches

La variante `Français · 6 couches expérimental` utilise le modèle Kyutai d’octobre 2026 converti par Line of Flight, sans FluidAudio. Les fichiers sont épinglés à la révision `f056529a59b35950bfb67750b7e6a021e9db8376` de `lineofflight/pocket-tts-coreml`, vérifiés par SHA-256 après téléchargement, et stockés séparément du modèle 24 couches. Le modèle provient de `kyutai/pocket-tts-without-voice-cloning` à la révision `a7056f505a4a8ca72d8b5fb1440071d6f1a35739`. Attribution : Kyutai, CC-BY-4.0 ; conversion : https://huggingface.co/lineofflight/pocket-tts-coreml.

Le pack utilise six caches clé/valeur séparés et le vecteur BOS explicite ; les états initiaux Mimi sont fournis par la conversion. Il propose l’intersection des voix autorisées par Eudes et de celles présentes dans le pack. Le modèle 24 couches est conservé lorsqu’on change de variante ou supprime le modèle sélectionné.

L’essai XCTest optionnel utilise `TEST_RUNNER_EUDES_EXPERIMENTAL_6L_FIXTURES` pointant vers une copie locale du dépôt vérifiée ; il produit un fichier WAV pour l’écoute. La génération numérique sur simulateur ne prouve ni la qualité audible, ni la latence, ni le fonctionnement sur iPhone physique.

## Assistant vocal en arrière-plan

L’assistant en arrière-plan, y compris les sessions Siri, utilise Core ML en mode CPU uniquement. iOS restreint l’accès au GPU pour une app en arrière-plan ; les aperçus à l’écran conservent le mode CPU/GPU. Lors d’un changement de contexte, le moteur est rechargé avec la politique correspondante. Le mode CPU peut être plus lent : la fluidité et le comportement sur iPhone verrouillé nécessitent une validation sur appareil. L’avertissement de synthèse précédent est effacé après une lecture PocketTTS terminée avec succès ; il ne prouve pas à lui seul la cause d’un échec antérieur.

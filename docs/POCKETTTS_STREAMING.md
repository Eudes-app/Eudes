# Essai de lecture progressive PocketTTS

Note historique : cet essai concernait l'ancienne implémentation sherpa-onnx,
remplacée depuis par FluidAudio (voir `POCKETTTS_FLUIDAUDIO.md`).

Le callback sherpa fournit les buffers PCM pendant le décodage ; ils sont copiés
avant son retour puis mis en file pour AVAudioPlayerNode. Le callback ne commence
qu'après la génération des latents de la phrase courante. L'annulation arrête
le moteur et invalide les callbacks tardifs. Les erreurs après début de lecture
ne déclenchent pas une relecture complète par le moteur iOS. La mise à l'échelle
finale des silences est désactivée en mode progressif car elle n'est pas appliquée
aux buffers du callback ; les tests comparent les échantillons reçus au résultat
final avec cette configuration.

Sonde Mac (sherpa-onnx 2.0.1, modèle français, Estelle, 8 étapes) :
- Phrase d'aperçu : première sortie callback 1,553 s / génération terminée 1,601 s ; répétition 1,067 s / 1,130 s.
- Phrase plus longue : 1,883 s / 2,413 s ; répétition 2,320 s / 2,865 s.

Ces chiffres chronomètrent l'inférence chargée et les callbacks, pas le début
sonore sur iPhone ni le coût initial de chargement. Les entrées sont synthétiques.
La génération réelle et l'ordre des échantillons sont testés par le test
optionnel EUDES_POCKET_FIXTURES. Latence audible, coupures, Bluetooth et énergie
sur iPhone restent à mesurer.

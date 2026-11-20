> Historique : remplacé par le [moteur Core ML direct](POCKETTTS_COREML.md). Les résultats ci-dessous concernent uniquement l’ancien moteur.

# Migration PocketTTS vers FluidAudio

FluidAudio 0.18.2 est épinglé dans Package.resolved. Le modèle français Core ML
`FluidInference/pocket-tts-coreml` est épinglé à la révision
`c2e998e269e4d4b51f74061faddb8450cd8f9a9a`. L'inventaire embarqué contient les
empreintes de 49 fichiers : SHA-256 pour les fichiers LFS et SHA-1 Git pour les
fichiers ordinaires. La taille est vérifiée et chaque fichier est haché hors du
thread principal avant validation. L'interface annonce environ 1,6 Go et
conserve les confirmations et l'annulation, y compris la confirmation cellulaire.

Seules les 24 voix autorisées réellement disponibles dans ce modèle sont
proposées. `cosette` et `jean` sont exclus des téléchargements et de l'interface.
La voix `daan` n'est pas présente dans le modèle. Une ancienne sélection
inconnue revient à Estelle. L'ancienne installation ONNX est préservée jusqu'à
ce que l'utilisateur choisisse explicitement de la supprimer.

L'inférence impose le mode hors ligne FluidAudio et exige le cache complet ;
aucun téléchargement n'est lancé pour un aperçu ou une réponse. Les logs
FluidAudio de niveau info/debug, qui peuvent contenir du texte, sont désactivés.
La sortie est lue progressivement et le réglage de vitesse passe par un nœud
AVAudioUnitTimePitch. En cas d'erreur avant lecture l'assistant peut utiliser la
voix système ; l'annulation ne déclenche pas de relecture.

Tests : `TEST_RUNNER_EUDES_FLUID_FIXTURES=/path/to/fixture bash tools/test-ios.sh`
exécute des synthèses françaises Core ML hors ligne avec trois voix ; sans fixtures,
ce test est explicitement ignoré. Les fichiers de test sont publics et ne
contiennent pas de données utilisateur. La qualité, la vitesse, l'usage mémoire,
la batterie, le verrouillage et le routage audio restent à mesurer sur iPhone.

## Validation locale du 7 novembre 2026

Une précédente suite complète : 421 XCTest, zéro échec ni test ignoré avec les fixtures Core ML
publiques. Trois phrases françaises ont été générées par le code Swift réel sur
simulateur ; leurs échantillons sont finis, non silencieux, et identiques à la
suite des blocs. Une transcription automatique indépendante et locale retrouve
les trois phrases, y compris « aujourd'hui » et la dernière phrase complète.
Ce test ne remplace pas une écoute humaine. Lors d'un essai répété, la
transcription automatique a omis une fin de phrase ; un essai expérimental à
température 0,3 a produit un signal presque silencieux. Le réglage standard
de FluidAudio reste utilisé et la fiabilité de la parole n'est pas démontrée.

Le premier test de chargement/génération a pris environ 49 à 64 secondes selon
les exécutions. Le simulateur a émis des diagnostics Core ML / MPSGraph / E5RT,
et un relevé ponctuel pendant les essais indiquait environ 3,2 Gio de mémoire
résidente. Ces chiffres ne sont pas des mesures iPhone. Ils imposent une mesure
sur l'appareil physique avant de conclure sur la rapidité, la mémoire ou la
batterie. Aucune installation sur l'iPhone n'est incluse dans cette PR.


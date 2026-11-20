# Diagnostic PocketTTS français — ticket 16

L'utilisateur indique des bruits et coupures avec toutes les voix essayées,
déjà présents en 1.93, avant la lecture progressive. Le retour au lecteur
précédent ne peut donc pas être présenté comme un correctif démontré.

Le modèle français inclut une normalisation des apostrophes typographiques
(Kyutai, configuration french_24l). La chaîne envoyée à sherpa-onnx conservait
ces caractères : le tokenizer les encode comme trois jetons d'octets, au lieu
d'une apostrophe ordinaire. Comparaison Mac locale du modèle et de la voix
Estelle épinglés, sherpa-onnx 2.0.1, même référence et seeds 1, 42 et 128 :
une transcription automatique locale Whisper small rendait « aujourd’hui »
sous forme « au jour » aux trois essais sans normalisation, et « aujourd'hui »
aux trois essais avec normalisation. Ce contrôle automatique n'est pas une
validation humaine de la qualité sonore et n'établit pas que tous les bruits
ont disparu. D'autres sorties normalisées demeurent parfois mal transcrites.

Les remplacements concernent uniquement le texte transmis au TTS : apostrophes,
guillemets, parenthèses, tiret demi-cadratin et ponctuation. Les deux-points
entre chiffres sont conservés pour éviter d'altérer une heure. Les données et
messages de conversation ne sont pas modifiés. Les tests ne prouvent pas
l'absence d'artefacts sur iPhone, ni la justesse de toutes les voix et phrases.

Référence fabricant : https://github.com/kyutai-labs/pocket-tts/blob/main/pocket_tts/config/french_24l.yaml
Signalement amont sur l'intégration sherpa : https://github.com/k2-fsa/sherpa-onnx/issues/3755

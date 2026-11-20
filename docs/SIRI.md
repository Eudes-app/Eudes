# Utiliser l’assistant vocal Eudes depuis Siri

## Personnaliser les réponses vocales — 1.76 (78)

Dans **Réglages → Assistant vocal → Instruction vocale**, une instruction en anglais demande au modèle de répondre dans la langue de la demande, en une à deux phrases courtes, idéalement moins de 30 mots, sans emojis, Markdown, listes à puces ni tableaux. Le modèle peut développer sur demande explicite ou lorsque l’exactitude l’exige. Il s’agit d’une consigne au modèle, pas d’une coupure du texte généré.

Modifie le texte puis touche **Enregistrer**. Revenir en arrière abandonne les modifications. **Rétablir l’instruction par défaut** restaure le texte dans l’éditeur ; touche ensuite **Enregistrer** pour l’appliquer. Le choix est conservé sur l’iPhone et dans la configuration de l’assistant vocal lancé par Siri lorsqu’elle est activée.

La consigne s’ajoute aux instructions du serveur uniquement pour l’assistant vocal d'Eudes, y compris ses sessions lancées par Siri et ses réponses avec recherche Web. Les conversations écrites et l’action indépendante **Poser une question à Eudes** conservent leurs instructions habituelles. Le respect exact de la longueur et de la langue dépend du modèle choisi.

## Démarrer Eudes sans lui transmettre de question via Siri — 1.69 (71)

Le raccourci **Ouvrir l’assistant vocal Eudes** démarre maintenant une session vocale autonome, sans demander l’ouverture de l’application ni une authentification supplémentaire. L’identifiant existant est conservé. La phrase existante **« Siri, ouvrir l’assistant vocal d'Eudes »** et la nouvelle phrase **« Siri, démarrer l’assistant vocal Eudes »** ciblent cette même action, sans paramètre Question. Cette modification remplace explicitement son ancien comportement au premier plan. L’action **Poser une question à Eudes** reste indépendante.

### Préparation sur l’iPhone déverrouillé

1. Sélectionne le serveur et le modèle à utiliser.
2. Dans **Réglages → Assistant vocal**, **Apple · local** est sélectionné par défaut. Touche **Préparer Apple** pour autoriser le microphone et installer le modèle français si nécessaire. Cette étape doit être faite avant un lancement par Siri ; aucun téléchargement ni demande de permission ne démarre en arrière-plan.
3. Active **Siri, écran verrouillé** et autorise les activités en direct d'Eudes dans iOS. L’option conserve son activation précédente lors d’une mise à jour ; la préparation est à faire après installation de ce lot.
4. Dis directement **« Siri, démarrer l’assistant vocal Eudes »**, sans autre action ni paramètre. Aucun raccourci personnel à créer n’est nécessaire. Si un raccourci iOS personnel ouvre seulement Eudes, teste d’abord cette commande directe avant de revoir le contenu du raccourci.

Eudes dit « Je t’écoute », transcrit avec le modèle Apple local, interroge le modèle sélectionné et lit sa réponse avec la voix choisie dans Eudes. Elle recommence ensuite à écouter, avec le contexte des tours précédents. Seule la réponse finale est lue, jamais le thinking. **Arrête Eudes**, **Stop Eudes** ou le bouton **Arrêter** de l’activité terminent la session. Le bouton Arrêter apparaît aussi dans les réglages tant que la session existe.

Pour la lecture des réponses, choisis les voix système iOS ou **PocketTTS · local** dans **Réglages → Assistant vocal → Synthèse vocale**. Le modèle PocketTTS français Core ML (environ 1,6 Go avec les voix) n’est téléchargé qu’après confirmation explicite — avec une confirmation supplémentaire si la connexion est cellulaire — et fonctionne ensuite hors ligne.

Depuis la version 1.70 (72), deux notes discrètes indiquent qu'Eudes attend la réponse du modèle. Le premier signal arrive après 0,4 seconde, puis se répète toutes les 4 secondes. Il cesse avant la réponse parlée, à l’arrêt ou en cas d’erreur. Ce retour sonore est aussi présent dans l’assistant ouvert à l’écran ; il suit le volume multimédia et la sortie audio de la session. Une réponse plus rapide que le premier signal reste silencieuse.

L’activité affiche uniquement une phase (préparation, écoute, réflexion, réponse), sans transcription, réponse, nom de serveur ni clé. Elle est requise par le parcours AudioRecordingIntent. Le microphone reste réellement actif pendant cette session explicite pour éviter de le réactiver après chaque réponse en arrière-plan ; les échantillons sont conservés et transcrits uniquement pendant la phase d’écoute. Ils sont ignorés pendant la réponse et l’attente du modèle. Aucun faux son silencieux ni API d’appel téléphonique n’est utilisé.

La session se termine après 12 secondes sans début de parole, 10 minutes au total, une interruption audio ou une déconnexion de sortie. Une prise de parole est limitée à 45 secondes. La détection de fin attend environ 2,5 secondes de silence. Le backend autorise 20 tours et 128 Kio de texte maximum sans tronquer silencieusement le contexte, et attend au plus 120 secondes une réponse de modèle. Le plafond connu du modèle est vérifié avant chaque tour. Le bouton Arrêter reste utilisable pendant une génération ou une réponse parlée.

Chaque tour terminé est conservé dans la même conversation en attente du trousseau. L’import dans l’historique attend la fin de session et l’accès aux données protégées ; les tours déjà terminés restent récupérables après arrêt du processus. Aucun brouillon ni historique préexistant n’est envoyé. La révocation de l’option ou le changement de configuration annulent la session et la requête en cours.

La transcription Apple utilise `SpeechAnalyzer` et `SpeechTranscriber` sur iOS 26 ou ultérieur et sur les appareils/langues pris en charge. Le modèle est géré par iOS ; sa disponibilité est vérifiée à chaque préparation, y compris après relancement d'Eudes. Si Apple est indisponible, Eudes explique le problème dans les réglages, sans bascule automatique. Le choix est conservé pour toute la session. Les API Apple locales ne demandent pas l’autorisation de reconnaissance vocale des API serveur ; seule la permission microphone est nécessaire.

Aucun poids de reconnaissance tiers n’est préparé. Les conversations ordinaires restent protégées. Le calcul Apple local utilise CPU et Neural Engine, sans GPU. Après redémarrage de l’iPhone, un premier déverrouillage est nécessaire.

### Limites de validation

Retour utilisateur du 1er novembre 2026 : le lancement de l’assistant fonctionne ; l’échec précédent était lié au raccourci iOS utilisé, selon l’utilisateur. Aucun correctif de code ni réinstallation n’ont été nécessaires. Ce retour confirme le lancement, sans constituer une validation de tous les scénarios audio ou de CarPlay.

La configuration utilise les API publiques `AudioRecordingIntent`, `AudioPlaybackIntent` et `LiveActivityIntent`, avec exécution en arrière-plan. Ce protocole d’enregistrement nécessite iOS 18 ou ultérieur ; l’assistant depuis l’écran d'Eudes reste disponible sous iOS 17. Les métadonnées compilées attestent ces déclarations, pas l’acceptation par Siri/CarPlay.

Le transfert réel du microphone de Siri vers Eudes, le lancement à froid sur écran verrouillé, les performances de la synthèse PocketTTS et le routage CarPlay nécessitent un essai physique. Le modèle Apple local reste soumis aux restrictions d’iOS en arrière-plan. En cas de refus, un message est renvoyé par l’action et conservé dans **Réglages → Assistant vocal**. Aucun succès vocal réel n’est déduit d’une compilation ou de la fixture simulateur sans audio.

Références : [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent), [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent), [AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent).

## Poser une question sans ouvrir Eudes

1. Choisis le serveur et le modèle à utiliser dans Eudes.
2. Dans **Réglages → Assistant vocal**, active **Siri, écran verrouillé**. Cette option autorise Eudes à conserver une copie dédiée de la configuration et de la clé API, accessible après le premier déverrouillage de l’iPhone suivant un redémarrage. Elle est désactivée par défaut.
3. Vérifie dans les réglages iOS que Siri est autorisé lorsque l’écran est verrouillé.
4. Dis **« Siri, poser une question à Eudes »**. Siri recueille la question, Eudes consulte le modèle en arrière-plan, puis Siri lit la réponse.

L’action **Poser une question à Eudes** conserve son identifiant et sa phrase mais change de fonctionnement : elle ne demande plus l’ouverture de l’app et retourne désormais le texte et un dialogue Siri. Elle expose un champ **Question** dans Raccourcis. Un raccourci personnel contenant cette action seule peut être conservé ; si iOS conserve son ancienne définition ou force l’ouverture d'Eudes, retire puis réajoute l’action et n’ajoute pas d’action « Ouvrir l’app ».

Dans ce parcours, la reconnaissance et la voix de réponse sont celles de **Siri**, selon ses réglages et le traitement prévu par Apple. Aucun modèle de reconnaissance tiers n’est démarré. Le serveur choisi reçoit uniquement la nouvelle question et les instructions configurées ; le brouillon et l’historique existant ne sont pas transmis. Il s’agit d’une question indépendante à chaque invocation, pas d’une écoute continue.

Les réponses complètes sont conservées temporairement dans un espace dédié du trousseau, accessible après le premier déverrouillage, puis ajoutées aux conversations lors du retour dans Eudes déverrouillé. Elles n’écrasent pas la conversation sélectionnée ni le brouillon. La protection des conversations existantes et des clés API ordinaires reste inchangée. Désactiver l’option révoque la configuration dédiée ; les réponses déjà obtenues attendent leur import dans l’historique.

Siri impose une durée d’exécution limitée. Eudes arrête l’attente après environ 25 secondes et signale si le modèle est trop lent. Choisis un modèle réactif pour ce parcours ; il n’y a ni relance automatique, ni changement silencieux de serveur. Le modèle Apple reste soumis à sa disponibilité et aux restrictions de calcul en arrière-plan d’iOS.

Ce parcours est conçu pour éviter l’ouverture de l’app refusée dans les contextes vocaux tels que CarPlay. La compilation et les tests automatisés ne garantissent pas son acceptation par Siri dans chaque voiture : un test réel avec l’iPhone verrouillé et CarPlay connecté reste nécessaire. Après chaque redémarrage de l’iPhone, un premier déverrouillage est indispensable avant l’accès à la configuration dédiée.

## Utiliser l’assistant depuis l’écran d'Eudes

Le parcours avec interface utilise le même choix de transcription que Siri. Son écoute reste liée à cet écran ; le lancement Siri décrit plus haut utilise un service distinct indépendant de l’écran. L’accès direct à cette interface reste actuellement réservé au scénario de validation ; ouvrir Eudes pendant une session Siri affiche sa visualisation.

Dans l’app :

1. **Réglages → Assistant vocal → Transcription** : **Apple · local** est le seul moteur, par défaut y compris après mise à jour. Sous iOS 17 à 25 ou sur un appareil non pris en charge par Apple, la transcription locale est indisponible et Eudes l’indique.
2. Autorise le microphone. Apple peut télécharger le modèle français lors de la préparation au premier plan.
3. Eudes demande « Que souhaites-tu faire ? », puis écoute. Une courte pause termine l’écoute ; **J’ai terminé** reste disponible.
4. Le texte est envoyé au modèle choisi, une conversation est créée et la réponse est lue par la voix iOS sélectionnée dans Eudes.

L’audio transcrit par Apple reste en mémoire sur l’iPhone. Eudes utilise ces modèles pour la transcription et ne les entraîne pas sur les enregistrements. Le lancement par Siri reste soumis au traitement de Siri par Apple. Le téléchargement des poids est distinct et n’envoie pas d’enregistrement vocal.

Ces parcours posent des questions au modèle et lisent ses réponses. Ils ne créent pas de rendez-vous ni d’itinéraires et n’envoient pas de messages.


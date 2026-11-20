# Actions vocales sur iPhone

L’assistant vocal au premier plan reconnaît des commandes françaises simples sans appel au LLM. Pour les formulations plus libres, il demande au modèle sélectionné une proposition JSON, puis valide les paramètres avant de présenter une confirmation. Aucun Raccourci iOS n’est utilisé.

## Commandes locales

- « Ouvre Spotify », « Lance Waze » : Deezer, Spotify, Waze, YouTube, WhatsApp, Plans, Messages et Mail. L’application doit être installée et accepter son schéma d’ouverture ; un échec est signalé.
- « Ouvre wikipedia.org » : site HTTPS explicite.
- « Recherche sur le Web horaires du Louvre » : recherche dans le navigateur via Google.
- « Cherche dans Plans une pharmacie » : recherche dans Plans.
- « Itinéraire vers Bordeaux » : préparation de l’itinéraire dans Plans, sans démarrer une navigation automatique.
- « Écris à Paul : j’arrive » : proposition de SMS. Messages permet de choisir Paul puis de vérifier et envoyer le message. Un nom n’est jamais traité comme un numéro ; le carnet d’adresses n’est pas envoyé au LLM.
- « Rappelle-moi de téléphoner demain à 9 h » : proposition de rappel, avec alarme après confirmation.
- « Ajoute Dentiste demain à 14 h pendant 1 heure » : proposition d’événement avec durée explicite.

Les titres, dates et heures des rappels/événements restent modifiables avant création. Les permissions iOS sont demandées uniquement au moment de confirmer : écriture seule pour Calendrier, accès Rappels requis par EventKit. Eudes ne lit pas les événements ni les rappels existants pour cette fonction.

## Interprétation par le modèle

Les demandes susceptibles de contenir une action passent par le transport texte existant (Chat Completions, Responses ou modèle Apple). Aucun support natif du tool calling n’est exigé. Les fragments réseau et les instantanés cumulatifs Apple sont traités séparément. Une sortie invalide, une application inconnue ou des paramètres manquants ne déclenchent aucune action.

Le modèle n’a accès qu’à la demande et aux précisions de ce tour, sans historique privé ni contacts. Une clarification peut être suivie en choisissant « Poser une autre question ». « Annule » abandonne ce contexte. Une demande combinant plusieurs actions doit être précisée : cette version exécute une action à la fois. Les questions ordinaires conservent le circuit de conversation et de recherche Web existant.

Les ouvertures reconnues localement se déclenchent après la réponse parlée. Les propositions du LLM et les créations nécessitent « Vérifier l’action ». Le résultat de la confirmation est affiché dans l’assistant ; aucun envoi de SMS ni création n’est annoncé avant le retour de l’API correspondante.

## Limites et validation

- Actions disponibles dans l’assistant ouvert sur l’iPhone déverrouillé. La conversation vocale d’arrière-plan conserve les commandes nécessitant une interface jusqu’à l’ouverture d'Eudes ; sa recherche Web reste disponible.
- Pas de contrôle des boutons d’autres applications, de modification des réglages système, de suppression, d’appels téléphoniques ou d’e-mails dans ce lot.
- La reconnaissance locale couvre les formulations ci-dessus ; les variantes passent par le modèle, dont la qualité d’interprétation dépend du modèle choisi.
- Les tests automatisés utilisent des réponses LLM simulées : ils vérifient les formats, pas la fiabilité de chaque fournisseur réel.
- Les vérifications sur simulateur ne prouvent pas le fonctionnement de Messages, des applications tierces, de la dictée réelle ou de Siri sur iPhone physique.

Références API : [EventKit](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [MessageUI](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller), [ouverture d’URL](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)).

### Vérification du 5 novembre 2026

- Xcode 27.2, simulateur iPhone Duo iOS 27.1 : **410 tests réussis, zéro échec** sur le code final.
- Résultat local : `build/test-results/20261105T213047Z-19680/EudesTests.xcresult`.
- Couverture ajoutée : commandes directes et négations/citations, encodage des URL, refus des schémas et sorties non autorisés, dates locales et durée, SMS, séparation recherche Web/arrière-plan, flux réseau et Apple sans modification de l’historique.
- Aucun test d’envoi de SMS, de création dans un compte personnel ou d’ouverture d’application tierce sur un iPhone physique.
- Vérification visuelle sur Eudes Composer QA iPhone 18 Pro, iOS 27.0 : rappel clair, événement clair/sombre, SMS sombre, annulation et indisponibilité SMS du simulateur. Titres, dates locales et boutons lisibles sans chevauchement. Captures dans `../validation/voice-actions-2026-11-05/ui/`. Session QA fermée.

### Correction du lancement par raccourci — 1.84 (86)

Le raccourci existant « Ouvrir l’assistant vocal Eudes » ouvre désormais Eudes au premier plan et son écran vocal, au lieu de démarrer la session de l’île dynamique. Son identifiant et ses phrases sont conservés. iOS demande l’authentification si l’appareil est verrouillé ; un appareil déjà déverrouillé passe directement au parcours vocal d'Eudes. Une éventuelle ancienne session de fond est arrêtée avant la prise du microphone par l’écran vocal. Le message de refus en arrière-plan indique maintenant qu'Eudes doit être affiché, sans assimiler arrière-plan et verrouillage.

411 tests réussis sur simulateur. Métadonnées App Intents du paquet iPhone vérifiées : `OpenEudesVoiceIntent`, `openAppWhenRun=true`, mode foreground, sans protocoles audio d’arrière-plan. Le véritable lancement depuis le raccourci personnel sur iPhone reste à vérifier par l’utilisateur.

Contrôle complémentaire : avec le paquet simulateur exact 1.84 (86), lancement depuis Raccourcis > Apps > Eudes > Ouvrir l’assistant confirmé : Eudes passe au premier plan et affiche l’écran vocal. La transcription Apple locale est indisponible sur ce simulateur ; aucune validation acoustique n’en est déduite. Un premier essai utilisait un ancien paquet Xcode 1.82 et a été exclu de cette validation.

### Barres vocales, disponibilité du micro et Siri — 1.89 (91)

Cinq barres remplacent le portrait : leur hauteur suit le niveau audio lissé (attaque rapide, relâchement plus doux), sans oscillation artificielle au silence. Le rendu existe dans l’écran vocal et dans la visualisation mains libres. Le mode Réduire les animations désactive l’interpolation continue.

L’écran annonce « Préparation du microphone… » jusqu’au démarrage effectif du moteur audio, puis « Je t’écoute… ». La session audio reste active entre la synthèse et l’écoute pour éviter la désactivation/réactivation de la route. La baisse réelle de latence et les débuts de phrases restent à vérifier sur iPhone/Bluetooth.

Deux commandes explicites sont disponibles :
- « Siri, ouvre l’assistant vocal Eudes » : ouvre Eudes, avec actions au premier plan ; déverrouillage requis par iOS. Cette formulation exacte est ajoutée aux phrases existantes, conservées.
- « Siri, parler à Eudes mains libres » : conversation dans l’île dynamique, même écran verrouillé si « Siri, écran verrouillé » a été activé et la transcription préparée dans Eudes. Les actions nécessitant une interface demandent toujours d’ouvrir Eudes.

Les commandes Siri sont réindexées au lancement. Une phrase publiée et des tests réussis ne prouvent pas la reconnaissance Siri sur l’appareil de l’utilisateur.

### Lancement unifié et retour depuis l’activité — 1.90 (92)

Les deux phrases publiées (« Ouvre l’assistant vocal Eudes » et « Parler à Eudes mains libres ») démarrent désormais la même session en arrière-plan. Leurs identifiants restent compatibles avec les raccourcis existants. Si une session tourne déjà, la commande ne la redémarre pas. Ce comportement remplace les deux parcours Siri distincts décrits dans les versions précédentes.

Préparer la transcription et le microphone dans Eudes, puis activer « Siri, écran verrouillé » reste nécessaire. L’activité affiche uniquement l’état et un identifiant opaque. Toucher sa carte ou la Dynamic Island ouvre l’interface de la session existante, après le déverrouillage demandé par iOS. Aucun nouvel enregistrement ni nouvelle conversation ne sont créés par ce lien ; un lien périmé ne relance pas l’assistant.

Une commande reconnue comme nécessitant l’écran (par exemple « Ouvre Deezer ») reste en mémoire jusqu’à l’affichage d'Eudes. Les ouvertures locales sont alors exécutées une seule fois ; les propositions du modèle et les créations passent par la vérification existante. Les questions ordinaires restent dans le même contexte de conversation. Masquer l’interface conserve l’écoute ; le silence relance l’écoute sans préparer à nouveau le moteur audio.

Pendant l’attente d’une action ou de sa confirmation, l’écoute est suspendue : utiliser le bouton Arrêter de l’activité ou de l’interface pour terminer. La durée maximale et les protections de consentement restent applicables. Les actions complexes restent dépendantes du routage et de l’interprétation du modèle ; cette version ne permet pas de piloter arbitrairement les autres applications.

422 tests réussis sur le code final, dont attente/reprise d’action dans la même session, exécution unique, confirmation, rejet des retours périmés, conversation ordinaire inchangée, liens d’activité et reprise après silence. Le fonctionnement Siri/verrouillé et l’audio réel nécessitent toujours une validation sur iPhone.

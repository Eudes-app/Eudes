# Outils natifs du modèle Apple

Quand le Web est autorisé pour le chat ou l’assistant vocal, Eudes fournit au modèle local Apple deux outils Foundation Models :

- `web_search(query)` recherche depuis l’iPhone et retourne les sources numérotées du tour.
- `web_fetch(source)` lit une de ces sources avec le lecteur HTTPS existant.

La session native reçoit les instructions et l’historique complet avec ses rôles. Foundation Models choisit les outils, génère leurs arguments typés et réutilise leurs résultats. Une session distincte produit ensuite la réponse avec les sources collectées, comme pour les moteurs distants. Aucune clé ni requête de modèle distant n’est utilisée pour Apple. Les outils Web nécessitent Internet.

Les réglages Web du chat et de la voix restent applicables. Une salutation peut ne produire aucun appel. Si le modèle ne demande aucun outil malgré une demande explicite de recherche, le secours Eudes est identifié comme tel dans la trace. Une indisponibilité Apple reste une erreur explicite, sans bascule vers un modèle distant.

Le budget partagé est contrôlé dans le code avant chaque appel, y compris les appels invalides ou répétés. Les callbacks natifs sont sérialisés afin qu’un arrêt au plafond ne perde pas une recherche déjà acceptée. Chaque tour possède sa propre table de sources ; un numéro d’un ancien tour n’autorise aucune lecture. Les limites réseau, la validation des URL, le refus des redirections, et le marquage des données Web non fiables restent ceux des services existants.

L’annulation interrompt la recherche. Une limite de contexte native peut arrêter la collecte en conservant ses sources ; la synthèse vérifie ensuite son propre contexte, sans supprimer silencieusement l’historique. Les erreurs de lecture conservent l’extrait et une trace d’échec, sans prétendre que la page a été lue.

Les anciens historiques avec le motif `appleLocal` restent décodables. Les nouvelles recherches Apple portent des appels d’origine `model` et les sources restent affichées par l’interface existante.

## Validation

Les tests déterministes injectent la session native et les services Web : ils couvrent le routage Apple, le chat et les deux parcours vocaux, les réglages Web désactivés, la transmission des sources à la synthèse, le budget, les appels concurrents, les doublons, les arguments invalides, les erreurs, l’annulation et les limites de contexte. Les outils `Tool` et leurs schémas `@Generable` sont compilés avec le SDK installé.

À vérifier sur un iPhone compatible avec Apple Intelligence activé : sélection réelle des outils en français, recherche suivie d’une lecture, arrêt en cours, pertinence de la réponse et latence. Les tests simulés ne prouvent pas ces comportements du modèle installé. Les actions à effets de bord (rappels, calendrier, messages) ne sont pas exposées par cette intégration Web et conservent leurs confirmations existantes.

Validation locale du 6 novembre 2026 : **439 XCTest réussis, 0 échec**, dont 16 tests `AppleWebResearchTests`, via `bash ../tools/test-ios.sh` depuis `ios/`, Xcode 27.2 (27B52), simulateur iPhone Duo iOS 27.1. Résultat : `build/test-results/20261106T222424Z-22577/EudesTests.xcresult`. Le simulateur était déjà démarré avant la tâche et a été préservé. Aucun avertissement de compilation dans les nouveaux fichiers lors de ce dernier passage. Xcode a signalé un échec de collecte des diagnostics additionnels (`simctl` introuvable dans son sous-processus) après les tests ; le bundle de résultats existe et la suite termine avec `TEST SUCCEEDED`.

# Eudes — client iOS pour tes LLM locaux

Projet natif SwiftUI : discuter avec un serveur compatible OpenAI (vLLM, llama.cpp, LM Studio, Ollama…), avec le modèle Apple embarqué dans iOS, ou avec un modèle GGUF téléchargé sur l'iPhone et exécuté par llama.cpp. Interface française, claire ou sombre selon iOS, iPhone et iPad, iOS 17 minimum ; la voix et le modèle Apple demandent iOS 26. Aucun compte Eudes, aucun service d'analytics, aucun serveur de l'éditeur : les conversations et les réglages restent sur l'appareil, sauf vers le serveur ou le modèle que tu as choisi.

**État : application en développement, distribuée hors App Store par sideloading. Version 1.111 (build 113).** GitHub Actions lance les tests après validation de la review ; la compilation de livraison et la fusion suivent une validation finale manuelle, selon [les parcours de livraison](docs/DELIVERY_WORKFLOWS.md). Les résultats réels sont dans [Actions](https://github.com/Eudes-app/Eudes/actions), l'histoire des versions dans [CHANGELOG.md](CHANGELOG.md).

## Instructions pour les assistants IA

Lire [AGENTS.md](AGENTS.md), puis le [skill de suivi Eudes](.agents/skills/eudes-development-cycle/SKILL.md)
avant de modifier le dépôt ou d'en rapporter l'avancement. Cette version du skill est la référence
pour le checkout courant ; elle décrit l'affichage des étapes, tandis que GitHub Actions gère
les automatismes. Un outil qui ne charge pas `AGENTS.md` automatiquement doit être configuré
pour le lire explicitement. La présence des fichiers ne garantit pas leur lecture par tous les outils.

Ce dépôt est public : **aucun nom, prénom, adresse, adresse e-mail, identifiant d'appareil, adresse
réseau privée réelle, jeton ou clé ne doit être écrit** dans le code, les documents, les commits,
les issues, les pull requests, les commentaires de revue, les captures ou les artefacts. Les règles
et les formulations neutres attendues sont dans [AGENTS.md](AGENTS.md#never-publish-personal-data).

## Structure du dépôt

Tout le code est dans [ios/](ios/). Ouvrir `ios/Eudes.xcodeproj`, pas un fichier Swift isolé.

| Chemin | Contenu |
|---|---|
| `ios/Eudes/App` | point d'entrée et état applicatif |
| `ios/Eudes/Core` | modèles, URLs et endpoints locaux, décodeur SSE |
| `ios/Eudes/Services` | réseau, stockage privé, trousseau, moteur llama.cpp, PocketTTS, Siri, recherche Web |
| `ios/Eudes/UI` | vues SwiftUI et design system |
| `ios/Eudes/Shared` | App Intents et attributs d'activité partagés avec le widget |
| `ios/EudesTests` | suite XCTest |
| `ios/EudesVoiceWidget` | widget et Live Activity de l'assistant vocal |
| `ios/Packages/EudesLlama` | paquet local autour de llama.cpp, épinglé à une révision |
| `tools/`, `tests/` | scripts de développement et tests Python, jamais embarqués dans l'app |

`ios/Version.xcconfig` porte la version de base ; les numéros de livraison sont réservés dans le registre GitHub commun, selon la [procédure de versionnement des IPA](docs/IPA_VERSIONING.md). La carte du code, les protocoles internes et les flux sont décrits dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Les trois moteurs

1. **Serveur compatible OpenAI** — Chat Completions par défaut, Responses en option, protocole choisi par connexion. Les domaines de fournisseurs sont autorisés avec validation TLS et refus des redirections ; la boucle locale (`localhost`, `127.0.0.1`, `[::1]`) est acceptée. Voir [protocoles et limites](docs/PROTOCOLS.md) et [boucle locale](docs/LOCALHOST.md).
2. **Modèle Apple** — `SystemLanguageModel` sur iOS 26+ avec Apple Intelligence activé. Aucune clé ni requête distante pour le modèle ; la recherche Web passe par les outils natifs `web_search` et `web_fetch`, décrits dans [outils natifs du modèle Apple](docs/APPLE_TOOLS.md).
3. **Modèles GGUF sur l'iPhone** — llama.cpp compilé dans l'app, catalogue de modèles à licence compatible distribution : LFM3 1.7B et VL 2B, Qwen3.5 2B et 4B, Qwen3 1,7B et 4B, Qwen3-VL 2B et 4B, Gemma 4 E2B et E4B, SmolLM3 3B, Phi-4-mini. Les fichiers sont téléchargés depuis Hugging Face à la demande, vérifiés par SHA-256, puis exécutés en Metal au premier plan et en CPU lorsque l'app n'est plus active. La fenêtre de contexte est calculée par modèle à partir de la mémoire réellement disponible, voir [contexte et longueur de réponse](docs/CONTEXT.md).

## Ce que fait Eudes

- Chat en streaming, Markdown et blocs de code, arrêt et régénération ; les réponses partielles ne sont pas réinjectées dans le contexte.
- Images en entrée avec les modèles texte et vision (`LFM3 VL 2B`, `Qwen3-VL 2B` et `4B`) : photothèque ou presse-papiers, avec avertissement si le modèle choisi est purement textuel.
- Plusieurs profils de serveurs, clé API facultative dans le trousseau, découverte via `/models`, identifiants proposés depuis le catalogue public NVIDIA Build, ou identifiant de modèle saisi à la main si la découverte n'est pas disponible.
- Historique, recherche et suppression des conversations sur l'appareil ; le modèle est mémorisé avec chaque conversation.
- Instruction système, température, limite de tokens et fenêtre de contexte réglables.
- Vérification orthographique native dans le champ de message, sur l'appareil, désactivable ; voir [orthographe](docs/SPELLCHECK.md).
- Assistant vocal : transcription Apple locale (`SpeechAnalyzer`, iOS 26+), lecture par les voix système ou par PocketTTS en Core ML, Live Activity et poursuite de la session en arrière-plan ; voir [actions vocales](docs/VOICE_ACTIONS.md).
- Siri et Raccourcis : poser une question sans ouvrir l'app, ou lancer l'assistant vocal ; voir [Siri et Raccourcis](docs/SIRI.md).
- Recherche Web expérimentale, réglable séparément pour le chat et la voix, autorisée par le bouton globe du composeur ; voir [recherche Web](docs/WEB_SEARCH.md).
- Copie explicite, presse-papiers local uniquement, expiration après deux minutes.
- Protection des données à l'écran lorsque l'app devient inactive.

## Installer sans Mac

Aucune version signée n'est publiée : l'app se compile sur GitHub Actions et se signe avec ton propre identifiant Apple.

1. Onglet **Actions** du dépôt, workflow **Build IPA**, puis **Run workflow** sur la branche voulue (un tag `v*` le déclenche aussi). Le run réserve une paire version/build et produit une **IPA non signée**, publiée comme artefact `eudes-<version>-build-<n>-unsigned-…`.
2. Télécharger et décompresser l'artefact, puis signer le `.ipa` avec un identifiant Apple gratuit : **Sideloadly** sur PC ou Mac, ou **SideStore** sur l'iPhone.
3. Installer sur l'appareil. Un compte gratuit impose une signature valable 7 jours : SideStore la renouvelle sans câble, Sideloadly demande de rebrancher.
4. Garder l'identifiant de bundle `fr.eudes.app` pour les mises à jour : en changer supprime l'app et son historique.

Rien n'est signé par un certificat de l'éditeur, et la CI n'a jamais accès à un appareil.

## Compiler soi-même

1. Clone le dépôt et ouvre **ios/Eudes.xcodeproj**.
2. Utilise **Xcode 27 ou ultérieur**, avec un SDK et un simulateur iOS 27 installés.
3. Sélectionne le scheme **Eudes** et un simulateur iPhone, puis **Product → Run**.
4. Pour ton iPhone : dans le target **Eudes → Signing & Capabilities**, sélectionne ta Team et remplace `fr.eudes.app` par un identifiant disponible pour ton compte. Adapte également celui du target de tests si nécessaire.
5. Active le mode développeur de l'iPhone si Xcode le demande, puis lance l'app sur cet appareil.
6. Accepte la permission **Réseau local** lors de la première connexion.

Le projet n'a besoin ni de CocoaPods ni de Flutter. Le moteur PocketTTS utilise les frameworks Apple Core ML et AVFoundation, sans paquet Swift externe ; ses poids sont téléchargés séparément dans l'app après accord de l'utilisateur. La génération du projet via Python n'est pas nécessaire pour l'ouvrir.

## Connecter ton serveur

Dans **Connecter mon serveur** :

| Champ | Exemple à remplacer par tes valeurs |
|---|---|
| Nom | Mon serveur |
| Adresse de base | `http://192.168.1.20:8000/v1` |
| Clé API | Vide si ton serveur n'en exige pas |
| Autoriser HTTP | À activer explicitement pour cette URL HTTP |
| Modèle | Choisir après le test, ou saisir le nom publié par le serveur |

L'adresse est un exemple : aucune adresse réelle n'est préconfigurée. `/v1` n'est pas ajouté automatiquement ; il fait partie de l'URL de base renseignée. Ne saisis pas `/chat/completions` dans ce champ. Le serveur doit écouter sur son interface réseau locale et le pare-feu doit autoriser le port depuis l'iPhone.

Le client cible l'API **OpenAI Chat Completions**. Il peut donc dialoguer avec vLLM, llama.cpp, LM Studio ou Ollama **lorsque le serveur expose cette API compatible**, par exemple Ollama sur `http://192.168.1.20:11434/v1`. La compatibilité doit être vérifiée avec ta version du serveur. Ni API native Ollama `/api/chat`, ni authentification SSO ne sont implémentées.

Le choix du modèle est enregistré avec chaque conversation. Modifier le modèle par défaut du serveur s'applique aux nouvelles conversations. Choisir un autre serveur crée un espace de saisie neuf ; un ancien historique n'est pas automatiquement envoyé à un nouveau profil. Modifier l'adresse d'un profil existant modifie volontairement la destination de ce profil, y compris pour ses anciennes conversations.

## Frontière de confidentialité

- Toutes les requêtes passent par le client HTTP de l'app ; les redirections sont refusées, même vers une autre adresse privée.
- Aucune connexion au démarrage : les requêtes partent lors d'un test ou d'un envoi explicite.
- Sessions réseau éphémères : pas de cache disque, de cookies partagés ni d'identifiants de session automatiques. Aucune configuration de proxy applicative héritée.
- ATS conserve son comportement général, avec des exceptions HTTP limitées aux trois plages privées et à la boucle locale (iOS 17+) ; en plus de l'exception système, HTTP exige un consentement par profil. Aucun contournement des certificats HTTPS.
- L'historique et les profils sont dans `Application Support/EudesPrivate/workspace.json`, avec protection de fichiers complète et exclusion des sauvegardes du dossier et du fichier.
- Les clés sont dans le trousseau, `synchronizable=false`, `WhenUnlockedThisDeviceOnly`. Cette classe interdit la migration vers un autre appareil ; elle n'est pas une promesse d'absence de tout mécanisme de sauvegarde système du trousseau.
- Les fenêtres inactives sont masquées et la génération est arrêtée à la perte d'activité ; une réponse peut donc être interrompue en changeant d'app. La session vocale, elle, est conçue pour continuer en arrière-plan.
- Aucun export automatique, journal de prompts, chargement d'image Markdown distante, WebView, navigation web, télémétrie ni synchronisation iCloud applicative.

**Limites :** une adresse privée peut correspondre à un proxy qui contacte ensuite Internet. Eudes ne contrôle ni les sorties de ton serveur, ni les services iOS, le VPN, les claviers tiers, les captures d'écran ou les copies explicites. HTTP est en clair sur le réseau. La protection des fichiers dépend du verrouillage iOS et ne remplace pas un chiffrement applicatif indépendant. Aucun effacement forensique n'est promis. L'exclusion de sauvegarde implique qu'une perte de l'appareil peut entraîner la perte de l'historique.

## Validation sur Mac

Dans Xcode : **Product → Test** (`⌘U`). Les tests couvrent les adresses publiques et les formes d'URL ambiguës, HTTP explicite, le refus des redirections, l'encodage UTF-8 du streaming, les bornes de taille, les erreurs du flux, la persistance, l'exclusion de sauvegarde, le trousseau, le catalogue de modèles et les parcours vocaux.

Ou, à la racine du dépôt, avec le même script que GitHub Actions :

```bash
bash tools/test-ios.sh
```

Le script choisit un simulateur iPhone iOS 27 ou ultérieur installé et lance toute la suite XCTest du scheme **Eudes**, sur les sources du checkout courant. Les journaux et le rapport `.xcresult`, ouvrable dans Xcode, sont conservés dans `build/test-results/`. Le code de sortie reste en échec si la compilation ou un test échoue.

Pour imposer un simulateur, utilise `EUDES_SIMULATOR_ID=<UDID> bash tools/test-ios.sh`. `DEVELOPER_DIR` permet de sélectionner Xcode ; `EUDES_DERIVED_DATA_PATH` permet de réutiliser le cache de compilation. La signature du simulateur est ad hoc : aucun compte développeur ni certificat personnel n'est requis.

## Tests automatiques GitHub Actions

Le parcours de développement est **Issue → Development → Pull request → Review → Corrections → CI checks**. Après revue, l'étiquette `review-validée` déclenche les tests Python et XCTest sur des runners macOS hébergés par GitHub : aucun runner auto-hébergé n'est utilisé, et une pull request venue d'un fork externe exige une approbation manuelle avant l'exécution du moindre job. La suite XCTest compile ses cibles de test ; aucune compilation Release de livraison ne suit automatiquement cette CI.

Le test sur appareil se fait à la main depuis un Mac auquel l'iPhone est connecté : `APPLE_TEAM_ID=… bash tools/build-device.sh` puis `python3 tools/install-iphone.py install`, puis on teste et on approuve la pull request sur le commit exact. Aucun runner auto-hébergé n'est nécessaire, et la CI n'a jamais accès à un appareil. La **Validation finale — compiler et fusionner** est une commande manuelle distincte ; elle exige cette approbation humaine au SHA, compile en Release puis fusionne. Un nouveau commit impose une nouvelle review, CI et validation.

Voir [le mode d'emploi des deux parcours](docs/DELIVERY_WORKFLOWS.md) et les retours vers Corrections. Les rapports XCTest sont conservés 14 jours, l'IPA 90 jours. Le contrôle léger `Workflow automation checks` vérifie les scripts dès l'ouverture de la PR, sans lancer XCTest avant la review.

## Suivi du projet GitHub

Les vues **Développement** et **Validation iPhone** suivent les deux parcours ; le champ **Livraison finale** affiche la validation humaine, la compilation et la fusion. La vue **Historique livraison** conserve les anciennes étapes et les cartes.

Les transitions sont exécutées par GitHub Actions (`project-workflow.yml` et les workflows de livraison), sans skill. Lier chaque PR avec `Closes #123` ; les événements et résultats obsolètes sont ignorés. Le suivi vit dans un projet **d'organisation**, que seul un jeton doté du droit `project` peut modifier : le secret `PROJECT_AUTOMATION_TOKEN` doit porter ce droit, car `GITHUB_TOKEN` ne suffit pas pour Projects. Ne jamais publier le jeton.

## Périmètre

Ni App Store, ni compte, ni synchronisation entre appareils. Pas de pièces jointes autres que des images, pas d'outil MCP, pas de statistiques de tokens détaillées. Le contexte complet des messages terminés est envoyé : si le serveur refuse un contexte trop long, crée une nouvelle conversation ou réduis la fenêtre. Les champs propriétaires de raisonnement sont ignorés ; le texte `delta.content` est affiché. Le serveur doit accepter `temperature`, `max_tokens` et le streaming SSE. Les modèles utilisant un autre contrat nécessiteront un adaptateur.

Les réglages de génération et le budget de contexte sont décrits dans [CONTEXT.md](docs/CONTEXT.md), le rendu du texte dans [RICH_MARKDOWN.md](docs/RICH_MARKDOWN.md).

## Composants embarqués

- La transcription locale en français utilise `SpeechTranscriber` / `SpeechAnalyzer` d'Apple sur iOS 26+, gérés par le système ; aucun poids tiers n'est embarqué.
- [PocketTTS](https://huggingface.co/kyutai/pocket-tts) par [Kyutai](https://kyutai.org) est un modèle de synthèse vocale local en français distribué sous [licence CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) (attribution requise). Il est exécuté directement avec Core ML par le moteur Swift d'Eudes, sans dépendance au paquet FluidAudio. Le modèle est téléchargé après accord de l'utilisateur ; le tokenizer et la découverte du schéma sont adaptés de FluidAudio (Apache-2.0). Voir [le moteur Core ML](docs/POCKETTTS_COREML.md). Seules les voix à licence compatible commercial (CC0 / CC-BY-4.0) sont proposées.
- llama.cpp (MIT) est compilé via le paquet local `EudesLlama`. Les poids du catalogue ne sont jamais embarqués : ils sont téléchargés depuis Hugging Face, chacun sous sa propre licence, rappelée sur la ligne du modèle dans les réglages.
- Les licences complètes sont incluses dans `ios/Eudes/Resources/Licenses/`.

## Signaler un problème

Bugs et idées passent par les formulaires d'issue du dépôt, qui demandent le moteur utilisé, la version et l'appareil. Une **vulnérabilité** se signale en privé, par le rapport de sécurité de l'onglet **Security**, jamais dans une issue publique : voir [SECURITY.md](SECURITY.md).

Pour proposer du code : [CONTRIBUTING.md](CONTRIBUTING.md) — une issue par sujet, une branche par issue, et les commandes de test qui marchent sans Mac.

## Licence

Eudes est distribué sous **GNU General Public License v3.0** — voir [LICENSE](LICENSE). Tu peux utiliser, modifier et redistribuer l'application, à condition de publier tes modifications sous la même licence et de conserver la mention de copyright.

Une **permission supplémentaire**, prévue par la section 7 de la GPL, autorise en plus la distribution de l'application par les magasins d'applications (App Store, TestFlight) : voir [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md). Elle ajoute un droit, ne retire rien, et chacun peut la retirer de sa propre copie.

Le texte de la licence et celui de cette permission accompagnent l'application, et les licences des modèles et des composants tiers embarqués sont réunies dans `ios/Eudes/Resources/Licenses/`.

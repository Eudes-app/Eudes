# Contribuer à Eudes

Merci de prendre le temps. Ce dépôt est petit et les règles sont courtes : une issue par sujet, une branche par issue, une preuve par changement.

Lire d'abord [AGENTS.md](AGENTS.md) : il contient la règle sur les données personnelles, qui vaut pour tout ce qui est publié ici — code, commits, issues, pull requests, revues et captures.

## Avant d'écrire du code

1. **Chercher l'existant** : issues ouvertes et fermées, pull requests, et le projet de suivi. Un doublon coûte plus cher qu'un délai.
2. **Ouvrir une issue** avec l'un des formulaires. Pour un bug, donne le moteur utilisé, la version de l'app et le modèle d'iPhone ; pour une idée, décris le besoin avant la solution.
3. **Attendre l'accord** sur le principe avant d'écrire beaucoup de code. Les changements d'interface, de confidentialité ou de parcours de livraison se discutent d'abord.

Un lot = une issue = une branche = une pull request. Si une dépendance technique oblige à empiler deux changements, le second part d'une base non fusionnée et le dit dans sa description.

## Garde-fou automatique

Un contrôle refuse les données personnelles avant qu'elles n'entrent dans le dépôt.

```bash
# une fois par clone, après avoir cloné
git config core.hooksPath .githooks
```

Le hook `pre-commit` analyse les lignes ajoutées à l'index et refuse le commit s'il y trouve un nom de personne réel, une adresse e-mail, un identifiant d'appareil, un Team ID Apple, une adresse réseau privée ou un jeton. Il n'affiche jamais la valeur, seulement sa nature et sa position. `git commit --no-verify` passe outre : c'est une décision à assumer, pas une habitude.

Les valeurs d'exemple documentées passent sans bruit : `192.168.1.20`, les plages de documentation RFC 5737 (`192.0.2.0/24` et voisines) et les adresses `noreply.github.com`. Un fichier de tests qui doit citer des adresses privées le déclare en tête, par la ligne `personal-data: allow-file` suivie de sa justification.

Le même contrôle tourne en intégration continue sur le texte des issues et des pull requests (`Personal data check`), où rien ne peut être bloqué avant publication. Il ne remplace pas la relecture : il signale en secondes ce qu'une relecture aurait vu en minutes.

## Branches et commits

- Nomme la branche d'après le sujet : `pseudo/sujet-court`, par exemple `adrienn/renommage-eudes`.
- Ne pousse jamais directement sur `main`. Tout passe par une pull request.
- Messages de commit courts, en français, à l'impératif, une ligne : `Clavier : ne plus relire l'en-tête GGUF à chaque frappe`. Le corps reste facultatif et factuel.
- **Identité de commit** : utilise l'adresse `noreply` de ton compte GitHub (« Keep my email addresses private » dans les réglages GitHub). Une adresse réelle dans une pull request devient publique et reste dans l'historique.
- Ne réécris pas l'historique d'une pull request déjà relue sans le dire : cela invalide la revue.

## Pull request

- Lie l'issue avec `Closes #123`. C'est ce qui met le projet de suivi à jour ; un simple « lié à » n'est pas reconnu.
- Remplis le gabarit : ce qui change, ce qui est vérifié, si le parcours iPhone est nécessaire.
- Pour tout changement d'interface, joins un visuel avant/après à l'issue liée.
- Les tests automatiques partent à l'ouverture de la PR (et à chaque push) ; les brouillons ne déclenchent rien. Le check `iOS tests` est requis pour fusionner sur `main`.
- Les pull requests venues d'un fork exigent une approbation manuelle avant le moindre job.

## Compiler et tester

**macOS et Xcode 27 sont obligatoires.** Le SDK iOS 27 est utilisé par le code (modèle Apple, actions Siri, tâches de fond) : ni Linux ni Windows ne compilent ce projet.

```bash
# suite XCTest complète, sur un simulateur iPhone iOS 27
bash tools/test-ios.sh

# un simulateur précis, ou un cache de compilation réutilisé
EUDES_SIMULATOR_ID=<UDID> bash tools/test-ios.sh
EUDES_DERIVED_DATA_PATH=build/DerivedData bash tools/test-ios.sh

# ce que fait la CI : tranche simulateur seule, sans la tranche appareil
LLAMA_BUILD_SLICES=simulator bash tools/test-ios.sh
```

Sans `LLAMA_BUILD_SLICES`, les deux tranches de llama.cpp sont compilées ; la tranche appareil est nécessaire à `tools/build-device.sh`, qui refuse sinon de compiler.

Les journaux et le bundle `.xcresult` restent dans `build/test-results/`. En cas d'échec de compilation ou de test, le script sort en erreur.

Sans Mac, il reste les mêmes vérifications en Python, qui ne touchent ni Xcode ni le simulateur :

```bash
python3 -m unittest discover -s tests -v
bash -n tools/*.sh
```

Ces commandes reprennent celles de `automation-checks.yml`. La compilation, elle, ne se fait que sur un runner macOS, dans la CI du dépôt : une pull request de fork y passe après approbation.

## Conventions de code

- Swift et SwiftUI, sans CocoaPods, sans Flutter, sans dépendance Swift tierce. Le seul paquet local est `ios/Packages/EudesLlama`, épinglé à une révision de llama.cpp.
- Ouvre `ios/Eudes.xcodeproj` ; ajoute les nouveaux fichiers à la cible concernée, sinon ils ne compilent pas.
- L'interface et les messages destinés à l'utilisateur sont en français, sans emoji. Les commentaires de code sont en français.
- L'état vit dans `AppStore` (`@MainActor`) ; les services ne connaissent pas SwiftUI et restent testables par injection. La carte du code est dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Toute logique nouvelle vient avec ses tests, sans appel réseau réel : les fixtures remplacent les protocoles.
- Un réglage par défaut qui change demande une migration explicite : une valeur déjà enregistrée dans `UserDefaults` prime sur le nouveau défaut.
- Ni clé, ni jeton, ni adresse d'appareil en dur : les identifiants d'automatisation passent par les secrets et variables Actions.

## Documentation

Un changement de comportement met à jour le `README.md` ou le document correspondant de `docs/`. Un nouveau réglage, une nouvelle limite ou un nouveau parcours de livraison sans documentation sera refusé en revue, même si le code est bon.

## Sécurité

Ne décris jamais une faille exploitable dans une issue ou une pull request : utilise le rapport privé de l'onglet **Security**, décrit dans [SECURITY.md](SECURITY.md).

## Licence des contributions

Le projet est distribué sous GNU GPL v3 (voir [LICENSE](LICENSE)). En proposant une pull request, tu acceptes que ta contribution soit publiée sous cette même licence.

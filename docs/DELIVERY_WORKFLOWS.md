# Développement et validation iPhone

## Développement

Issue → Development → Pull request → Review → Corrections → CI checks.

L’issue passe en Development lors de son assignation. Une PR liée avec `Closes #…` fait avancer le suivi. La review et les corrections précèdent la validation humaine `review-validée`. Cette étiquette lance Python + XCTest sur un runner macOS hébergé par GitHub. Une CI en échec retourne vers Corrections. Pour un incident de runner, relancer les jobs concernés ; aucun commit de correction artificiel n’est requis. Les demandes de changements d’une review sont bloquantes pour la livraison.

Un push ou le retour en brouillon retire `review-validée`, remet la review à faire et invalide les champs de validation. Les résultats d’un ancien commit ne déplacent pas la carte. Ne pas interpréter la position CI checks comme un succès : la conclusion Actions est la preuve.

## Tests sur iPhone

Le test sur appareil est manuel. Depuis un Mac auquel l’iPhone est connecté :

```bash
APPLE_TEAM_ID=XXXXXXXXXX bash tools/build-device.sh
python3 tools/install-iphone.py install
```

L’identifiant de l’iPhone connecté et la version à installer sont détectés tout seuls (un seul appareil connecté, valeurs de `ios/Version.xcconfig`) ; `IPHONE_DEVICE_ID`, `DELIVERY_VERSION` et `DELIVERY_BUILD` restent utilisables pour forcer une valeur. `python3 tools/install-iphone.py preflight` affiche la version installée et la version cible sans rien modifier.

Ces scripts lisent la version déjà installée, refusent un retour en arrière, compilent avec le certificat configuré, vérifient app et widget, installent en place puis relisent la version. Aucun runner GitHub ni secret du dépôt n’est impliqué : la machine est celle de la personne qui teste, et elle n’est pas joignable depuis la CI.

Une installation ne prouve ni lancement ni gestes ni microphone/Siri/VoiceOver. Ces fonctions se testent à la main selon les critères d’acceptation.

La preuve exigée par **Validation finale — compiler et fusionner** est une **approbation humaine de la pull request sur le commit exact**, posée après le test. Pas de reçu d’installation, pas d’identifiant d’appareil : la CI ne manipule aucune donnée d’appareil.

En cas de défaut constaté, lancer **Signaler des corrections** avec la PR et son SHA : l’étiquette de review est retirée et les validations sont remises à faire. Une review GitHub « Request changes » bloque également la livraison.

Poser l’étiquette `iphone-requis` sur une PR exige un test sur appareil : elle survit à un push, donc chaque nouveau commit doit être réinstallé et retesté, et tant qu’elle est présente la validation finale refuse la dispense. Une compilation échouée ne peut pas être déclarée validée.

## Validation finale manuelle puis compilation et merge

Dans Actions, lancer **Validation finale — compiler et fusionner** depuis `main` :

1. Numéro de PR et SHA complet validé.
2. `Tests iPhone validés` avec l’ID du run d’installation réussi, ou `Non nécessaire` pour un changement ne nécessitant aucun test physique. Cette seconde option est refusée si `iphone-requis` est présent.
3. Cocher explicitement l’autorisation de compiler puis fusionner.

Le clic manuel atteste les tests et autorise les deux actions. Un compte humain disposant de l’écriture est requis. Aucun skill n’ajoute cette validation automatiquement.

Après vérification des prérequis, **Validation iPhone** indique **Validé manuellement** pour `Tests iPhone validés`, ou **Non nécessaire** pour cette décision. Cette dernière valeur indique une dispense, sans attester de test physique. Un nouveau commit ou une demande de corrections remet la validation à **À refaire**.

Les gardes vérifient la PR, la review, le dernier vrai run CI (un run vide dû à une autre étiquette ne masque pas les tests), l’approbation humaine du test sur appareil, et la compatibilité avec `main`. La branche doit contenir le `main` actuel ; sinon, la mettre à jour et refaire review/CI/tests nécessaires. Une compilation Release non signée vérifie ensuite l’app pour appareil, sans réserver de nouveau numéro de livraison.

Le job de fusion n’exécute pas de code provenant de la PR. Il recontrôle tous les prérequis et appelle l’API de merge avec le SHA attendu. Un nouveau commit, une CI devenue rouge, une review retirée ou un changement de base observé bloque la fusion. Les protections GitHub du dépôt restent applicables, sans contournement administrateur. Le contrôle de SHA de l’API est atomique pour la tête de PR ; pour verrouiller aussi les mises à jour concurrentes de `main` à l’instant exact du merge, utiliser les protections/merge queue GitHub.

Compilation et merge réussis font passer **Livraison finale** à Fusionné. Une erreur reste visible dans Actions et remet le suivi en Corrections/Échec. Le merge effectué avec `GITHUB_TOKEN` met lui-même le projet à jour, sans dépendre d’un événement en cascade.

## Configuration

- Runners hébergés par GitHub : `xcode-27` pour Xcode et les tests, `ubuntu-latest` pour l'automatisation du projet ; `gh` et Python 3 disponibles sur les deux. La signature Apple est fournie par les secrets du dépôt.
- Aucune variable d’appareil n’est nécessaire : la CI ne voit jamais d’iPhone. `IPHONE_DEVICE_ID`, `APPLE_TEAM_ID`, `DELIVERY_VERSION` et `DELIVERY_BUILD` ne servent qu’aux scripts lancés à la main sur un Mac.
- Secret `PROJECT_AUTOMATION_TOKEN` avec accès au dépôt et au projet. Aucun secret Apple dans le dépôt.
- Champs du projet : Workflow développement, Validation iPhone, Livraison finale. Les options sont résolues par nom, sans identifiants d’options figés. Validation iPhone doit proposer **Non nécessaire** avant l’utilisation du workflow corrigé, en conservant les options et valeurs existantes.
- Les vues Développement et Validation iPhone filtrent les issues ouvertes ; l’historique conserve les cartes et les valeurs antérieures, y compris les cartes fermées.

## Première activation

Ces workflows manuels doivent exister sur `main` avant d’apparaître dans Actions. La PR de mise en place est donc revue et testée avec le workflow existant, puis intégrée après validation humaine explicite. Les nouveaux automatismes prennent en charge les événements suivants. Aucune installation sur appareil ni fusion d’une autre PR n’est nécessaire pour cette activation.

Références : [déclenchement manuel](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch), [GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token).

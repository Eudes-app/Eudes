# Développement et validation iPhone

## Développement

Workflow GitHub par défaut : à chaque pull request ouverte, synchronisée ou repassée en « ready for review », la CI lance les tests Python puis la suite XCTest complète sur un runner macOS hébergé par GitHub (`ios.yml`). Les brouillons ne déclenchent rien. Une CI en échec bloque la fusion si le check est requis ; pour un incident de runner, relancer les jobs concernés. Les demandes de changements d’une review sont bloquantes via les protections de branche.

Pour garder le garde-fou de fusion, le check **iOS tests** doit figurer dans les status checks requis de `main` (protection de branche), comme le sont déjà `Workflow automation checks` et `Personal data check`.

## Tests sur iPhone

Le test sur appareil est manuel. Depuis un Mac auquel l’iPhone est connecté :
```bash
APPLE_TEAM_ID=XXXXXXXXXX bash tools/build-device.sh
python3 tools/install-iphone.py install
```

L’identifiant de l’iPhone connecté et la version à installer sont détectés tout seuls (un seul appareil connecté, valeurs de `ios/Version.xcconfig`) ; `IPHONE_DEVICE_ID`, `DELIVERY_VERSION` et `DELIVERY_BUILD` restent utilisables pour forcer une valeur. `python3 tools/install-iphone.py preflight` affiche la version installée et la version cible sans rien modifier.

Ces scripts lisent la version déjà installée, refusent un retour en arrière, compilent avec le certificat configuré, vérifient app et widget, installent en place puis relisent la version. Aucun runner GitHub ni secret du dépôt n’est impliqué : la machine est celle de la personne qui teste, et elle n’est pas joignable depuis la CI.

Une installation ne prouve ni lancement ni gestes ni microphone/Siri/VoiceOver. Ces fonctions se testent à la main selon les critères d’acceptation.

L’état du test sur appareil se porte sur la PR avec deux étiquettes :

- `à tester sur iPhone` — un test physique est attendu avant fusion (équivalent de l’ancien `iphone-requis` ; la protection de branche peut exiger une review approuvée sur le commit exact) ;
- `validé iPhone` — posé par la personne ayant testé sur appareil, idéalement accompagné d’une review `APPROVED` sur le commit testé.

En cas de défaut constaté, retirer `validé iPhone` et rouvrir la review ; une review GitHub « Request changes » bloque également la fusion.

## Compilation et livraison

`build-ipa.yml` reste autonome : déclenché manuellement ou sur tag `v*`, il réserve les numéros de livraison via `tools/delivery_version.py` (branche orpheline `eudes-delivery-versions`, indépendante de tout projet) et produit un IPA non signé. Rien à détacher.

La fusion se fait via l’interface GitHub (bouton Merge) une fois la CI verte et la review approuvée, sous réserve des protections de branche.

## Configuration

- Runners hébergés par GitHub : `xcode-27` pour Xcode et les tests, `ubuntu-latest` pour les checks d’automatisation ; `gh` et Python 3 disponibles sur les deux. La signature Apple est fournie par les secrets du dépôt.
- Aucune variable d’appareil n’est nécessaire en CI : la CI ne voit jamais d’iPhone. `IPHONE_DEVICE_ID`, `APPLE_TEAM_ID`, `DELIVERY_VERSION` et `DELIVERY_BUILD` ne servent qu’aux scripts lancés à la main sur un Mac.
- Aucun secret de projet n’est requis : `PROJECT_AUTOMATION_TOKEN` n’est plus utilisé.
- Status checks requis de `main` : `Workflow automation checks`, `Personal data check`, `iOS tests`.

Références : [déclenchement pull_request](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request), [protection de branche](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token).

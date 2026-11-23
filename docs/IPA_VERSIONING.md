# Versions des livraisons iPhone

Le workflow **Build IPA** réserve une version avant de compiler, la transmet à
l’application et au widget, puis vérifie les deux `Info.plist` avant de créer
l’archive. L’artefact et l’IPA portent le même nom, par exemple :

`eudes-1.112-build-114-unsigned-43590821354-1`

Un manifeste JSON accompagne l’IPA : identifiant du lot, version, build, commit
compilé, exécution et tentative GitHub. L’IPA reste **non signée** : il faut la
signer pour le téléphone avant installation. Un numéro réservé ou un artefact
produit ne prouve ni une installation ni une validation sur iPhone.

## Préparer une livraison

Dans **Actions → Build IPA → Run workflow**, sélectionner la branche contenant
les changements à livrer. Le champ `delivery_id` permet de nommer le lot, par
exemple `iphone-2026-11-14`. Un nouvel identifiant réserve le numéro suivant.
Sans identifiant, le lot s’appelle `run-<identifiant de l’exécution GitHub>`.

La référence initiale est **1.111 (113)** : cette version correspond à la première publication (voir [CHANGELOG.md](../CHANGELOG.md)). La première nouvelle réservation est donc **1.112 (114)**. L’incrément porte sur le
deuxième entier de la version et sur le build : `1.99` devient `1.100`, pas `2.0`.

## Recompiler le même lot

- **Re-run jobs** conserve automatiquement le même identifiant et les numéros.
- Pour une nouvelle exécution, y compris après une correction du code, saisir
  le même `delivery_id`. Il est indiqué dans les logs et dans le manifeste.
- Une compilation ratée conserve sa réservation ; ses numéros ne sont jamais
  réattribués à un autre lot. En cas de réponse réseau perdue lors de la
  réservation, reprendre le même identifiant.
- Un nouveau lot reçoit de nouveaux numéros. Une recompilation d’un ancien lot
  conserve ses anciens numéros, même si des lots plus récents existent.
- Un tag `v1.112` réutilise la livraison 1.112 si elle est réservée. Sinon, un tag
  ne peut réserver que la prochaine version attendue. Un tag incohérent échoue
  avant compilation ; il ne produit pas une IPA portant un autre numéro.

## Référence commune et concurrence

La branche dédiée **`eudes-delivery-versions`**, créée automatiquement à la
première réservation, contient uniquement `deliveries.json`. Son historique
Git enregistre les attributions de toutes les branches de développement. Le
registre est indépendant du cache du runner, de la durée de conservation des
artefacts et de la connexion de l’iPhone.

Chaque écriture fournit le SHA précédent du fichier à l’[API Contents de
GitHub](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents).
Si deux préparations se présentent simultanément, une écriture concurrente
échoue, puis relit le registre : un même lot réutilise la réservation gagnante ;
deux lots différents obtiennent deux numéros distincts. Le nombre de reprises
est borné. Une erreur de permissions, un registre incohérent ou un conflit
persistant fait échouer la préparation, sans revenir aux anciennes valeurs.

Le job de réservation possède `contents: write` via `GITHUB_TOKEN`. Le job de
compilation garde `contents: read`. Aucun nouveau secret personnel n’est requis.
Les règles du dépôt doivent permettre au workflow de créer puis mettre à jour
cette branche de registre. Conserver son historique : ne pas la supprimer, la
réinitialiser, la fusionner dans `main` ni la modifier par force-push. En cas de
perte, restaurer son dernier état depuis l’historique/sauvegarde avant toute
nouvelle livraison ; ne pas redémarrer volontairement le compteur initial.

## Builds ordinaires et installations locales

`ios/Version.xcconfig` est la base de développement commune aux configurations
Debug/Release de l’application et du widget, ainsi que le point de départ du
registre. Les tests et la compilation de validation des PR utilisent cette
base **sans réserver ni augmenter** de numéro. Elle ne représente pas le
dernier lot livré : consulter le registre et le manifeste de l’artefact.

Pour une livraison locale, utiliser une réservation du workflow et ses numéros,
ou signer l’artefact correspondant. Ne plus attribuer indépendamment un numéro
par une commande Xcode locale. Une reprise du même lot conserve ses numéros.
Après initialisation, un changement de la base nécessite une migration
explicite du registre ; le script refuse une divergence silencieuse.

## Vérifications

`python3 -m unittest discover -s tests -v` couvre les attributions, les courses
concurrentes, les reprises, les erreurs, les tags et le paquet IPA. Cette suite
s’exécute aussi à chaque pull request, avant XCTest. Le workflow Build IPA
transmet les numéros réservés à `xcodebuild` et bloque la publication si le
widget manque, si un bundle a d’autres numéros ou si le produit conserve une
signature/provision de livraison précédente. Le packaging utilise un dossier
temporaire isolé ; l’archive conserve permissions et liens symboliques.

Les workflows présents sur des branches anciennes restent ceux de ces
branches. Pour bénéficier de cette procédure, intégrer ce changement dans la
branche choisie avant de lancer **Build IPA**.

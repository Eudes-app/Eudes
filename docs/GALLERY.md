# Galerie Eudes

Captures réelles de l'application sur iPhone, avec des données de démonstration. Aucune
conversation personnelle, aucune adresse réseau réelle, aucune clé : les règles de publication
sont celles de [AGENTS.md](../AGENTS.md#never-publish-personal-data).

La galerie se remplit **au fil des pull requests** : une capture s'ajoute quand une PR touche un
écran, quand une issue en fournit une, ou quand une vérification visuelle est faite de toute façon.
Il n'y a pas de campagne de captures dédiée. Le tableau de couverture dit ce qui est déjà publié et
ce qui n'a pas encore d'image ; une section vide est simplement un écran qu'aucune PR n'a encore
documenté, ce n'est pas une tâche en attente.

Les images de cette galerie remplacent celles publiées avant le renommage : elles montraient
l'ancien nom de l'application et ont été retirées du dépôt.

## Règles des images

- Écran en **français**, thème clair et thème sombre lorsque le contraste compte.
- Données de démonstration uniquement : une conversation inventée, un serveur fictif, un modèle
  dont le nom est public. Aucune adresse IP de réseau local réelle, aucune clé d'API, aucun nom.
- Fichier dans [`screenshots/`](screenshots/), nommé `<écran>-<clair|sombre>-<issue>.png`, en
  minuscules et en tirets ; l'`<issue>` est celle qui apporte la capture.
- Affichage avec une largeur fixe, pour que la page reste légère :
  `<img src="screenshots/accueil-clair-42.png" alt="Accueil clair" width="360">`.
- Une capture montre ce qu'elle prétend montrer : pas de zone vide là où l'écran devrait afficher
  des données, pas de barre d'état porteuse d'un nom d'opérateur ou d'une heure personnelle.
- La version et le build d'une capture ne sont cités que s'ils ont été vérifiés sur l'image.

## Couverture

| # | Écran | Fichier attendu | État |
|---|---|---|---|
| 1 | Accueil, conversation vide | `accueil-clair-<issue>.png` | en attente |
| 2 | Accueil en thème sombre | `accueil-sombre-<issue>.png` | en attente |
| 3 | Conversation et réponse en streaming | `conversation-clair-<issue>.png` | en attente |
| 4 | Recherche Web et sources citées | `recherche-web-clair-<issue>.png` | en attente |
| 5 | Réglages : modèles installés | `modeles-clair-<issue>.png` | en attente |
| 6 | Réglages : serveur et connexion | `serveur-clair-<issue>.png` | en attente |
| 7 | Réglages en thème sombre | `reglages-sombre-<issue>.png` | en attente |
| 8 | Assistant vocal et Live Activity | `voix-clair-<issue>.png` | en attente |

## 1. Accueil

Écran d'ouverture, conversation vide et suggestions de prompts, avec une connexion fictive.
Montre que l'application s'ouvre sans compte ni assistant de configuration.

<!-- à ajouter : screenshots/accueil-clair-<issue>.png -->

## 2. Accueil en thème sombre

Même écran, apparence sombre suivant iOS.

<!-- à ajouter : screenshots/accueil-sombre-<issue>.png -->

## 3. Conversation et réponse

Une question courte et sa réponse en streaming, avec du Markdown et un bloc de code. Les
conversations sont inventées et ne reflètent aucune utilisation réelle.

<!-- à ajouter : screenshots/conversation-clair-<issue>.png -->

## 4. Recherche Web et sources

Réponse construite à partir d'une recherche Web, avec les sources citées par l'application.
Voir [recherche Web](WEB_SEARCH.md) pour le réglage et les limites.

<!-- à ajouter : screenshots/recherche-web-clair-<issue>.png -->

## 5. Réglages : modèles installés

Liste des modèles présents sur l'appareil et de ceux qui restent à télécharger, avec la fenêtre de
contexte réglée par modèle. Le catalogue et les empreintes sont décrits dans
[contexte et longueur de réponse](CONTEXT.md).

<!-- à ajouter : screenshots/modeles-clair-<issue>.png -->

## 6. Réglages : serveur et connexion

Profil de serveur fictif : adresse locale de démonstration, protocole, modèle découvert ou saisi à
la main. Voir [protocoles et limites](PROTOCOLS.md) et [boucle locale](LOCALHOST.md).

<!-- à ajouter : screenshots/serveur-clair-<issue>.png -->

## 7. Réglages en thème sombre

Même écran de réglages en apparence sombre, pour vérifier le contraste des libellés et des
séparateurs.

<!-- à ajouter : screenshots/reglages-sombre-<issue>.png -->

## 8. Assistant vocal

Session vocale et Live Activity, lorsque l'appareil qui capture dispose d'iOS 26 ou plus. Voir
[actions vocales](VOICE_ACTIONS.md).

<!-- à ajouter : screenshots/voix-clair-<issue>.png -->

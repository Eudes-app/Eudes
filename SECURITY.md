# Signaler une vulnérabilité

Ce dépôt est public et les issues sont visibles de tous. **Ne décris jamais une faille exploitable dans une issue, une pull request ou un commentaire** : le signalement se fait en privé.

## Comment signaler

1. Onglet **Security** du dépôt → **Report a vulnerability**. C'est un rapport privé, visible seulement des mainteneurs.
2. Si ce bouton n'est pas disponible, ouvre une issue **sans aucun détail technique** demandant un canal privé, et attends la réponse avant d'en dire davantage.

Ne joins ni identifiant d'appareil, ni adresse réseau réelle, ni jeton dans le rapport. Décris l'environnement par catégorie (« iPhone de test, iOS 27 »), pas par identifiant.

## Périmètre

Sont dans le périmètre :

- l'application : validation des URL et des redirections, gestion des clés dans le trousseau, stockage privé, politique HTTP/HTTPS, fuite d'information dans les journaux ou l'interface ;
- les modèles embarqués : chargement des fichiers GGUF, vérification SHA-256, chemins de téléchargement ;
- l'assistant vocal, le widget et les actions Siri, y compris la session en arrière-plan ;
- les workflows GitHub Actions : permissions, épinglage des actions, secrets, injection dans les scripts.

Hors périmètre :

- le comportement ou la qualité des réponses des modèles, y compris ceux exécutés sur l'iPhone ;
- la sécurité du serveur que tu connectes, de ton réseau, de ton VPN ou de ton compte Apple ;
- les appareils jailbreakés, les réglages développeur et les builds modifiés par un tiers ;
- les vulnérabilités des dépendances amont déjà publiques, sauf si l'app les rend exploitables.

## Suites

Les mainteneurs accusent réception dès que possible, sans engagement de délai contractuel, puis travaillent à un correctif avant toute publication. Le crédit du signalement est indiqué dans l'avis publié, sauf demande contraire. Merci de laisser un délai raisonnable avant toute divulgation, en particulier parce que les versions installées sur les appareils ne se mettent pas à jour toutes seules.

# Maquettes

Plans d'écran produits **avant** le code, pour discuter d'une direction sans dépenser un
build. Ce ne sont pas des captures de l'application : la galerie des captures réelles
reste [`../GALLERY.md`](../GALLERY.md).

Une maquette à main levée est acceptée ici si elle reste fidèle aux teintes de
`ios/Eudes/UI/DesignSystem.swift` et aux libellés réellement prévus — une maquette qui
promet un écran qui n'existe pas coûte plus cher qu'elle ne rapporte.

## Fichiers

- `catalogue-familles.png` — catalogue rangé par familles, avec trois raccourcis par
  usage en tête (issue #31).
- `points-forts-catalogue.png` — avant / après du catalogue : le badge « Vision » ne
  reste sur la famille que si **toute** la famille lit les images, et le point fort de
  chaque modèle s'affiche sous sa ligne (PR #39).
- `poids-modeles-catalogue-43.html` / `.png` — avant / après du catalogue : jauge de
  poids à cinq segments, sections par rôle et ligne « Afficher plus » (issue #43).
- `poids-modeles-accueil-43.html` / `.png` — avant / après de l'écran principal, avec la
  jauge compacte sous les lignes de modèles (issue #43).
- `rangement-automatique-conversations.html` — le rangement automatique en quatre
  écrans : plan à cocher case par case, bandeau d'annulation complet, réglages avec
  profondeur et modèle d'analyse ; jamais de déplacement silencieux (issue #45).
- `catalogue-simplifie.html` / `.png` / `-sombre.png` — les deux écrans du choix d'un
  modèle, dans un seul flux : « Modèles et serveurs » (modèle actuel en tête, trois
  usages, modèles téléchargés) et « Choisir un modèle » (un seul ordre du plus léger au
  plus lourd, poids écrit en clair, filtres Texte / Images / Installés, un geste par
  ligne). Interactions réelles : sélection, téléchargement simulé avec progression,
  fiche « i » avec suppression, clair et sombre (issue #49). Le code correspondant est
  dans `ios/Eudes/UI/SettingsView.swift` (PR #50).

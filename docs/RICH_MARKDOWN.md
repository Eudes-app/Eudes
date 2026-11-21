# Markdown enrichi — 1.16

Rendu natif SwiftUI : aucun WebView, moteur JavaScript, CDN, chargement de fichier, bridge natif ou ressource distante depuis le contenu. Aucune dépendance tierce ajoutée. Les liens Markdown existants ne s’ouvrent que sur un appui explicite (HTTP/HTTPS/mailto).

## Périmètre pris en charge

- Notes : références `[^id]` et définitions sur une ligne `[^id]: texte`, numérotation et regroupement en fin de réponse. Identifiants ASCII alphanumériques, tiret et soulignement (40 caractères). Première définition retenue ; référence inconnue littérale. Pas de navigation vers la note ni de définition multiligne.
- Mathématiques : `$...$` et `$$...$$`, lettres/chiffres, exposants et indices simples, symboles grecs usuels, intégrale, somme, produit, infini, comparaisons et opérateurs courants. C’est un sous-ensemble typographique de LaTeX, pas TeX complet : fractions, matrices, macros, commandes de fichiers et groupes imbriqués ne sont pas interprétés. Source lisible en cas de syntaxe non prise en charge. Limite 4 096 caractères par formule. Les dollars échappés, espaces de délimitation et code en ligne ne deviennent pas des formules.
- Mermaid : organigrammes acycliques `graph`/`flowchart` TD, TB ou LR ; nœuds simples, rectangles/losanges, flèches `-->`, libellés `|Oui|`. Au maximum 24 nœuds et 40 arêtes, 20 000 caractères. Aucun script, directive init, lien/action, style Mermaid ou diagramme séquentiel. Cycles et syntaxe non reconnue restent en code source. Défilement pour les graphes plus grands.
- HTML : fragments bien formés (syntaxe XML), balises div, span, p, strong/b, em/i, code, br. Sur le div extérieur seulement : background/background-color hexadécimal à six chiffres, padding et border-radius de 0 à 24px. Adaptation de contraste en sombre. Les autres attributs/balises/styles, événements, DTD, scripts, iframes, images et ressources externes sont refusés ; le fragment original reste lisible. Pas de navigateur HTML général ni réparation de HTML mal formé.
- Les caractères Markdown échappés restent littéraux. Le code ordinaire clôturé reste du code ; seule une clôture déclarée `mermaid` entre dans le parseur de diagrammes.

Les boutons Copier conservent le contenu source, notamment les délimiteurs mathématiques et définitions de notes ; le bouton d’un bloc clôturé conserve son contenu sans les clôtures, comme auparavant. La réponse partielle reste affichable : une construction incomplète utilise la source jusqu’à ce que sa syntaxe soit complète.

## Vérifications

83 tests automatiques réussis sur le simulateur QA iPhone 18 Pro : notes, délimiteurs/échappements, code, syntaxe incomplète, refus HTML/entités/attributs, commandes LaTeX interdites, directives et cycles Mermaid, plus la suite de régression existante. Release iOS non signée compilée, bundle 1.16/build18.

Les huit images de composants SwiftUI examinées à l'époque ont été rendues directement, en clair et en sombre, avec des données synthétiques ; elles montraient l'ancien nom de l'application et ont été retirées du dépôt avec le renommage. Ce n'étaient pas des captures de l'application entière : les zones ScrollView ne sont pas correctement exportées par ImageRenderer et la fenêtre de test retournait une image noire. Ces constats restent valables, et les captures de l'application complète sont à refaire dans [la galerie](GALLERY.md), qui liste les écrans concernés. La validation tactile des défilements, de la copie et du streaming dans l'interface complète reste à effectuer. Aucun test d'inférence ni aucune installation iPhone.

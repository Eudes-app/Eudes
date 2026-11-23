# Recherche Web depuis l’iPhone

Eudes propose une recherche **expérimentale**, configurable séparément pour le chat et l’assistant vocal. En mode Par conversation, le bouton globe du composeur autorise la recherche pour cette conversation et conserve ce choix. Les recherches et lectures de pages utilisent directement la connexion Internet de l’iPhone. Aucun compte de recherche, clé d’API de recherche ou serveur intermédiaire Eudes n’est requis. Le modèle distant utilise toujours sa connexion et ses identifiants habituels.

Le modèle sélectionné reçoit **les résultats avec le contexte du chat**, pas seulement la dernière question : échanges précédents, résumé explicite éventuel, contraintes et précisions restent présents. Il est invité à construire une réponse pertinente sans renvois numérotés ni liste de références dans le texte. Les liens réellement récupérés et la date de recherche sont conservés sous la réponse, dans un bloc **Sources replié par défaut**, et dans l’historique. Chaque lien affiche son titre et son domaine, sans numéro. L’activité Web reste affichée séparément, avec l’origine des appels (modèle ou Eudes). Un modèle peut néanmoins mal interpréter une source ; les liens permettent de la vérifier.

## Recherche hybride

- **API acceptant les outils** : une phase de recherche présente au même modèle l’historique complet et les outils `web_search` et `web_fetch`. Le modèle formule une requête autonome à partir de la conversation (par exemple en comprenant « et en France ? »), peut affiner ses recherches et demander le texte d’une source. Le globe autorise ces outils ; une salutation ne nécessite pas forcément de recherche.
- **Modèle sans outils** : Eudes recherche la dernière question, puis transmet les extraits avec le même historique au modèle pour la synthèse. Ce chemin reste celui du modèle Apple local. Il n’exige pas de support des outils par l’API.
- Les capacités explicitement annoncées par le fournisseur sont prises en compte. En leur absence, Eudes essaie les outils ; un refus explicite des outils déclenche le repli et est mémorisé uniquement pour la session, le profil, l’URL, le protocole et le modèle concernés. Une erreur d’authentification, de quota, de réseau ou de contexte n’est pas prise pour une incompatibilité.

Les formats Chat Completions et Responses sont pris en charge. La phase de recherche peut faire plusieurs appels au modèle, donc ajouter du délai et des tokens facturés par son fournisseur. Les outils du modèle partagent un **plafond de 100 appels par réponse par défaut**, réglable dans Réglages → Recherche Web → Outils du modèle. Chaque recherche ou lecture tentée consomme un appel, y compris un échec ou un appel refusé. Le modèle choisit leur répartition et peut terminer avant le plafond. Il n’y a plus de quotas distincts pour les recherches, les lectures, les tours, les échanges d’outils ou les sources cumulées. Chaque recherche continue de fournir au plus cinq résultats. Les identifiants de sources restent stables pendant le tour et sont uniquement internes aux outils. Les messages techniques d’outils ne sont pas enregistrés dans l’historique ; les preuves utiles et l’activité le sont.

Le budget repart de zéro pour chaque réponse, y compris une régénération, et s’applique au chat et à l’assistant vocal. Le réglage est mémorisé sur l’iPhone et figé au début du tour. Au plafond, Eudes passe à la synthèse avec les preuves déjà obtenues et signale la limite dans le détail d’activité ; si aucune preuve n’a été obtenue après les tentatives, elle conserve le comportement d’erreur. Si un lot d’appels dépasse le budget restant, seuls les premiers appels qui y tiennent sont traités. Le repli automatique d'Eudes reste une recherche simple, indépendante de ce budget.

La synthèse finale repasse par le transport existant, avec l’historique, les preuves, les instructions et les réglages du modèle. Le mode Responses récupérable reste appliqué à cette réponse finale. Les résultats ne remplacent ni le contexte du chat ni les instructions de l’utilisateur. Les références sont propres à chaque réponse ; une ancienne table n’est pas confondue avec les nouvelles sources.

## Réglages et utilisation

Dans **Réglages → Recherche Web**, deux choix indépendants sont conservés après le redémarrage de l’app.

| Chat | Comportement |
|---|---|
| Désactivé | Aucun nouvel envoi ni régénération du chat ne lance de recherche. |
| Par conversation | Le globe active ou désactive la recherche pour la conversation courante. Le choix reste enregistré avec cette conversation. Une nouvelle conversation commence sans Web. |
| Toutes les conversations | Le Web est autorisé pour chaque envoi texte. Un modèle compatible choisit quand chercher ; en repli, Eudes recherche chaque question. Le globe reflète ce réglage. |

| Vocal | Comportement |
|---|---|
| Désactivé | Aucune recherche pour les questions vocales. |
| À la demande | Commencer par « Cherche sur Internet… », « Recherche sur le Web… » ou « Peux-tu chercher sur Internet… » déclenche la recherche pour cette question seulement. |
| En permanence | Le Web est autorisé pour chaque question vocale, avec les mêmes chemins hybride et de repli. Cela ne signifie pas une écoute permanente. |

La première utilisation adopte **Par conversation**, globe éteint, et **Vocal : Désactivé**. Les conversations anciennes sans choix enregistré restent sans recherche en mode Par conversation. Le choix d’un brouillon sans conversation enregistrée est temporaire ; créer une nouvelle conversation le remet à zéro.

La détection vocale du mode À la demande reconnaît localement des commandes françaises explicites. Une simple mention du mot Internet, une citation ou une demande négative ne suffit pas. Ce n’est pas une interprétation générale de toute formulation naturelle. Les réglages de chat et de voix restent indépendants, y compris quand l’assistant vocal est lancé via Siri. La recherche utilise uniquement le texte final transcrit. L’action distincte « Poser une question à Eudes », dont la dictée et la lecture sont prises en charge directement par Siri, conserve son comportement sans recherche Web.

Le bouton **Régénérer** applique le réglage actuel : celui du chat pour une question écrite, celui du vocal pour une question provenant de l’assistant vocal. Désactiver la recherche empêche donc aussi les nouvelles recherches lors d’une régénération. Les sources déjà présentes dans l’historique sont conservées et peuvent rester dans le contexte du modèle.

Après envoi, Eudes prépare la recherche avant la synthèse du modèle. Déplier Sources permet d’ouvrir les liens dans le navigateur. Les anciens marqueurs numériques clairement identifiables peuvent être masqués dans la présentation des réponses documentées, sans modifier le texte sauvegardé ni les nombres, le code et les liens sans rapport. En mode Web, une image seule exige une question écrite. Une commande explicite reconnue par la détection française déclenche le repli de recherche si le modèle n'appelle aucun outil.

## Circulation des données

- La requête choisie par le modèle, ou la dernière question en repli, est envoyée telle quelle après normalisation des espaces à `https://html.duckduckgo.com/html/`. L’application n’y joint ni historique brut, ni images, ni clés du modèle. Une requête formulée par le modèle peut contenir des précisions issues du chat ; les instructions lui demandent de n’envoyer que les informations nécessaires. Le moteur voit la requête et l’adresse IP.
- L’historique est transmis au modèle pour préparer la recherche, puis les extraits, les textes de pages éventuellement lus et leurs URL lui sont transmis avec le contexte pour la synthèse. Avec un serveur distant, ces étapes ne sont donc pas entièrement locales à l’iPhone.
- La recherche utilise une session HTTPS éphémère sans cookies, cache disque ni identifiants partagés. La lecture d’une page utilise une connexion TLS directe distincte, sans cookies ni clé du modèle. Le site voit son URL demandée et l’adresse IP. Les redirections sont refusées.
- Les résultats sont conservés avec l’historique privé existant. Une réponse terminée peut réutiliser ses extraits dans les échanges suivants ; aucune nouvelle recherche ne part à la simple ouverture d’une conversation.
- Le contenu externe est délimité comme donnée non fiable. Le modèle reçoit une instruction de ne pas suivre les consignes contenues dans les extraits. Ce cadrage ne garantit pas que le modèle citera correctement chaque fait.

## Limites et erreurs

Le moteur HTML n’offre pas de contrat d’API stable. Un CAPTCHA, HTTP 202/403/429, un changement de format, l’absence de résultats ou une panne fait échouer la recherche. En mode outils, le modèle peut reformuler dans les limites prévues. Si aucune recherche n’aboutit, la synthèse est arrêtée avec une erreur ; Eudes ne la présente pas comme documentée. Une page illisible laisse son extrait disponible, clairement identifié comme tel. Hors commande explicite reconnue, une décision du modèle de ne lancer aucun outil permet une réponse ordinaire sans nouvelles sources.

Une recherche a un délai d’inactivité de 15 secondes, un délai total de 25 secondes et une limite de réponse de 512 Kio. Chaque résultat fournit son extrait complet et un titre de 300 caractères.

`web_fetch` accepte uniquement le numéro d’une source obtenue pendant ce tour, jamais une URL inventée par le modèle. HTTPS sur le port 443 est obligatoire. Toutes les adresses DNS doivent être publiques ; la connexion utilise une adresse IP validée, avec vérification du certificat TLS pour le nom du site, afin d’éviter une seconde résolution. Les redirections, cookies, identifiants, réponses comprimées, PDF et JavaScript sont refusés. HTML, XHTML, texte brut et Markdown sont acceptés. Le délai total est de 15 secondes, résolution DNS comprise. Le résultat est le texte extrait de la page, sans garantie de lecture intégrale.

Le contexte est réévalué avant chaque tour d’outils et après ajout des preuves. La limite de taille de réponse et la capacité du contexte restent distinctes du plafond d’appels. Si l’historique technique des outils atteint cette capacité après une collecte réussie, Eudes termine la recherche et tente la synthèse avec les sources obtenues, dont le contexte est vérifié séparément ; le détail d’activité signale cet arrêt. Aucun ancien échange n’est supprimé silencieusement pour faire entrer les résultats. L’estimation reste prudente et approximative ; un petit modèle peut encore refuser le contexte final enrichi avant d’atteindre le plafond d’appels. L’utilisateur peut arrêter pendant la recherche ; un résultat arrivé après l’arrêt ne déclenche pas la synthèse.

## Sources techniques consultées

- [Version HTML/Lite officielle de DuckDuckGo](https://duckduckgo.com/duckduckgo-help-pages/features/non-javascript).
- [Accès au réseau cellulaire dans URLSession](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess).
- [Appels d'outils Chat Completions et Responses](https://developers.openai.com/api/docs/guides/function-calling) et [conservation du raisonnement entre appels](https://developers.openai.com/api/docs/guides/reasoning).
- [Politique d’utilisation DuckDuckGo](https://duckduckgo.com/acceptable-use) : ne pas assimiler l’existence du site HTML à une autorisation générale de redistribution ou à un engagement de disponibilité. À examiner avant une diffusion publique de cette intégration expérimentale.

Le probe réseau de développement du 1 novembre 2026 depuis un poste de développement a reçu un challenge DuckDuckGo (HTTP 202). Ensuite, la recherche réelle dans l’app sur simulateur a récupéré cinq sources pour « Swift programming language » (Swift.org, Apple Developer, Wikipedia, W3Schools et docs.swift.org). La génération suivante a échoué sur le serveur QA fictif : aucune synthèse réelle complète ni validation sur iPhone physique n’est revendiquée. Les résultats de compilation et de tests sont consignés dans le journal des versions (`CHANGELOG.md`).

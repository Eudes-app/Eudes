# Protocoles des connexions — Eudes

Dans la configuration d’une connexion, choisir OpenAI Chat Completions (défaut) ou OpenAI Responses. Le serveur doit réellement implémenter le protocole choisi : une liste `/models` accessible ne garantit pas une génération réussie. Le contrôle reste sans génération facturable ; si `/models` est absent, il consulte `OPTIONS` sur la route choisie.

Les profils existants sans champ de protocole restent Chat Completions. Les clés restent dans le trousseau existant, sans migration ni nouvelle clé. Les déclarations de compatibilité des images sont propres au couple adresse/protocole/modèle : passer à Responses ne réutilise pas implicitement une déclaration Chat Completions. L’historique local est préservé et retransmis explicitement avec le protocole actuellement choisi pour la connexion.

| Élément | Chat Completions | Responses |
|---|---|---|
| Route relative à l’URL de base | `chat/completions` | `responses` |
| Historique | `messages` | `input` |
| Consigne volontaire | message système, sinon absent | `instructions`, sinon absent |
| Image utilisateur | `image_url` | `input_image`, JPEG data URL |
| Limite de génération | `max_tokens` | `max_output_tokens` (inclut les tokens de raisonnement selon le modèle) |
| Créativité | température configurée | défaut du fournisseur, expliqué dans l’éditeur |
| Streaming | deltas Chat Completions | événements sémantiques Responses |

Responses fonctionne ici sans état hébergé : `store: false`, pas de `conversation` ni `previous_response_id`, et `truncation: disabled`. Cela exprime la demande API de non-conservation ; les politiques de journalisation/rétention du fournisseur restent indépendantes. Les erreurs de fenêtre de contexte restent à traiter par le serveur ; ce lot n’ajoute ni comptage ni découpage automatique.

Le texte et les refus sont affichés progressivement. Les instantanés finaux ne sont pas concaténés une seconde fois. Échec, réponse incomplète et interruption de transport conservent le texte reçu. Le transport de synthèse n'exécute pas d'outils reçus dans son flux. Les limites de sortie effectives dépendent du modèle et du serveur. Le choix du protocole ne signifie pas que tous les modèles acceptent toutes les options.

Quand la [recherche Web](WEB_SEARCH.md) est autorisée, une phase distincte non streamée peut présenter les fonctions locales `web_search` et `web_fetch` au modèle. Elle conserve le même historique et les mêmes réglages de connexion. Chat Completions utilise les messages `tool_calls` et `tool` associés par identifiant ; Responses utilise `function_call` et `function_call_output`, avec `store: false` et le rejeu des éléments de raisonnement requis, y compris leur contenu chiffré lorsqu'il est fourni. Ces échanges techniques restent en mémoire. Aucun outil de recherche hébergé ni conversation hébergée n'est demandé. Le refus explicite des outils déclenche une recherche gérée par Eudes ; la synthèse reçoit toujours les preuves avec le contexte du chat. Le streaming final et son éventuel mode de récupération Responses conservent leur fonctionnement existant.

TLS, refus des redirections, autorisation HTTP explicite, bornes de lecture, sessions éphémères et limites des images sont conservés. Les tests utilisent des réponses HTTP/SSE synthétiques, jamais les identifiants ou serveurs de l’utilisateur.

Références officielles consultées le 27 octobre 2026 :
- [Créer une réponse](https://developers.openai.com/api/reference/python/resources/responses/methods/create)
- [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Événements Responses](https://developers.openai.com/api/reference/resources/responses/streaming-events)

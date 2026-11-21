# Réponse, contexte et capacités — Eudes 1.08

## Deux réglages différents

**Longueur maximale de la réponse du modèle** est affichée uniquement dans l’éditeur serveur, auprès du choix du modèle. Seule la métadonnée explicite `top_provider.max_completion_tokens` du catalogue est reconnue actuellement. Un entier positif valide est affiché avec sa provenance ; absence, booléen, fraction ou valeur négative ne donne aucun nombre. La fenêtre de contexte ne sert jamais à déduire une sortie maximale. Les données sont isolées par adresse, protocole et modèle, et une nouvelle découverte sans cette information efface l’ancienne métadonnée.

**Limite volontaire de génération** : son contrôle a été retiré des Réglages en 1.08 à la demande de l’utilisateur. Les choix déjà enregistrés sont conservés, sans migration destructive. La limite transmise est le minimum des valeurs connues (choix volontaire et plafond annoncé). Sans aucune des deux, le paramètre est omis : `max_tokens` pour Chat Completions, `max_output_tokens` pour Responses, `maximumResponseTokens` nil pour Apple. Aucun 2048/32768 arbitraire n’est injecté. Pour Responses, la réserve peut inclure le raisonnement. Si un serveur compatible exige un paramètre absent, l’erreur serveur est affichée ; aucune valeur de secours n’est inventée ; cette version ne propose plus de contrôle pour définir un nouveau plafond volontaire.

Migration : les anciennes valeurs différentes de 2048 sont conservées comme choix utilisateur. L’ancien 2048 ne distinguait pas le défaut automatique d’une sélection explicite : il reste stocké mais n’est plus envoyé automatiquement. Les choix explicitement enregistrés en 1.07, y compris « Aucune limite demandée », restent persistants. Sans sortie connue, le préflight avertit qu’il ne peut garantir la réserve lorsque le contexte est renseigné ; il ne suppose pas une réserve de zéro et ne tronque rien.

Sources officielles : [Responses](https://developers.openai.com/api/reference/cli/resources/responses/methods/create/index.md), [Chat Completions](https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions/index.md), [Apple maximumResponseTokens](https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens). Ces paramètres sont facultatifs ; leur omission laisse le fournisseur décider, sans promettre une sortie illimitée.

**Contexte maximal du modèle** est un seul champ, par connexion/adresse/protocole/modèle. Sans métadonnée fiable, il reste vide avec le texte indicatif **Non renseigné**. Une capacité reçue remplit automatiquement le champ tant qu’aucune valeur manuelle n’a été enregistrée. La saisie est persistante ; effacer explicitement le champ conserve aussi ce choix après actualisation. Les anciennes valeurs manuelles sont préservées. La copie d’une connexion ne reprend pas ces valeurs liées à l’ancienne destination.

La valeur manuelle remplace la capacité annoncée pour l’avertissement client, sans reconfigurer le modèle ou le serveur. Une limite serveur explicite plus petite continue de borner le préflight. La longueur maximale de réponse reste un réglage séparé.

## Capacités en lecture seule

Les lignes **Images** et **Documents PDF** affichent **Pris en charge**, **Non pris en charge** ou **Non déterminé**. Aucun interrupteur de déclaration n’est proposé. Le nom du modèle ne sert jamais à déduire ses capacités.

Le catalogue OpenRouter documente `architecture.input_modalities` : une liste valide contenant `image` annonce les images ; une liste texte explicite sans image annonce leur absence. Une liste manquante, mal typée ou contradictoire reste inconnue. Les informations sont isolées par adresse, protocole et modèle et remplacées à chaque découverte réussie. Cela reste une déclaration du fournisseur, pas une vérification par génération.

Aucun champ actuellement reconnu ne prouve le support natif des PDF : `image` ou `file` ne suffit pas. Pour les API distantes, PDF reste donc **Non déterminé**. Eudes n’a pas de transport de pièce jointe PDF et le précise. Le moteur Apple intégré dans Eudes est textuel : images et PDF non pris en charge dans cette intégration.

Migration : une ancienne connexion manuellement configurée pour les images peut continuer à joindre des images si aucune nouvelle métadonnée ne la contredit. Son statut affiché reste **Non déterminé**, avec une note sur cette ancienne configuration ; elle n’est pas présentée comme confirmée par l’API. Une annonce explicite négative bloque l’ajout. Les brouillons et pièces jointes ne sont pas supprimés.

## Découverte sans génération

La liste des modèles est consultée lors de l’affichage ou du changement de la sélection connexion/modèle d’une nouvelle conversation, et par Tester et charger les modèles dans l’éditeur. Les métadonnées sont traitées avec la liste, sans seconde requête de génération ni déduction à partir du nom du modèle. Une erreur conserve la dernière découverte datée ; une nouvelle réponse réussie remplace les métadonnées de cette adresse/protocole, y compris lorsqu’une limite n’est plus annoncée. Aucun appel à une route de comptage ou d’inférence supplémentaire.

Champs optionnels reconnus dans les entrées de `/models` :

| Champ effectivement fourni | Interprétation affichée |
|---|---|
| `context_length` | Capacité de contexte annoncée |
| `max_model_len` | Limite de contexte serveur annoncée |
| `top_provider.context_length` | Limite de contexte annoncée pour le fournisseur sélectionné par le catalogue |
| `top_provider.max_completion_tokens` | Plafond de sortie annoncé |

Les nombres sont acceptés uniquement s’ils sont entiers positifs, non booléens, et dans la borne de lecture de 100 millions. Les champs absents, nuls, mal typés, négatifs ou hors borne sont ignorés ; les identifiants de modèles restent utilisables. Des entrées dupliquées conservent le plus petit plafond. La provenance API ou saisie manuelle est indiquée près du champ ; les sources détaillées et la date restent conservées dans les métadonnées. Ce sont des déclarations reçues du serveur, pas des capacités certifiées ni une garantie de routage fournisseur.

Le schéma OpenAI standard ne fournit pas systématiquement ces champs. Sans eux : **Non renseigné**, saisie manuelle possible, fonctionnement antérieur conservé. Aucun contexte par défaut inventé. Les réponses `/models` restent bornées et soumises aux protections réseau existantes.

Apple : lorsque le moteur est disponible, le SDK fournit la capacité via `SystemLanguageModel.default.contextSize`, sans génération. Aucune constante de contexte n’est substituée si le moteur est indisponible. La valeur manuelle Apple est sauvegardée séparément, y compris un effacement explicite. La mesure réelle peut varier selon le modèle et l’OS ; elle ne doit pas être confondue avec le plafond de sortie Eudes.

## Préflight et limites

Avant envoi ou régénération, Eudes évalue uniquement les messages complets réellement inclus par les adaptateurs, les instructions explicites et le nouveau message. L’estimation du texte utilise **un token par octet UTF-8**, plus 16 par message/instruction. C’est volontairement prudent et peut fortement surestimer, notamment pour Unicode ; ce n’est ni un tokenizer exact, ni une borne mathématique garantie. Les formats internes des fournisseurs et leurs instructions ajoutées sont inconnus. Même avec Apple, cette version emploie cette estimation commune, pas `tokenCount`.

Le calcul réserve le plafond de sortie appliqué et une marge de `max(128, budget / 20)` tokens. La marge est une politique du client explicitement affichée, pas une métadonnée modèle. Le coût des images dépend du fournisseur : il reste **inconnu**, sans conversion des octets JPEG en tokens. Une image avec budget connu déclenche donc un avertissement même si le texte semble tenir.

En cas de dépassement estimé ou de coût image inconnu avec budget défini : dialogue **Annuler / Envoyer quand même**. Annuler conserve le brouillon et les pièces jointes ; aucun envoi ni conversation n’est créé. Confirmer doit correspondre au même texte et au même état de conversation/configuration ; un changement impose une nouvelle confirmation. L’historique n’est ni tronqué, ni résumé, ni supprimé. Sans limite connue ni budget manuel, le comportement existant est conservé. Le serveur reste l’autorité et peut refuser pour contexte insuffisant ; ses erreurs continuent à préserver le texte et les données locales.

## Validation

Tests synthétiques : migration sans nouveaux champs, persistance/isolation par destination/protocole/modèle, valeurs invalides et entrées dupliquées, plafonds contradictoires, réserve de sortie, Unicode, coût image inconnu, correspondance des deux payloads et plafond Apple, annulation puis confirmation périmée/refaite, découverte retardée après changement de modèle ou enregistrement de la connexion. Aucun service réel ni clé utilisateur utilisé. Les contrôles visuels sont consignés dans [la galerie](GALLERY.md), qui indique les écrans capturés et ceux qui restent à vérifier.

Références officielles consultées le 27 octobre 2026 :
- [OpenAI — liste des modèles](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenRouter — propriétés des modèles](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
- [vLLM — contexte et max_model_len](https://docs.vllm.ai/en/v0.27.1/features/context_extension/)
- [Apple — gestion du contexte](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Apple — contextSize](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize)

## Actualisation dans la configuration — 1.10

Un changement de modèle relance le catalogue après 300 ms de stabilité, sans requête de génération. Les boutons Actualiser du contexte et des capacités ne remplacent que leur domaine pour ce modèle. Une seule requête est active ; les réponses périmées sont ignorées, y compris si un transport ne respecte pas immédiatement l’annulation. Changer adresse, protocole ou clé annule le travail en cours.

Une réponse réussie sans métadonnée retire la valeur automatique et laisse les capacités inconnues. Les valeurs manuelles, y compris le choix explicite d’un champ vide, restent prioritaires et persistantes. Un échec affiche une erreur et conserve les dernières données connues du même modèle ; il ne copie jamais celles du modèle précédent. Les plafonds de sortie restent distincts et inchangés par ces deux boutons. La découverte dépend des métadonnées effectivement exposées par /models ; aucun nom de modèle ne sert à deviner une capacité.

## Autorisation manuelle des images — 1.12

Le bouton Autoriser les images manuellement mémorise le choix pour cette connexion/adresse/protocole/modèle. Il autorise le transport existant lorsque la capacité API est inconnue ; il ne transforme pas la ligne Images en capacité détectée. Désactivé, la détection automatique redevient seule applicable. Une incompatibilité explicitement annoncée et le moteur Apple texte uniquement ne sont pas contournés. L’option ne permet pas les PDF. Actualiser les métadonnées conserve le choix. Les deux phrases entourées sous le bouton dans la maquette ne sont pas ajoutées. Aucun changement de collage ni de permission Photos.

# API locale sur le Mac — Eudes 1.05

Le validateur refusait explicitement les adresses de boucle locale. La livraison 1.05 accepte `localhost`, `127.0.0.1` et `[::1]` (IPv6), avec HTTP/HTTPS, port explicite de 1 à 65535 et chemin API. Les formes IPv6 développées équivalentes à `::1` sont normalisées. Les autres adresses 127/8, sous-domaines `.localhost`, formes numériques abrégées/ambiguës et adresses non spécifiées restent refusées.

## Configuration

Dans le simulateur iPhone sur le Mac, utiliser par exemple `http://127.0.0.1:8000/v1` ou `http://localhost:8000/v1`, en remplaçant **8000 par le port réellement configuré** dans oMLX. Activer **Autoriser HTTP sur ce serveur** pour cette connexion. Eudes ajoute `/models`, `/chat/completions` ou `/responses` au chemin de base suivant l’action et le protocole choisi. Ne pas ajouter ces suffixes dans l’adresse de base.

Sur un **iPhone physique**, localhost et les adresses de boucle locale désignent l’iPhone lui-même, pas le Mac. Utiliser l’adresse LAN du Mac et une configuration serveur accessible depuis ce réseau. Cette livraison ne modifie ni oMLX, ni son écoute réseau, ni le pare-feu. Aucun appel à oMLX n’a été effectué pour les tests.

## Protections conservées

L’accord HTTP par connexion reste obligatoire, même pour localhost. Les exceptions ATS ajoutées sont limitées à `localhost`, `127.0.0.1` et `::1/128`, sans sous-domaines, sans `NSAllowsArbitraryLoads` et sans exception globale de réseau local. Les exceptions privées existantes sont conservées. La validation du certificat HTTPS reste celle d’iOS. Aucune désactivation TLS, redirection, identifiant URL, query/fragment, chemin relatif ou port ambigu n’est accepté. Sessions éphémères, absence de cookies/cache et délais bornés inchangés.

[Documentation Apple des exceptions ATS par domaine/adresse](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains) : les adresses et plages CIDR sont prises en charge depuis iOS 17. Les clés d’exception ne contiennent pas de port.

## Validation

Tests de validation des trois hôtes, ports, chemins et trois routes API ; accord HTTP requis, refus des formes ambiguës ; contrôle des exceptions du bundle. Un test de transport utilise réellement URLSession/ATS vers un serveur HTTP synthétique éphémère, lié uniquement au loopback, pour charger un catalogue fictif via chacun des trois hôtes. Il n’envoie aucun prompt ni clé et ne contacte aucun fournisseur.

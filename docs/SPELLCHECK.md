# Correcteur orthographique du champ de message

Ajout d'une section « Correcteur » dans **Réglages → Conversations** : le toggle « Vérification orthographique » (activé par défaut) active le correcteur natif d'iOS (`UITextView.spellCheckingType`, fondé sur `UITextChecker`) dans le compositeur de conversation. Les fautes de frappe sont soulignées et les corrections proposées par le menu natif à l'appui long, entièrement sur l'appareil. La correction automatique pendant la frappe reste désactivée (`autocorrectionType = .no`).



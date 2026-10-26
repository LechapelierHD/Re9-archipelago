# RE9-AP-Client

Archipelago client research and REFramework Lua tooling for **Resident Evil Requiem (RE9)**.

## RE9 AP Wizard (lanceur)

`launcher\` contient le lanceur WPF, sur le modèle du RE4R AP Wizard : Accueil, Rejoindre un multimonde (YAML, test de la room, installation), Héberger un multimonde (Archipelago, apworld, YAML, génération, room) et État de la configuration (jeu, REFramework, client).

- `launcher\build_package.ps1` compile le lanceur et assemble le dossier `Resident Evil 9 AP\` (exe autonome + `assets\` : scripts Lua, données, `lua-apclientpp.dll`, apworld). `-Zip` produit aussi l'archive à distribuer.
- En jeu : notifications en haut à droite, bandeau de progression en haut, fenêtre « Archipelago - Resident Evil Requiem » visible avec le menu REFramework (Insert).

## Current focus

This repository currently targets the inventory injection pipeline needed for Archipelago-style item delivery.

## Testing
- Testing is currently done by moving the scripts from the randomizer folder to the autorun folder. Test every Script one by one for functionality.

## Docs

- `docs/reverse-engineering-next-steps.md` for the recommended live reverse-engineering workflow.



## Special Thanks
- Fuzzy for his work on the RE2R AP Client. This Project uses most of his work on the APClient as a base.

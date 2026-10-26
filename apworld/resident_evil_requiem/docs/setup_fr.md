# Resident Evil Requiem - installation

## Prérequis

- Resident Evil Requiem (Steam)
- Windows
- [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.8 ou plus récent

## Client

Télécharge le client **1.0.121** sur https://lechapelierhd.github.io/Re9-AP-site/ et lance `RE9.AP.Launcher.exe`.
Le lanceur installe REFramework, les scripts et l'apworld **1.0.7**.

Le code du projet est sur https://github.com/LechapelierHD/Re9-archipelago

## Générer une partie

1. L'apworld `resident_evil_requiem` est installé par le lanceur, ou copie `resident_evil_requiem.apworld` dans `Archipelago\custom_worlds`.
2. Copie `Resident Evil Requiem.yaml` dans `Archipelago\Players`.
   `game_difficulty` doit correspondre à la difficulté de la sauvegarde.
3. Génère et héberge la partie comme d'habitude.
   Une nouvelle seed est nécessaire pour les crédits et la logique de l'hôpital (apworld 1.0.7).

## Jouer

1. En jeu, ouvre le menu REFramework, fenêtre **Archipelago RE Requiem**.
2. Renseigne le serveur, le nom du slot et le mot de passe, puis connecte avant de ramasser.
3. Chaque check ramassé est envoyé. Les crédits reçus d'un autre joueur restent au changement de chapitre.

<a id="english"></a>

# Re9 archipelago — client 1.0.121, apworld 1.0.7

**English** | [Français](#francais)

[Archipelago](https://archipelago.gg) randomizer for **Resident Evil Requiem** (RE9).

Items lying in the world become checks shared with the other players of the multiworld.
Picking up an item sends its check; what you find may belong to another player, and your own items
may be found in other games.

> Back up your RE9 saves before playing.

## What's new (client 1.0.121, apworld 1.0.7)

- **Guidance**: tick “When changing chapter, send the missed checks” to send the unfinished checks of the chapter you leave. Off by default. The chapter does not restart.
- Credits received from another player stay when you change chapter.
- Apworld **1.0.7**. A new seed is required for the credit packs and the hospital (Care Center) logic. The client update alone does not need one.

## What the mod includes

- **"Re9 archipelago" launcher** (Windows): join or host a multiworld, install REFramework, the in-game
  client and the apworld, check your setup, create a full player YAML, and get updates with the
  **Update** button (the **Updates** tab shows what the latest update added).
  Available in English and French (**Language** button at the bottom left).
- **In-game client** (REFramework script): server connection, sending checks, receiving items.
- **Chapter skip** (optional, installed from *Setup status*, settings in the **Guidance** tab): as Grace,
  press F on the billboard (first investigation point) to skip ahead. The checks of skipped chapters are sent
  (or their items go to the item box when offline). Save before skipping.
- **`resident_evil_requiem` apworld**: the Archipelago world used to generate games.

## Source code

The source of the project is this repository.

- `apworld/` — Archipelago world (Python)
- `client/reframework/` — in-game Lua client
- `client/launcher/` — C# launcher
- `client/native/` — lua-apclientpp

The playable client stays on the site: https://lechapelierhd.github.io/Re9-AP-site/

<a id="screenshots"></a>

## Screenshots

| Launcher home | Player options (YAML) |
|---|---|
| ![Home](docs/screenshots/home.png) | ![Join a multiworld](docs/screenshots/join.png) |
| **Host a multiworld** | **Setup status** |
| ![Host](docs/screenshots/host.png) | ![Setup](docs/screenshots/setup.png) |

**In-game client** (REFramework menu):

![In-game client](docs/screenshots/client_ingame.jpg)

## How it works in game

- Items on the floor, in drawers, safes, lockers, etc. across the 20 chapters (**Ch1 to Ch20**, in story
  order) are checks. The count depends on the difficulty and the options. No items are given at the start.
- These pickups stay in the world and are never checks: Screwdriver, Lighter, Flashlight, Override Manual,
  Unknown Item, and the first fuse (`Ch3 st30_001 - Fuse`).
- Locations are named `ChN Area - Item` (e.g. `Ch1 AbandonedHotel - Wire Cutters`).
- Picking up a check that holds **one of your own AP items** puts it straight into your inventory
  (option; if there is no room, it goes to the item box).
- Picking up a check that holds **another player's item** does not give you the original game item.
- Items received from other players go straight into the **played character's inventory** (ammo, healing,
  key items of the current chapter); the rest, or what does not fit, goes to the **item box**.
  While playing Leon, received items wait until you are back on Grace.
- **F7** opens the item box screen from anywhere.
- The item name and its owner are shown on pickup ("Found: Green Herb for Bob"), in the game's language.
- Names are shown above nearby checks not done yet (Guidance tab).
- Notifications (item, sender, destination, rarity color), progress bar and client window (REFramework menu), customizable colors, English / French.
- **Debug** tab (enable "Developer tools" in **Customize**): resend checks, redeliver lost items, take an
  item from the item box into your inventory, give yourself an item if a check failed, journal.
- **Goal**: beat the final boss. The client sends the victory.

## YAML options

| Option | Values | Effect |
|---|---|---|
| `game_difficulty` | `casual`, `modern` (default), `classic`, `insanity` | Must match the difficulty of your save: some items only exist on some difficulties. |
| `key_items` | `vanilla` (default), `shuffled` | Progressive keys are checks. The cinematic pickups listed above stay on the ground. |
| `supply_box` | `false` (default), `true` | `true`: the 11 merchant rows are checks. The Ch13 ground crates stay checks either way. |
| `enemy_drops` | `0`–`50` (default `50`) | Enemy deaths and broken pots send the next of these checks, in order. They only hold filler. `0` turns them off. |
| `death_link` | off / on | Archipelago death link. |

The launcher's **Join a multiworld** page creates a full YAML in the Archipelago template format, with
every option explained (including the common ones: `progression_balancing`, `accessibility`,
`local_items`, `start_inventory`, `item_links`...).

Short example:

```yaml
name: Player{number}
game: Resident Evil Requiem
requires:
  version: 0.6.8

Resident Evil Requiem:
  progression_balancing: 50
  accessibility: full
  game_difficulty: modern
  key_items: vanilla
  supply_box: false
  enemy_drops: 50
```

## Install

Requirements: Resident Evil Requiem (Steam), Windows, and [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.8 or newer to host or generate.

1. Download the client from the [site](https://lechapelierhd.github.io/Re9-AP-site/) (`RE9-AP-Client-1.0.121.zip`) and extract it anywhere.
2. Run `RE9.AP.Launcher.exe`.
3. Choose **Join a multiworld** (or **Host a multiworld**) and follow the steps:
   the launcher installs REFramework, the client and the apworld.
4. In game, open the REFramework menu and connect **before** picking anything up.

Updates then arrive in the launcher: "Update available" banner at the top, **Update** button.
The launcher updates itself too: it closes and restarts on its own.

## Known limitations

- Weapons have no logic: they are shuffled like everything else, with no guarantee of getting them early.
- Credit packs and the Care Center logic need a seed generated with apworld 1.0.7.

## Reporting a bug

In the launcher, click **Create a bug report**: a `RE9-bugreport-….zip` file is created on the
desktop. Send it with a description of what happened.

## Credits

- [Archipelago](https://archipelago.gg)
- [REFramework](https://github.com/praydog/REFramework) by praydog
- Fuzzy, for the RE2R AP client used as the base of the client
- The RE4R AP Wizard, which the launcher is modeled on

---

<a id="francais"></a>

# Re9 archipelago — client 1.0.121, apworld 1.0.7 — Français

[English](#english) | **Français**

Randomizer [Archipelago](https://archipelago.gg) pour **Resident Evil Requiem** (RE9).

Les objets posés dans le monde deviennent des checks partagés avec les autres joueurs du multimonde.
Ramasser un objet envoie son check ; ce que tu trouves peut appartenir à un autre joueur, et tes propres
objets peuvent être trouvés dans d'autres jeux.

> Fais une sauvegarde de tes parties RE9 avant de jouer.

## Nouveautés (client 1.0.121, apworld 1.0.7)

- **Guidage** : cocher « Au changement de chapitre, envoyer les checks oubliés » envoie les checks pas faits du chapitre quitté. Décoché par défaut. Le chapitre ne recommence pas.
- Les crédits reçus d'un autre joueur restent au changement de chapitre.
- Apworld **1.0.7**. Une nouvelle seed est nécessaire pour les paquets de crédits et la logique de l'hôpital (Care Center). La mise à jour du client seule n'en demande pas.

## Ce que contient le mod

- **Lanceur « Re9 archipelago »** (Windows) : rejoindre ou héberger un multimonde, installer REFramework,
  le client en jeu et l'apworld, vérifier la configuration, créer un YAML joueur complet, et recevoir
  les mises à jour avec le bouton **Mettre à jour** (l'onglet **Mises à jour** montre les nouveautés de
  la dernière mise à jour). En français ou en anglais.
- **Client en jeu** (script REFramework) : connexion au serveur, envoi des checks, réception des objets.
- **Saut de chapitre** (optionnel, à installer depuis *État de la configuration*, réglages dans l'onglet
  **Guidage**) : avec Grace, F sur le panneau publicitaire (premier point d'enquête) fait sauter des
  chapitres. Les checks des chapitres sautés sont envoyés
  (ou leurs objets vont au coffre hors connexion). Sauvegarde avant de sauter.
- **apworld `resident_evil_requiem`** : le monde Archipelago pour générer les parties.

## Code source

Le code du projet est ce dépôt.

- `apworld/` — monde Archipelago (Python)
- `client/reframework/` — client Lua en jeu
- `client/launcher/` — lanceur C#
- `client/native/` — lua-apclientpp

Le client jouable reste sur le site : https://lechapelierhd.github.io/Re9-AP-site/

## Captures d'écran

Voir les [captures d'écran plus haut](#screenshots) (lanceur affiché en anglais ; le français est la
langue par défaut).

## Fonctionnement en jeu

- Les objets au sol, dans les tiroirs, coffres-forts, casiers, etc. des 20 chapitres (**Ch1 à Ch20**,
  dans l'ordre de l'histoire) sont des checks. Le nombre dépend de la difficulté et des options. Aucun objet n'est donné au départ.
- Ces ramassages restent au sol et ne sont jamais des checks : tournevis, briquet, lampe, manuel,
  objet inconnu, et le premier fusible (`Ch3 st30_001 - Fuse`).
- Les locations s'appellent `ChN Zone - Objet` (ex. `Ch1 AbandonedHotel - Wire Cutters`).
- Ramasser un check contenant **ton propre objet AP** te le donne directement dans l'inventaire
  (option ; s'il n'y a pas de place, il part au coffre).
- Ramasser un check contenant **l'objet d'un autre joueur** ne te donne pas l'objet du jeu d'origine.
- Les objets reçus des autres joueurs vont directement dans l'**inventaire du personnage joué**
  (munitions, soins, objets clés du chapitre en cours) ; le reste, ou ce qui ne tient pas, va au **coffre**.
  Pendant Leon, les objets reçus attendent le retour sur Grace.
- **F7** ouvre l'écran du coffre de n'importe où.
- Nom de l'objet et du joueur affiché au ramassage (« Trouvé : Herbe verte pour Bob »), dans la langue du jeu.
- Noms affichés au-dessus des checks proches pas encore faits (onglet Guidage).
- Notifications (objet, expéditeur, destination, couleur de rareté), bandeau de progression et fenêtre du
  client (menu REFramework), couleurs personnalisables, français / anglais.
- Onglet **Debug** (case « Outils développeur » dans **Personnaliser**) : renvoyer les checks, redonner
  des objets perdus, prendre un objet du coffre dans son inventaire, se donner un objet si un check a
  raté, journal.
- **Objectif** : battre le dernier boss. Le client envoie la victoire.

## Options du YAML

| Option | Valeurs | Effet |
|---|---|---|
| `game_difficulty` | `casual`, `modern` (défaut), `classic`, `insanity` | Doit correspondre à la difficulté de ta sauvegarde : certains objets n'existent que dans certaines difficultés. |
| `key_items` | `vanilla` (défaut), `shuffled` | Les clés progressives sont des checks. Les ramassages de cinématique listés plus haut restent au sol. |
| `supply_box` | `false` (défaut), `true` | `true` : les 11 lignes du marchand sont des checks. Les caisses au sol du Ch13 restent des checks dans les deux cas. |
| `enemy_drops` | `0`–`50` (défaut `50`) | Une mort d'ennemi ou un pot cassé envoie le prochain de ces checks, dans l'ordre. Ils ne contiennent que du filler. `0` les coupe. |
| `death_link` | off / on | Death link Archipelago. |

La page **Rejoindre un multimonde** du lanceur crée un YAML complet au format des modèles Archipelago,
avec toutes les options expliquées (y compris les options communes : `progression_balancing`,
`accessibility`, `local_items`, `start_inventory`, `item_links`...).

Exemple court :

```yaml
name: Joueur{number}
game: Resident Evil Requiem
requires:
  version: 0.6.8

Resident Evil Requiem:
  progression_balancing: 50
  accessibility: full
  game_difficulty: modern
  key_items: vanilla
  supply_box: false
  enemy_drops: 50
```

## Installer

Prérequis : Resident Evil Requiem (Steam), Windows, et [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.8 ou plus récent pour héberger ou générer.

1. Télécharge le client sur le [site](https://lechapelierhd.github.io/Re9-AP-site/) (`RE9-AP-Client-1.0.121.zip`) et décompresse-le où tu veux.
2. Lance `RE9.AP.Launcher.exe`.
3. Choisis **Rejoindre un multimonde** (ou **Héberger un multimonde**) et suis les étapes :
   le lanceur installe REFramework, le client et l'apworld.
4. En jeu, ouvre le menu REFramework et connecte-toi **avant** de ramasser quoi que ce soit.

Les mises à jour arrivent ensuite dans le lanceur : bandeau « Mise à jour disponible » en haut,
bouton **Mettre à jour**. Le lanceur se met aussi à jour lui-même : il se ferme et se relance tout seul.

## Limites connues

- Les armes n'ont pas de logique : elles sont mélangées comme le reste, sans garantie de les avoir tôt.
- Les paquets de crédits et la logique du Care Center demandent une seed générée avec l'apworld 1.0.7.

## Signaler un bug

Dans le lanceur, clique sur **Générer un rapport de bug** : un zip `RE9-bugreport-….zip` est créé
sur le bureau. Envoie-le avec une description de ce qui s'est passé.

## Remerciements

- [Archipelago](https://archipelago.gg)
- [REFramework](https://github.com/praydog/REFramework) par praydog
- Fuzzy, pour le client AP de RE2R qui sert de base au client
- Le RE4R AP Wizard, modèle du lanceur


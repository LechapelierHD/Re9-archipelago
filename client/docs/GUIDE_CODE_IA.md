# Guide du code ajouté par l'IA (15/10/2026)

Ce guide explique tout ce que l'IA a ajouté ou modifié, pour pouvoir trouver un bug sans elle.
Le détail des lignes comptées est dans `RAPPORT_IA.txt`.

## Où lire les erreurs

- **Journal REFramework** : `re2_framework_log.txt` dans le dossier du jeu.
  Toutes les lignes du client commencent par `[RE9 AP]`.
- **Crash du jeu** : la fin du même journal donne la pile d'appels (`[TDB: app.Xxx.methode]`)
  et REFramework écrit `reframework_crash.dmp` à côté.
  Regarde la ligne `[RE9 AP]` ou `Exception thrown in REMethodDefinition::invoke` juste avant.
- **Derniers ramassages** : `reframework\data\ArchipelagoRE9\last_pickups.json`
  (dossier de l'objet, emplacement trouvé, raison).
- **État de la partie** : `reframework\data\ArchipelagoRE9\session_state.json`
  (`checked`, `last_index`, `goal_sent`...).
- Après avoir modifié un `.lua`, il faut le recopier dans le jeu puis faire
  **Insert > ScriptRunner > Reset scripts** (ou relancer le jeu).
  Le journal affiche `Running script ...ArchipelagoRE9.lua` à chaque rechargement :
  si cette ligne n'apparaît pas, l'ancienne version tourne encore.

---

## 1. Saut de chapitre — `reframework\optional\chapterskip.lua`

Installé dans le jeu sous `autorun\ArchipelagoRE9\chapterskip.lua`.

**Ce que ça fait** : avec Grace, la touche F sur le panneau `Gm11_001` saute à la scène choisie
et termine les chapitres sautés (checks envoyés si connecté, sinon objets mis au coffre).

**Comment ça marche**
- `SCENES` : liste `{ scène, chapitre de l'apworld }` dans l'ordre du jeu.
  `CHAPTER_NAMES` : noms affichés (repris du Modular Chapter Skip de MaVeRicK).
- Deux hooks interceptent l'enquête du panneau :
  `app.InteractActionCrimeResearch.onProcess` et `app.CrimeResearchObject.requestResearchStart`.
  Si c'est le bon objet et le bon personnage, `on_interact` demande le saut
  et bloque l'enquête normale (`SKIP_ORIGINAL`).
- `do_jump` : `MainGameFlowManager.setNewGameSceneName(cible)`
  puis `SceneTransitionManager.requestMainGameJump(NewgameSetupRequestArgs.Default)`.
- Une fois arrivé (`re.on_frame`), la scène de nouvelle partie est remise à `Chap1_00`
  et `finish_skipped` termine les chapitres sautés.
- Réglages sauvegardés dans `data\ArchipelagoRE9\chapter_skip.json`.

**Journal** : `saut de chapitre installé`, `Saut X -> Y : demandé / ÉCHEC`,
`arrivé dans ...`, `Chapitres sautés terminés : N check(s)...`.

**Bugs possibles**
- Rien ne se passe sur F : mauvais personnage (`Seulement avec Grace`), mauvais objet,
  ou un hook `introuvable` dans le journal (le jeu a changé de version).
- Une « nouvelle partie » démarre au mauvais endroit : `restore_scene` n'a pas remis `Chap1_00`
  (le saut n'est jamais arrivé à la cible).
- Attention : sauter jusqu'à la fin du jeu peut envoyer la victoire. Le serveur donne alors
  tous les objets restants d'un coup (c'est ce qui a rempli le coffre de Tracking Modules).

**Désactiver** : décocher « Activer le saut » dans l'onglet du client, ou retirer le fichier.

---

## 2. Objets lâchés par les ennemis = checks

### Côté apworld — `resident_evil_requiem\__init__.py` et `Options.py`

- `ENEMY_DROPS` : 50 emplacements `Enemy Drop #1..#50`, IDs `7092000` à `7092049`.
  Ils ne sont pas dans `Locations.py` (fichier généré), ils sont ajoutés à la main.
- Option `enemy_drops` (`EnemyDrops`, 0 à 50, 15 par défaut) : `generate_early` garde
  les N premiers dans `self.enemy_drops`.
- `create_regions` : ils sont placés dans la région `Menu` (accessibles dès le début,
  avec Grace comme avec Leon) en `LocationProgressType.EXCLUDED` :
  **jamais d'objet de progression dedans**, donc une partie ne peut pas être bloquée
  si on ne tue pas assez d'ennemis.
- `create_items` : un objet de remplissage au hasard par drop (`get_filler_item_name`).
- `fill_slot_data` : les IDs sont ajoutés à `locations` et comptés dans `check_count`.
- Version `WORLD_VERSION = "1.0.6"` (+ `archipelago.json`).

### Côté données — `generate.ps1` et `re9_ap_ids.json`

- Les 50 drops ont `chapter = "Drop"`, `zone = "Enemy"`, sans clé ni position.
- Le client fait confiance à la liste du serveur seulement si **tous** les IDs existent
  dans `re9_ap_ids.json` et que le nombre égale `check_count`.
  Si on change le nombre max de drops, il faut régénérer ce fichier (et sa copie dans
  `reframework\data\ArchipelagoRE9\`), sinon : « Liste des checks inconnue ».

### Côté client — `reframework\autorun\ArchipelagoRE9\detector.lua`

- `DROP_FOLDERS` : `AppResident/Instance/Item` et `AppResident/Instance/DropResource`,
  les dossiers où le jeu crée les objets lâchés. Ces dossiers sont ignorés d'habitude
  (`ctx.IGNORED_FOLDER_PREFIXES` dans `config.lua`).
- `enemy_drop(info)` : si l'objet ramassé vient d'un de ces dossiers, prend le premier
  emplacement `chapter == "Drop"` actif et pas encore fait (`ctx.mark_checked`), dans l'ordre des IDs.
- Dans `on_pickup`, branche `is_ignored` : si un drop est trouvé → `announce_check`
  + `remember_pickup(..., "objet lâché par un ennemi", "check")`.
  On renvoie `nil` : **le joueur garde l'objet**, rien n'est remplacé.

**Journal / last_pickups.json** : `match = "objet lâché par un ennemi"`, `status = "check"`.
Sinon `"objet généré en jeu"` = drop ignoré.

**Bugs possibles**
- Aucun check sur un drop : la partie a été générée avec un ancien apworld (pas de « Enemy Drop »
  dans le slot), tous les drops sont déjà faits, ou l'objet vient d'un autre dossier
  (regarder `folder_path` dans `last_pickups.json` et l'ajouter à `DROP_FOLDERS`).
- Un objet qui n'est pas un drop envoie un check : il vient d'un dossier `Instance/...`
  utilisé pour autre chose. Restreindre `DROP_FOLDERS`.

**Désactiver** : `enemy_drops: 0` dans le YAML.

---

## 3. Icônes des checks sur la carte — `reframework\autorun\ArchipelagoRE9\markers.lua`

**Ce que ça fait** : les checks pas faits des zones chargées apparaissent sur la carte du jeu
sans avoir été vus. Rien n'est écrit dans la sauvegarde.

**Comment ça marche**
- La carte n'affiche un objet que si son statut d'icône (`app.structure.MapIconStatus`,
  dans `MapIconControllerForItem._MapIconStatus`) répond « découvert ».
- `force_discovered` met un hook sur `MapIconStatus.get_IsDiscovered` et `get_IsDiscoveredAny` :
  si l'adresse du statut est dans `forced_status`, on renvoie `true` (`sdk.to_ptr(1)`).
- `scan()` (toutes les 2 s) : pour chaque check actif pas fait de la scène,
  `reveal_on_map` cherche le contrôleur (`map_controller` : sur l'objet ou son parent),
  lit `_MapIconStatus` et garde son adresse (`e.status_addr`).
  `forced_status` est **reconstruit à chaque scan** : un check ramassé perd son icône forcée.
- Si un objet n'a pas de statut après 5 essais (`MAP_TRIES`), il est noté « sans icône ».
- Réglage : case « Icônes des checks sur la carte du jeu » (`ctx.marker_prefs.map_icons`,
  sauvegardé dans `markers.json`).

**Journal** : `carte : N check(s) affiché(s), M sans icône de carte (noms...)`
puis une ligne `carte :   Nom @ x, y, z` par check affiché. Écrit seulement quand ça change.

**Important — ne pas faire**
- **Ne pas appeler `MapIconControllerForItem.discovered()`** : pendant le chargement d'une
  sauvegarde, ça lève une exception puis fait planter le jeu
  (`ComponentStateSetMediator.processRequests`).
- Écrire `_DiscoveredByObjectIcon` / `_DiscoveredByInteractIcon` ne sert à rien.
- `set_IsDiscovered(true)` n'affichait rien et modifiait la sauvegarde : retiré.

**Bugs possibles**
- Aucune icône : regarder si `carte : ...` apparaît. Sinon, la case est décochée ou
  `MapIconStatus.get_IsDiscovered introuvable` (le jeu a changé).
- Un check dans une caisse, un tiroir... n'a pas d'icône : l'objet n'a pas de
  `MapIconControllerForItem`, le jeu n'a rien prévu. Il faudrait créer une icône soi-même
  (`GuiMapModel.addMapIcon`, pas encore fait).
- Plusieurs checks au même endroit ou sur un autre étage : les icônes se superposent
  ou sont sur l'autre étage de la carte.
- Ralentissements : le hook est appelé très souvent ; il ne fait qu'une recherche dans une table.
  Si ça rame, décocher la case pour vérifier.

**Désactiver** : décocher la case dans l'onglet des marqueurs.

---

## 4. Lanceur — `launcher\RE9.AP.Launcher`

- **Part de l'IA** : `Core\AppInfo.cs` → `AiCodePercent`. Affiché par `Views\HomeView.xaml(.cs)`
  (`AiShareText`), traduit dans `Core\Lang.cs`. À garder égal au total de `RAPPORT_IA.txt`.
- **Bouton Crédits** : `Views\MainWindow.xaml` (bouton après « Ouvrir le dossier des journaux »),
  `MainWindow.xaml.cs` → `Credits_Click` affiche la constante `Credits` dans une MessageBox.
  Traduction anglaise dans `Lang.cs` (clé `Views.MainWindow.Credits`).
- **Logos** : `assets\logo.png`, `logo_small.png`, `app.ico` (dessin de Aure0re, recadré).
- **Modèle YAML** : `Core\YamlTools.cs`, section `enemy_drops` après les objets clés.
  C'est une chaîne C# brute `"""` : pas de `""` à l'intérieur.

**Bugs possibles** : texte non traduit = clé absente de `Lang.cs` (la clé est le texte français exact).
Un changement dans le lanceur n'arrive chez les joueurs qu'avec un patch `-Launcher`.

---

## 5. Publier

- `launcher\make_patch.ps1 -Title ... -Notes @(...) -TitleEn ... -NotesEn @(...) -Label "1.0.0 alpha" [-Launcher]`
  (le lancer avec `& .\make_patch.ps1`, pas `powershell -File`, sinon les notes sont fusionnées).
- `launcher\publish_github.ps1 -Version X.Y.Z` pour la release GitHub.
- `apworld\build_apworld.ps1 -Install` reconstruit et installe l'apworld.

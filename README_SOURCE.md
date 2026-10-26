# Resident Evil 9 AP — Source

Dossier généré le 2026-10-17 11:18.
Basé sur `re9ap_source_1.0.31.zip`, mis à jour avec les fichiers du build installé
(`assets\Lua`, `assets\Data\resident_evil_requiem`, Optional).

## Contenu

- `apworld/` — world Archipelago (Python, scripts generate.ps1, exports JSON)
- `client/reframework/autorun/` — client Lua REFramework
- `client/reframework/optional/` — modules optionnels (chapter skip, warp…)
- `client/launcher/` — lanceur C# / WPF (RE9.AP.Launcher)
- `client/wizard/` — utilitaire C#
- `GUIDE_CODE_IA.md`, `RAPPORT_IA.txt` — notes IA

## Exclu volontairement

- `RE9.AP.Launcher.exe` / patches `.zip` / `lua-apclientpp.dll` (binaires)
- Gros packs de patch installés

## Note

Le pack source zip était en 1.0.31 ; Lua / apworld ont été écrasés par la
version présente dans le dossier d'installation (patches jusqu'à ~1.0.54 côté client).

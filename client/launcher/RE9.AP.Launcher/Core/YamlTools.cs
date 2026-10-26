using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace RE9.AP.Launcher.Core
{
    public sealed class YamlInfo
    {
        public string Path = "";
        public string Name = "";
        public string Game = "";

        public bool IsRe9
        {
            get { return string.Equals(Game, AppInfo.GameName, StringComparison.OrdinalIgnoreCase); }
        }

        public string Display
        {
            get
            {
                return (Name.Length > 0 ? Name : "(sans nom)") + "  —  " + (Game.Length > 0 ? Game : "jeu inconnu")
                    + "  —  " + System.IO.Path.GetFileName(Path);
            }
        }
    }

    public static class YamlTools
    {
        public static readonly Regex SlotNamePattern = new Regex("^[^\\s].{0,15}$");

        private static readonly string[] Difficulties = { "casual", "modern", "classic", "insanity" };
        private static readonly string[] KeyItemModes = { "vanilla", "shuffled" };
        private static readonly string[] BalancingModes = { "random", "random-low", "random-high", "random-range-0-99", "disabled", "normal", "extreme" };
        private static readonly string[] AccessModes = { "full", "minimal" };

        // Calqué sur Players\Templates\Resident Evil Requiem.yaml (format pondéré d'Archipelago)
        private const string Template = """
# Q. What is this file?
# A. This file contains options which allow you to configure your multiworld experience while allowing
#    others to play how they want as well.
#
# Q. How do I use it?
# A. The options in this file are weighted. This means the higher number you assign to a value, the
#    more chances you have for that option to be chosen. For example, an option like this:
#
#    map_shuffle:
#      on: 5
#      off: 15
#
#    Means you have 5 chances for map shuffle to occur, and 15 chances for map shuffle to be turned
#    off.
#
# Q. I've never seen a file like this before. What characters am I allowed to use?
# A. This is a .yaml file. You are allowed to use most characters.
#    To test if your yaml is valid or not, you can use this website:
#        http://www.yamllint.com/
#    You can also verify that your Archipelago options are valid at this site:
#        https://archipelago.gg/check

# Your name in-game, limited to 16 characters.
#     {player} will be replaced with the player's slot number.
#     {PLAYER} will be replaced with the player's slot number, if that slot number is greater than 1.
#     {number} will be replaced with the counter value of the name.
#     {NUMBER} will be replaced with the counter value of the name, if the counter value is greater than 1.
name: @NAME@

# Used to describe your yaml. Useful if you have multiple files.
description: @DESCRIPTION@

game: Resident Evil Requiem
requires:
  version: 0.6.8 # Version of Archipelago required for this yaml to work as expected.

Resident Evil Requiem:
  ################
  # Game Options #
  ################
  progression_balancing:
    # A system that can move progression earlier, to try and prevent the player from getting stuck and bored early.
    # 
    # A lower setting means more getting stuck. A higher setting means less getting stuck.
    #
    # You can define additional values between the minimum and maximum values.
    # Minimum value is 0
    # Maximum value is 99
@BALANCING@

  accessibility:
    # Set rules for reachability of your items/locations.
    # 
    # **Full:** ensure everything can be reached and acquired.
    # 
    # **Minimal:** ensure what is needed to reach your goal can be acquired.
@ACCESSIBILITY@

  game_difficulty:
    # The difficulty you will play on. Some items only exist on some difficulties;
    # a spot that does not exist on yours would be a check you can never reach, so it is left out.
    # Generation cannot see the game: set it to match your save.
    #
    # Casual / Modern / Classic / Insanity: the difficulty of your save.
@DIFFICULTY@
  key_items:
    # What happens to key items (keys, keycards, fuses, quartz, lighter, lockpick...).
    # 
    # Vanilla: key items stay where they are and are not checks. The story can never be blocked.
    # Shuffled: every check is placed at random in any world of the multiworld.
    # Hotel keys, the first fuse, the screwdriver and the cutscene items stay on the ground.
@KEYITEMS@
  enemy_drops:
    # Number of "Enemy Drop" checks. Each item from an enemy death or a broken pot
    # sends the next of these checks, in order. Filler only. 0 turns them off.
    #
    # Minimum value is 0
    # Maximum value is 50
@ENEMYDROPS@
  supply_box:
    # Les 11 lignes d'achat du Supply Box. Le marchand se débloque après avoir fini le jeu une fois.
    # false : ces lignes ne sont pas des checks.
    # true : Archipelago choisit l'objet de chaque ligne.
    # Les caisses Ch13 Supply Box restent des checks.
@SUPPLYBOX@
  death_link:
    # When you die, everyone who enabled death link dies. Of course the reverse is true too.
@DEATHLINK@

  ###########################
  # Item & Location Options #
  ###########################
  local_items:
    # Forces these items to be in their native world.
    []

  non_local_items:
    # Forces these items to be outside their native world.
    []

  start_inventory:
    # Start with the specified amount of these items. Example: {Bomb: 1, Arrow: 3}
    {}

  start_inventory_from_pool:
    # Start with the specified amount of these items and don't place them in the world. Example: {Bomb: 1, Arrow: 3}
    # 
    # The game decides what the replacement items will be.
    {}

  start_hints:
    # Start with these item's locations prefilled into the ``!hint`` command.
    []

  start_location_hints:
    # Start with these locations and their item prefilled into the ``!hint`` command.
    []

  exclude_locations:
    # Prevent these locations from having an important item.
    # Example: [Ch16 st40_611 - Hatch Key]  or a whole chapter: [Ch5]
    []

  priority_locations:
    # Prevent these locations from having an unimportant item.
    []

  item_links:
    # Share part of your item pool with other players.
    []

  plando_items:
    # Generic items plando.
    []

""";

        public static string Build(string slot, string difficulty, string keyItems, int enemyDrops, bool supplyBox, bool deathLink, string balancing, string accessibility)
        {
            int drops = enemyDrops < 0 || enemyDrops > 50 ? 15 : enemyDrops;
            string supply = supplyBox ? "    'false': 0\n    'true': 50\n" : "    'false': 50\n    'true': 0\n";
            string death = deathLink ? "    'false': 0\n    'true': 50\n" : "    'false': 50\n    'true': 0\n";
            return Template.Replace("\r\n", "\n")
                .Replace("@NAME@", Quote(slot))
                .Replace("@DESCRIPTION@", "Resident Evil Requiem - " + AppInfo.DisplayName + " " + PatchUpdater.CurrentLabel)
                .Replace("@DIFFICULTY@", Weights(Difficulties, difficulty, "modern"))
                .Replace("@KEYITEMS@", Weights(KeyItemModes, keyItems, "vanilla"))
                .Replace("@ENEMYDROPS@", "    " + drops + ": 50\n")
                .Replace("@SUPPLYBOX@", supply)
                .Replace("@DEATHLINK@", death)
                .Replace("@BALANCING@", Weights(BalancingModes, balancing, "normal"))
                .Replace("@ACCESSIBILITY@", Weights(AccessModes, accessibility, "full"))
                .Replace("\n", Environment.NewLine);
        }

        private static string Weights(string[] values, string chosen, string fallback)
        {
            string pick = Array.IndexOf(values, (chosen ?? "").Trim().ToLowerInvariant()) >= 0 ? chosen.Trim().ToLowerInvariant() : fallback;
            StringBuilder b = new StringBuilder();
            foreach (string v in values) b.Append("    ").Append(v).Append(": ").Append(v == pick ? 50 : 0).Append('\n');
            return b.ToString();
        }

        private static string Quote(string s)
        {
            return "\"" + (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        public static string SafeFileName(string slot)
        {
            string name = slot ?? "joueur";
            foreach (char c in System.IO.Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
            return "RE9_" + name.Trim() + ".yaml";
        }

        public static YamlInfo Inspect(string path)
        {
            YamlInfo info = new YamlInfo { Path = path };
            foreach (string raw in File.ReadAllLines(path))
            {
                if (raw.StartsWith(" ") || raw.StartsWith("\t") || raw.StartsWith("#")) continue;
                Match m = Regex.Match(raw, "^(name|game)\\s*:\\s*(.*?)\\s*$");
                if (!m.Success) continue;
                string value = m.Groups[2].Value.Trim().Trim('"', '\'');
                if (m.Groups[1].Value == "name" && info.Name.Length == 0) info.Name = value;
                if (m.Groups[1].Value == "game" && info.Game.Length == 0) info.Game = value;
            }
            return info;
        }
    }
}

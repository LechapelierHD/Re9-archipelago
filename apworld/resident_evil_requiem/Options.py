from dataclasses import dataclass

from Options import Choice, DeathLink, PerGameCommonOptions, Range, StartInventoryPool, Toggle


class GameDifficulty(Choice):
    """The difficulty you will play on. Some items only exist on some difficulties;
    a spot that does not exist on yours would be a check you can never reach, so it is left out.
    Generation cannot see the game: set it to match your save."""

    display_name = "Game Difficulty"
    option_casual = 0
    option_modern = 1
    option_classic = 2
    option_insanity = 3
    default = 1


class KeyItems(Choice):
    """Objets progressifs (clés, cartes, quartz, lockpick).
    Ils sont des checks, placés au hasard dans n'importe quel monde.
    Restent au sol : tournevis, briquet, lampe, manuel, et le premier fusible."""

    display_name = "Key Items"
    option_vanilla = 0
    option_shuffled = 1
    default = 0


class FlagItems(Choice):
    """Items that set story / cutscene flags on pickup (Lighter, Override Manual…).
    Same idea as RE4R pickup-event flags: when shuffled, the client re-fires the
    acquisition flags on check and on receive so cinematics still work.

    vanilla: stay in the world, not checks (safe for story).
    shuffled: become AP checks; client applies Acquired/Pickedup (+ related) like RE4R."""

    display_name = "Flag Items"
    option_vanilla = 0
    option_shuffled = 1
    default = 0


class SupplyBox(Toggle):
    """Les 11 lignes d'achat du Supply Box (armes, gilet, mallette, remède, munitions).
    Le marchand se débloque après avoir fini le jeu une fois.
    false : ces lignes ne sont pas des checks.
    true : Archipelago choisit l'objet de chaque ligne.
    Les caisses « Ch13 Supply Box » restent des checks."""

    display_name = "Supply Box"
    default = False


class EnemyDrops(Range):
    """Number of "Enemy Drop" checks. Each item from an enemy death OR a broken ceramic pot
    (Grace or Leon) sends the next of these checks, in order. They only hold filler items:
    a run with few drops can never softlock. 0 turns them off. Prefer 40–50 if you want pots."""

    display_name = "Enemy Drops"
    range_start = 0
    range_end = 50
    default = 50


@dataclass
class RE9Options(PerGameCommonOptions):
    start_inventory_from_pool: StartInventoryPool
    game_difficulty: GameDifficulty
    key_items: KeyItems
    flag_items: FlagItems
    supply_box: SupplyBox
    enemy_drops: EnemyDrops
    death_link: DeathLink

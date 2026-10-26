"""
Resident Evil Requiem (RE9) for Archipelago.
Every world pickup of the chapter exports is a check; received items are injected into the
item box by the REFramework client.
"""

from typing import Any

from BaseClasses import Item, ItemClassification, Location, LocationProgressType, Region, Tutorial
from Options import OptionError
from worlds.AutoWorld import WebWorld, World

from .Items import item_name_groups, item_name_to_id, item_table
from .Locations import CHAPTERS, location_name_groups, location_name_to_id, location_table
from .Options import RE9Options

GAME_NAME = "Resident Evil Requiem"
WORLD_VERSION = "1.0.7"
VICTORY = "Victory"

# Ces objets lancent une cinématique au ramassage. Ils restent au sol.
STORY_ITEMS = frozenset({
    "Screwdriver",
    "Lighter", "Flashlight", "Override Manual", "Unknown Item (it99_05_002)",
})
# Ramassage Capcom, jamais un check. Le client retire les mêmes ids du slot.
VANILLA_LOCATIONS = frozenset({
    "Ch3 st30_001 - Fuse",
    "Ch3 st30_004 - Screwdriver",
})
# L'entrée exige ces objets. state.has les voit même s'ils sont dans un autre monde.
# Une entrée absente du graphe fait planter la génération.
REGION_GATES = {
    "To Ch4": ("Cherub Key",),
    # Sans ces objets on ne sort pas du Care Center, donc ils ne peuvent pas être après.
    "To Ch6": (
        "West Wing Keycard",
        "ID Wristband (Level 1)",
        "Artificial Lungs",
        "Artificial Heart",
        "ID Wristband (Level 2)",
    ),
}
# Chapitre client correspondant à la porte (affichage « il manque »).
GATE_CHAPTER = {
    "To Ch4": "Ch4",
    "To Ch6": "Ch6",
}
# Sous-zones du Care Center. La clé reste multiworld, mais plus derrière sa porte.
AREA_GATES = {
    "To Ch5 West": ("West Wing Keycard",),
    "To Ch5 East": ("East Wing Keycard",),
    "To Ch5 Secure": ("West Wing Keycard", "ID Wristband (Level 1)"),
    "To Ch5 Cold Storage": ("West Wing Keycard", "ID Wristband (Level 1)", "Wrench"),
}
# Le garage est rangé « East 2nd » dans l'export, mais c'est le van de l'aile ouest.
SECURE_LOCATIONS = frozenset({
    "Ch5 East 2nd - Handgun Ammo",
    "Ch5 Key Items - Artificial Lungs",
    "Ch5 Key Items - Organ Transport Box",
    "Ch5 Key Items - Wrench",
})
COLD_LOCATIONS = frozenset({
    "Ch5 Key Items - Artificial Heart",
})
FILLER_CATEGORIES = frozenset({"Heal", "Ammo", "Material"})
# Prix vanilla des 11 lignes. Archipelago les répartit au hasard.
SUPPLY_PRICE_POOL = (500, 600, 800, 900, 1500, 2500, 5500, 6000, 7000, 7000, 15000)
DIFFICULTY_NAMES = ("Casual", "Modern", "Classic", "Insanity")

ENEMY_DROP_COUNT = 100
ENEMY_DROP_BASE = 7092000
ENEMY_DROP_NAMES: tuple[str, ...] = tuple(f"Enemy Drop #{i}" for i in range(1, ENEMY_DROP_COUNT + 1))
ENEMY_DROPS: dict[str, int] = {
    name: ENEMY_DROP_BASE + i for i, name in enumerate(ENEMY_DROP_NAMES)
}

FILLER_NAMES: tuple[str, ...] = tuple(sorted(
    name for name, data in item_table.items()
    if data.category in FILLER_CATEGORIES
    and data.classification == ItemClassification.filler
    and not name.startswith("Unknown Item")
))
# Pas d'objet en jeu : le client ajoute le montant au portefeuille. Un autre monde peut les trouver.
CREDIT_PACKS: dict[str, tuple[int, int]] = {
    "500 Credits": (7093000, 500),
    "1000 Credits": (7093001, 1000),
    "2500 Credits": (7093002, 2500),
    "5000 Credits": (7093003, 5000),
}
CREDIT_FILL: tuple[str, ...] = (
    ("500 Credits",) * 10
    + ("1000 Credits",) * 8
    + ("2500 Credits",) * 4
    + ("5000 Credits",) * 2
)


class RE9Item(Item):
    game = GAME_NAME


class RE9Location(Location):
    game = GAME_NAME


class RE9Web(WebWorld):
    theme = "stone"
    tutorials = [
        Tutorial(
            "Guide d'installation",
            "Installer le client Archipelago pour Resident Evil Requiem (REFramework).",
            "Français",
            "setup_fr.md",
            "setup/fr",
            ["RE9 AP"],
        )
    ]


class RE9World(World):
    """
    Resident Evil Requiem. Every item lying around Raccoon City's remains may belong
    to someone else's world.
    """

    game = GAME_NAME
    web = RE9Web()
    options_dataclass = RE9Options
    options: RE9Options
    topology_present = True
    origin_region_name = "Menu"

    item_name_to_id = {
        **item_name_to_id,
        **{name: code for name, (code, _amount) in CREDIT_PACKS.items()},
    }
    location_name_to_id = {**location_name_to_id, **ENEMY_DROPS}
    item_name_groups = {**item_name_groups, "Credits": set(CREDIT_PACKS)}
    location_name_groups = {**location_name_groups, "Enemy Drops": set(ENEMY_DROP_NAMES)}

    def generate_early(self) -> None:
        self.difficulty = DIFFICULTY_NAMES[self.options.game_difficulty.value]
        self.shuffle_keys = self.options.key_items.current_key == "shuffled"
        self.active_locations = [
            name for name, data in location_table.items()
            if name not in VANILLA_LOCATIONS
            and (not data.difficulties or self.difficulty in data.difficulties)
            and self._is_check(name, data.vanilla_item)
            and (self.options.supply_box.value or not name.startswith("Supply Box - "))
        ]
        if not self.active_locations:
            raise OptionError(f"{GAME_NAME} ({self.player_name}): no location left for these options")

        drop_count = self.options.enemy_drops.value
        self.enemy_drops = ENEMY_DROP_NAMES[:drop_count]
        shop_names = [name for name in self.active_locations if name.startswith("Supply Box - ")]
        pool = list(SUPPLY_PRICE_POOL)
        self.random.shuffle(pool)
        self.supply_prices = {
            location_table[name].code: pool[i % len(pool)]
            for i, name in enumerate(shop_names)
        }
        self.chapter_requirements: dict[str, dict[str, int]] = {}

        for entrance_name, required in REGION_GATES.items():
            chapter = GATE_CHAPTER.get(entrance_name)
            if chapter is None:
                raise OptionError(f"{GAME_NAME}: porte {entrance_name} sans chapitre")
            self.chapter_requirements[chapter] = {name: 1 for name in required}

    def _is_check(self, location_name: str, vanilla: str) -> bool:
        return vanilla not in STORY_ITEMS

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)

        previous = menu
        regions: dict[str, Region] = {}
        for chapter in CHAPTERS:
            region = Region(chapter, self.player, self.multiworld)
            self.multiworld.regions.append(region)
            previous.connect(region, f"To {chapter}")
            regions[chapter] = region
            previous = region

        care = regions["Ch5"]
        for area_name in ("Ch5 West", "Ch5 East", "Ch5 Secure", "Ch5 Cold Storage"):
            area = Region(area_name, self.player, self.multiworld)
            self.multiworld.regions.append(area)
            care.connect(area, f"To {area_name}")
            regions[area_name] = area

        for name in self.active_locations:
            data = location_table[name]
            region = regions[self._area_for(name, data)]
            region.locations.append(RE9Location(self.player, name, data.code, region))

        for name in self.enemy_drops:
            location = RE9Location(self.player, name, ENEMY_DROPS[name], menu)
            location.progress_type = LocationProgressType.EXCLUDED
            menu.locations.append(location)

        victory = RE9Location(self.player, VICTORY, None, previous)
        victory.place_locked_item(RE9Item(VICTORY, ItemClassification.progression, None, self.player))
        previous.locations.append(victory)

    def create_item(self, name: str) -> Item:
        pack = CREDIT_PACKS.get(name)
        if pack is not None:
            return RE9Item(name, ItemClassification.filler, pack[0], self.player)
        data = item_table[name]
        return RE9Item(name, data.classification, data.code, self.player)

    def get_filler_item_name(self) -> str:
        return self.random.choice(FILLER_NAMES)

    def create_items(self) -> None:
        pool: list[Item] = []
        filler_slots: list[int] = []
        for name in self.active_locations:
            item = self.create_item(location_table[name].vanilla_item)
            if item.classification == ItemClassification.filler:
                filler_slots.append(len(pool))
            pool.append(item)
        self.random.shuffle(filler_slots)
        for slot, credit_name in zip(filler_slots, CREDIT_FILL):
            pool[slot] = self.create_item(credit_name)
        pool += [self.create_item(self.get_filler_item_name()) for _ in self.enemy_drops]
        self.multiworld.itempool += pool

    def _area_for(self, name: str, data) -> str:
        if data.chapter != "Ch5":
            return data.chapter
        if name in SECURE_LOCATIONS:
            return "Ch5 Secure"
        if name in COLD_LOCATIONS:
            return "Ch5 Cold Storage"
        if data.zone.startswith("West 2nd"):
            return "Ch5 West"
        if data.zone.startswith("East 1st") or data.zone.startswith("East 2nd"):
            return "Ch5 East"
        return "Ch5"

    def _lock_entrance(self, entrance_name: str, required: tuple[str, ...]) -> None:
        player = self.player
        try:
            entrance = self.get_entrance(entrance_name)
        except KeyError:
            raise OptionError(
                f"{GAME_NAME}: porte {entrance_name} absente du graphe"
            ) from None
        needed = tuple(required)
        entrance.access_rule = lambda state, req=needed: state.has_all(req, player)

    def set_rules(self) -> None:
        for entrance_name, required in REGION_GATES.items():
            self._lock_entrance(entrance_name, required)
        for entrance_name, required in AREA_GATES.items():
            self._lock_entrance(entrance_name, required)
        self.multiworld.completion_condition[self.player] = lambda state: state.has(VICTORY, self.player)

    def fill_slot_data(self) -> dict[str, Any]:
        location_codes = [location_table[name].code for name in self.active_locations]
        location_codes += [ENEMY_DROPS[name] for name in self.enemy_drops]
        return {
            "apworld_version": WORLD_VERSION,
            "goal": "finish_game",
            "difficulty": self.difficulty,
            "key_items": self.options.key_items.current_key,
            "enemy_drops": int(self.options.enemy_drops.value),
            "supply_box": bool(self.options.supply_box.value),
            "supply_prices": ",".join(
                f"{code}:{price}" for code, price in sorted(self.supply_prices.items())
            ),
            "death_link": bool(self.options.death_link.value),
            "check_count": len(location_codes),
            # Cumulatif : "Ch3=7090100:1,7090101:2;Ch4=..."
            "chapter_keys": ";".join(
                chapter + "=" + ",".join(
                    f"{item_table[name].code}:{count}" for name, count in sorted(required.items())
                )
                for chapter, required in self.chapter_requirements.items()
            ),
            # Tout ramassage absent de cette liste reste vanilla côté client
            "locations": sorted(location_codes),
            "items": {
                **{str(data.code): [data.game_id, data.default_amount] for data in item_table.values()},
                **{str(code): ["credits", amount] for _name, (code, amount) in CREDIT_PACKS.items()},
            },
        }

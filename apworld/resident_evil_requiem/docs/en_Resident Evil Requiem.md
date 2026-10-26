# Resident Evil Requiem

Client **1.0.121**, apworld **1.0.7**. Download the client at https://lechapelierhd.github.io/Re9-AP-site/. Source: https://github.com/LechapelierHD/Re9-archipelago

## What is randomized?

Items lying in the world (floor, drawers, safes, lockers) are checks. Enemy drops and broken pots send the next Enemy Drop check, up to the `enemy_drops` count (default 50). They only hold filler.

These stay on the ground and are never checks: Screwdriver, Lighter, Flashlight, Override Manual, Unknown Item, and the first fuse.

With `supply_box: true`, the 11 merchant rows are checks. The Ch13 ground crates stay checks either way.

Credit packs (500, 1000, 2500, 5000) can replace filler. A new seed generated with apworld 1.0.7 is required for them and for the Care Center logic.

## Which difficulty?

Some pickups only exist on some difficulties. Set `game_difficulty` to the difficulty of your save.

## What is the goal?

Finish the game. The client sends the victory when the final boss is beaten.

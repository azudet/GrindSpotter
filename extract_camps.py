#!/usr/bin/env python3
"""
extract_camps.py - Generates camps.json from cmangos_db/classicmangos.sqlite
Extracts high-density open-world grinding camps (rank=0, maps 0 & 1), filters trade-good drops,
calculates zone-relative coordinates, tags mob abilities/types, and flags quest mobs.
"""

import sqlite3
import json
import os
import math
from collections import defaultdict

ZONE_BOUNDS = {
    # Kalimdor (Map 1)
    "Durotar": (1, 1411, 2300.0, -2000.0, -3800.0, -6000.0, "Horde"),
    "Mulgore": (1, 1412, -700.0, -3700.0, 600.0, -2400.0, "Horde"),
    "The Barrens": (1, 1413, 2200.0, -4200.0, -600.0, -4000.0, "Horde"),
    "Teldrassil": (1, 1438, 11400.0, 8400.0, 3200.0, 200.0, "Alliance"),
    "Darkshore": (1, 1439, 7800.0, 4800.0, 1350.0, -3150.0, "Alliance"),
    "Ashenvale": (1, 1440, 3900.0, 1500.0, 1050.0, -2550.0, "Both"),
    "Thousand Needles": (1, 1441, -3900.0, -6700.0, -300.0, -3100.0, "Both"),
    "Stonetalon Mountains": (1, 1442, 3000.0, 300.0, 2200.0, -800.0, "Both"),
    "Desolace": (1, 1443, 300.0, -2500.0, 2900.0, -1300.0, "Both"),
    "Feralas": (1, 1444, -3600.0, -8200.0, 2700.0, -1900.0, "Both"),
    "Dustwallow Marsh": (1, 1445, -2300.0, -5100.0, -2100.0, -4900.0, "Both"),
    "Tanaris": (1, 1446, -6400.0, -10800.0, -1400.0, -4400.0, "Both"),
    "Azshara": (1, 1447, 4500.0, 1100.0, -3000.0, -8100.0, "Both"),
    "Felwood": (1, 1448, 7100.0, 3500.0, 1000.0, -1400.0, "Both"),
    "Un'Goro Crater": (1, 1449, -6000.0, -8400.0, 300.0, -2100.0, "Both"),
    "Silithus": (1, 1451, -5900.0, -8300.0, 1900.0, -700.0, "Both"),
    "Winterspring": (1, 1452, 7900.0, 4300.0, -1600.0, -5200.0, "Both"),

    # Eastern Kingdoms (Map 0)
    "Tirisfal Glades": (0, 1420, 3200.0, 1200.0, 2500.0, -100.0, "Horde"),
    "Silverpine Forest": (0, 1421, 1600.0, -600.0, 1900.0, 100.0, "Horde"),
    "Western Plaguelands": (0, 1422, 3200.0, 1200.0, 100.0, -2100.0, "Both"),
    "Eastern Plaguelands": (0, 1423, 3400.0, 1600.0, -2100.0, -4500.0, "Both"),
    "Hillsbrad Foothills": (0, 1424, 200.0, -1600.0, 800.0, -1600.0, "Both"),
    "The Hinterlands": (0, 1425, 800.0, -900.0, -2100.0, -4300.0, "Both"),
    "Dun Morogh": (0, 1426, -4400.0, -6600.0, 1100.0, -1900.0, "Alliance"),
    "Searing Gorge": (0, 1427, -6100.0, -7600.0, -1000.0, -2700.0, "Both"),
    "Burning Steppes": (0, 1428, -7100.0, -9100.0, -1900.0, -3900.0, "Both"),
    "Elwynn Forest": (0, 1429, -8400.0, -10400.0, 900.0, -1900.0, "Alliance"),
    "Deadwind Pass": (0, 1430, -9900.0, -11700.0, -1400.0, -2800.0, "Both"),
    "Duskwood": (0, 1431, -9800.0, -11400.0, 400.0, -1800.0, "Alliance"),
    "Loch Modan": (0, 1432, -4700.0, -6300.0, -2400.0, -4000.0, "Alliance"),
    "Redridge Mountains": (0, 1433, -8700.0, -10300.0, -1900.0, -3700.0, "Alliance"),
    "Stranglethorn Vale": (0, 1434, -11100.0, -15300.0, 900.0, -2300.0, "Both"),
    "Swamp of Sorrows": (0, 1435, -9700.0, -11100.0, -2100.0, -3900.0, "Both"),
    "Westfall": (0, 1436, -9200.0, -11800.0, 2300.0, 100.0, "Alliance"),
    "Wetlands": (0, 1437, -2500.0, -4500.0, -1300.0, -3700.0, "Alliance"),
    "Alterac Mountains": (0, 1416, 1200.0, -400.0, 1100.0, -500.0, "Both"),
    "Arathi Highlands": (0, 1417, -700.0, -2700.0, -1700.0, -4000.0, "Both"),
    "Badlands": (0, 1418, -5700.0, -7400.0, -2500.0, -4200.0, "Both"),
    "Blasted Lands": (0, 1419, -10200.0, -12600.0, -2200.0, -4600.0, "Both"),
}

def world_to_zone_coords(map_id, wx, wy):
    best_zone = None
    best_dist = -999999
    best_result = None

    for zone_name, (c_map, ui_map, top_x, bottom_x, left_y, right_y, d_faction) in ZONE_BOUNDS.items():
        if map_id != c_map:
            continue
        
        x_min, x_max = min(top_x, bottom_x), max(top_x, bottom_x)
        y_min, y_max = min(left_y, right_y), max(left_y, right_y)

        if x_min <= wx <= x_max and y_min <= wy <= y_max:
            norm_x = (left_y - wy) / (left_y - right_y) * 100.0
            norm_y = (top_x - wx) / (top_x - bottom_x) * 100.0
            
            if 0.0 <= norm_x <= 100.0 and 0.0 <= norm_y <= 100.0:
                margin = min(norm_x, 100.0 - norm_x, norm_y, 100.0 - norm_y)
                if margin > best_dist:
                    best_dist = margin
                    best_zone = zone_name
                    best_result = {
                        "zone": zone_name,
                        "mapID": ui_map,
                        "x": round(norm_x, 1),
                        "y": round(norm_y, 1),
                        "faction": d_faction
                    }

    return best_result

def get_creature_type_tag(c_type):
    type_map = {
        1: "BEAST",
        2: "DRAGONKIN",
        3: "DEMON",
        4: "ELEMENTAL",
        5: "GIANT",
        6: "UNDEAD",
        7: "HUMANOID",
        9: "MECHANICAL"
    }
    return type_map.get(c_type)

def load_db_data(cur):
    print("Loading quest data...")
    cur.execute('''
        SELECT DISTINCT abs(ReqCreatureOrGOId1) FROM quest_template WHERE ReqCreatureOrGOId1 > 0
        UNION
        SELECT DISTINCT abs(ReqCreatureOrGOId2) FROM quest_template WHERE ReqCreatureOrGOId2 > 0
        UNION
        SELECT DISTINCT abs(ReqCreatureOrGOId3) FROM quest_template WHERE ReqCreatureOrGOId3 > 0
        UNION
        SELECT DISTINCT abs(ReqCreatureOrGOId4) FROM quest_template WHERE ReqCreatureOrGOId4 > 0
    ''')
    quest_creature_ids = {row[0] for row in cur.fetchall() if row[0]}

    cur.execute('SELECT DISTINCT entry FROM creature_loot_template WHERE ChanceOrQuestChance < 0')
    for row in cur.fetchall():
        if row[0]:
            quest_creature_ids.add(row[0])

    cur.execute('''
        SELECT DISTINCT id FROM creature_involvedrelation
        UNION
        SELECT DISTINCT id FROM creature_questrelation
    ''')
    for row in cur.fetchall():
        if row[0]:
            quest_creature_ids.add(row[0])

    print("Loading creature spells and tags...")
    cur.execute('''
        SELECT cts.entry, s1.SpellName, s2.SpellName, s3.SpellName, s4.SpellName
        FROM creature_template_spells cts
        LEFT JOIN spell_template s1 ON cts.Spell1 = s1.Id
        LEFT JOIN spell_template s2 ON cts.Spell2 = s2.Id
        LEFT JOIN spell_template s3 ON cts.Spell3 = s3.Id
        LEFT JOIN spell_template s4 ON cts.Spell4 = s4.Id
    ''')
    creature_spell_tags = defaultdict(set)
    for entry, s1, s2, s3, s4 in cur.fetchall():
        all_spells = " ".join([str(s) for s in [s1, s2, s3, s4] if s]).lower()
        if not all_spells:
            continue
        if "heal" in all_spells or "renew" in all_spells or "rejuvenation" in all_spells:
            creature_spell_tags[entry].add("HEALER")
        if "silence" in all_spells or "kick" in all_spells or "pummel" in all_spells or "shield bash" in all_spells:
            creature_spell_tags[entry].add("SILENCE")
        if "mana burn" in all_spells or "drain mana" in all_spells:
            creature_spell_tags[entry].add("MANA_BURN")
        if "poison" in all_spells or "venom" in all_spells or "toxin" in all_spells:
            creature_spell_tags[entry].add("POISON")
        if "curse" in all_spells:
            creature_spell_tags[entry].add("CURSE")
        if "enrage" in all_spells or "frenzy" in all_spells or "bloodlust" in all_spells or "berserk" in all_spells:
            creature_spell_tags[entry].add("ENRAGE")
        if "thrash" in all_spells or "flurry" in all_spells:
            creature_spell_tags[entry].add("THRASH")
        if "disarm" in all_spells:
            creature_spell_tags[entry].add("DISARM")
        if "stealth" in all_spells or "shadowmeld" in all_spells or "prowl" in all_spells or "backstab" in all_spells:
            creature_spell_tags[entry].add("STEALTH")
        if "net" in all_spells or "web" in all_spells or "root" in all_spells or "entangling" in all_spells or "frost nova" in all_spells:
            creature_spell_tags[entry].add("NET_ROOT")
        if "bolt" in all_spells or "shock" in all_spells or "blast" in all_spells or "strike" in all_spells or "fireball" in all_spells:
            creature_spell_tags[entry].add("CASTER")

    print("Loading trade good drops...")
    creature_drops = defaultdict(dict)

    cur.execute('''
        SELECT clt.entry, clt.item, it.name, clt.ChanceOrQuestChance
        FROM creature_loot_template clt
        JOIN item_template it ON clt.item = it.entry
        WHERE clt.ChanceOrQuestChance > 0
    ''')
    for c_entry, item_id, item_name, chance in cur.fetchall():
        rate = round(chance / 100.0, 4)
        if rate < 0.001:
            continue
        is_cloth = "Cloth" in item_name
        is_leather = "Leather" in item_name or "Hide" in item_name or "Scale" in item_name
        is_meat = any(w in item_name for w in ["Meat", "Liver", "Egg", "Ribs", "Flank", "Hops", "Okra", "Oil", "Venison", "Chit", "Clam", "Eye", "Tenderloin", "Tusk", "Snout"])
        is_gem = item_name in ["Malachite", "Tigerseye", "Shadowgem", "Jade", "Lesser Moonstone", "Moss Agate", "Aquamarine", "Star Ruby", "Large Opal", "Huge Emerald", "Blue Sapphire", "Azerothian Diamond", "Small Pearl", "Black Pearl", "Golden Pearl"]
        is_elemental = any(w in item_name for w in ["Elemental", "Essence of", "Globe of Water", "Heart of Fire", "Core of Earth", "Breath of Wind", "Ichor of Undeath", "Living Essence"])
        is_parts = any(w in item_name for w in ["Bolts", "Copper Tube", "Copper Modulator", "Fused Wiring", "Bronze Tube", "Iron Strut", "Gyrochronatom", "Twilight Text", "Twilight Cultist"])
        is_valuable = any(w in item_name for w in ["Pattern", "Recipe", "Schematic", "Flame Sac", "Dragon Scale"])
        
        if is_cloth or is_leather or is_meat or is_gem or is_elemental or is_parts or is_valuable:
            creature_drops[c_entry][item_name] = max(creature_drops[c_entry].get(item_name, 0.0), round(rate, 4))

    cur.execute('''
        SELECT ct.Entry, slt.item, it.name, slt.ChanceOrQuestChance
        FROM creature_template ct
        JOIN skinning_loot_template slt ON ct.SkinningLootId = slt.entry
        JOIN item_template it ON slt.item = it.entry
        WHERE slt.ChanceOrQuestChance > 0
    ''')
    for c_entry, item_id, item_name, chance in cur.fetchall():
        rate = round(chance / 100.0, 4)
        if rate < 0.001:
            continue
        if "Leather" in item_name or "Hide" in item_name or "Scale" in item_name or "Dragon Scale" in item_name:
            creature_drops[c_entry][item_name] = max(creature_drops[c_entry].get(item_name, 0.0), round(rate, 4))

    return quest_creature_ids, creature_spell_tags, creature_drops

def simplify_mob_name(name):
    for prefix in ["Young ", "Elder ", "Enraged ", "Savage ", "Rabid ", "Starving ", "Greater ", "Lesser ", "Wild ", "Frenzied "]:
        if name.startswith(prefix):
            return name[len(prefix):]
    return name

def cluster_spawns(all_spawns, quest_creature_ids, creature_spell_tags, creature_drops):
    zone_mob_spawns = defaultdict(list)
    for spawn in all_spawns:
        guid, entry, map_id, wx, wy, wz, respawn_sec, name, min_lvl, max_lvl, c_type, faction, armor = spawn
        
        if max_lvl <= 1 and c_type == 8:
            continue

        zone_info = world_to_zone_coords(map_id, wx, wy)
        if not zone_info:
            continue
            
        group_key = simplify_mob_name(name)
        zone_mob_spawns[(zone_info["zone"], group_key)].append({
            "guid": guid,
            "entry": entry,
            "map_id": map_id,
            "wx": wx,
            "wy": wy,
            "wz": wz,
            "respawn_sec": respawn_sec,
            "name": name,
            "min_lvl": min_lvl,
            "max_lvl": max_lvl,
            "c_type": c_type,
            "faction": faction,
            "armor": armor,
            "zone_info": zone_info
        })

    raw_camps = []
    
    for (zone_name, group_key), spawns in zone_mob_spawns.items():
        if len(spawns) < 5:
            continue
            
        clusters = []
        for s in spawns:
            placed = False
            for cl in clusters:
                cx = sum(item["wx"] for item in cl) / len(cl)
                cy = sum(item["wy"] for item in cl) / len(cl)
                dist = math.hypot(s["wx"] - cx, s["wy"] - cy)
                if dist <= 240.0:
                    cl.append(s)
                    placed = True
                    break
            if not placed:
                clusters.append([s])

        for cl in clusters:
            if len(cl) < 5:
                continue

            avg_wx = sum(item["wx"] for item in cl) / len(cl)
            avg_wy = sum(item["wy"] for item in cl) / len(cl)

            zone_info = world_to_zone_coords(cl[0]["map_id"], avg_wx, avg_wy)
            if not zone_info:
                continue

            entries = {item["entry"] for item in cl}
            names = sorted(list({item["name"] for item in cl}))
            min_level = min(item["min_lvl"] for item in cl)
            max_level = max(item["max_lvl"] for item in cl)
            c_type = cl[0]["c_type"]
            avg_armor = sum(item["armor"] for item in cl) / len(cl)
            
            respawn_times = [item["respawn_sec"] for item in cl if item["respawn_sec"] > 0]
            avg_respawn_min = round((sum(respawn_times) / len(respawn_times)) / 60.0, 1) if respawn_times else 2.0
            avg_respawn_min = max(1.0, min(avg_respawn_min, 10.0))

            spawn_count = len(cl)
            if spawn_count >= 18:
                density = "High"
            elif spawn_count >= 10:
                density = "Medium"
            else:
                density = "Low"

            is_quest_mob = any(e in quest_creature_ids for e in entries)

            camp_drops = {}
            for e in entries:
                for item_name, rate in creature_drops.get(e, {}).items():
                    camp_drops[item_name] = max(camp_drops.get(item_name, 0.0), rate)

            tags = set()
            type_tag = get_creature_type_tag(c_type)
            if type_tag:
                tags.add(type_tag)

            if avg_armor >= 2000 or (min_level >= 20 and avg_armor >= min_level * 50):
                tags.add("HIGH_ARMOR")
            elif avg_armor <= 400 and min_level >= 15:
                tags.add("LOW_ARMOR")

            for e in entries:
                for t in creature_spell_tags.get(e, []):
                    tags.add(t)

            if type_tag == "HUMANOID" and "FLEE_RUNNER" not in tags:
                tags.add("FLEE_RUNNER")

            if density == "High" and spawn_count >= 20:
                tags.add("HEAVY_PACKS")
            elif spawn_count <= 8:
                tags.add("CASUAL_PULL")

            camp_faction = zone_info["faction"]

            if len(names) == 1:
                camp_name = f"{names[0]} ({zone_info['zone']})"
            elif len(names) == 2:
                camp_name = f"{names[0]} & {names[1]} ({zone_info['zone']})"
            else:
                camp_name = f"{names[0]} & {names[1]} ({zone_info['zone']})"

            clean_name = names[0].lower().replace(" ", "_").replace("'", "").replace("-", "_")
            clean_zone = zone_info["zone"].lower().replace(" ", "_").replace("'", "").replace("-", "_")
            camp_id = f"{clean_zone}_{clean_name}_{int(zone_info['x'])}_{int(zone_info['y'])}"

            valuable_drops = sum(rate for rate in camp_drops.values())
            density_score = spawn_count * 2.0 + (5.0 if density == "High" else 2.0)
            level_relevance = 10.0 if 10 <= min_level <= 60 else 0.0
            score = density_score + valuable_drops * 10.0 + level_relevance

            raw_camps.append({
                "id": camp_id,
                "name": camp_name,
                "creatureEntry": int(cl[0]["entry"]),
                "mapID": zone_info["mapID"],
                "zone": zone_info["zone"],
                "x": zone_info["x"],
                "y": zone_info["y"],
                "minLevel": max(1, min_level),
                "maxLevel": min(60, max_level),
                "faction": camp_faction,
                "density": density,
                "respawnMin": avg_respawn_min,
                "isQuestMob": is_quest_mob,
                "tags": sorted(list(tags)),
                "drops": camp_drops,
                "_score": score,
                "_spawn_count": spawn_count
            })

    return raw_camps

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(script_dir, "cmangos_db", "classicmangos.sqlite")
    output_json = os.path.join(script_dir, "camps.json")

    if not os.path.exists(db_path):
        print(f"Error: Database {db_path} not found.")
        return

    print("Connecting to cmangos sqlite database...")
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    quest_creature_ids, creature_spell_tags, creature_drops = load_db_data(cur)

    print("Extracting open-world spawns...")
    cur.execute('''
        SELECT c.guid, c.id, c.map, c.position_x, c.position_y, c.position_z, c.spawntimesecsmin,
               ct.Name, ct.MinLevel, ct.MaxLevel, ct.CreatureType, ct.Faction, ct.Armor
        FROM creature c
        JOIN creature_template ct ON c.id = ct.Entry
        WHERE c.map IN (0, 1) AND ct.Rank = 0
    ''')
    all_spawns = cur.fetchall()
    print(f"Loaded {len(all_spawns)} rank-0 spawns on maps 0 & 1.")

    print("Clustering spawns into camps...")
    raw_camps = cluster_spawns(all_spawns, quest_creature_ids, creature_spell_tags, creature_drops)
    print(f"Total raw candidate camps found: {len(raw_camps)}")

    level_buckets = {
        "1-10": [],
        "10-20": [],
        "20-30": [],
        "30-40": [],
        "40-50": [],
        "50-60": []
    }

    deduped_camps = []
    seen_zones_locs = defaultdict(list)
    raw_camps.sort(key=lambda c: c["_score"], reverse=True)

    for c in raw_camps:
        if not c["drops"]:
            continue
            
        is_overlap = False
        for ex_x, ex_y in seen_zones_locs[c["zone"]]:
            if math.hypot(c["x"] - ex_x, c["y"] - ex_y) < 4.0:
                is_overlap = True
                break
        if is_overlap:
            continue

        seen_zones_locs[c["zone"]].append((c["x"], c["y"]))
        deduped_camps.append(c)

        lvl = c["minLevel"]
        if lvl < 10:
            level_buckets["1-10"].append(c)
        elif lvl < 20:
            level_buckets["10-20"].append(c)
        elif lvl < 30:
            level_buckets["20-30"].append(c)
        elif lvl < 40:
            level_buckets["30-40"].append(c)
        elif lvl < 50:
            level_buckets["40-50"].append(c)
        else:
            level_buckets["50-60"].append(c)

    selected_camps = []
    selected_camps.extend(level_buckets["1-10"][:10])
    selected_camps.extend(level_buckets["10-20"][:35])
    selected_camps.extend(level_buckets["20-30"][:35])
    selected_camps.extend(level_buckets["30-40"][:35])
    selected_camps.extend(level_buckets["40-50"][:35])
    selected_camps.extend(level_buckets["50-60"][:40])

    if len(selected_camps) < 175:
        existing_ids = {c["id"] for c in selected_camps}
        for c in deduped_camps:
            if c["id"] not in existing_ids and len(selected_camps) < 185:
                selected_camps.append(c)
                existing_ids.add(c["id"])

    final_output = []
    seen_ids = set()
    for c in selected_camps:
        camp_id = c["id"]
        counter = 1
        while camp_id in seen_ids:
            camp_id = f"{c['id']}_{counter}"
            counter += 1
        seen_ids.add(camp_id)

        sorted_drops = sorted(c["drops"].items(), key=lambda x: x[1], reverse=True)[:15]
        drops_dict = {k: v for k, v in sorted_drops}

        final_output.append({
            "id": camp_id,
            "name": c["name"],
            "creatureEntry": int(c.get("creatureEntry", 0)),
            "mapID": int(c["mapID"]),
            "zone": c["zone"],
            "x": float(c["x"]),
            "y": float(c["y"]),
            "minLevel": int(c["minLevel"]),
            "maxLevel": int(c["maxLevel"]),
            "faction": c["faction"],
            "density": c["density"],
            "respawnMin": float(c["respawnMin"]),
            "isQuestMob": bool(c["isQuestMob"]),
            "tags": c["tags"],
            "drops": drops_dict
        })

    print(f"Writing {len(final_output)} curated grinding camps to {output_json}...")
    with open(output_json, "w", encoding="utf-8") as f:
        json.dump(final_output, f, indent=2)

    print(f"Done! Extracted {len(final_output)} grinding camps.")

if __name__ == "__main__":
    main()


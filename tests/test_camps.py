import unittest
import json
import os
import math

class TestCampsData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cls.json_path = os.path.join(cls.script_dir, "camps.json")
        cls.data_lua_path = os.path.join(cls.script_dir, "Data.lua")
        
        with open(cls.json_path, "r", encoding="utf-8") as f:
            cls.camps = json.load(f)

    def test_camps_not_empty(self):
        self.assertGreater(len(self.camps), 0, "camps.json must contain at least one camp")

    def test_camp_structure_and_types(self):
        valid_factions = {"Alliance", "Horde", "Both", "Neutral"}
        valid_densities = {"Low", "Medium", "High"}
        known_tags = {
            "HUMANOID", "BEAST", "UNDEAD", "ELEMENTAL", "DRAGONKIN", "DEMON", "MECHANICAL", "GIANT",
            "HIGH_ARMOR", "LOW_ARMOR", "THRASH", "DISARM", "STONE_SKIN", "SILENCE", "MANA_BURN",
            "FAST_ATTACK", "MAGIC_RESIST", "POISON", "CURSE", "ENRAGE", "FLEE_RUNNER", "STEALTH",
            "NET_ROOT", "HEALER", "CASTER", "HEAVY_PACKS", "CASUAL_PULL"
        }

        seen_ids = set()
        for camp in self.camps:
            camp_id = camp.get("id")
            self.assertIsNotNone(camp_id, "Camp missing id")
            self.assertNotIn(camp_id, seen_ids, f"Duplicate camp id: {camp_id}")
            seen_ids.add(camp_id)

            self.assertIsInstance(camp.get("name"), str, f"Camp {camp_id} missing valid name")
            self.assertIsInstance(camp.get("creatureEntry"), int, f"Camp {camp_id} creatureEntry must be int")
            self.assertGreaterEqual(camp.get("creatureEntry", 0), 0, f"Camp {camp_id} creatureEntry must be non-negative")
            self.assertTrue(bool(camp.get("zone")), f"Camp {camp_id} missing valid zone")
            self.assertIsInstance(camp.get("mapID"), int, f"Camp {camp_id} mapID must be int")
            self.assertGreater(camp["mapID"], 0, f"Camp {camp_id} mapID must be > 0")

            self.assertIsInstance(camp.get("x"), (int, float), f"Camp {camp_id} x coordinate must be numeric")
            self.assertIsInstance(camp.get("y"), (int, float), f"Camp {camp_id} y coordinate must be numeric")
            self.assertTrue(0.0 <= camp["x"] <= 100.0, f"Camp {camp_id} x out of range: {camp['x']}")
            self.assertTrue(0.0 <= camp["y"] <= 100.0, f"Camp {camp_id} y out of range: {camp['y']}")

            self.assertIsInstance(camp.get("minLevel"), int, f"Camp {camp_id} minLevel must be int")
            self.assertIsInstance(camp.get("maxLevel"), int, f"Camp {camp_id} maxLevel must be int")
            self.assertGreaterEqual(camp["minLevel"], 1, f"Camp {camp_id} minLevel < 1")
            self.assertLessEqual(camp["maxLevel"], 60, f"Camp {camp_id} maxLevel > 60")
            self.assertLessEqual(camp["minLevel"], camp["maxLevel"], f"Camp {camp_id} minLevel > maxLevel")

            self.assertIn(camp.get("faction"), valid_factions, f"Camp {camp_id} has invalid faction: {camp.get('faction')}")
            self.assertIn(camp.get("density"), valid_densities, f"Camp {camp_id} has invalid density: {camp.get('density')}")
            self.assertIsInstance(camp.get("respawnMin"), (int, float), f"Camp {camp_id} respawnMin must be numeric")
            self.assertGreater(camp["respawnMin"], 0, f"Camp {camp_id} respawnMin must be > 0")
            self.assertIsInstance(camp.get("isQuestMob"), bool, f"Camp {camp_id} isQuestMob must be bool")

            self.assertIsInstance(camp.get("tags"), list, f"Camp {camp_id} tags must be list")
            for tag in camp["tags"]:
                self.assertIn(tag, known_tags, f"Camp {camp_id} has unrecognized tag: {tag}")

            self.assertIsInstance(camp.get("drops"), dict, f"Camp {camp_id} drops must be dict")
            for item, rate in camp["drops"].items():
                self.assertTrue(bool(item.strip()), f"Camp {camp_id} has empty drop item name")
                self.assertIsInstance(rate, (int, float), f"Camp {camp_id} drop rate for '{item}' must be numeric")
                self.assertGreater(rate, 0.0, f"Camp {camp_id} drop rate for '{item}' must be > 0")
                self.assertLessEqual(rate, 1.0, f"Camp {camp_id} drop rate for '{item}' must be <= 1.0")

    def test_generated_data_lua(self):
        self.assertTrue(os.path.exists(self.data_lua_path), "Data.lua must exist")
        with open(self.data_lua_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("GrindSpotterData = GrindSpotterData or {}", content)
        self.assertIn("GrindSpotterData.camps = {", content)
        self.assertNotIn("= 0.00,", content, "No drop rates or coordinates should be truncated to 0.00")
        self.assertNotIn("= 0.0,", content, "No drop rates should be formatted to 0.0")

        camp_count = content.count('id = "')
        self.assertEqual(camp_count, len(self.camps), f"Data.lua camp count ({camp_count}) != camps.json ({len(self.camps)})")



class TestGrindSpotterLogicSimulation(unittest.TestCase):
    def test_skinning_formula(self):
        def get_max_skinnable(rank):
            if rank <= 100:
                return math.floor(rank / 10) + 10
            return math.floor(rank / 5)

        def get_required_rank(mob_level):
            if mob_level <= 20:
                return max(1, (mob_level - 10) * 10)
            return mob_level * 5

        self.assertEqual(get_max_skinnable(0), 10)
        self.assertEqual(get_max_skinnable(10), 11)
        self.assertEqual(get_max_skinnable(100), 20)
        self.assertEqual(get_max_skinnable(105), 21)
        self.assertEqual(get_max_skinnable(300), 60)

        self.assertEqual(get_required_rank(10), 1)
        self.assertEqual(get_required_rank(20), 100)
        self.assertEqual(get_required_rank(21), 105)
        self.assertEqual(get_required_rank(60), 300)

    def test_kill_estimation_math(self):
        rates = [0.001, 0.005, 0.04, 0.33, 1.0]
        qty = 20
        for rate in rates:
            kills = math.ceil(qty / rate)
            self.assertGreater(kills, 0)
            self.assertEqual(kills, math.ceil(20 / rate))

    def test_mob_xp_estimation(self):
        def get_zd(player_level):
            if player_level <= 5:
                return 5
            elif player_level <= 39:
                return math.floor(player_level / 10) + 5
            elif player_level <= 44:
                return 9
            elif player_level <= 49:
                return 11
            elif player_level <= 54:
                return 12
            else:
                return 17

        def estimate_mob_xp(player_level, mob_level):
            if mob_level <= (player_level - get_zd(player_level)):
                return 0
            base_xp = mob_level * 5 + 45
            diff = mob_level - player_level
            if diff == 0:
                return base_xp
            elif diff > 0:
                mult = min(1.2, 1.0 + 0.05 * diff)
                return math.floor(base_xp * mult)
            else:
                zd = get_zd(player_level)
                mult = max(0.0, 1.0 - (player_level - mob_level) / zd)
                return math.floor(base_xp * mult)

        self.assertEqual(estimate_mob_xp(60, 10), 0)
        self.assertEqual(estimate_mob_xp(20, 20), 145)
        self.assertGreater(estimate_mob_xp(20, 22), estimate_mob_xp(20, 20))



class TestLuaSyntaxValidation(unittest.TestCase):
    def test_grindspotter_lua_syntax(self):
        from luaparser import ast
        script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        lua_path = os.path.join(script_dir, "GrindSpotter.lua")
        with open(lua_path, "r", encoding="utf-8") as f:
            code = f.read()
        tree = ast.parse(code)
        self.assertIsNotNone(tree, "GrindSpotter.lua AST parsing failed")
        self.assertTrue(len(tree.body.body) > 0, "GrindSpotter.lua should have parsed statements")

if __name__ == "__main__":
    unittest.main()

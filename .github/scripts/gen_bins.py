import zipfile
import json
import struct
import os
import io

def process_recipes(zip_obj, furnace_list, crafting_set, crafting_recipes):
    # 1.21 changed folder from 'recipes' to 'recipe'
    recipe_files = [f for f in zip_obj.namelist() if f.startswith('data/minecraft/recipe/') and f.endswith('.json')]
    count = 0
    for file_path in recipe_files:
        try:
            with zip_obj.open(file_path) as file:
                data = json.load(file)
                rtype = data.get("type", "")

                # --- Furnace / Smelting Logic ---
                if rtype in ["minecraft:smelting", "minecraft:blasting"]:
                    ing = data.get("ingredient")
                    # Handle 1.21 list or single string/dict
                    if isinstance(ing, list): ing = ing[0]
                    item_in = ing if isinstance(ing, str) else ing.get("item") or ing.get("tag")
                    
                    # 1.21 result uses 'id' instead of 'item'
                    res = data.get("result")
                    item_out = res if isinstance(res, str) else res.get("id") or res.get("item")
                    
                    if item_in and item_out:
                        furnace_list.append((item_in, item_out))

                # --- Crafting Logic (Grid / Crafting) ---
                if "crafting" in rtype:
                    res = data.get("result", {})
                    # 1.21 result uses 'id' instead of 'item'
                    out = res if isinstance(res, str) else res.get("id") or res.get("item")
                    if out:
                        crafting_set.add(out)

                    # Process crafting recipes
                    if rtype in ["minecraft:crafting_shaped", "minecraft:crafting_shapeless"]:
                        recipe = {
                            "type": rtype,
                            "result": {
                                "item": out,
                                "count": data.get("result", {}).get("count", 1)
                            }
                        }

                        if rtype == "minecraft:crafting_shaped":
                            recipe["pattern"] = data.get("pattern", [])
                            recipe["key"] = data.get("key", {})
                        else:
                            recipe["ingredients"] = data.get("ingredients", [])

                        crafting_recipes.append(recipe)
            count += 1
        except Exception:
            continue
    return count

def get_item_index(item_name, crafting_items):
    # Create a mapping of item names to indices
    item_index = 1
    item_index_map = {}
    for item in sorted(list(crafting_items)):
        item_index_map[item] = item_index
        item_index += 1
    return item_index_map.get(item_name, 1)  # Default to 1 if not found

def generate_bins():
    jar_path = "server.jar"
    furnace_data = []
    crafting_items = set()
    crafting_recipes = []

    if not os.path.exists(jar_path):
        print("server.jar not found.")
        return

    with zipfile.ZipFile(jar_path, 'r') as outer_zip:
        # Check for nested Bundler JAR first (standard for 1.21)
        is_bundler = False
        for name in outer_zip.namelist():
            if name.startswith("META-INF/versions/") and name.endswith(".jar"):
                print(f"Detected Bundler. Processing inner JAR: {name}")
                with outer_zip.open(name) as inner_file:
                    inner_data = io.BytesIO(inner_file.read())
                    with zipfile.ZipFile(inner_data) as inner_zip:
                        process_recipes(inner_zip, furnace_data, crafting_items, crafting_recipes)
                is_bundler = True
                break
        
        # If not a bundler, try the root
        if not is_bundler:
            process_recipes(outer_zip, furnace_data, crafting_items, crafting_recipes)

    # Create unified JSON structure
    recipes = {
        "recipes": {
            "furnace": [],
            "crafting": []
        },
        "itemLookup": {}
    }

    # Add furnace recipes
    for item_in, item_out in furnace_data:
        recipes["recipes"]["furnace"].append({
            "type": "minecraft:smelting",
            "ingredient": item_in,
            "result": item_out,
            "experience": 0.7,
            "cookingtime": 200
        })

    # Add crafting recipes
    for recipe in crafting_recipes:
        recipes["recipes"]["crafting"].append(recipe)

    # Add item lookup
    item_index = 1
    for item in sorted(list(crafting_items)):
        recipes["itemLookup"][item] = item_index
        item_index += 1

    # Write to JSON file
    with open("recipes/recipes.json", "w") as f:
        json.dump(recipes, f, indent=2)

    print(f"Success! Generated JSON:")
    print(f" - recipes.json: {len(furnace_data)} furnace recipes, {len(crafting_recipes)} crafting recipes, {len(crafting_items)} items")

if __name__ == "__main__":
    generate_bins()
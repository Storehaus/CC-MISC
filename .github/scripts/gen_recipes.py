import zipfile
import json
import struct
import os
import io
import urllib.request

def download_latest_server():
    print("Locating latest Minecraft server jar...")
    manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    
    try:
        # 1. Fetch version manifest to find the latest version ID
        with urllib.request.urlopen(manifest_url) as response:
            manifest = json.loads(response.read().decode('utf-8'))
        
        latest_version = manifest['latest']['release']
        print(f"Latest release version: {latest_version}")
        
        # 2. Find the URL for the specific version package JSON
        version_url = None
        for version in manifest['versions']:
            if version['id'] == latest_version:
                version_url = version['url']
                break
                
        if not version_url:
            print("Error: Could not find version details.")
            return False

        # 3. Fetch version details to get the actual download link
        with urllib.request.urlopen(version_url) as response:
            version_data = json.loads(response.read().decode('utf-8'))
            
        server_url = version_data['downloads']['server']['url']
        print(f"Downloading server.jar from {server_url}...")
        
        # 4. Download the file
        urllib.request.urlretrieve(server_url, "server.jar")
        print("Download complete!")
        return True
        
    except Exception as e:
        print(f"Failed to download server.jar: {e}")
        return False

def process_tags(zip_obj, tags_map):
    # Scan for item tags
    # Path format in jar: data/<namespace>/tags/item/<name>.json
    tag_files = [f for f in zip_obj.namelist() if '/tags/item/' in f and f.endswith('.json')]
    
    # First pass: Load all raw tags
    raw_tags = {}
    
    for file_path in tag_files:
        try:
            with zip_obj.open(file_path) as file:
                data = json.load(file)
                
                # Derive tag name from path
                # data/minecraft/tags/item/logs.json -> minecraft:logs
                parts = file_path.split('/')
                # parts usually: ['data', 'minecraft', 'tags', 'item', 'logs.json']
                if len(parts) >= 5:
                    namespace = parts[1]
                    name = os.path.splitext(parts[-1])[0]
                    tag_key = f"{namespace}:{name}" # e.g. "minecraft:logs"
                    # Add # prefix to match how recipe inputs look
                    full_key = f"#{tag_key}" 
                    
                    values = []
                    raw_values = data.get("values", [])
                    for v in raw_values:
                        if isinstance(v, str):
                            values.append(v)
                        elif isinstance(v, dict) and "id" in v:
                            values.append(v["id"])
                    
                    raw_tags[full_key] = values
        except Exception:
            continue

    # Second pass: Resolve tags within tags (basic flattening)
    # We loop a few times to resolve nested tags like #minecraft:logs containing #minecraft:oak_logs
    for _ in range(3): 
        for tag, values in raw_tags.items():
            new_values = []
            for v in values:
                if v.startswith('#'):
                    # It's a reference to another tag, expand it if we know it
                    if v in raw_tags:
                        new_values.extend(raw_tags[v])
                    else:
                        new_values.append(v) # Keep it if we can't resolve it
                else:
                    new_values.append(v)
            # Remove duplicates
            raw_tags[tag] = list(set(new_values))

    # Copy to the output map
    for k, v in raw_tags.items():
        # Remove the # prefix for the key in the aliases table if preferred, 
        # but keeping it makes lookup easier for exact matches on inputs like "#minecraft:logs"
        tags_map[k] = v

    return len(raw_tags)

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
                    # Ensure tags start with #
                    if item_in and not item_in.startswith('#') and ':' in item_in and not item_in.startswith('minecraft:'): 
                         # Heuristic: if it's a tag in the json but just a string here, we might miss the #
                         # But standard JSON reader usually sees "tag": "minecraft:logs"
                         pass
                    
                    if isinstance(ing, dict) and "tag" in ing:
                        item_in = "#" + ing["tag"]

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

def generate_bins():
    # Automatically download the latest server jar
    if not download_latest_server():
        print("Aborting generation due to download failure.")
        return

    jar_path = "server.jar"
    furnace_data = []
    crafting_items = set()
    crafting_recipes = []
    tags_map = {}

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
                        process_tags(inner_zip, tags_map)
                is_bundler = True
                break
        
        # If not a bundler, try the root
        if not is_bundler:
            process_recipes(outer_zip, furnace_data, crafting_items, crafting_recipes)
            process_tags(outer_zip, tags_map)

    # Create unified JSON structure
    recipes = {
        "recipes": {
            "furnace": [],
            "crafting": []
        },
        "itemLookup": {},
        "aliases": tags_map # Add the aliases/tags table here
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
    if not os.path.exists("recipes"):
        os.makedirs("recipes")
        
    with open("recipes/recipes.json", "w") as f:
        json.dump(recipes, f, indent=2)

    print(f"Success! Generated JSON:")
    print(f" - {len(tags_map)} tags/aliases processed")
    print(f" - {len(furnace_data)} furnace recipes")
    print(f" - {len(crafting_recipes)} crafting recipes")
    print(f" - {len(crafting_items)} items")

if __name__ == "__main__":
    generate_bins()
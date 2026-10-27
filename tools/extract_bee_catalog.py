#!/usr/bin/env python3
"""Build the client-side bee catalogue from decompiled installed mod classes.

The script intentionally consumes decompiled Java instead of upstream sources: this
keeps the result tied to the exact JARs installed in the McSkill client.  CFR 0.152
was used for the checked-in catalogue.
"""

from __future__ import annotations

import argparse
import itertools
import json
import re
import zipfile
from pathlib import Path


BASE_GENES = {
    "SPEED": "EnumAllele.Speed.SLOWEST",
    "LIFESPAN": "EnumAllele.Lifespan.SHORTER",
    "FERTILITY": "EnumAllele.Fertility.NORMAL",
    "TEMPERATURE_TOLERANCE": "EnumAllele.Tolerance.NONE",
    "NEVER_SLEEPS": "false",
    "HUMIDITY_TOLERANCE": "EnumAllele.Tolerance.NONE",
    "TOLERATES_RAIN": "false",
    "CAVE_DWELLING": "false",
    "FLOWER_PROVIDER": "EnumAllele.Flowers.VANILLA",
    "FLOWERING": "EnumAllele.Flowering.SLOWEST",
    "TERRITORY": "EnumAllele.Territory.AVERAGE",
    "EFFECT": "AlleleEffects.effectNone",
}


def enum_blocks(text: str, stop_marker: str) -> dict[str, str]:
    text = text[text.index("public enum "): text.index(stop_marker)]
    starts = list(re.finditer(r"(?m)^    ([A-Z][A-Z0-9_]*)\(", text))
    return {
        match.group(1): text[match.start(): (starts[i + 1].start() if i + 1 < len(starts) else len(text))]
        for i, match in enumerate(starts)
    }


def method_body(block: str, name: str) -> str:
    match = re.search(r"\b%s\([^)]*\)\s*\{" % re.escape(name), block)
    if not match:
        return ""
    start = match.end()
    depth = 1
    for pos in range(start, len(block)):
        if block[pos] == "{":
            depth += 1
        elif block[pos] == "}":
            depth -= 1
            if depth == 0:
                return block[start:pos]
    return ""


def clean_expr(value: str) -> str:
    value = re.sub(r"AlleleHelper\.getAllele\((.*?)\.getUID\(\)\)", r"\1", value, flags=re.S)
    value = re.sub(r"\([A-Za-z][A-Za-z0-9_$.<>? ]*\)", "", value)
    return re.sub(r"\s+", " ", value).strip()


def genes(body: str) -> dict[str, str]:
    found: dict[str, str] = {}
    pattern = re.compile(r"EnumBeeChromosome\.([A-Z_]+),\s*(.*?)\);", re.S)
    for chromosome, value in pattern.findall(body):
        found[chromosome] = clean_expr(value)
    return found


def drops(body: str) -> list[dict[str, object]]:
    result = []
    pattern = re.compile(r"\.(addProduct|addSpecialty)\((.*?),\s*Float\.valueOf\(([0-9.]+)f?\)\)", re.S)
    for kind, item, chance in pattern.findall(body):
        result.append({"kind": "product" if kind == "addProduct" else "specialty",
                       "item": clean_expr(item), "chance": float(chance)})
    return result


def mutation_conditions(chain: str) -> list[str]:
    return [re.sub(r"\s+", " ", name + "(" + args.strip() + ")")
            for name, args in re.findall(r"\.(restrict[A-Za-z]+|setIsSecret)\((.*?)\)", chain, re.S)]


def mutation_rows(body: str, result_uid: str, uid_for) -> list[dict[str, object]]:
    rows = []
    pattern = re.compile(r"this\.registerMutation\((.*?),\s*(.*?),\s*(\d+)\)(.*?);", re.S)
    for parent1, parent2, chance, chain in pattern.findall(body):
        p1, p2 = clean_expr(parent1).split(".")[-1], clean_expr(parent2).split(".")[-1]
        if p1 in {"hiveBee0", "COMMON"} and p2 in {"hiveBee1", "hiveBee"}:
            continue
        if p2 == "parent2":
            choices = re.search(r"EnumSet\.of\((.*?)\)", body, re.S)
            if choices:
                for choice in choices.group(1).split(","):
                    rows.append({"result": result_uid, "parents": [uid_for(p1), uid_for(choice.strip())],
                                 "chance": int(chance), "conditions": mutation_conditions(chain)})
            continue
        rows.append({"result": result_uid, "parents": [uid_for(p1), uid_for(p2)],
                     "chance": int(chance), "conditions": mutation_conditions(chain)})
    return rows


def load_lang(jar: Path, path: str) -> dict[str, str]:
    with zipfile.ZipFile(jar) as archive:
        raw = archive.read(path).decode("utf-8", "replace")
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line and not line.lstrip().startswith("#"))


def parse_java_species(source: Path, branches_source: Path, mod: str, climate: dict, lang: dict[str, str]):
    text = source.read_text()
    branch_text = branches_source.read_text()
    species_blocks = enum_blocks(text, "private static final" if mod == "forestry" else "private final IBranchDefinition")
    branch_blocks = enum_blocks(branch_text, "private final IClassification")
    branch_genes = {name: {**BASE_GENES, **genes(method_body(block, "setBranchProperties"))}
                    for name, block in branch_blocks.items()}
    known = set(species_blocks)

    def uid_for(name: str) -> str:
        name = name.strip()
        if name in known:
            return ("forestry.species" + name.title().replace("_", "") if mod == "forestry"
                    else "extrabees.species." + name.lower())
        return "forestry.species" + name.title().replace("_", "")

    species, mutations = [], []
    for enum_name, block in species_blocks.items():
        header = re.search(r"^\s*[A-Z0-9_]+\((.*?),\s*\"([^\"]+)\",\s*(true|false),", block, re.S)
        if not header:
            continue
        branch = header.group(1).split(".")[-1]
        uid = uid_for(enum_name)
        props = method_body(block, "setSpeciesProperties")
        native = {**branch_genes.get(branch, BASE_GENES), **genes(method_body(block, "setAlleles"))}
        temperature, humidity = climate.get(uid, ["NORMAL", "NORMAL"])
        temp = re.search(r"\.setTemperature\(EnumTemperature\.([A-Z]+)\)", props)
        hum = re.search(r"\.setHumidity\(EnumHumidity\.([A-Z]+)\)", props)
        temperature = temp.group(1) if temp else temperature
        humidity = hum.group(1) if hum else humidity
        if mod == "forestry":
            key = "for.bees.species." + enum_name.lower()
        else:
            key = "extrabees.species." + enum_name.lower() + ".name"
        species.append({
            "uid": uid, "mod": mod, "enum": enum_name, "name": lang.get(key, enum_name.title()),
            "branch": branch, "binomial": header.group(2), "dominant": header.group(3) == "true",
            "requirements": {"temperature": temperature, "humidity": humidity,
                "flowers": native["FLOWER_PROVIDER"], "needsSky": native["CAVE_DWELLING"] == "false",
                "worksInRain": native["TOLERATES_RAIN"] == "true",
                "time": "any" if native["NEVER_SLEEPS"] == "true" else "day"},
            "nativeGenes": native, "effect": native["EFFECT"], "drops": drops(props),
        })
        mutations.extend(mutation_rows(method_body(block, "registerMutations"), uid, uid_for))

    if mod == "forestry":
        hive = ["FOREST", "MARSHY", "MEADOWS", "MODEST", "TROPICAL", "WINTRY"]
        for a, b in itertools.combinations(hive, 2):
            mutations.append({"result": uid_for("COMMON"), "parents": [uid_for(a), uid_for(b)], "chance": 15, "conditions": []})
        for parent in hive:
            mutations.append({"result": uid_for("CULTIVATED"), "parents": [uid_for("COMMON"), uid_for(parent)], "chance": 12, "conditions": []})
    else:
        def static_uid(expr: str) -> str:
            name = clean_expr(expr).split(".")[-1]
            return ("forestry.species" + name.title().replace("_", "")
                    if "BeeDefinition." in expr else "extrabees.species." + name.lower())
        pattern = re.compile(r"ExtraBeeDefinition\.registerMutation\((.*?),\s*(.*?),\s*(.*?),\s*(\d+)\)(.*?);", re.S)
        for parent1, parent2, result, chance, chain in pattern.findall(method_body(text, "doInit")):
            mutations.append({"result": static_uid(result), "parents": [static_uid(parent1), static_uid(parent2)],
                              "chance": int(chance), "conditions": mutation_conditions(chain)})
    return species, mutations


def parse_gendustry(jar: Path, climate: dict, lang: dict[str, str], diligent_genes: dict[str, str]):
    with zipfile.ZipFile(jar) as archive:
        text = archive.read("assets/gendustry/config/bees_color.cfg").decode()
    species, mutations = [], []
    bees_start = text.index("    cfg Bees {")
    brace = text.index("{", bees_start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    bees_text = text[brace + 1:end - 1]
    blocks = re.split(r"(?m)^        cfg ", bees_text)[1:]
    for block in blocks:
        ident = re.match(r"(\w+)", block).group(1)
        uid = "gendustry.bee." + ident
        if uid not in climate:
            continue
        get = lambda key, default="": (re.search(r"(?m)^\s*%s\s*=\s*\"?([^\n\"]+)" % key, block) or [None, default])[1].strip()
        traits = {m.group(1).upper(): m.group(2) for m in re.finditer(r"(?m)^\s*(Speed|Humidity_Tolerance|Temperature_Tolerance)\s*=\s*\"([^\"]+)", block)}
        native = dict(diligent_genes)
        native.update({k: v for k, v in traits.items()})
        temp, hum = climate[uid]
        drop = re.search(r"Products\s*=\s*DropsList\([^0-9]*([0-9.]+)%\s+([^\s)]+)", block, re.S)
        species.append({"uid": uid, "mod": "gendustry", "enum": ident.upper(),
            "name": lang.get("gendustry.bees.species." + ident, ident.title()), "branch": "COLOR",
            "binomial": get("Binominal"), "dominant": get("Dominant") == "Yes",
            "requirements": {"temperature": temp, "humidity": hum, "flowers": native["FLOWER_PROVIDER"],
                "needsSky": True, "worksInRain": False, "time": "day"},
            "nativeGenes": native, "effect": native["EFFECT"],
            "drops": ([{"kind": "product", "item": drop.group(2), "chance": float(drop.group(1)) / 100}] if drop else [])})
    for chance, parent1, parent2, result in re.findall(
            r'mutation:\s*([0-9.]+)%\s*"([^"]+)"\s*\+\s*"([^"]+)"\s*=>\s*"([^"]+)"', text):
        if result in climate:
            mutations.append({"result": result, "parents": [parent1, parent2],
                              "chance": float(chance), "conditions": []})
    return species, mutations


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decompiled", required=True, type=Path)
    parser.add_argument("--client", required=True, type=Path)
    parser.add_argument("--climate", default="src/climate-data.json", type=Path)
    parser.add_argument("--output", default="src/bee-catalog.json", type=Path)
    args = parser.parse_args()
    climate = json.loads(args.climate.read_text())
    mods = args.client / "mods"
    forestry_jar = next(mods.glob("forestry_*.jar"))
    binnie_jar = next(mods.glob("binnie-mods-*.jar"))
    gendustry_jar = next(mods.glob("gendustry-*.jar"))
    forestry_lang = load_lang(forestry_jar, "assets/forestry/lang/ru_ru.lang")
    binnie_lang = load_lang(binnie_jar, "assets/extrabees/lang/ru_RU.lang")
    gendustry_lang = load_lang(gendustry_jar, "assets/gendustry/lang/ru_RU.lang")
    species, mutations = parse_java_species(args.decompiled / "forestry/forestry/apiculture/genetics/BeeDefinition.java",
        args.decompiled / "forestry/forestry/apiculture/genetics/BeeBranchDefinition.java", "forestry", climate, forestry_lang)
    extra_species, extra_mutations = parse_java_species(args.decompiled / "binnie/binnie/extrabees/genetics/ExtraBeeDefinition.java",
        args.decompiled / "binnie/binnie/extrabees/genetics/ExtraBeeBranchDefinition.java", "extrabees", climate, binnie_lang)
    diligent_genes = next(row["nativeGenes"] for row in species if row["uid"] == "forestry.speciesDiligent")
    color_species, color_mutations = parse_gendustry(gendustry_jar, climate, gendustry_lang, diligent_genes)
    species += extra_species + color_species
    mutations += extra_mutations + color_mutations
    payload = {"schema": 1, "scope": "client", "completeForClientSpecies": len(species) == len(climate),
        "sources": {"forestry": forestry_jar.name, "binnie": binnie_jar.name, "gendustry": gendustry_jar.name,
                    "note": "Server registry and server-only overrides are not included."},
        "species": sorted(species, key=lambda row: row["uid"]), "mutations": mutations}
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {len(species)} species and {len(mutations)} mutation recipes to {args.output}")


if __name__ == "__main__":
    main()

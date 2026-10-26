"""Embed the maintained automation source into the five-file OpenOS package."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
START = '-- BEGIN EMBEDDED AUTOMATION\n'
END = '-- END EMBEDDED AUTOMATION\n'


def build_body():
    data = json.loads((ROOT / 'src/climate-data.json').read_text(encoding='utf-8'))
    lines = ['local climateDefaults = {']
    for uid, values in sorted(data.items()):
        assert all(isinstance(v,str) and v.replace('_','').replace('.','').isalnum() for v in (uid,*values))
        lines.append('  ["'+uid+'"]={"'+values[0]+'","'+values[1]+'"},')
    lines.append('}\n')
    return '\n'.join(lines)+(ROOT/'src/climate.lua').read_text(encoding='utf-8')+(ROOT/'src/dashboard.lua').read_text(encoding='utf-8')+(ROOT/'src/automation.lua').read_text(encoding='utf-8')


def embed():
    target = ROOT / 'openbeekeeper.lua'
    source = target.read_text(encoding='utf-8')
    body = build_body()
    block = START + body + END
    if START in source:
        a = source.index(START)
        b = source.index(END, a) + len(END)
        source = source[:a] + block + source[b:]
    else:
        pos = source.index('local function runApiaries()')
        source = source[:pos] + block + '\n' + source[pos:]
    target.write_text(source, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    embed()

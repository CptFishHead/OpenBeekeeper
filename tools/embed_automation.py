"""Embed the maintained automation source into the five-file OpenOS package."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = '-- BEGIN EMBEDDED AUTOMATION\n'
END = '-- END EMBEDDED AUTOMATION\n'


def embed():
    target = ROOT / 'openbeekeeper.lua'
    source = target.read_text(encoding='utf-8')
    body = (ROOT / 'src/automation.lua').read_text(encoding='utf-8')
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

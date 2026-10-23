"""Inline the shared shader core into the web preview page."""
import json
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
core = (root / 'godot' / 'shaders' / 'wormhole_core.gdshaderinc').read_text()
scene = json.loads((root / 'godot' / 'scene.json').read_text())
scene.pop('_comment', None)
page = (root / 'preview' / 'template.html').read_text().replace('/*CORE*/', core).replace('/*SCENE*/', json.dumps(scene))
out = root / 'preview' / 'wormhole.html'
out.write_text(page)
print(out, len(page), 'bytes')

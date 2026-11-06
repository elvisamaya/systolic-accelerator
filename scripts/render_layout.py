#!/usr/bin/env python3
"""render_layout.py - draw a GDSII layout to a PNG with KLayout (no GUI needed).

    python3 scripts/render_layout.py openlane/runs/*/final/gds/accel_chip.gds docs/layout.png

Shows the metal and via layers that matter for a quick look at a chip:
cell area (li1), and the five routing metals (met1..met5). Fill and
other technology layers are hidden so the structure stays readable.
"""
import sys

import klayout.db as db
import klayout.lay as lay

# sky130 GDS layer/datatype pairs: (name, layer, datatype, colour)
LAYERS = [
    ("li1",  67, 20, 0x8a8a8a),
    ("met1", 68, 20, 0x3b7dd8),
    ("met2", 69, 20, 0xd84b3b),
    ("met3", 70, 20, 0x3bb36b),
    ("met4", 71, 20, 0xc79a2b),
    ("met5", 72, 20, 0x9b59b6),
]


def main():
    gds, png = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 1600

    view = lay.LayoutView()
    view.set_config("background-color", "#ffffff")
    view.set_config("grid-visible", "false")
    view.set_config("text-visible", "false")
    idx = view.load_layout(gds, True)
    view.max_hier()
    view.clear_layers()
    for name, layer, dtype, colour in LAYERS:
        props = lay.LayerPropertiesNode()
        props.source = f"{layer}/{dtype}@{idx + 1}"
        props.name = name
        props.fill_color = colour
        props.frame_color = colour
        props.dither_pattern = 1 if name == "li1" else 0
        props.transparent = True
        view.insert_layer(view.end_layers(), props)
    view.zoom_fit()
    view.save_image(png, size, size)
    top = view.cellview(idx).layout().top_cell()
    bbox = top.dbbox()
    print(f"rendered {top.name}: {bbox.width():.0f} x {bbox.height():.0f} um -> {png}")


if __name__ == "__main__":
    main()

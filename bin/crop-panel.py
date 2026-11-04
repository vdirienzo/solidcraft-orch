#!/usr/bin/env python3
"""Recorta la region del panel Project de una captura, para que la evidencia
se lea de un vistazo: la fila del error y el boton (o su ausencia).

Uso: crop-panel.py <png> <salida> [x0 y0 x1 y1]
"""
import sys
from PIL import Image

src = sys.argv[1]
dst = sys.argv[2]
box = tuple(int(v) for v in sys.argv[3:7]) if len(sys.argv) >= 7 else None

im = Image.open(src)
if box is None:
    box = (0, 0, im.size[0], im.size[1])
crop = im.crop(box)
crop.save(dst)
print(f"{dst} {crop.size}")

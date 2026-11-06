#!/usr/bin/env python3

import argparse
import sys

import mapnik


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("min_easting", type=float)
    parser.add_argument("min_northing", type=float)
    parser.add_argument("max_easting", type=float)
    parser.add_argument("max_northing", type=float)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    parser.add_argument("scale_factor", type=float, nargs="?", default=1.0)
    parser.add_argument("--style", default="map.xml",
                        help="Mapnik stylesheet to render with")
    return parser.parse_args()


args = parse_args()

bbox_bng = mapnik.Box2d(
    args.min_easting,
    args.min_northing,
    args.max_easting,
    args.max_northing,
)

print(f"Map area: {(args.max_easting - args.min_easting) / 1000:.1f} × "
      f"{(args.max_northing - args.min_northing) / 1000:.1f} km", file=sys.stderr)

print(f"Image: {args.width} × {args.height} pixels", file=sys.stderr)

m = mapnik.Map(args.width, args.height)

mapnik.load_map(m, args.style)
m.zoom_to_box(bbox_bng)

image = mapnik.Image(args.width, args.height)
mapnik.render(m, image, args.scale_factor)
sys.stdout.buffer.write(image.to_string("png"))

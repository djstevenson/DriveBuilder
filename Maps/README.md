# Maps

The map dials (the progress maps and the route map) render their base maps
by running `maprender.py`, a thin Mapnik wrapper, from this folder:

| File | Purpose |
|---|---|
| `maprender.py` | Renders a British National Grid box to PNG on stdout |
| `map.xml` | Full-detail style: land, water, roads, road-number shields |
| `map-national.xml` | Country-wide style: land, trunk roads, motorways |
| `symbols/` | Road-number shield artwork used by `map.xml` |
| `osm-import.lua` | osm2pgsql style that builds the `gb` database |
| `osm_data/` | Coastline polygons (downloaded, not in git) |

Roads, places and water come from the `gb` PostGIS database, which the
speed-limit lookup (`SpeedLimitLookup.swift`) also queries.

## Setting up

Tools, via Homebrew: `postgresql@18`, `postgis`, `osm2pgsql`, `mapnik`.

### Python Mapnik bindings

`maprender.py` runs as `env python3`, and only the pyenv 3.13.3 Python has
the Mapnik bindings (`.python-version` here selects it; the renderer puts
`~/.pyenv/shims` on `PATH`):

```sh
pyenv install 3.13.3
~/.pyenv/versions/3.13.3/bin/python3 -m pip install mapnik
```

Check with `python3 -c 'import mapnik'` from this folder.

### Coastline polygons

Download the split WGS84 land polygons from
<https://osmdata.openstreetmap.de/data/land-polygons.html> and unzip them
here, so the shapefile is at
`osm_data/land-polygons-split-4326/land_polygons.shp`.

### The `gb` database

Download Geofabrik's Great Britain extract (about 2 GB):

```sh
curl -L -o ~/Downloads/great-britain-latest.osm.pbf \
  https://download.geofabrik.de/europe/great-britain-latest.osm.pbf
```

Then import it from this folder (about 15 minutes on an M1 Ultra):

```sh
createdb gb && psql -d gb -c 'CREATE EXTENSION postgis'
osm2pgsql --create --slim --output=flex --style=osm-import.lua \
    -d gb ~/Downloads/great-britain-latest.osm.pbf
```

To refresh an existing database without downtime, import into `gb_new`
instead, check it, then swap:

```sh
psql -d postgres -c 'ALTER DATABASE gb RENAME TO gb_old' \
                 -c 'ALTER DATABASE gb_new RENAME TO gb'
```

When changing `osm-import.lua`, try it on a small area first by adding
`--bbox=min_lon,min_lat,max_lon,max_lat` and importing into a scratch
database.

After changing the data or the styles, bump the `dials` and `route_map`
versions in `RenderRecords.swift` so Studio flags existing movies as out
of date.

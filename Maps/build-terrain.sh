#!/bin/sh
# Builds terrain/shade.tif, the hill shading map.xml multiplies over the
# map, from the OS Terrain 50 ASCII grid download in terr50_gagg_gb/.
# Run from anywhere; takes about a minute.
set -eu

cd "$(dirname "$0")"
mkdir -p terrain/asc

# The download is one zip per 10 km square; only the height grids and
# their projection files are needed.
for zip in terr50_gagg_gb/data/*/*.zip; do
    unzip -qo -j "$zip" '*.asc' '*.prj' -d terrain/asc
done

# gdalbuildvrt needs every tile to have the same data type, but the odd
# tile has only whole-number heights, which GDAL reads as integers:
# rewrite those (the files with no decimal point at all) as floats.
for tile in $(grep -L -F . terrain/asc/*.asc); do
    gdal_translate -q -ot Float32 -of AAIGrid "$tile" "$tile.float"
    mv "$tile.float" "$tile"
    rm -f "$tile.float.prj" "$tile.float.aux.xml" "$tile.aux.xml"
done

gdalbuildvrt -q -a_srs EPSG:27700 terrain/dtm.vrt terrain/asc/*.asc

# Light from several directions, slightly exaggerated relief. Flat ground
# comes out at about 181, so rescale to make it white: multiplied over the
# map, only slopes facing away from the light then darken it.
gdaldem hillshade -q -multidirectional -z 1.5 -compute_edges \
    -co TILED=YES -co COMPRESS=DEFLATE terrain/dtm.vrt terrain/hillshade.tif
gdal_translate -q -scale 0 181 0 255 -ot Byte -a_nodata none \
    -co TILED=YES -co COMPRESS=DEFLATE terrain/hillshade.tif terrain/shade.tif
gdaladdo -q -r average terrain/shade.tif 2 4 8 16 32
rm terrain/hillshade.tif

echo "Built $(pwd)/terrain/shade.tif"

-- osm2pgsql flex style for the drive-builder map database ("gb").
--
-- Import (into a fresh database) with:
--
--   createdb gb && psql -d gb -c 'CREATE EXTENSION postgis'
--   osm2pgsql --create --slim --output=flex --style=osm-import.lua \
--       -d gb great-britain-latest.osm.pbf
--
-- Tables:
--   osm_roads        highways, for map.xml and speed limit lookups
--   osm_places       named settlements
--   osm_water_areas  lakes, reservoirs, wide rivers and estuaries (polygons)
--   osm_waterways    rivers, streams and canals (centre lines)
--
-- Roads and places carry both WGS84 (geom) and British National Grid
-- (geom_bng) geometry; the water tables are only drawn, so are BNG only.

local tables = {}

tables.roads = osm2pgsql.define_table({
    name = 'osm_roads',
    ids = { type = 'way', id_column = 'way_id', create_index = 'always' },
    columns = {
        { column = 'highway', type = 'text' },
        { column = 'name', type = 'text' },
        { column = 'ref', type = 'text' },
        { column = 'maxspeed', type = 'text' },
        { column = 'maxspeed_forward', type = 'text' },
        { column = 'maxspeed_backward', type = 'text' },
        { column = 'maxspeed_conditional', type = 'text' },
        { column = 'oneway', type = 'text' },
        { column = 'lanes', type = 'text' },
        { column = 'junction', type = 'text' },
        { column = 'surface', type = 'text' },
        { column = 'geom', type = 'linestring', projection = 4326, not_null = true },
        { column = 'geom_bng', type = 'linestring', projection = 27700 },
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'geom_bng', method = 'gist' },
    },
})

tables.places = osm2pgsql.define_table({
    name = 'osm_places',
    ids = { type = 'node', id_column = 'node_id', create_index = 'primary_key' },
    columns = {
        { column = 'place', type = 'text', not_null = true },
        { column = 'name', type = 'text', not_null = true },
        { column = 'population', type = 'int4' },
        { column = 'geom', type = 'point', projection = 4326, not_null = true },
        { column = 'geom_bng', type = 'point', projection = 27700, not_null = true },
    },
    indexes = {
        { column = 'geom', method = 'gist' },
        { column = 'geom_bng', method = 'gist' },
    },
})

tables.water_areas = osm2pgsql.define_table({
    name = 'osm_water_areas',
    ids = { type = 'area', id_column = 'area_id', create_index = 'always' },
    columns = {
        { column = 'kind', type = 'text', not_null = true },
        { column = 'name', type = 'text' },
        { column = 'intermittent', type = 'bool' },
        -- Square metres, so small stylesheets can skip garden ponds.
        { column = 'area_m2', type = 'real' },
        { column = 'geom', type = 'multipolygon', projection = 27700, not_null = true },
    },
})

tables.waterways = osm2pgsql.define_table({
    name = 'osm_waterways',
    ids = { type = 'way', id_column = 'way_id', create_index = 'always' },
    columns = {
        { column = 'waterway', type = 'text', not_null = true },
        { column = 'name', type = 'text' },
        { column = 'intermittent', type = 'bool' },
        -- True for culverted/underground stretches, which aren't drawn.
        { column = 'tunnel', type = 'bool' },
        { column = 'geom', type = 'linestring', projection = 27700, not_null = true },
    },
})

local road_highways = {
    motorway = true, motorway_link = true,
    trunk = true, trunk_link = true,
    primary = true, primary_link = true,
    secondary = true, secondary_link = true,
    tertiary = true, tertiary_link = true,
    unclassified = true, residential = true, living_street = true,
    service = true, road = true,
}

local place_kinds = { city = true, town = true, village = true, hamlet = true }

local waterway_kinds = {
    river = true, stream = true, canal = true, drain = true, ditch = true,
}

-- Returns the water kind for an area's tags, or nil if it isn't water.
local function water_kind(tags)
    if tags.natural == 'water' then
        return tags.water or 'water'
    end
    if tags.waterway == 'riverbank' then
        return 'river'
    end
    if tags.landuse == 'reservoir' or tags.landuse == 'basin' then
        return tags.landuse
    end
    return nil
end

local function population(value)
    if value == nil then
        return nil
    end
    local digits = value:gsub('[,%s]', '')
    if digits:match('^%d+$') then
        return tonumber(digits)
    end
    return nil
end

local function add_water_area(object, kind, geometry)
    tables.water_areas:insert({
        kind = kind,
        name = object.tags.name,
        intermittent = object.tags.intermittent == 'yes',
        area_m2 = geometry:transform(27700):area(),
        geom = geometry,
    })
end

function osm2pgsql.process_node(object)
    local tags = object.tags
    if place_kinds[tags.place] and tags.name then
        local point = object:as_point()
        tables.places:insert({
            place = tags.place,
            name = tags.name,
            population = population(tags.population),
            geom = point,
            geom_bng = point,
        })
    end
end

function osm2pgsql.process_way(object)
    local tags = object.tags

    if road_highways[tags.highway] then
        local line = object:as_linestring()
        tables.roads:insert({
            highway = tags.highway,
            name = tags.name,
            ref = tags.ref,
            maxspeed = tags.maxspeed,
            maxspeed_forward = tags['maxspeed:forward'],
            maxspeed_backward = tags['maxspeed:backward'],
            maxspeed_conditional = tags['maxspeed:conditional'],
            oneway = tags.oneway,
            lanes = tags.lanes,
            junction = tags.junction,
            surface = tags.surface,
            geom = line,
            geom_bng = line,
        })
    end

    if waterway_kinds[tags.waterway] then
        tables.waterways:insert({
            waterway = tags.waterway,
            name = tags.name,
            intermittent = tags.intermittent == 'yes',
            tunnel = tags.tunnel ~= nil and tags.tunnel ~= 'no',
            geom = object:as_linestring(),
        })
    end

    if object.is_closed then
        local kind = water_kind(tags)
        if kind then
            add_water_area(object, kind, object:as_polygon())
        end
    end
end

function osm2pgsql.process_relation(object)
    if object.tags.type ~= 'multipolygon' then
        return
    end
    local kind = water_kind(object.tags)
    if kind then
        add_water_area(object, kind, object:as_multipolygon())
    end
end

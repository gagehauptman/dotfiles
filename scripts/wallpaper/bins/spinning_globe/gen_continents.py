#!/usr/bin/env python3
"""Generate continents.rs from Natural Earth GeoJSON."""

import json
import urllib.request
import re

def fetch_geojson(url):
    with urllib.request.urlopen(url) as response:
        return json.loads(response.read().decode())

def simplify_line(coords, tolerance=0.5):
    """Douglas-Peucker simplification."""
    if len(coords) < 3:
        return coords
    
    def point_line_distance(point, start, end):
        if start == end:
            return ((point[0] - start[0])**2 + (point[1] - start[1])**2)**0.5
        n = abs((end[1] - start[1]) * point[0] - (end[0] - start[0]) * point[1] + end[0] * start[1] - end[1] * start[0])
        d = ((end[1] - start[1])**2 + (end[0] - start[0])**2)**0.5
        return n / d if d > 0 else 0
    
    dmax = 0
    index = 0
    for i in range(1, len(coords) - 1):
        d = point_line_distance(coords[i], coords[0], coords[-1])
        if d > dmax:
            index = i
            dmax = d
    
    if dmax > tolerance:
        left = simplify_line(coords[:index + 1], tolerance)
        right = simplify_line(coords[index:], tolerance)
        return left[:-1] + right
    else:
        return [coords[0], coords[-1]]

def name_to_const(name):
    """Convert country name to Rust const name."""
    # Special cases
    mapping = {
        "United States of America": "USA",
        "United Kingdom": "UK",
        "United Arab Emirates": "UAE",
        "Democratic Republic of the Congo": "DR_CONGO",
        "Republic of the Congo": "CONGO",
        "Dominican Republic": "DOMINICAN_REP",
        "Czechia": "CZECH_REP",
        "Central African Republic": "CENTRAL_AFRICAN_REP",
        "Bosnia and Herzegovina": "BOSNIA",
        "North Macedonia": "NORTH_MACEDONIA",
        "South Korea": "SOUTH_KOREA",
        "North Korea": "NORTH_KOREA",
        "South Africa": "SOUTH_AFRICA",
        "South Sudan": "SOUTH_SUDAN",
        "Sri Lanka": "SRI_LANKA",
        "Saudi Arabia": "SAUDI_ARABIA",
        "New Zealand": "NEW_ZEALAND",
        "Papua New Guinea": "PAPUA_NEW_GUINEA",
        "French Guiana": "FRENCH_GUIANA",
        "Falkland Islands": "FALKLAND_ISLANDS",
        "Solomon Islands": "SOLOMON_ISLANDS",
        "Equatorial Guinea": "EQ_GUINEA",
        "Guinea-Bissau": "GUINEA_BISSAU",
        "Ivory Coast": "IVORY_COAST",
        "Western Sahara": "WESTERN_SAHARA",
        "eSwatini": "ESWATINI",
        "East Timor": "TIMOR_LESTE",
        "New Caledonia": "NEW_CALEDONIA",
        "The Bahamas": "BAHAMAS",
        "Trinidad and Tobago": "TRINIDAD",
        "Puerto Rico": "PUERTO_RICO",
        "El Salvador": "EL_SALVADOR",
        "Costa Rica": "COSTA_RICA",
        "Burkina Faso": "BURKINA_FASO",
        "Sierra Leone": "SIERRA_LEONE",
    }
    if name in mapping:
        return mapping[name]
    
    # General case: uppercase, replace spaces/special chars with underscore
    const = re.sub(r'[^a-zA-Z0-9]', '_', name.upper())
    const = re.sub(r'_+', '_', const)
    return const.strip('_')

def main():
    base_url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
    
    # Fetch both datasets - countries + map_units (for territories like French Guiana)
    print("Fetching Natural Earth data...")
    countries_data = fetch_geojson(base_url + "ne_110m_admin_0_countries.geojson")
    map_units_data = fetch_geojson(base_url + "ne_110m_admin_0_map_units.geojson")
    
    # Merge features, map_units has territories countries doesn't
    all_features = countries_data["features"] + map_units_data["features"]
    
    # All countries/territories to include (using exact Natural Earth names)
    include = {
        # North America
        "United States of America", "Canada", "Mexico", "Guatemala", "Honduras",
        "Nicaragua", "Costa Rica", "Panama", "Cuba", "Dominican Republic", "Haiti",
        "Jamaica", "Puerto Rico", "The Bahamas", "Belize", "El Salvador",
        # South America
        "Brazil", "Argentina", "Chile", "Colombia", "Peru", "Venezuela",
        "Ecuador", "Bolivia", "Paraguay", "Uruguay", "Guyana", "Suriname",
        "French Guiana", "Falkland Islands", "Trinidad and Tobago",
        # Europe
        "United Kingdom", "France", "Spain", "Italy", "Germany", "Poland",
        "Ukraine", "Norway", "Sweden", "Finland", "Ireland", "Portugal",
        "Belgium", "Netherlands", "Austria", "Czechia", "Hungary",
        "Romania", "Bulgaria", "Greece", "Belarus", "Lithuania", "Latvia",
        "Estonia", "Serbia", "Croatia", "Bosnia and Herzegovina", "Slovenia",
        "Slovakia", "North Macedonia", "Albania", "Montenegro", "Moldova",
        "Kosovo", "Switzerland", "Denmark", "Iceland", "Greenland", "Cyprus",
        # Africa
        "Egypt", "Libya", "Algeria", "Sudan", "South Africa", "Nigeria",
        "Democratic Republic of the Congo", "Morocco", "Tunisia", "Kenya", "Tanzania",
        "Ethiopia", "Somalia", "Somaliland", "Mozambique", "Namibia", "Botswana",
        "Zimbabwe", "Zambia", "Angola", "Central African Republic", "Cameroon",
        "Chad", "Niger", "Mali", "Mauritania", "Gabon", "Republic of the Congo",
        "Equatorial Guinea", "Benin", "Togo", "Ghana", "Ivory Coast", "Liberia",
        "Sierra Leone", "Guinea", "Guinea-Bissau", "Senegal", "Gambia", "Burkina Faso",
        "Malawi", "Burundi", "Rwanda", "Uganda", "South Sudan", "Eritrea",
        "Djibouti", "Western Sahara", "Madagascar", "Lesotho", "eSwatini",
        # Asia
        "Russia", "China", "India", "Indonesia", "Japan", "Philippines",
        "Saudi Arabia", "Iran", "Turkey", "Kazakhstan", "Mongolia", "Pakistan",
        "Thailand", "Vietnam", "Myanmar", "Malaysia", "Afghanistan", "Iraq",
        "Syria", "Jordan", "Israel", "Palestine", "Yemen", "Oman",
        "United Arab Emirates", "Bangladesh", "Nepal", "Sri Lanka", "Laos",
        "Cambodia", "North Korea", "South Korea", "Taiwan", "Turkmenistan",
        "Uzbekistan", "Tajikistan", "Kyrgyzstan", "Azerbaijan", "Georgia",
        "Armenia", "Kuwait", "Qatar", "Bahrain", "Lebanon", "Bhutan", "Brunei",
        "East Timor",
        # Oceania
        "Australia", "Papua New Guinea", "New Zealand", "Fiji",
        "Solomon Islands", "Vanuatu", "New Caledonia",
        # Antarctica
        "Antarctica",
    }
    
    countries = {}  # name -> list of (const_name, coords)
    seen_names = set()  # track already-processed countries to avoid duplicates
    
    for feature in all_features:
        props = feature.get("properties", {})
        name_field = props.get("NAME") or ""
        admin_field = props.get("ADMIN") or ""
        
        # Check if either NAME or ADMIN is in our include list
        if name_field in include:
            name = name_field
        elif admin_field in include:
            name = admin_field
        else:
            continue
        
        # Skip if we've already processed this country (from the other dataset)
        if name in seen_names:
            continue
        seen_names.add(name)
        
        const_name = name_to_const(name)
        geom = feature["geometry"]
        coords = geom["coordinates"]
        
        if geom["type"] == "Polygon":
            polygons = [coords]
        else:  # MultiPolygon
            polygons = coords
        
        polys = []
        for poly in polygons:
            exterior = poly[0] if isinstance(poly[0][0], list) else poly
            if len(exterior) >= 4:
                simplified = simplify_line(exterior, tolerance=0.5)
                if len(simplified) >= 4:
                    polys.append(simplified)
        
        # Sort by size (largest first)
        polys.sort(key=len, reverse=True)
        
        if name not in countries:
            countries[name] = []
        
        for i, poly_coords in enumerate(polys):
            # Skip tiny islands (except for small island nations)
            if len(poly_coords) < 6 and i > 0:
                continue
            
            suffix = "" if i == 0 else f"_{i+1}"
            countries[name].append((f"{const_name}{suffix}", poly_coords))
    
    # Write Rust file
    with open("src/continents.rs", "w") as f:
        f.write("// Natural Earth 110m country outlines (simplified)\n")
        f.write("// Auto-generated from ne_110m_admin_0_countries.geojson\n")
        f.write("// Public domain - https://www.naturalearthdata.com/\n\n")
        
        all_consts = []
        
        for name in sorted(countries.keys()):
            for const_name, coords in countries[name]:
                f.write(f"pub const {const_name}: &[(f32, f32)] = &[\n")
                for lon, lat in coords:
                    f.write(f"    ({lon:.1f}, {lat:.1f}),\n")
                f.write("];\n\n")
                all_consts.append(const_name)
        
        # Write ALL_LANDMASSES array
        f.write("pub const ALL_LANDMASSES: &[&[(f32, f32)]] = &[\n")
        for const_name in sorted(all_consts):
            f.write(f"    {const_name},\n")
        f.write("];\n")
    
    print(f"Generated src/continents.rs with {len(all_consts)} landmasses from {len(countries)} countries")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate RON files for each region from Natural Earth GeoJSON."""

import json
import urllib.request
import os

def fetch_geojson(url):
    with urllib.request.urlopen(url) as response:
        return json.loads(response.read().decode())

def simplify_line(coords, tolerance=0.6):
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

def write_ron(filepath, coords):
    """Write coordinates to a RON file."""
    with open(filepath, 'w') as f:
        f.write("[\n")
        for i, (lon, lat) in enumerate(coords):
            comma = "," if i < len(coords) - 1 else ""
            f.write(f"    ({lon:.2f}, {lat:.2f}){comma}\n")
        f.write("]\n")

def main():
    url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson"
    print("Fetching Natural Earth data...")
    data = fetch_geojson(url)
    
    # Create regions directory
    regions_dir = "assets/regions"
    os.makedirs(regions_dir, exist_ok=True)
    
    # Clear existing RON files
    for f in os.listdir(regions_dir):
        if f.endswith('.ron'):
            os.remove(os.path.join(regions_dir, f))
    
    # Countries to include - comprehensive list
    include_list = {
        # North America
        "United States of America": "usa",
        "Canada": "canada",
        "Mexico": "mexico",
        "Guatemala": "guatemala",
        "Honduras": "honduras",
        "Nicaragua": "nicaragua",
        "Costa Rica": "costa_rica",
        "Panama": "panama",
        "Cuba": "cuba",
        "Dominican Rep.": "dominican_rep",
        "Haiti": "haiti",
        "Jamaica": "jamaica",
        "Puerto Rico": "puerto_rico",
        "The Bahamas": "bahamas",
        "Belize": "belize",
        "El Salvador": "el_salvador",
        
        # South America
        "Brazil": "brazil",
        "Argentina": "argentina",
        "Chile": "chile",
        "Colombia": "colombia",
        "Peru": "peru",
        "Venezuela": "venezuela",
        "Ecuador": "ecuador",
        "Bolivia": "bolivia",
        "Paraguay": "paraguay",
        "Uruguay": "uruguay",
        "Guyana": "guyana",
        "Suriname": "suriname",
        "French Guiana": "french_guiana",
        "Falkland Is.": "falkland_islands",
        "Trinidad and Tobago": "trinidad",
        
        # Europe
        "United Kingdom": "uk",
        "France": "france",
        "Spain": "spain",
        "Italy": "italy",
        "Germany": "germany",
        "Poland": "poland",
        "Ukraine": "ukraine",
        "Norway": "norway",
        "Sweden": "sweden",
        "Finland": "finland",
        "Ireland": "ireland",
        "Portugal": "portugal",
        "Belgium": "belgium",
        "Netherlands": "netherlands",
        "Austria": "austria",
        "Czech Rep.": "czech_rep",
        "Hungary": "hungary",
        "Romania": "romania",
        "Bulgaria": "bulgaria",
        "Greece": "greece",
        "Belarus": "belarus",
        "Lithuania": "lithuania",
        "Latvia": "latvia",
        "Estonia": "estonia",
        "Serbia": "serbia",
        "Croatia": "croatia",
        "Bosnia and Herz.": "bosnia",
        "Slovenia": "slovenia",
        "Slovakia": "slovakia",
        "North Macedonia": "north_macedonia",
        "Albania": "albania",
        "Montenegro": "montenegro",
        "Moldova": "moldova",
        "Kosovo": "kosovo",
        "Switzerland": "switzerland",
        "Denmark": "denmark",
        "Iceland": "iceland",
        "Greenland": "greenland",
        
        # Africa
        "Egypt": "egypt",
        "Libya": "libya",
        "Algeria": "algeria",
        "Sudan": "sudan",
        "South Africa": "south_africa",
        "Nigeria": "nigeria",
        "Dem. Rep. Congo": "dr_congo",
        "Morocco": "morocco",
        "Tunisia": "tunisia",
        "Kenya": "kenya",
        "Tanzania": "tanzania",
        "Ethiopia": "ethiopia",
        "Somalia": "somalia",
        "Mozambique": "mozambique",
        "Namibia": "namibia",
        "Botswana": "botswana",
        "Zimbabwe": "zimbabwe",
        "Zambia": "zambia",
        "Angola": "angola",
        "Central African Rep.": "central_african_rep",
        "Cameroon": "cameroon",
        "Chad": "chad",
        "Niger": "niger",
        "Mali": "mali",
        "Mauritania": "mauritania",
        "Gabon": "gabon",
        "Congo": "congo",
        "Eq. Guinea": "eq_guinea",
        "Benin": "benin",
        "Togo": "togo",
        "Ghana": "ghana",
        "Côte d'Ivoire": "ivory_coast",
        "Liberia": "liberia",
        "Sierra Leone": "sierra_leone",
        "Guinea": "guinea",
        "Guinea-Bissau": "guinea_bissau",
        "Senegal": "senegal",
        "Gambia": "gambia",
        "Burkina Faso": "burkina_faso",
        "Malawi": "malawi",
        "Burundi": "burundi",
        "Rwanda": "rwanda",
        "Uganda": "uganda",
        "South Sudan": "south_sudan",
        "Eritrea": "eritrea",
        "Djibouti": "djibouti",
        "W. Sahara": "western_sahara",
        "Madagascar": "madagascar",
        "Lesotho": "lesotho",
        "eSwatini": "eswatini",
        
        # Asia
        "Russia": "russia",
        "China": "china",
        "India": "india",
        "Indonesia": "indonesia",
        "Japan": "japan",
        "Philippines": "philippines",
        "Saudi Arabia": "saudi_arabia",
        "Iran": "iran",
        "Turkey": "turkey",
        "Kazakhstan": "kazakhstan",
        "Mongolia": "mongolia",
        "Pakistan": "pakistan",
        "Thailand": "thailand",
        "Vietnam": "vietnam",
        "Myanmar": "myanmar",
        "Malaysia": "malaysia",
        "Afghanistan": "afghanistan",
        "Iraq": "iraq",
        "Syria": "syria",
        "Jordan": "jordan",
        "Israel": "israel",
        "Yemen": "yemen",
        "Oman": "oman",
        "United Arab Emirates": "uae",
        "Bangladesh": "bangladesh",
        "Nepal": "nepal",
        "Sri Lanka": "sri_lanka",
        "Laos": "laos",
        "Cambodia": "cambodia",
        "North Korea": "north_korea",
        "South Korea": "south_korea",
        "Taiwan": "taiwan",
        "Turkmenistan": "turkmenistan",
        "Uzbekistan": "uzbekistan",
        "Tajikistan": "tajikistan",
        "Kyrgyzstan": "kyrgyzstan",
        "Azerbaijan": "azerbaijan",
        "Georgia": "georgia",
        "Armenia": "armenia",
        "Kuwait": "kuwait",
        "Qatar": "qatar",
        "Bahrain": "bahrain",
        "Lebanon": "lebanon",
        "Bhutan": "bhutan",
        "Brunei": "brunei",
        "Timor-Leste": "timor_leste",
        
        # Oceania
        "Australia": "australia",
        "Papua New Guinea": "papua_new_guinea",
        "New Zealand": "new_zealand",
        "Fiji": "fiji",
        "Solomon Is.": "solomon_islands",
        "Vanuatu": "vanuatu",
        "New Caledonia": "new_caledonia",
        
        # Antarctica
        "Antarctica": "antarctica",
    }
    
    region_count = 0
    
    for feature in data["features"]:
        props = feature.get("properties", {})
        name = props.get("ADMIN") or props.get("NAME") or props.get("name")
        
        if name not in include_list:
            continue
        
        base_name = include_list[name]
        geom = feature["geometry"]
        coords = geom["coordinates"]
        
        if geom["type"] == "Polygon":
            polygons = [coords]
        else:  # MultiPolygon
            polygons = coords
        
        # Process all polygons for this country
        country_polys = []
        for poly in polygons:
            exterior = poly[0] if isinstance(poly[0][0], list) else poly
            if len(exterior) >= 4:
                simplified = simplify_line(exterior, tolerance=0.5)
                if len(simplified) >= 4:
                    country_polys.append(simplified)
        
        # Sort by size (largest first)
        country_polys.sort(key=len, reverse=True)
        
        for i, poly_coords in enumerate(country_polys):
            # Skip very small polygons
            if len(poly_coords) < 6 and i > 0:
                continue
            
            if i == 0:
                filename = f"{base_name}.ron"
            else:
                filename = f"{base_name}_{i+1}.ron"
            
            filepath = os.path.join(regions_dir, filename)
            write_ron(filepath, poly_coords)
            region_count += 1
    
    print(f"Generated {region_count} region files in {regions_dir}/")
    
    # List files by size
    files = os.listdir(regions_dir)
    files.sort()
    print(f"\nFiles: {len(files)}")

if __name__ == "__main__":
    main()

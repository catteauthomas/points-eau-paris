#!/usr/bin/env python3
"""Récupère tous les points d'eau potable publics de Paris et les écrit dans un seul fichier JSON.

Sources (la source officielle d'abord, OpenStreetMap seulement en complément) :
  1. Open Data Paris « fontaines-a-boire » (Eau de Paris) : fontaines de rue et de parc
     + carte officielle d'Eau de Paris (fontaine.eaudeparis.fr, serveur WFS mis à jour chaque matin) : l'état du jour de
       chaque fontaine, dont les fermetures d'hiver (gel), que l'Open Data ne voit pas
  2. Open Data GPSO « bornes-fontaines » : bornes-fontaines de Boulogne-Billancourt, avec leur état
  3. OpenStreetMap (Overpass) : amenity=drinking_water dans Paris et les communes voisines, sans les doublons des
     fontaines officielles
  + Open Data Paris « arrondissements » : contours officiels, pour ranger chaque point OSM dans son arrondissement
  + API Géo (geo.api.gouv.fr) : contours officiels des communes voisines entre Paris et la Seine (Boulogne-Billancourt,
    Neuilly-sur-Seine, Levallois-Perret, Clichy, Saint-Ouen-sur-Seine)

Chaque fontaine reçoit « ar » (arrondissement 1-20, 0 = hors Paris, par ex. les cimetières parisiens de Thiais ou
Pantin), « com » (commune voisine, pour les points hors Paris situés dans l'une d'elles) et « pts » (points gagnés dans le jeu quand on la prend en photo sur place, selon sa rareté).
« fermeNuit » marque les points inaccessibles la nuit : fontaines d'un square, parc, jardin ou cimetière, points OSM avec
des horaires limités. « gel » marque les fontaines coupées pour l'hiver (risque de gel). Les commerces partenaires ne sont plus repris (fermés la nuit : l'appli doit marcher à 3 h du matin).

Sorties :
  docs/data/points.json   servi par GitHub Pages, téléchargé par l'appli
  docs/data/meta.json     date et nombre de points par source
  ios/PointsEau/points.json   copie embarquée dans l'appli (marche sans réseau)

Garde-fou : une source qui renvoie une page d'erreur ou beaucoup moins de points que d'habitude est considérée comme
ratée. On garde alors ses points de la dernière récupération réussie (si elle existe), sinon le script échoue.

Compatible Python 3.9, bibliothèque standard uniquement. Usage : python3 scraper/scrape.py
"""
import datetime as dt
import gzip
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SORTIES = [os.path.join(RACINE, "docs", "data", "points.json"), os.path.join(RACINE, "ios", "PointsEau", "points.json")]
META = os.path.join(RACINE, "docs", "data", "meta.json")

OPENDATA = "https://opendata.paris.fr/api/explore/v2.1/catalog/datasets/"
OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
AGENT = "points-eau-paris/1.0"
# Serveur de la carte officielle d'Eau de Paris (fontaine.eaudeparis.fr, fichier apps/default.json : url_data_edp)
EDP_WFS = ("https://edp.jdev.fr/geoserver/edp/ows?service=WFS&version=1.0.0&request=GetFeature"
           "&typeName=edp%3A{couche}&outputFormat=application%2Fjson")
GPSO = "https://data.seineouest.fr/api/explore/v2.1/catalog/datasets/bornes-fontaines/exports/json"
GEO_API = "https://geo.api.gouv.fr/communes/{code}?format=geojson&geometry=contour&fields=nom,code"

# Communes entre Paris et la Seine (côté ouest et nord, dans la boucle du fleuve) : leurs points d'eau sont ajoutés
VOISINES = {
    "92012": "Boulogne-Billancourt",
    "92051": "Neuilly-sur-Seine",
    "92044": "Levallois-Perret",
    "92024": "Clichy",
    "93070": "Saint-Ouen-sur-Seine",
}

# Nombre minimal de points pour qu'une récupération soit jugée réussie (environ 80 % des volumes de novembre 2026)
MINIMUM = {"fontaines": 1050, "osm": 1100, "gpso": 40}
# Sources secondaires : si elles échouent sans récupération précédente, on continue sans elles
OPTIONNELLES = ("gpso",)

# Fontaines officielles dont l'adresse est un lieu fermé la nuit
LIEUX_FERMES_LA_NUIT = ("SQUARE", "JARDIN", "PARC", "CIMETIERE")
OUVERTS_LA_NUIT = ("PARC DE LA VILLETTE",)


def ferme_la_nuit(voie):
    v = " ".join((voie or "").upper().split())
    return v.startswith(LIEUX_FERMES_LA_NUIT) and not v.startswith(OUVERTS_LA_NUIT)


def horaires_24h(h):
    h = (h or "").replace(" ", "")
    return not h or "24/7" in h or "00:00-24:00" in h or "00:00-00:00" in h or "00:00-23:59" in h

# Paris intra-muros avec les bois de Boulogne et de Vincennes, et les communes voisines (Saint-Ouen monte à 48,923)
BBOX = (48.80, 2.20, 48.93, 2.48)
# Les fontaines Eau de Paris des cimetières parisiens hors Paris (Thiais, Pantin, Bagneux…) restent dans ce cadre
BBOX_LARGE = (48.70, 2.10, 49.00, 2.60)

DOUBLON_M = 25  # un point OSM à moins de 25 m d'une fontaine officielle est la même fontaine

TYPES = {
    "FONTNE_WALLACE": "Fontaine Wallace",
    "FONTAINE_ARCEAU": "Fontaine Arceau",
    "FTNE_PETILLANTE": "Fontaine pétillante",
    "FONTAINE_2EN1": "Fontaine 2 en 1",
    "FONTAINE_BOIS": "Fontaine à boire",
    "BORNE_FONTAINE": "Borne-fontaine",
    "FONTAINE_TOTEM": "Fontaine Totem",
    "FONTAINE_ALBIEN": "Fontaine à l'albien",
    "FTNE_MILLENAIRE": "Fontaine du Millénaire",
    "FTNE_POING_EAU": "Fontaine Poing d'eau",
}

# Points du jeu selon la rareté du type (nombre de fontaines de ce type à Paris entre parenthèses)
POINTS = {
    "Fontaine à boire": 10,        # (~930) la plus courante
    "Borne-fontaine": 10,          # (~40)
    "Fontaine 2 en 1": 15,         # (~100) boire + brumiser
    "Fontaine Arceau": 15,         # (~50)
    "Fontaine Totem": 15,          # (~10)
    "Fontaine Wallace": 20,        # (~160) l'emblème de Paris
    "Fontaine Poing d'eau": 40,    # (5)
    "Fontaine pétillante": 50,     # (17) eau plate et gazeuse
    "Fontaine du Millénaire": 75,  # (3)
    "Fontaine à l'albien": 100,    # (3) eau de la nappe de l'Albien, à 600 m sous terre
}
POINTS_DEFAUT = 10

MOTIFS = {
    "APP A RENOUVELER": "À remplacer",
    "APP A REPARER": "En panne",
    "APP SANS EAU": "Sans eau",
    "APP SUR CHANTIER": "Dans un chantier",
    "FERME DEMANDE SSQ": "Fermée",
    "FERME DEMANDE TIERS": "Fermée",
    "FERMETURE HIVERNALE": "Coupée pour l'hiver (gel)",
    "INACCESSIBLE": "Inaccessible",
}


class Rate(Exception):
    pass


def telecharger(url, donnees=None, essais=3, delai=60):
    """GET (ou POST si donnees) qui renvoie du JSON décodé ; lève Rate si la réponse n'est pas du JSON."""
    derniere = None
    for n in range(essais):
        try:
            corps = None if donnees is None else urllib.parse.urlencode(donnees).encode()
            req = urllib.request.Request(url, data=corps, headers={"User-Agent": AGENT, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=delai) as r:
                brut = r.read()
            if brut[:2] == b"\x1f\x8b":
                brut = gzip.decompress(brut)
            try:
                return json.loads(brut.decode("utf-8"))
            except ValueError:
                raise Rate("réponse qui n'est pas du JSON (page d'erreur ?) : " + brut[:120].decode("utf-8", "replace"))
        except (urllib.error.URLError, TimeoutError, OSError, Rate) as e:
            derniere = e
            if n < essais - 1:
                time.sleep(10 * (n + 1))
    raise Rate(str(derniere))


def dans_cadre(lat, lon):
    return BBOX[0] <= lat <= BBOX[2] and BBOX[1] <= lon <= BBOX[3]


MOIS = {"janvier": 1, "fevrier": 2, "février": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6, "juillet": 7,
        "aout": 8, "août": 8, "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12, "décembre": 12}


def date_iso(texte):
    """« 06/11/2026 » ou « Lundi 23 Novembre 2026 à 06:15 » → « 2026-11-06 » ; « » si illisible."""
    t = (texte or "").strip()
    if len(t) >= 10 and t[2] == "/" and t[5] == "/":
        return f"{t[6:10]}-{t[3:5]}-{t[0:2]}"
    mots = t.lower().split()
    for i, m in enumerate(mots):
        if m in MOIS and i >= 1 and i + 1 < len(mots) and mots[i - 1].isdigit() and mots[i + 1].isdigit():
            return f"{mots[i + 1]}-{MOIS[m]:02d}-{int(mots[i - 1]):02d}"
    return ""


def date_jeu(slug):
    """Date de dernière mise à jour du jeu de données Open Data (AAAA-MM-JJ)."""
    try:
        m = telecharger(OPENDATA + slug)["metas"]["default"]
        return (m.get("data_processed") or m.get("modified") or "")[:10]
    except (Rate, KeyError, TypeError):
        return ""


def coord(x):
    return round(float(x), 6)


def arrondissement_commune(commune):
    """« PARIS 14EME ARRONDISSEMENT » → 14, « PARIS 1ER ARRONDISSEMENT » → 1, autre commune → 0."""
    c = (commune or "").upper()
    if not c.startswith("PARIS"):
        return 0
    chiffres = "".join(ch for ch in c.split("ARR")[0] if ch.isdigit())
    return int(chiffres) if chiffres and 1 <= int(chiffres) <= 20 else 0


def contours_voisines():
    """[(nom, anneau de (lon, lat))] des communes voisines, depuis l'API Géo officielle ; [] si l'une manque."""
    contours = []
    for code, nom in VOISINES.items():
        try:
            g = telecharger(GEO_API.format(code=code))["geometry"]
        except (Rate, KeyError, TypeError):
            return []
        polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
        for poly in polys:
            contours.append((nom, poly[0]))
    return contours


def commune_point(lat, lon, voisines):
    for nom, anneau in voisines:
        if dans_polygone(lon, lat, anneau):
            return nom
    return None


def contours_arrondissements():
    """[(numéro, [anneaux de (lon, lat)])] depuis le jeu officiel « arrondissements »."""
    try:
        d = telecharger(OPENDATA + "arrondissements/exports/geojson")
        contours = []
        for f in d["features"]:
            g = f["geometry"]
            polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
            for poly in polys:
                contours.append((int(f["properties"]["c_ar"]), poly[0]))
        return contours if len(contours) >= 20 else []
    except (Rate, KeyError, TypeError, ValueError):
        return []


def dans_polygone(lon, lat, anneau):
    dedans = False
    j = len(anneau) - 1
    for i in range(len(anneau)):
        xi, yi = anneau[i][0], anneau[i][1]
        xj, yj = anneau[j][0], anneau[j][1]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / ((yj - yi) or 1e-12) + xi:
            dedans = not dedans
        j = i
    return dedans


def arrondissement_point(lat, lon, contours):
    for num, anneau in contours:
        if dans_polygone(lon, lat, anneau):
            return num
    return 0


def fontaines():
    lignes = telecharger(OPENDATA + "fontaines-a-boire/exports/json")
    if not isinstance(lignes, list):
        raise Rate("format inattendu")
    points = []
    for f in lignes:
        g = f.get("geo_point_2d") or {}
        if g.get("lat") is None or g.get("lon") is None:
            continue
        lat, lon = coord(g["lat"]), coord(g["lon"])
        if not (BBOX_LARGE[0] <= lat <= BBOX_LARGE[2] and BBOX_LARGE[1] <= lon <= BBOX_LARGE[3]):
            continue
        code = f.get("type_objet") or ""
        modele = f.get("modele") or ""
        nom = TYPES.get(code, "Fontaine à boire")
        if "Wallace" in modele:
            nom = "Fontaine Wallace"
        p = {"id": "f" + str(f.get("gid")), "src": "fontaine",
             "cat": "petillante" if code == "FTNE_PETILLANTE" else "fontaine",
             "lat": lat, "lon": lon, "type": nom, "ok": True,
             "ar": arrondissement_commune(f.get("commune")), "pts": POINTS.get(nom, POINTS_DEFAUT)}
        if ferme_la_nuit(f.get("voie")):
            p["fermeNuit"] = True
        appliquer_etat(p, f.get("dispo"), f.get("motif_ind"), (f.get("fin_ind") or "")[:10])
        points.append(p)
    return points


# Codes de la carte Eau de Paris absents de l'Open Data (le même modèle en version « 2 en 1 »)
TYPES_EDP = {"FTNE_MAT_SOURCE_2EN1": "Fontaine 2 en 1", "FONTAINE_TOTEM_2EN1": "Fontaine 2 en 1",
             "FONTNE_WALLACE_2EN1": "Fontaine Wallace"}


def etats_eau_de_paris():
    """({gid: propriétés}, date « AAAA-MM-JJ ») depuis la carte officielle d'Eau de Paris, mise à jour chaque matin.
    Bien plus fraîche que l'Open Data : c'est elle qui montre les centaines de fontaines coupées pour l'hiver."""
    d = telecharger(EDP_WFS.format(couche="fontaines"), delai=90)
    feats = d.get("features") if isinstance(d, dict) else None
    if not isinstance(feats, list) or len(feats) < MINIMUM["fontaines"]:
        raise Rate(f"seulement {len(feats or [])} fontaines (minimum {MINIMUM['fontaines']})")
    etats = {}
    for f in feats:
        pr = f.get("properties") or {}
        if pr.get("gid") is not None:
            etats[str(pr["gid"])] = pr
    maj = ""
    try:
        maj = date_iso(telecharger(EDP_WFS.format(couche="fontaines_maj"))["features"][0]["properties"]["datemaj"])
    except (Rate, KeyError, IndexError, TypeError):
        pass
    return etats, maj or dt.date.today().isoformat()


def appliquer_etat(p, dispo, motif_code, fin):
    """Écrit l'état (en service ou non, motif, date de retour, coupure d'hiver) sur un point officiel."""
    for k in ("motif", "retour", "gel"):
        p.pop(k, None)
    p["ok"] = (dispo or "").upper() != "NON"
    if not p["ok"]:
        p["motif"] = MOTIFS.get(motif_code or "", "Hors service")
        if motif_code == "FERMETURE HIVERNALE":
            p["gel"] = True
        if fin and fin >= dt.date.today().isoformat():  # une date de retour déjà passée n'apprend rien
            p["retour"] = fin


def appliquer_etats(points, etats):
    """Met l'état du jour de la carte Eau de Paris sur les fontaines officielles et ajoute celles qui viennent d'être
    créées (pas encore dans l'Open Data). Renvoie le nombre de fontaines ajoutées."""
    vus = set()
    for p in points:
        e = etats.get(p["id"][1:])
        if e:
            vus.add(p["id"][1:])
            appliquer_etat(p, e.get("dispo"), e.get("motif_ind"), date_iso(e.get("fin_ind")))
    ajouts = 0
    for gid, e in etats.items():
        if gid in vus or e.get("latitude") is None or e.get("longitude") is None:
            continue
        lat, lon = coord(e["latitude"]), coord(e["longitude"])
        if not (BBOX_LARGE[0] <= lat <= BBOX_LARGE[2] and BBOX_LARGE[1] <= lon <= BBOX_LARGE[3]):
            continue
        code = e.get("type_objet") or ""
        nom = TYPES_EDP.get(code) or TYPES.get(code, "Fontaine à boire")
        p = {"id": "f" + gid, "src": "fontaine", "cat": "petillante" if code == "FTNE_PETILLANTE" else "fontaine",
             "lat": lat, "lon": lon, "type": nom, "ok": True,
             "ar": arrondissement_commune(e.get("nom_commun")), "pts": POINTS.get(nom, POINTS_DEFAUT)}
        if ferme_la_nuit(e.get("nom_voie")):
            p["fermeNuit"] = True
        appliquer_etat(p, e.get("dispo"), e.get("motif_ind"), date_iso(e.get("fin_ind")))
        points.append(p)
        ajouts += 1
    return ajouts


def gpso():
    """Bornes-fontaines de Boulogne-Billancourt (Grand Paris Seine Ouest, Licence Ouverte), avec leur état."""
    lignes = telecharger(GPSO)
    if not isinstance(lignes, list):
        raise Rate("format inattendu")
    points = []
    for f in lignes:
        if str(f.get("code_insee") or "") != "92012" and (f.get("commune") or "").upper() != "BOULOGNE-BILLANCOURT":
            continue
        g = f.get("geo_point_2d") or {}
        if g.get("lat") is None or g.get("lon") is None or not f.get("id_fontaine"):
            continue
        p = {"id": "g" + str(f["id_fontaine"]), "src": "gpso", "cat": "fontaine",
             "lat": coord(g["lat"]), "lon": coord(g["lon"]), "type": "Borne-fontaine", "ok": True,
             "ar": 0, "com": "Boulogne-Billancourt", "pts": POINTS["Borne-fontaine"]}
        if ferme_la_nuit(f.get("localisation")):
            p["fermeNuit"] = True
        if (f.get("en_service") or "").strip().lower() == "non":
            p["ok"] = False
            p["motif"] = "Hors service"
        points.append(p)
    return points


# Requête par cadre (bien plus légère pour les serveurs que la recherche par zone) ; les points hors des 20
# arrondissements sont ensuite écartés grâce aux contours officiels.
REQUETE_OSM = """[out:json][timeout:90];
(
  nwr["amenity"="drinking_water"]({b});
  nwr["drinking_water"="yes"]["amenity"!="drinking_water"]({b});
);
out center tags;""".format(b=",".join(str(x) for x in BBOX))


def osm(contours, voisines):
    derniere = None
    for serveur in OVERPASS:
        try:
            r = telecharger(serveur, {"data": REQUETE_OSM}, essais=4, delai=120)
            elements = r.get("elements")
            if isinstance(elements, list) and elements:
                break
            derniere = Rate("réponse vide de " + serveur)
        except Rate as e:
            derniere = e
    else:
        raise Rate(str(derniere))
    points = []
    for e in elements:
        t = e.get("tags") or {}
        lat = e.get("lat", (e.get("center") or {}).get("lat"))
        lon = e.get("lon", (e.get("center") or {}).get("lon"))
        if lat is None or lon is None:
            continue
        if t.get("drinking_water") == "no" or t.get("access") in ("private", "no", "customers"):
            continue
        if any(k in t for k in ("disused:amenity", "abandoned:amenity")) or t.get("disused") == "yes":
            continue
        lat, lon = coord(lat), coord(lon)
        if not dans_cadre(lat, lon):
            continue
        if t.get("fountain") == "wallace" or "wallace" in (t.get("name") or "").lower():
            nom = "Fontaine Wallace"
        elif t.get("amenity") == "toilets":
            nom = "Sanisette avec robinet"
        elif t.get("man_made") == "water_tap" or t.get("amenity") == "water_point":
            nom = "Robinet d'eau potable"
        elif t.get("fountain") == "bubbler" or t.get("amenity") == "drinking_water":
            nom = "Fontaine à boire"
        elif t.get("amenity") == "fountain":
            nom = "Fontaine (eau potable)"
        else:
            nom = "Point d'eau potable"
        ar = arrondissement_point(lat, lon, contours)
        com = commune_point(lat, lon, voisines) if ar == 0 else None
        if contours and ar == 0 and not com:  # dans le cadre mais ni à Paris ni dans une commune voisine (Montreuil…)
            continue
        p = {"id": "o" + e["type"][0] + str(e["id"]), "src": "osm", "cat": "fontaine",
             "lat": lat, "lon": lon, "type": nom, "ok": True, "ar": ar, "pts": POINTS.get(nom, POINTS_DEFAUT)}
        if com:
            p["com"] = com
        if t.get("opening_hours"):
            p["horaires"] = t["opening_hours"][:80]
            if not horaires_24h(t["opening_hours"]):
                p["fermeNuit"] = True
        if t.get("seasonal") not in (None, "no"):
            p["saison"] = True
        points.append(p)
    return points


def distance_m(a, b):
    """Distance en mètres (approximation plane, très précise à l'échelle de Paris)."""
    k = math.cos(math.radians((a["lat"] + b["lat"]) / 2))
    dx = (a["lon"] - b["lon"]) * 111320 * k
    dy = (a["lat"] - b["lat"]) * 110574
    return math.hypot(dx, dy)


def sans_doublons(osm_points, officiels):
    """Enlève les points OSM qui sont des fontaines déjà présentes dans le jeu officiel (grille de 0,001°)."""
    grille = {}
    for p in officiels:
        grille.setdefault((int(p["lat"] * 1000), int(p["lon"] * 1000)), []).append(p)
    gardes = []
    for p in osm_points:
        i, j = int(p["lat"] * 1000), int(p["lon"] * 1000)
        proches = [q for di in (-1, 0, 1) for dj in (-1, 0, 1) for q in grille.get((i + di, j + dj), [])]
        if not any(distance_m(p, q) < DOUBLON_M for q in proches):
            gardes.append(p)
    return gardes


def precedent():
    try:
        with open(SORTIES[0], encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main():
    ancien = precedent()
    anciens_points = (ancien or {}).get("points", [])
    anciennes_dates = (ancien or {}).get("sources", {})
    sources, resultats, alertes = {}, {}, []


    contours = contours_arrondissements()
    if not contours:
        alertes.append("contours des arrondissements indisponibles : les points OSM sont classés « hors Paris »")
    voisines = contours_voisines()
    if not voisines:
        alertes.append("contours des communes voisines indisponibles : on garde leurs points OSM précédents")
    for cle, fonction, src in (("fontaines", fontaines, "fontaine"), ("gpso", gpso, "gpso"),
                               ("osm", lambda: osm(contours, voisines), "osm")):
        try:
            pts = fonction()
            if len(pts) < MINIMUM[cle]:
                raise Rate(f"seulement {len(pts)} points (minimum {MINIMUM[cle]})")
            resultats[cle] = pts
            sources[cle] = {"date": dt.date.today().isoformat(), "points": len(pts)}
        except Rate as e:
            garde = [p for p in anciens_points if p.get("src") == src]
            if not garde and cle not in OPTIONNELLES:
                print(f"ÉCHEC {cle} : {e} (et aucune récupération précédente à garder)", file=sys.stderr)
                sys.exit(1)
            alertes.append(f"{cle} : {e} → on garde les {len(garde)} points de la dernière récupération réussie")
            resultats[cle] = garde
            sources[cle] = dict(anciennes_dates.get(cle, {}), points=len(garde), garde=True)

    # État du jour des fontaines officielles : carte Eau de Paris (sinon celui de l'Open Data, moins frais)
    try:
        etats, maj_etats = etats_eau_de_paris()
        ajouts = appliquer_etats(resultats["fontaines"], etats)
        sources["fontaines"]["maj"] = maj_etats
        sources["fontaines"]["etat"] = "carte Eau de Paris"
        sources["fontaines"]["points"] = len(resultats["fontaines"])
        if ajouts:
            sources["fontaines"]["nouvelles"] = ajouts
    except Rate as e:
        alertes.append(f"état du jour Eau de Paris : {e} → états de l'Open Data (moins frais, sans les coupures d'hiver)")
        # Date officielle du jeu Open Data (celle qu'on affiche dans l'appli)
        if not sources["fontaines"].get("garde"):
            d = date_jeu("fontaines-a-boire")
            if d:
                sources["fontaines"]["maj"] = d

    # Fontaines officielles hors Paris situées dans une commune voisine (cimetière parisien de Saint-Ouen)
    if voisines:
        for p in resultats["fontaines"]:
            if p.get("ar") == 0:
                c = commune_point(p["lat"], p["lon"], voisines)
                if c:
                    p["com"] = c

    brut_osm = len(resultats["osm"])
    if not sources["osm"].get("garde"):
        resultats["osm"] = sans_doublons(resultats["osm"], resultats["fontaines"] + resultats["gpso"])
        if not voisines:
            resultats["osm"] += [p for p in anciens_points if p.get("src") == "osm" and p.get("com")]
        sources["osm"]["points"] = len(resultats["osm"])
        sources["osm"]["avant_dedoublonnage"] = brut_osm

    points = resultats["fontaines"] + resultats["gpso"] + resultats["osm"]
    points.sort(key=lambda p: p["id"])
    sortie = {
        "version": 1,
        "genere": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "credits": ("Eau de Paris / Ville de Paris (ODbL) · Grand Paris Seine Ouest (Licence Ouverte) · "
                    "© contributeurs OpenStreetMap (ODbL)"),
        "points": points,
    }

    # On ne réécrit pas les fichiers si les points n'ont pas changé (pas de commit inutile chaque jour)
    if ancien and ancien.get("points") == points:
        print("Données identiques à la dernière récupération, rien à écrire.")
    else:
        texte = json.dumps(sortie, ensure_ascii=False, separators=(",", ":"))
        for chemin in SORTIES:
            os.makedirs(os.path.dirname(chemin), exist_ok=True)
            tmp = chemin + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(texte)
            os.replace(tmp, chemin)
        meta = {"genere": sortie["genere"], "sources": sources, "total": len(points)}
        with open(META, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"Écrit : {len(points)} points ({len(texte) // 1024} Ko)")

    hs = sum(1 for p in resultats["fontaines"] if not p["ok"])
    gel = sum(1 for p in resultats["fontaines"] if p.get("gel"))
    print(f"  fontaines officielles : {len(resultats['fontaines'])} (dont {hs} hors service, {gel} coupées pour l'hiver)")
    print(f"  Boulogne (GPSO)       : {len(resultats['gpso'])}")
    print(f"  fermés la nuit        : {sum(1 for p in points if p.get('fermeNuit'))}")
    print(f"  OpenStreetMap         : {len(resultats['osm'])} ajoutés (sur {brut_osm} avant dédoublonnage)")
    for nom in VOISINES.values():
        print(f"  {nom:<22}: {sum(1 for p in points if p.get('com') == nom)}")
    for a in alertes:
        print("::warning::" + a)


if __name__ == "__main__":
    main()

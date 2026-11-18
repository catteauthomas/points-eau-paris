#!/usr/bin/env python3
"""App Store Connect pour l'appli Fontaines (points d'eau de Paris), par l'API (clé d'équipe de Titouan).

Variables d'environnement : ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contenu du fichier .p8).
Facultative : TESTER_EMAIL (par défaut thomas.c@tteau.com, utilisateur App Store Connect de l'équipe).

Usage : python3 scripts/asc.py <commande>
  check    vérifie la clé et liste les applis du compte
  bundle   enregistre l'identifiant com.catteauthomas.pointseau (App ID)
  interne  groupe TestFlight interne « Interne » (accès à tous les builds) + le testeur, puis état des builds
L'API ne sait pas créer la fiche de l'appli : elle se crée dans App Store Connect (Apps → +).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

BUNDLE = "com.catteauthomas.pointseau"
NAME = "Fontaines Paris"
API = "https://api.appstoreconnect.apple.com"
TESTER = os.environ.get("TESTER_EMAIL", "thomas.c@tteau.com").strip()


class ApiError(Exception):
    def __init__(self, code, text):
        super().__init__(f"HTTP {code} : {text}")
        self.code = code


_tok = {"exp": 0, "value": ""}


def token():
    now = int(time.time())
    if _tok["exp"] - now < 60:
        _tok["value"] = jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
            os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
        _tok["exp"] = now + 1200
    return _tok["value"]


def call(method, path, body=None, params=None):
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        text = e.read().decode(errors="replace")
        try:
            errs = json.loads(text).get("errors", [])
            text = " | ".join(f"{x.get('title', '')} {x.get('detail', '')}".strip() for x in errs) or text
        except ValueError:
            pass
        raise ApiError(e.code, text)
    return json.loads(raw) if raw else {}


def get(path, **params):
    return call("GET", path, params=params or None)


def create(kind, attributes, relationships):
    return call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": attributes, "relationships": relationships}})["data"]


def rel(kind, id_):
    return {"data": {"type": kind, "id": id_}}


def find_app():
    apps = get("/v1/apps", **{"filter[bundleId]": BUNDLE})["data"]
    return apps[0] if apps else None


def cmd_check():
    for a in get("/v1/apps", limit="50")["data"]:
        print(f"{a['attributes']['name']:<32} {a['attributes']['bundleId']}  ({a['id']})")
    print("\nClé valide." + ("" if find_app() else f"\nPas encore de fiche pour {BUNDLE} : à créer dans App Store Connect."))


def cmd_bundle():
    found = get("/v1/bundleIds", **{"filter[identifier]": BUNDLE})["data"]
    if any(b["attributes"]["identifier"] == BUNDLE for b in found):
        print(f"Identifiant déjà enregistré : {BUNDLE}")
        return
    b = create("bundleIds", {"identifier": BUNDLE, "name": NAME, "platform": "IOS"}, {})
    print(f"Identifiant enregistré : {b['attributes']['identifier']} ({b['id']})")


def cmd_interne():
    app = find_app()
    if not app:
        raise SystemExit(f"Fiche introuvable : crée l'appli dans App Store Connect (Apps → +) avec l'identifiant {BUNDLE}.")
    app_id = app["id"]
    groups = get(f"/v1/apps/{app_id}/betaGroups")["data"]
    g = next((x for x in groups if x["attributes"].get("isInternalGroup")), None)
    if g:
        print(f"Groupe interne existant : {g['attributes']['name']}")
    else:
        g = create("betaGroups", {"name": "Interne", "isInternalGroup": True, "hasAccessToAllBuilds": True},
                   {"app": rel("apps", app_id)})
        print("Groupe interne « Interne » créé (accès à tous les builds)")
    members = get(f"/v1/betaGroups/{g['id']}/betaTesters", limit="200")["data"]
    if any(m["attributes"].get("email", "").lower() == TESTER.lower() for m in members):
        print(f"Testeur déjà dans le groupe : {TESTER}")
    else:
        try:
            create("betaTesters", {"email": TESTER}, {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}})
            print(f"Testeur ajouté : {TESTER} (invitation TestFlight envoyée par Apple)")
        except ApiError as e:
            existing = get("/v1/betaTesters", **{"filter[email]": TESTER})["data"]
            if not existing:
                raise SystemExit(f"Ajout du testeur impossible : {e}. Il doit être utilisateur App Store Connect de l'équipe.")
            call("POST", f"/v1/betaGroups/{g['id']}/relationships/betaTesters",
                 {"data": [{"type": "betaTesters", "id": existing[0]["id"]}]})
            print(f"Testeur existant ajouté au groupe : {TESTER}")
    builds = get("/v1/builds", **{"filter[app]": app_id, "sort": "-uploadedDate", "limit": "5"})["data"]
    if not builds:
        print("Aucun build reçu pour l'instant.")
    for b in builds:
        a = b["attributes"]
        print(f"Build {a['version']} : {a['processingState']} (envoyé le {a['uploadedDate'][:16].replace('T', ' ')})")


def cmd_builds():
    """Lecture seule : état de traitement des 5 derniers builds."""
    app = find_app()
    if not app:
        raise SystemExit(f"Fiche introuvable pour {BUNDLE}.")
    builds = get("/v1/builds", **{"filter[app]": app["id"], "sort": "-uploadedDate", "limit": "5"})["data"]
    if not builds:
        print("Aucun build reçu pour l'instant.")
    for b in builds:
        a = b["attributes"]
        print(f"Build {a['version']} : {a['processingState']} (envoyé le {a['uploadedDate'][:16].replace('T', ' ')})")


def cmd_diag():
    """Lecture seule : relations exposées par l'API pour la fiche (recherche des déclarations App Compliance)."""
    app = find_app()
    print("app :", sorted((app.get("relationships") or {}).keys()))
    for info in get(f"/v1/apps/{app['id']}/appInfos")["data"]:
        print("appInfo", info["id"], info["attributes"].get("state") or info["attributes"].get("appStoreState"))
        print("   relations :", sorted((info.get("relationships") or {}).keys()))
        for k, v in (info.get("relationships") or {}).items():
            if any(w in k.lower() for w in ("compliance", "declar", "ai", "security", "china")):
                print("   ", k, v.get("links"))


if __name__ == "__main__":
    commands = {"check": cmd_check, "bundle": cmd_bundle, "interne": cmd_interne, "builds": cmd_builds, "diag": cmd_diag}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]]()

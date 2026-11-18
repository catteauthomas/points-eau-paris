#!/usr/bin/env python3
"""App Store Connect pour l'appli Fontaines (points d'eau de Paris), par l'API (clé d'équipe de Titouan).

Variables d'environnement : ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contenu du fichier .p8).
Facultative : TESTER_EMAIL (par défaut thomas.c@tteau.com, utilisateur App Store Connect de l'équipe).

Usage : python3 scripts/asc.py <commande>
  check    vérifie la clé et liste les applis du compte
  testflight  testeurs externes : description de test, contact, groupe « Amis » avec lien public, dernier build,
              testeurs de TESTEURS (adresses séparées par des virgules), envoi en vérification bêta
  beta     état de la vérification bêta du dernier build, lien public et testeurs du groupe « Amis » (lecture seule)
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

from pathlib import Path

import jwt

BUNDLE = "com.catteauthomas.pointseau"
NAME = "Fontaines Paris"
API = "https://api.appstoreconnect.apple.com"
TESTER = os.environ.get("TESTER_EMAIL", "thomas.c@tteau.com").strip()
ROOT = Path(__file__).resolve().parent.parent
META = json.loads((ROOT / "appstore" / "metadata.json").read_text(encoding="utf-8"))
PAGES = "https://catteauthomas.github.io/points-eau-paris/"


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


def contact(app_id):
    """Coordonnées de vérification déjà saisies sur la fiche App Store de l'appli (workflow Fiche App Store)."""
    keys = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"]
    for v in get(f"/v1/apps/{app_id}/appStoreVersions", limit="5")["data"]:
        try:
            a = (get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data") or {}).get("attributes") or {}
        except ApiError:
            continue
        if all(a.get(k) for k in keys):
            return {k: a[k] for k in keys}
    raise SystemExit("Coordonnées de vérification introuvables : lance d'abord le workflow Fiche App Store.")


def groupe_amis(app_id):
    groups = get(f"/v1/apps/{app_id}/betaGroups")["data"]
    return next((x for x in groups if x["attributes"]["name"] == META["beta"]["group"]), None)


def dernier_build(app_id):
    b = get("/v1/builds", **{"filter[app]": app_id, "filter[processingState]": "VALID", "sort": "-uploadedDate", "limit": "1"})["data"]
    return b[0] if b else None


def etat_beta(build):
    d = get(f"/v1/builds/{build['id']}/buildBetaDetail")["data"]["attributes"]
    return d.get("externalBuildState") or "?"


def cmd_testflight():
    app = find_app()
    if not app:
        raise SystemExit(f"Fiche introuvable pour {BUNDLE}.")
    app_id, beta = app["id"], META["beta"]
    # Description de test
    attrs = {"description": beta["description"], "feedbackEmail": beta["feedbackEmail"],
             "marketingUrl": PAGES, "privacyPolicyUrl": PAGES + "confidentialite.html"}
    locs = get(f"/v1/apps/{app_id}/betaAppLocalizations")["data"]
    cur = next((l for l in locs if l["attributes"]["locale"].startswith("fr")), None)
    if cur:
        call("PATCH", f"/v1/betaAppLocalizations/{cur['id']}", {"data": {"type": "betaAppLocalizations", "id": cur["id"], "attributes": attrs}})
    else:
        create("betaAppLocalizations", dict(attrs, locale="fr-FR"), {"app": rel("apps", app_id)})
    print("Description de test : ok")
    # Contact pour la vérification bêta
    d = get(f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    call("PATCH", f"/v1/betaAppReviewDetails/{d['id']}", {"data": {"type": "betaAppReviewDetails", "id": d["id"], "attributes": dict(
        contact(app_id), demoAccountRequired=False, notes=META["reviewNotes"])}})
    print("Contact pour la vérification bêta : ok")
    # Dernier build et « À tester »
    b = dernier_build(app_id)
    if not b:
        raise SystemExit("Aucun build traité pour l'instant.")
    blocs = get(f"/v1/builds/{b['id']}/betaBuildLocalizations")["data"]
    cur = next((l for l in blocs if l["attributes"]["locale"].startswith("fr")), None)
    if cur:
        call("PATCH", f"/v1/betaBuildLocalizations/{cur['id']}", {"data": {"type": "betaBuildLocalizations", "id": cur["id"], "attributes": {"whatsNew": beta["whatToTest"]}}})
    else:
        create("betaBuildLocalizations", {"locale": "fr-FR", "whatsNew": beta["whatToTest"]}, {"build": rel("builds", b["id"])})
    print(f"Build {b['attributes']['version']} : « À tester » rempli")
    # Groupe externe avec lien public
    g = groupe_amis(app_id)
    if not g:
        g = create("betaGroups", {"name": beta["group"], "publicLinkEnabled": True, "publicLinkLimitEnabled": False,
                                  "feedbackEnabled": True}, {"app": rel("apps", app_id)})
        print(f"Groupe externe « {beta['group']} » créé")
    call("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
    # Testeurs (Apple leur envoie l'invitation dès que le build est validé pour les testeurs externes)
    for email in [e.strip() for e in os.environ.get("TESTEURS", "").split(",") if e.strip()]:
        try:
            create("betaTesters", {"email": email}, {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}})
            print(f"Testeur ajouté : {email}")
        except ApiError as e:
            existing = get("/v1/betaTesters", **{"filter[email]": email})["data"]
            if not existing:
                raise SystemExit(f"Ajout de {email} impossible : {e}")
            call("POST", f"/v1/betaGroups/{g['id']}/relationships/betaTesters", {"data": [{"type": "betaTesters", "id": existing[0]["id"]}]})
            print(f"Testeur existant ajouté au groupe : {email}")
    # Envoi en vérification bêta
    try:
        create("betaAppReviewSubmissions", {}, {"build": rel("builds", b["id"])})
        print("Build envoyé en vérification bêta (testeurs externes)")
    except ApiError as e:
        if e.code != 409:
            raise
        print(f"Vérification bêta déjà demandée ({str(e)[:120]})")
    cmd_beta()


def cmd_beta():
    """Lecture seule : état de la vérification bêta, lien public, testeurs du groupe externe."""
    app = find_app()
    b = dernier_build(app["id"])
    if b:
        print(f"ETAT_BETA build {b['attributes']['version']} : {etat_beta(b)}")
    g = groupe_amis(app["id"])
    if not g:
        print("Pas encore de groupe externe.")
        return
    g = get(f"/v1/betaGroups/{g['id']}")["data"]
    print(f"LIEN_PUBLIC {g['attributes'].get('publicLink') or '(pas encore actif)'}")
    for t in get(f"/v1/betaGroups/{g['id']}/betaTesters", limit="50")["data"]:
        a = t["attributes"]
        print(f"Testeur {a.get('email')} : {a.get('state') or a.get('inviteType') or ''}")


if __name__ == "__main__":
    commands = {"check": cmd_check, "bundle": cmd_bundle, "interne": cmd_interne, "builds": cmd_builds, "diag": cmd_diag,
                "testflight": cmd_testflight, "beta": cmd_beta}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]]()

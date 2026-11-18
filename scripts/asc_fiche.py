#!/usr/bin/env python3
"""Remplit la fiche App Store de l'appli Fontaines par l'API App Store Connect (repris de Passe le Tel et Biscoto).

Variables d'environnement : ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (obligatoires),
PRIVACY_URL, SUPPORT_URL, BUILD_NUMBER et SUBMIT (facultatives).

Remplit : nom, sous-titre, lien de confidentialité, classification 18+, catégories, droits sur le contenu,
description, mots-clés, texte promotionnel, lien d'assistance, copyright, notes et coordonnées pour la
vérification, prix (gratuite) et disponibilité (tous les pays sauf la Chine continentale, qui exige des déclarations
« App Compliance » impossibles à remplir par l'API), captures d'écran, build.
Avec SUBMIT : envoie la version en vérification, seulement si aucune étape n'a échoué.
L'API ne gère pas la confidentialité de l'app (App Privacy) : elle reste à faire dans App Store Connect.
"""
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import jwt
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
META = json.loads((ROOT / "appstore" / "metadata.json").read_text(encoding="utf-8"))
SHOTS = sorted(p for p in (ROOT / "appstore" / "captures").glob("[0-9]-*.png"))
API = "https://api.appstoreconnect.apple.com"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
PRIVACY_URL = os.environ.get("PRIVACY_URL", "").strip()
SUPPORT_URL = os.environ.get("SUPPORT_URL", "").strip()
SUBMIT = os.environ.get("SUBMIT", "").strip().lower() in ("1", "true", "oui")
BUILD = os.environ.get("BUILD_NUMBER", "").strip()


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


RETRY_WAIT = (5, 15, 30)


def call(method, path, body=None, params=None):
    """Appel avec nouvelles tentatives quand Apple a des ratés (panne d'App Store Connect du 17/11/2026).

    401 : Apple a rejeté la requête avant de la traiter, on peut toujours la rejouer (avec un jeton neuf).
    500-504 et délais dépassés : rejoués seulement pour GET et PATCH, qu'on peut rejouer sans créer de doublon.
    Un POST (création) n'est jamais rejoué après une erreur serveur, car il a peut-être été pris en compte.
    """
    for wait in RETRY_WAIT + (None,):
        try:
            return _call_once(method, path, body, params)
        except ApiError as e:
            again = e.code == 401 or (e.code in (500, 502, 503, 504) and method in ("GET", "PATCH"))
            if wait is None or not again:
                raise
            if e.code == 401:
                _tok["exp"] = 0
            err = e
        except (TimeoutError, urllib.error.URLError) as e:
            if wait is None or method not in ("GET", "PATCH"):
                raise
            err = e
        print(f"   ↻ {method} {path} : {str(err)[:80]} (nouvel essai dans {wait} s)")
        time.sleep(wait)


def _call_once(method, path, body=None, params=None):
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
            parts = []
            for x in errs:
                parts.append(f"{x.get('title', '')} {x.get('detail', '')}".strip())
                # 409 « not in valid state » : Apple liste les vraies raisons dans meta.associatedErrors
                for where, subs in ((x.get("meta") or {}).get("associatedErrors") or {}).items():
                    for y in subs:
                        parts.append("  → %s : %s %s %s" % (where, y.get("code", ""), y.get("title", ""), y.get("detail", "")))
            text = "\n".join(parts) or text
        except ValueError:
            pass
        raise ApiError(e.code, text)
    return json.loads(raw) if raw else {}


def get(path, **params):
    return call("GET", path, params=params or None)


def patch(kind, id_, attributes=None, relationships=None):
    data = {"type": kind, "id": id_}
    if attributes:
        data["attributes"] = attributes
    if relationships:
        data["relationships"] = relationships
    return call("PATCH", f"/v1/{kind}/{id_}", {"data": data})


def create(kind, attributes, relationships):
    return call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": attributes, "relationships": relationships}})["data"]


def rel(kind, id_):
    return {"data": {"type": kind, "id": id_}}


def state(obj):
    a = obj["attributes"]
    return a.get("state") or a.get("appVersionState") or a.get("appStoreState") or ""


def localization(items):
    for it in items:
        if it["attributes"]["locale"] == META["locale"]:
            return it
    for it in items:
        if it["attributes"]["locale"].startswith("fr"):
            return it
    raise SystemExit(f"Pas de langue française sur la fiche ({[i['attributes']['locale'] for i in items]}).")


# --- Lecture de l'app ---------------------------------------------------------

apps = get("/v1/apps", **{"filter[bundleId]": META["bundleId"]})["data"]
if not apps:
    raise SystemExit(f"App introuvable : crée-la d'abord dans App Store Connect avec le bundle ID {META['bundleId']}.")
APP = apps[0]["id"]
print(f"App : {apps[0]['attributes']['name']} ({APP})")


def ready_build():
    params = {"filter[app]": APP, "filter[processingState]": "VALID", "filter[expired]": "false", "sort": "-uploadedDate", "limit": "1",
              "filter[preReleaseVersion.version]": META["version"]}
    if BUILD:
        params["filter[version]"] = BUILD
    data = get("/v1/builds", **params)["data"]
    return data[0] if data else None


if BUILD and not ready_build():
    raise SystemExit(f"Build {BUILD} pas encore traité par Apple : rien n'a été modifié, relance un peu plus tard.")

versions = get(f"/v1/apps/{APP}/appStoreVersions", **{"filter[platform]": "IOS"})["data"]
version = next((v for v in versions if state(v) in EDITABLE), None)
if not version:
    version = create("appStoreVersions", {"platform": "IOS", "versionString": META["version"], "releaseType": "AFTER_APPROVAL"},
                     {"app": rel("apps", APP)})
    print(f"Version {META['version']} créée")
VID = version["id"]
infos = get(f"/v1/apps/{APP}/appInfos")["data"]
info = next((i for i in infos if state(i) in EDITABLE), infos[0])
info_loc = localization(get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"])
ver_loc = localization(get(f"/v1/appStoreVersions/{VID}/appStoreVersionLocalizations")["data"])
print(f"Version : {version['attributes']['versionString']} ({state(version)})")

# --- Étapes (chacune indépendante) ---------------------------------------------

done, failed, skipped = [], [], []


def step(label, fn):
    try:
        note = fn()
    except Exception as e:  # on continue pour remplir le reste
        failed.append(f"{label} : {e}")
        print(f"❌ {label} : {e}")
        return
    if note:
        skipped.append(f"{label} : {note}")
        print(f"⏭️  {label} : {note}")
    else:
        done.append(label)
        print(f"✅ {label}")


def app_info():
    attrs = {"name": META["name"], "subtitle": META["subtitle"]}
    if PRIVACY_URL:
        attrs["privacyPolicyUrl"] = PRIVACY_URL
    patch("appInfoLocalizations", info_loc["id"], attrs)
    if not PRIVACY_URL:
        return "nom et sous-titre remplis, lien de confidentialité non fourni"


def age_rating():
    ar = get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    # Toutes les questions en une fois (Apple refuse une déclaration incomplète)
    patch("ageRatingDeclarations", ar["id"], META["ageRating"])


def categories():
    rels = {"primaryCategory": rel("appCategories", META["primaryCategory"]),
            "secondaryCategory": rel("appCategories", META["secondaryCategory"])}
    for k in ("primarySubcategoryOne", "primarySubcategoryTwo"):
        if META.get(k):
            rels[k] = rel("appCategories", META[k])
    patch("appInfos", info["id"], relationships=rels)


def content_rights():
    patch("apps", APP, {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"})


def texts():
    if not PRIVACY_URL:
        return "description non envoyée : elle doit contenir le lien de confidentialité (PRIVACY_URL)"
    attrs = {"description": META["description"].replace("{PRIVACY_URL}", PRIVACY_URL), "keywords": META["keywords"],
             "promotionalText": META["promotionalText"]}
    if SUPPORT_URL:
        attrs["supportUrl"] = SUPPORT_URL
    patch("appStoreVersionLocalizations", ver_loc["id"], attrs)
    if not SUPPORT_URL:
        return "textes remplis, lien d'assistance non fourni"


def copyright_():
    patch("appStoreVersions", VID, {"copyright": META["copyright"]})


def review_contact():
    """Coordonnées déjà saisies pour une autre appli du compte (même équipe, même personne)."""
    for a in get("/v1/apps", limit="50")["data"]:
        if a["id"] == APP:
            continue
        for v in get(f"/v1/apps/{a['id']}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "5"})["data"]:
            try:
                d = get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
            except ApiError:
                continue
            at = (d or {}).get("attributes") or {}
            if at.get("contactPhone") and at.get("contactEmail"):
                return {k: at.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")}, a["attributes"]["name"]
    return None, None


def review_notes():
    attrs = {"notes": META["reviewNotes"], "demoAccountRequired": False}
    try:
        cur = get(f"/v1/appStoreVersions/{VID}/appStoreReviewDetail").get("data")
    except ApiError as e:
        if e.code != 404:
            raise
        cur = None
    note = None
    if not (cur and (cur.get("attributes") or {}).get("contactPhone")):
        contact, src = review_contact()
        if contact:
            attrs.update(contact)
            print(f"   · coordonnées reprises de {src}")
        else:
            note = "notes remplies, coordonnées (nom, téléphone, e-mail) à saisir à la main"
    if cur:
        patch("appStoreReviewDetails", cur["id"], attrs)
    else:
        create("appStoreReviewDetails", attrs, {"appStoreVersion": rel("appStoreVersions", VID)})
    return note


def price_free():
    try:
        sched = get(f"/v1/apps/{APP}/appPriceSchedule").get("data")
    except ApiError as e:
        if e.code != 404:
            raise
        sched = None
    if sched:
        manual = get(f"/v1/appPriceSchedules/{sched['id']}/manualPrices", include="appPricePoint")
        pts = [p for p in manual.get("included", []) if p["type"] == "appPricePoints"]
        if pts and all(float(p["attributes"].get("customerPrice") or 0) == 0 for p in pts):
            return "déjà gratuite"
    try:
        pts = get(f"/v1/apps/{APP}/appPricePoints", **{"filter[territory]": "FRA", "limit": "200"})["data"]
    except ApiError as e:
        if e.code != 404:
            raise
        return "à régler à la main : Prix et disponibilité → prix 0 € (gratuite)"
    free = [p for p in pts if float(p["attributes"].get("customerPrice") or 0) == 0]
    if not free:
        raise RuntimeError("palier de prix gratuit introuvable")
    call("POST", "/v1/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": rel("apps", APP), "baseTerritory": rel("territories", "FRA"),
            "manualPrices": {"data": [{"type": "appPrices", "id": "${gratuit}"}]}}},
        "included": [{"type": "appPrices", "id": "${gratuit}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": rel("appPricePoints", free[0]["id"])}}]})


def availability():
    try:
        cur = get(f"/v1/apps/{APP}/appAvailabilityV2").get("data")
    except ApiError as e:
        if e.code != 404:
            raise
        cur = None
    if cur:
        return "déjà réglée (à vérifier dans App Store Connect si besoin)"
    terr, params = [], {"limit": "200"}
    page = get("/v1/territories", **params)
    terr += [t["id"] for t in page["data"]]
    while page.get("links", {}).get("next"):
        page = call("GET", page["links"]["next"].replace(API, ""))
        terr += [t["id"] for t in page["data"]]
    exclus = set(META.get("excludedTerritories", []))
    call("POST", "/v2/appAvailabilities", {
        "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True}, "relationships": {
            "app": rel("apps", APP),
            "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": "${%s}" % t} for t in terr]}}},
        "included": [{"type": "territoryAvailabilities", "id": "${%s}" % t, "attributes": {"available": t not in exclus},
                      "relationships": {"territory": rel("territories", t)}} for t in terr]})
    print(f"   · {len(terr) - len(exclus & set(terr))} pays (exclus : {', '.join(sorted(exclus)) or 'aucun'})")


def png(path, size):
    """PNG sans transparence, recadré au format demandé."""
    img = Image.open(path).convert("RGB")
    if size:
        w, h = size
        k = max(w / img.width, h / img.height)
        img = img.resize((round(img.width * k), round(img.height * k)), Image.LANCZOS)
        x, y = (img.width - w) // 2, (img.height - h) // 2
        img = img.crop((x, y, x + w, y + h))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def screenshots(kind, size=None):
    if not SHOTS:
        return "aucune capture dans appstore/captures (fichiers 1-….png à 6-….png)"
    sets = get(f"/v1/appStoreVersionLocalizations/{ver_loc['id']}/appScreenshotSets")["data"]
    cur = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == kind), None)
    if cur:
        olds = get(f"/v1/appScreenshotSets/{cur['id']}/appScreenshots")["data"]
        if [o["attributes"].get("sourceFileChecksum") for o in olds] == [hashlib.md5(png(p, size)).hexdigest() for p in SHOTS]:
            return "déjà à jour"
        for old in olds:
            call("DELETE", f"/v1/appScreenshots/{old['id']}")
    else:
        cur = create("appScreenshotSets", {"screenshotDisplayType": kind},
                     {"appStoreVersionLocalization": rel("appStoreVersionLocalizations", ver_loc["id"])})
    for path in SHOTS:
        data = png(path, size)
        shot = create("appScreenshots", {"fileName": path.name, "fileSize": len(data)},
                      {"appScreenshotSet": rel("appScreenshotSets", cur["id"])})
        for op in shot["attributes"]["uploadOperations"]:
            part = data[op["offset"]:op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
            urllib.request.urlopen(urllib.request.Request(op["url"], data=part, method=op["method"], headers=headers), timeout=120).read()
        patch("appScreenshots", shot["id"], {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()})
        print(f"   · {path.name} envoyée")


def build():
    b = ready_build()
    if not b:
        if BUILD:
            raise RuntimeError(f"build {BUILD} introuvable")
        return f"aucun build {META['version']} prêt (lance d'abord le workflow iOS et attends la fin du traitement)"
    call("PATCH", f"/v1/appStoreVersions/{VID}/relationships/build", rel("builds", b["id"]))
    print(f"   · build {b['attributes']['version']} attaché")


PRODUCTS = {}


def products():
    """Les 2 produits Premium créés par Thomas dans App Store Connect (appstore/achats.md)."""
    want = META.get("products")
    if not want:
        return "aucun (appli gratuite)"
    for g in get(f"/v1/apps/{APP}/subscriptionGroups", limit="20")["data"]:
        for s in get(f"/v1/subscriptionGroups/{g['id']}/subscriptions", limit="50")["data"]:
            if s["attributes"].get("productId") == want["subscription"]:
                PRODUCTS["subscription"] = s
    for p in get(f"/v1/apps/{APP}/inAppPurchasesV2", limit="50")["data"]:
        if p["attributes"].get("productId") == want["lifetime"]:
            PRODUCTS["lifetime"] = p
    missing = [want[k] for k in want if k not in PRODUCTS]
    if missing:
        raise RuntimeError("produits absents d'App Store Connect : " + ", ".join(missing))
    for k, p in PRODUCTS.items():
        print(f"   · {p['attributes']['productId']} : {state(p)}")
    bad = [f"{p['attributes']['productId']} ({state(p)})" for p in PRODUCTS.values() if state(p) == "MISSING_METADATA"]
    if bad:
        raise RuntimeError("produits incomplets (prix, description ou capture pour la vérification) : " + ", ".join(bad))


step("Nom, sous-titre et lien de confidentialité", app_info)
step("Classification par âge (4+)", age_rating)
step("Catégories (Navigation, Voyages)", categories)
step("Droits sur le contenu", content_rights)
step("Description, mots-clés, texte promo, lien d'assistance", texts)
step("Copyright", copyright_)
step("Notes et coordonnées pour la vérification", review_notes)
step("Prix : gratuite", price_free)
step("Disponibilité : tous les pays sauf la Chine continentale", availability)
for spec in META["screenshotSets"]:
    step(f"Captures d'écran {spec['label']}", lambda spec=spec: screenshots(spec["type"], spec.get("size")))
step("Build", build)


def shots_ready():
    for _ in range(40):
        states = [sh["attributes"].get("assetDeliveryState", {}).get("state")
                  for st in get(f"/v1/appStoreVersionLocalizations/{ver_loc['id']}/appScreenshotSets")["data"]
                  for sh in get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots")["data"]]
        if any(x == "FAILED" for x in states):
            raise RuntimeError("capture(s) refusée(s) par Apple")
        if all(x == "COMPLETE" for x in states):
            return
        time.sleep(15)
    raise RuntimeError("captures toujours en traitement chez Apple après 10 min, relance plus tard")


def submit():
    incomplete = [x for x in skipped if " : déjà" not in x and "appli gratuite" not in x]
    if failed or incomplete:
        return "pas de soumission : une étape a échoué ou n'est pas complète"
    shots_ready()
    # Premiers achats intégrés : ils partent en vérification avec cette version
    for k, p in PRODUCTS.items():
        if state(p) in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            continue
        try:
            if k == "subscription":
                call("POST", "/v1/subscriptionSubmissions", {"data": {"type": "subscriptionSubmissions",
                     "relationships": {"subscription": rel("subscriptions", p["id"])}}})
            else:
                call("POST", "/v1/inAppPurchaseSubmissions", {"data": {"type": "inAppPurchaseSubmissions",
                     "relationships": {"inAppPurchaseV2": rel("inAppPurchases", p["id"])}}})
            print(f"   · {p['attributes']['productId']} ajouté à la vérification")
        except ApiError as e:
            if e.code != 409:  # 409 : déjà ajouté à la version dans App Store Connect
                raise
            print(f"   · {p['attributes']['productId']} déjà ajouté ({e})")
    subs = get("/v1/reviewSubmissions", **{"filter[app]": APP, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})["data"]
    sub = subs[0] if subs else create("reviewSubmissions", {"platform": "IOS"}, {"app": rel("apps", APP)})
    if not get(f"/v1/reviewSubmissions/{sub['id']}/items")["data"]:
        call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": rel("reviewSubmissions", sub["id"]), "appStoreVersion": rel("appStoreVersions", VID)}}})
    patch("reviewSubmissions", sub["id"], {"submitted": True})
    print(f"   · version {version['attributes']['versionString']} envoyée en vérification")


if SUBMIT:
    step("Soumission à Apple", submit)

# --- Récapitulatif --------------------------------------------------------------

todo = ["Confidentialité de l'app : « Données non collectées », puis Publier (l'API ne le fait pas)"]
lines = ["## Fiche App Store : Fontaines", ""]
lines += [f"- ✅ {x}" for x in done] + [f"- ⏭️ {x}" for x in skipped] + [f"- ❌ {x}" for x in failed]
lines += ["", "### À faire dans App Store Connect", ""] + [f"- [ ] {x}" for x in todo]
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if failed else 0)

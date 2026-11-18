"""Certificats de signature du compte développeur (API App Store Connect).

Chaque build TestFlight lancé depuis GitHub crée un certificat « Apple Development » sur une machine jetable :
sa clé privée disparaît avec la machine, le certificat ne sert plus à rien, et Apple bloque quand il y en a trop.

Variables d'environnement : ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (obligatoires),
NETTOYER=true pour révoquer les certificats de développement « Created via API » créés il y a plus de AGE_H heures
(12 par défaut). Les autres certificats (Mac de Titouan, distribution) ne sont jamais touchés.
"""
import datetime as dt
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
NETTOYER = os.environ.get("NETTOYER", "").strip().lower() in ("1", "true", "oui")
AGE_H = float(os.environ.get("AGE_H", "12") or 12)


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} : HTTP {e.code} {e.read().decode(errors='replace')[:400]}")
    return json.loads(raw) if raw else {}


certs = call("GET", "/v1/certificates", {"limit": "200", "fields[certificates]": "name,displayName,certificateType,expirationDate,platform"})["data"]
now = dt.datetime.now(dt.timezone.utc)
jetables = []
print(f"{len(certs)} certificats :")
for c in sorted(certs, key=lambda c: c["attributes"]["expirationDate"]):
    a = c["attributes"]
    exp = dt.datetime.fromisoformat(a["expirationDate"].replace("Z", "+00:00"))
    cree = exp - dt.timedelta(days=365)  # les certificats durent un an
    api = "Created via API" in (a.get("name") or "") + (a.get("displayName") or "")
    dev = a["certificateType"] in ("DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT")
    vieux = (now - cree).total_seconds() > AGE_H * 3600
    marque = "à révoquer" if api and dev and vieux else ""
    if marque:
        jetables.append(c)
    print(f"  {a['certificateType']:<22} {a.get('name') or a.get('displayName')!s:<55} créé ~{cree:%d/%m %H:%M}  {marque}")

print(f"\n{len(jetables)} certificat(s) de développement créés par GitHub (plus de {AGE_H:g} h).")
if NETTOYER:
    for c in jetables:
        call("DELETE", f"/v1/certificates/{c['id']}")
        print("  révoqué :", c["attributes"].get("name"), c["id"])
    print("Nettoyage fait.")
else:
    print("Liste seulement (NETTOYER=true pour révoquer).")

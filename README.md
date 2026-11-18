# Fontaines : les points d'eau potable de Paris

Appli iPhone (SwiftUI + MapKit) qui affiche, avec ta position en direct, tous les points d'eau potable publics de Paris. C'est aussi un jeu : tu collectes les fontaines en les prenant en photo sur place.

## Données (`scraper/scrape.py`, Python 3.9, bibliothèque standard)

| Source | Contenu |
|---|---|
| Open Data Paris `fontaines-a-boire` (Eau de Paris, ODbL) | ~1 320 fontaines, type, état du jour (en service / hors service, motif, retour prévu) |
| OpenStreetMap / Overpass (ODbL) | points `amenity=drinking_water` dans Paris, sans ceux à moins de 25 m d'une fontaine officielle |
| Open Data Paris `arrondissements` | contours, pour ranger les points OSM par arrondissement |

Les commerces partenaires ne sont pas repris : ils sont fermés la nuit et l'appli doit marcher à 3 h du matin. Pour la même raison, le champ `fermeNuit` marque les fontaines situées dans un square, un parc, un jardin ou un cimetière, et les points OSM avec des horaires limités. De 21 h à 7 h, l'appli les masque et ne s'en sert pas pour la fontaine la plus proche.

Ce que fait le script :
- il écrit `docs/data/points.json` (servi par GitHub Pages, téléchargé par l'appli), `docs/data/meta.json` et `ios/PointsEau/points.json` (copie embarquée) ;
- garde-fou : si une source échoue ou renvoie trop peu de points, il garde ses points de la dernière récupération réussie.

Le workflow **Données** le lance chaque matin à 7 h UTC et committe seulement si les points ont changé.

## Appli (`ios/`, XcodeGen, iOS 17)

- **Carte** :
  - Apple Plans, avec regroupement des points ;
  - pastilles Fontaines / Pétillantes / Ouvertes la nuit (activée seule de 21 h à 7 h) / Collectées / Hors service ;
  - bandeau « fontaine la plus proche » et itinéraire à pied.
- **Jeu** :
  - à moins de 40 m d'une fontaine, l'appareil photo permet de la collecter (pas d'import depuis la galerie) ;
  - les points dépendent de la rareté : de 10 pour une fontaine à boire à 100 pour une fontaine à l'albien ;
  - 48 défis, dont un par arrondissement complet, et 8 niveaux ;
  - objectif « Tout Paris ».
- **Vie privée** : tout reste sur le téléphone (Application Support/Jeu). Pas de compte, pas de statistiques.
- **Debug** : `-demo` remplit une partie, `-onglet 1|2` ouvre un onglet, `-victoire` affiche l'écran de victoire.

## CI

- **iOS** :
  - à chaque push sur `ios/` : tests et captures d'écran sur simulateur (artefact `captures`) ;
  - en manuel, avec `testflight` coché : envoi sur TestFlight.
- **Apple** : `check`, `bundle`, `interne`, `builds`.
- **Secrets** : ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, APPLE_TEAM_ID (équipe de Titouan).

## Pages publiques

https://catteauthomas.github.io/points-eau-paris/ (aide) et `/confidentialite.html`.

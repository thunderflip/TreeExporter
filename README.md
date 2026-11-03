# TreeExporter

TreeExporter est un module d'export pour Lightroom Classic. Il recrée une
arborescence de dossiers dans une destination choisie et exporte uniquement les
fichiers absents. Un fichier déjà présent au même emplacement est toujours
conservé : il n'est ni recalculé ni écrasé.

## Utilisation

1. Installer le dossier `TreeExporter.lrplugin` dans **Fichier > Gestionnaire
   de modules externes**.
2. Sélectionner les photos, puis ouvrir **Fichier > Exporter** et choisir
   **TreeExporter** dans « Exporter vers ».
3. Dans **Structure relative depuis**, choisir le dossier situé au-dessus des
   années ou catégories à conserver. La liste propose les dossiers communs de
   la sélection et le bouton **Choisir...** permet d'en sélectionner un autre.
4. Choisir la **Destination**, puis exporter.

Exemple avec la racine `D:\Photos` et la destination `E:\Exports` :

```text
D:\Photos\2025\Vacances\IMG_001.NEF
  devient
E:\Exports\2025\Vacances\IMG_001.jpg
```

L'aperçu affiche deux chemins de destination complets avant l'export.

## Reprendre un export

Relancer exactement le même export est sans risque : les exports déjà présents
sont ignorés avant le rendu. Seules les nouvelles photos sont calculées par
Lightroom. La comparaison utilise le chemin complet et le nom attendu, extension
comprise : deux fichiers ayant le même nom dans des sous-dossiers différents sont
traités séparément.

## Règles importantes

- Le dossier de référence doit contenir toutes les photos sélectionnées.
- La destination ne peut pas être le dossier des originaux.
- Deux photos qui produiraient le même chemin arrêtent l'export avant le rendu.
- Les copies virtuelles utilisent `nom original - nom de copie.extension`.
- Les vidéos ne sont pas exportées par cette version.
- Les fichiers XMP accompagnant un export Original sont aussi conservés sans
  écrasement.

## Progression et diagnostic

La préparation vérifie les destinations avant le rendu. La progression d'export
compte les fichiers réellement exportés et reste stable. Le bilan final indique
les fichiers exportés, ignorés, en erreur, les durées et les transferts.

Un journal technique est écrit dans `TreeExporter.txt`, dans le dossier
`LrClassicLogs` de Lightroom.

## Développement

Les tests utilisent Lua 5.1.5 :

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run.ps1 -LuaDirectory C:\chemin\vers\lua-5.1.5
```

La suite contient 81 tests couvrant les chemins, collisions, reprise sans
écrasement, copies virtuelles, annulation, erreurs, interface et progression.
Les binaires Lua et les archives ZIP sont exclus des commits par `.gitignore`.

## Licence

Ce projet est publié sous licence [MIT](LICENSE).


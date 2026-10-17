# Traduction française (`fr`)

Ce dossier contient la traduction française. Les sept fichiers de `source/` et les
deux tables `hand/` couvrent **tout** l'anglais (23 853 entrées) : rien ne retombe sur
l'anglais. Le format reste éparse par construction — un thème peut arriver seul,
l'anglais comble les trous, comme le montre [`../es/`](../es/) — mais ici tous les
thèmes sont là.

Le fonctionnement (clés japonaises, une entrée par ligne, tables `hand/` indexées par
id) est le même que pour l'espagnol : voir [`../es/README.md`](../es/README.md).

```powershell
# construit le cache français et affiche la couverture
powershell -File tools\translations\Build-TranslationCache.ps1 -Locale fr
```

## Avancement

| Fichier | État |
|---------|------|
| `hand/e_day_of_week.json`, `hand/e_ui_text.json` | traduit |
| `source/ui-system.json`, `missions-rewards.json`, `character-equip.json` | traduit |
| `source/battle.json`, `gacha-shop.json`, `story-quest.json` | traduit |
| `source/dialogue.json` | traduit |
| `prefab/ui-prefab.json` (les 376 chaînes de l'interface PC) | traduit |
| `textures/` (138 images) | redessiné |

## Méthode

On traduit **depuis le japonais**, l'anglais sert de référence (et de garde-fou pour
les termes déjà fixés). Le patch PC est localisé aussi : `prefab/ui-prefab.json` et
`textures/` sont les équivalents français de `en/prefab/` et `en/textures/`. Ils ne
passent pas par le cache — ils sont cuits dans les bundles de l'interface par
`tools/prefab-patch/build_prefab_patch.py` et `build_inapp.py`, avec le cache
français et `prefab/ui-prefab.json`.

## Mises à jour du jeu

À chaque mise à jour du jeu, l'automatisation du mainteneur ajoute les nouvelles
lignes japonaises à `../en/` (telles que publiées en anglais), puis les traduit en
français en suivant ce README (conventions, caractères, glossaire). Elle vérifie
chaque ligne (balises recopiées, pas de japonais restant, pas de `œ` ni d'espace
insécable), les range dans le fichier de thème correspondant de `source/` (ou de
`hand/`), en fait un commit, puis republie le patch français. Une ligne qui échoue
aux vérifications reste en anglais jusqu'à une correction à la main.

Ces lignes sont traduites automatiquement : relire le commit de chaque mise à jour
et corriger ici ce qui sonne faux, comme pour n'importe quelle ligne.

## Caractères

Les polices du jeu (atlas TextMeshPro figés) ont tous les accents, `« »`, `’` et `…`,
mais **pas** :

- `œ` / `Œ` : écrire `oe` (`coeur`, `soeur`, `oeuvre`) ;
- l'espace fine insécable (U+202F) ; l'espace insécable (U+00A0) manque aussi dans
  deux polices. On met une **espace normale** avant `: ; ! ?`.

## Conventions

- **Interface et messages système** : vouvoiement, infinitif pour les boutons
  (« Se connecter », « Supprimer le compte »), phrases courtes.
- **Dialogues** : le registre des personnages (tu/vous selon la relation),
  pas de vouvoiement systématique.
- **Guillemets** : `« … »` pour citer un bouton ou un titre (« Menu », « Mushoku Tensei »).
- **Balises** (`<br>`, `<color=…>`, `<size=…>`, `{0}`) : recopiées telles quelles.
- **Longueur** : le patch réécrit chaque table à taille d'octets fixe ; si une table
  déborde, ses lignes les plus longues repassent en japonais. Le français est plus long
  que l'anglais : rester naturel mais concis.
- **Heures** : `18h00`, `{0}h00`.
- **Formats de date** (`yyyy/MM/dd HH:mmまで`, `開催期間：yyyy/MM/dd HH:mmまで`) : ce ne
  sont pas du texte, le jeu les passe à `DateTime.ToString`, où toute lettre non citée
  est un spécificateur. Entourer le texte littéral d'apostrophes et échapper
  l'apostrophe : `'Jusqu\'au' dd/MM/yyyy HH:mm`. Une apostrophe seule fait échouer
  `DateTime.ToString` et l'écran ne finit jamais de charger (le Tirage). Le build
  refuse désormais un format que `DateTime.ToString` rejette.

## Glossaire

| Japonais | Anglais | Français |
|----------|---------|----------|
| 魔石 | Magic Stones | Pierres magiques |
| 有償 / 無償魔石 | Paid / Free Magic Stones | Pierres magiques payantes / gratuites |
| 残響石 | Echo Stones | Pierres d'écho |
| 覚醒 | Awakening / Awaken | Éveil / éveiller |
| 限界突破 | Limit Break | Percée de limite |
| 親密度 | Bond | Lien |
| マイルーム | My Room | Ma chambre |
| プレゼントボックス | Present Box | Boîte à cadeaux |
| ガチャ | Gacha | Gacha |
| ピックアップ | Pickup | Vedette |
| クロエコガチャ | ChroEcho Gacha | Gacha ChroEcho |
| ガチャメダル | Gacha Medal | Médaille de gacha |
| 追憶 | Recollection | Souvenir |
| 奥義 | Secret Art | Art secret |
| スキル | Skill | Compétence |
| ルーン | Rune | Rune |
| メインシナリオ | Main Story | Histoire principale |
| 称号 | Title | Titre |
| 戦績 | Battle Record | Palmarès |
| 実績 | Achievements | Succès |
| ミッション | Mission | Mission |
| ログインボーナス | Login Bonus | Bonus de connexion |
| お知らせ | Notices | Annonces |
| データ引き継ぎ | Data Transfer | Transfert de données |
| データ連携 | Data Link | Liaison des données |
| アリーナ | Arena | Arène |
| レイド | Raid | Raid |
| 迷宮 | Labyrinth | Labyrinthe |
| 共闘戦 | Co-op Battle | Combat coop |
| 戦闘不能 | Unable to Battle | Hors de combat |
| バフ / デバフ | Buff / Debuff | Bonus / Malus |
| アタッカー / マーカー / サポーター | Attacker / Marker / Supporter | Attaquant / Marqueur / Soutien |
| 攻撃力 / 防御力 / 速度 | ATK / DEF / SPD | ATQ / DÉF / VIT |
| 討伐 | Subjugation | Extermination |
| 編成 | Party / Formation | Équipe |
| 装備品 | Equipment | Équipement |
| 交換所 | Exchange | Échange |
| 配置キャラ | Placed Characters | Personnages placés |
| AP / BP / SP / Pt | AP / BP / SP / Pt | AP / BP / SP / Pt |
| Lv | Lv | Niv. |

Noms propres : comme en anglais (Rudeus, Rudy, Roxy, Eris, Sylphiette, Sylphy, Fitz,
Ruijerd, Ghislaine, Paul, Zenith, Lilia, Norn, Aisha, Elinalise, Cliff, Zanoba…).

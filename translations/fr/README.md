# Traduction française (`fr`)

Ce dossier contient la traduction française. Comme l'espagnol, elle est **éparse** :
on n'y met que les lignes traduites, tout le reste retombe sur l'anglais de
[`../en/`](../en/) dans le patch construit. Elle peut donc arriver thème par thème.

Le fonctionnement (clés japonaises, une entrée par ligne, tables `hand/` indexées par
id) est le même que pour l'espagnol : voir [`../es/README.md`](../es/README.md).

```powershell
# construit le cache français (l'anglais comble les trous) et affiche la couverture
powershell -File tools\translations\Build-TranslationCache.ps1 -Locale fr
```

## Avancement

| Fichier | État |
|---------|------|
| `hand/e_day_of_week.json`, `hand/e_ui_text.json` | traduit |
| `source/ui-system.json`, `missions-rewards.json`, `character-equip.json` | traduit |
| `source/battle.json`, `gacha-shop.json`, `story-quest.json` | traduit |
| `source/dialogue.json` | traduit |

## Méthode

On traduit **depuis le japonais**, l'anglais sert de référence (et de garde-fou pour
les termes déjà fixés). Le patch PC (`en/prefab/`) et les images (`en/textures/`)
ne sont pas encore localisés.

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

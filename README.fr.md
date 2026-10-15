<p align="center"><img src="docs/images/icon.png" width="120" alt="Icône de Nunsseop"></p>

<h1 align="center">Nunsseop</h1>

<p align="center">
  <b>L’encoche de votre MacBook, enfin utile.</b><br>
  Musique, appels, fichiers, un lanceur façon Spotlight, usage de l’IA, notifications d’agents, calendrier et HUD système, à un survol de souris.
</p>

<p align="center">
  <a href="https://github.com/namekun/Nunsseop/releases/latest"><img src="https://img.shields.io/github/v/release/namekun/Nunsseop?color=111111&label=release" alt="Dernière version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 ou ultérieur">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="Licence MIT"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="Swift natif">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <b>Français</b> · <a href="https://namekun.github.io/Nunsseop/">Site web</a>
</p>

<p align="center">
  <img src="docs/images/home.png" width="720" alt="Encoche déployée avec la lecture en cours, le calendrier et la météo">
</p>

*Nunsseop* (눈썹) signifie *sourcil* en coréen : la petite arche au-dessus de votre écran. L’app est gratuite, open source, sans compte, sans abonnement et sans pistage.

## Installation en 30 secondes

```sh
brew install --cask namekun/tap/nunsseop
```

Nécessite [Homebrew](https://brew.sh). Homebrew retire l’attribut de quarantaine, l’app s’ouvre donc tout de suite. Pour la mettre à jour, lancez `brew update && brew upgrade --cask nunsseop` ; quand une mise à jour est disponible, Réglages › Général › Mises à jour copie cette commande dans le presse-papiers (pour une app installée depuis l’ancien dmg, une commande qui la fait passer à Homebrew).

Nécessite macOS 14 Sonoma ou ultérieur. Fonctionne sur les Mac Apple silicon (pas sur Intel), y compris sur les écrans sans encoche.

## Votre première minute

1. **Survolez l’encoche.** Elle s’ouvre. Éloignez le pointeur et elle se replie.
2. **Lancez de la musique** dans Music, Spotify, YouTube Music ou n’importe quel navigateur. L’encoche la détecte, et une fois repliée, elle affiche une minuscule pochette et un visualiseur.
3. **Faites un clic droit sur l’encoche → Réglages** pour choisir vos onglets, leur ordre, les pop-ups voulus et la taille.

Il n’y a pas d’icône dans le Dock. Nunsseop vit dans l’encoche.

Sur une installation toute neuve, l’encoche s’ouvre aussi toute seule au bout d’une seconde et vous guide en quatre courtes étapes : comment elle s’ouvre et se ferme, les onglets, les fichiers et la recherche, et la connexion des outils d’agents trouvés sur ce Mac (ou, s’il n’y en a aucun, « Tout est prêt »). « Passer », Échap ou « Terminer » y met fin, et Réglages › Général › « Revoir la présentation » la rejoue.

## Un aperçu

| | |
| :---: | :---: |
| <img src="docs/images/tab-search.png" alt="Rechercher affichant une app, une commande et un réglage"><br>**Rechercher.** Un lanceur pour les apps, fichiers, commandes, presse-papiers, emoji et calculs, avec le raccourci de votre choix. | <img src="docs/images/tab-ai.png" alt="Usage de l’IA pour Claude Code et Codex"><br>**Usage de l’IA.** Les limites de Claude Code et Codex, sans connexion. |
| <img src="docs/images/shelf.png" alt="Étagère avec les détails du fichier choisi et AirDrop"><br>**Étagère.** Posez des fichiers dans l’encoche, ou déposez-les sur AirDrop. | <img src="docs/images/tab-timer.png" alt="Onglet Minuteur"><br>**Minuteur.** Compte à rebours, Pomodoro et chronomètre, de la durée que vous voulez. |
| <img src="docs/images/tab-tools.png" alt="Onglet Outils"><br>**Outils.** Sortie audio, coupure du micro, garder éveillé, enregistrement de l’écran, sélecteur de couleur et capture de texte. | <img src="docs/images/tab-system.png" alt="Onglet Système avec les batteries des appareils"><br>**Système.** Processeur, mémoire, disque, réseau et batteries des appareils. |
| <img src="docs/images/tab-emoji.png" alt="Sélecteur d’emoji avec une liste de catégories"><br>**Emoji.** Les catégories à gauche, tous les emoji avec recherche, un clic pour copier. | <img src="docs/images/hud-headphones.png" alt="HUD de la batterie des écouteurs"><br>**HUD.** Volume, luminosité, batterie des AirPods et plus encore. |
| <img src="docs/images/collapsed-call.png" alt="Encoche repliée pendant un appel Zoom"><br>**Appels.** L’app d’appel et la durée de la conversation. | <img src="docs/images/collapsed-idle.png" alt="Encoche repliée affichant l’usage restant de Claude Code à gauche et la météo"><br>**D’un coup d’œil.** Choisissez ce que chaque côté de l’encoche fermée affiche. |

## Tout ce qu’elle sait faire

**🎵 Musique**
- **Lecture en cours depuis n’importe quelle app.** Music, Spotify, YouTube Music, et des navigateurs comme Safari, Chrome, Arc, Dia et Aside. Pochette, commandes et barre de progression que l’on peut faire glisser.
- **Paroles synchronisées** via [LRCLIB](https://lrclib.net), sous le titre ou sous l’encoche pendant que vous travaillez.
- **Aperçu discret.** Quand le morceau change, le titre se déploie un court instant.
- **Podcasts et longues vidéos** : sauts de 15 secondes et bouton de vitesse (de 1× à 2×), quand le lecteur le permet.

**🗂️ Pour avancer**
- **Étagère.** Faites glisser des fichiers sur l’encoche et ressortez-les plus tard, avec aperçu des images, PDF et vidéos qui grandit avec la hauteur de l’étagère. Les captures d’écran et les téléchargements terminés peuvent s’y ranger automatiquement. Secouez le pointeur en faisant glisser des fichiers n’importe où et une petite cible de dépôt apparaît juste à côté.
- **Calendrier et rappels.** La date du jour en grand, votre semaine avec un point sur les jours chargés, les événements du jour et des rappels à cocher. Tous les comptes ajoutés à macOS fonctionnent (Google, iCloud, Exchange et d’autres), et vous choisissez les calendriers à afficher.
- **Événements à venir.** Cinq minutes avant le début d’un événement horodaté, l’encoche affiche son titre et le temps restant. Les événements contenant un lien Zoom, Google Meet, Teams, Webex, FaceTime, Whereby ou Chime obtiennent un bouton vert Rejoindre dans Accueil, et un clic sur la notification rejoint la réunion.
- **Une recherche qui peut remplacer Spotlight.** Apps (même hors du dossier Applications), fichiers, commandes et réglages système, historique du presse-papiers, emoji (commencez par `:`) et calculs comme `12*(3+4)`, classés selon ce que vous ouvrez le plus. Les initiales fonctionnent : `vsc` trouve Visual Studio Code. Les flèches choisissent, Retour ouvre.
- **Votre raccourci.** <kbd>⇧⌘Espace</kbd> par défaut, ou enregistrez la combinaison de votre choix dans les Réglages. Nunsseop vous prévient quand macOS ou une autre app l’utilise déjà.
- **Minuteur, historique du presse-papiers, notes et sélecteur d’emoji.** L’historique du presse-papiers reste en mémoire et ignore tout ce qu’un gestionnaire de mots de passe marque comme secret. Les paramètres de suivi comme `utm_` et `fbclid` sont retirés des liens que vous copiez.
- **Un détail à côté de la liste.** Étagère, Presse-papiers, Apps, Rechercher et Notifications montrent à droite, avec ses actions, l’élément sous le pointeur (ou celui choisi avec ↑ ↓). Un clic sur une ligne copie, ouvre ou renvoie à la source tout de suite, comme avant.

**💻 Votre Mac**
- **HUD système.** Volume, luminosité (y compris les écrans externes DDC), rétroéclairage du clavier, charge, verrouillage des majuscules et batterie des AirPods apparaissent dans l’encoche. Elle peut prendre le contrôle des touches de volume et de luminosité pour que le HUD du système reste à l’écart.
- **Statistiques système et batteries.** Processeur, mémoire, disque, réseau et batterie de ce Mac en panneaux, ainsi que votre souris, clavier et trackpad, avec un avertissement quand l’un d’eux faiblit.
- **Indicateur caméra et micro.** Un point sur l’encoche tant qu’une app les utilise.
- **Outils.** Changez de sortie audio, réglez le volume de chaque app (expérimental, macOS 14.2 et ultérieur), coupez le micro, gardez le Mac éveillé, enregistrez l’écran, éjectez des disques, prélevez une couleur n’importe où à l’écran et copiez le texte de n’importe quelle zone de l’écran.
- **Météo, téléchargements, miroir et apps du Dock**, à un survol de souris. La météo est une ligne au bas d’Accueil.

**📞 Même fermée**
- **Appels.** Pendant un appel dans Zoom, FaceTime, Teams, Slack, Discord, WhatsApp ou Google Meet, l’encoche fermée affiche l’app et la durée de la conversation. Elle se base sur l’app qui utilise le micro, donc afficher l’appel d’une app de bureau ne demande aucune autorisation ; dans un navigateur (Meet, ou Zoom et Teams en ligne), il faut l’Automatisation pour ce navigateur. Pour Zoom, FaceTime et Meet, vous pouvez couper le micro depuis l’encoche (et désactiver la caméra dans Zoom et Meet), sans revenir à l’appel ; Zoom et FaceTime demandent l’Accessibilité, et Meet demande *Autoriser JavaScript depuis les Apple Events* dans un navigateur Chromium.
- **Votre choix de chaque côté.** Quand rien ne joue, affichez l’usage restant de Claude Code ou Codex, les agents au travail, la batterie, la météo ou la date.
- **Musique et minuteurs.** Une minuscule pochette et un visualiseur pendant la musique, et le temps restant pendant qu’un minuteur tourne. Les minuteurs, les appels et les téléchargements ajustent chaque côté à son propre contenu : une icône seule ne laisse pas de vide.
- **Téléchargements.** L’avancement d’un téléchargement Safari ou Chrome, en pourcentage, d’après la même progression que le Finder affiche sur le fichier. Rien n’interroge le système en boucle.

**🤖 Pour les développeurs**
- **Usage de l’IA.** Les limites de Claude et Codex avec leurs heures de réinitialisation, et la consommation de tokens sur les 5 dernières heures et les 7 derniers jours, tous Claude Code, Codex, gjc, omo et OpenCode confondus. Lu dans des fichiers que ces outils conservent déjà sur votre Mac : il n’y a rien à connecter. Une limite passe à l’orange avec un « ! » à partir de 70 %.
- **Limites de Claude depuis Claude Code.** Dans Réglages › Services › Usage de l’IA, connectez la ligne d’état de Claude Code. Claude Code lui transmet vos limites de 5 heures et hebdomadaires à chaque réponse : l’onglet Usage de l’IA reste à jour pendant que vous travaillez, sans que Nunsseop ne demande quoi que ce soit à Anthropic. La ligne d’état que vous aviez déjà continue de s’afficher comme avant, et Déconnecter la rétablit. Si votre commande précédente ne peut pas être restaurée, les Réglages vous le disent.
- **Limites de Claude en temps réel (optionnel).** Pour le cas où vous utilisez Claude ailleurs, l’onglet Usage de l’IA demande une fois s’il faut récupérer vos limites Claude de 5 heures et hebdomadaires auprès d’Anthropic, environ une fois par heure, avec la connexion que Claude Code garde dans le trousseau. Désactivé tant que vous n’avez pas accepté ; modifiable plus tard dans Réglages › Services. La source la plus récente l’emporte, et l’offre et les barres par modèle restent quand elle ne les fournit pas.
- **Notifications des agents et des terminaux.** Les hooks de Claude Code, Codex, Gemini CLI et OpenCode, les extensions d’omp, omo et pi, les agents dans Muxy 2, cmux, herdr et Paseo, et les sonneries de tmux et WezTerm s’affichent dans l’encoche. Cliquez sur une notification pour ramener au premier plan son terminal, son panneau ou son onglet ([réglage ci-dessous](#notifications-des-agents-et-des-terminaux)).
- **Demandes d’autorisation et questions.** Autorisez, refusez ou autorisez toujours ce que Claude Code demande d’exécuter ou de modifier, directement depuis l’encoche ; « Toujours autoriser » n’apparaît que si Claude Code suggère une règle en caractères de clavier simples (ASCII imprimable) qui tient sur la carte. La carte montre l’outil, le dossier et chaque champ, et une pastille orange « Caractères inhabituels » prévient quand le texte contient des caractères qui peuvent passer pour des lettres ou des symboles anglais. Les approbations de Codex pour les commandes, les modifications de fichiers (`apply_patch` liste les fichiers) et les outils MCP fonctionnent de même, avec « Répondre dans le terminal » à la place de « Toujours autoriser ». Les demandes d’autorisation d’OpenCode fonctionnent de même, ainsi que les approbations d’outils de Paseo, avec « Répondre dans Paseo » à la place de « Répondre dans le terminal ». Les questions de Claude Code aussi : choisissez une ou plusieurs réponses, passez d’une question à l’autre s’il y en a plusieurs, ou « Répondre dans le terminal » pour la lui rendre ; une question dont les réponses ne peuvent pas être montrées fidèlement reste dans le terminal. Si vous répondez d’abord dans le terminal, la carte disparaît. Ce qui est demandé reste en mémoire (à désactiver dans Réglages › Alertes).
- **Onglet Notifications.** Les 30 dernières notifications des agents, des terminaux et de votre calendrier, avec un badge pour celles que vous n’avez pas vues ; cliquez sur l’une d’elles pour retourner à sa source. Désactivé par défaut (Réglages › Encoche), et conservé en mémoire uniquement.
- **Agents au travail.** Un élément de l’encoche fermée qui indique combien d’agents de code vous attendent (une main jaune) ou, quand aucun n’attend, combien travaillent (un éclair vert). Il suit Claude Code, Codex, OpenCode, omp, omo et pi via leurs hooks ou extensions (à connecter dans Réglages › Alertes ; Codex vous demande d’approuver les hooks à son prochain démarrage), et gjc, herdr, Muxy 2 et Paseo sans rien connecter, y compris les sessions en arrière-plan lancées avec `claude --bg`. Quand Claude Code termine un tour alors que des sous-agents ou des commandes shell tournent encore en arrière-plan, la session continue de compter comme au travail, jusqu’à deux heures, avec une pastille « Arrière-plan · N tâches » dans l’onglet Agents.
- **Onglet Agents.** Une ligne par session d’agent de code au travail ou en attente de vous : Claude Code, Codex, OpenCode, omp, omo, pi, gjc, Paseo, et ce qui tourne dans herdr ou Muxy 2. L’état se lit à la forme autant qu’à la couleur : un point orange plein quand elle vous attend, un arc vert qui tourne pendant qu’elle travaille, un anneau vide quand elle est inactive. Viennent ensuite le titre (celui de `/rename` dans Claude Code ou son propre titre ; le nom du fil dans Codex), le dossier, l’outil et le modèle, une pastille si le mode de permissions n’est pas par défaut, une petite jauge de contexte avec le nombre de tokens, et le temps écoulé depuis le début de l’état. Chaque ligne a les boutons « Aller au terminal » (« Ouvrir dans Paseo » sur une ligne Paseo) et « Message » ; un bouton en pointillés ne peut pas agir pour l’instant, et son infobulle dit pourquoi. Une session qui vous attend se déplie avec « Répondre dans le terminal ». La ligne du bas résume les états (« 1 en attente · 3 en cours · 1 au repos »). Clavier : ↑↓ sélectionne, ↵ va au terminal, ⌘M ouvre le champ de message ; un double-clic sur une ligne va aussi à son terminal. Les sessions ouvertes utilisées ces 3 dernières heures apparaissent estompées comme « Inactive » (l’encoche fermée ne les compte pas). Quand aucune session n’est ouverte, « Récentes » liste jusqu’à 5 conversations de la dernière semaine qui ne sont pas ouvertes : cliquez sur l’une (ou appuyez sur ↵) pour la reprendre dans le terminal choisi dans Réglages › Alertes (`claude --resume`, `codex resume` ou l’option propre à chaque outil). Sont lus le dossier, le modèle, le nombre de tokens, le mode de permissions, le nom de la session et le dernier prompt dans les fichiers de session des outils sur votre Mac.
- **Écrire à une session, y déposer des fichiers.** Appuyez sur le bouton « Message » d’une ligne (ou ⌘M) : la ligne du bas devient un champ « À » portant le nom de la session, Retour envoie le texte à son entrée, suivi de Retour, et Échap annule. Déposez des fichiers de l’Étagère ou du Finder sur une ligne et leurs chemins sont tapés sans Retour ; en les faisant glisser depuis l’Étagère, laissez le pointeur sur le bouton de l’onglet Agents pour y passer. Cela marche pour les sessions dans Ghostty, Terminal, iTerm2, WezTerm, kitty, cmux, herdr, Muxy 2 et Orca (Terminal accepte les messages mais pas les fichiers), et pour Paseo uniquement les messages, aux agents qui ne travaillent pas (tableau ci-dessous, « Ce qui marche où »). Rien n’est envoyé tant qu’une demande d’autorisation ou une question peut être ouverte, ni à une session dans tmux, zellij ou screen, ni quand Nunsseop ne peut pas confirmer dans quel terminal se trouve la session.

**🧩 À votre façon**
- Tous les onglets tiennent sur une seule ligne de l’en-tête, et l’onglet actuel affiche son nom dans une capsule. Accueil, Minuteur, Outils, Système et Usage de l’IA sont des panneaux avec de grands chiffres et des barres fines. Les réglages ont une barre latérale, et la liste des onglets du volet Encoche est une grille à deux colonnes que vous pouvez réordonner en la faisant glisser.
- Choisissez vos onglets, réordonnez-les en les glissant, si l’en-tête affiche la date, ce qu’affiche l’encoche repliée, et les pop-ups que vous recevez. **Tout ce que vous désactivez cesse de tourner.**
- Sous macOS 26, l’encoche déployée et ses cartes utilisent Liquid Glass, ce qui laisse transparaître doucement l’arrière-plan. Vous réglez l’opacité du verre jusqu’à 100 % pour une encoche noire pleine, ou vous désactivez le verre.
- Sur les écrans sans encoche, l’encoche fermée est une petite pastille dans la barre des menus, en verre si vous le souhaitez, avec le sourcil, un trait de pinceau blanc, posé dessus. Le sourcil se soulève quand le pointeur le survole. Après un temps d’inactivité (de 3 à 60 secondes, ou jamais), il s’abaisse comme un œil qui se ferme et la pastille s’efface, puis elle revient quand le pointeur l’atteint ; restez dessus une demi-seconde et elle s’ouvre, fixée au bord supérieur. Là, les HUD, notifications, paroles et l’aperçu discret tiennent sur une seule ligne, avec le symbole juste à côté de la barre de niveau, du pourcentage ou du texte. Les valeurs au repos allongent la pastille juste assez pour chacune, juste à côté du sourcil, et le sourcil reste au-dessus de la caméra.
- Choisissez l’écran, la taille et le délai de survol, le lancement à l’ouverture de session, et masquez l’encoche quand le MacBook est fermé.
- Balayez vers le bas pour ouvrir, vers le haut pour fermer, sur le côté dans Accueil pour changer de morceau.
- Disponible en English, 한국어, 日本語, 简体中文, Español, Deutsch et Français, selon la langue de votre Mac.

## FAQ

<details>
<summary><b>macOS indique que Nunsseop ne peut pas être ouverte.</b></summary>

L’app n’est pas encore notarisée : installez-la avec Homebrew (`brew install --cask namekun/tap/nunsseop`). Homebrew retire l’attribut de quarantaine, et l’app s’ouvre tout de suite.
</details>

<details>
<summary><b>Rien ne s’affiche quand je lance de la musique.</b></summary>

Nunsseop affiche ce que macOS déclare comme lecture en cours : le lecteur doit donc apparaître dans le Centre de contrôle. C’est le cas de la plupart des apps et des navigateurs. Voir [le fonctionnement de la lecture en cours](#fonctionnement-de-la-lecture-en-cours) pour la solution de repli.
</details>

<details>
<summary><b>Rechercher peut-il remplacer Spotlight ?</b></summary>

Oui. Ouvrez Réglages → Services, cliquez sur le raccourci et appuyez sur <kbd>⌘Espace</kbd>. Nunsseop vous signalera que Spotlight l’utilise et ouvrira Raccourcis clavier, où vous décochez *Afficher la recherche Spotlight*. Rechercher s’ouvre aussi quand son onglet est masqué.
</details>

<details>
<summary><b>Il y a trop d’onglets.</b></summary>

Faites un clic droit sur l’encoche → Réglages → Encoche, et désactivez ce dont vous n’avez pas besoin. Les fonctions désactivées cessent complètement de tourner.
</details>

<details>
<summary><b>Mon Mac n’a pas d’encoche.</b></summary>

Sur un écran sans encoche, comme un moniteur externe avec le MacBook fermé, l’encoche fermée est une petite pastille flottant dans la barre des menus, avec le sourcil, un trait de pinceau blanc, posé dessus. Le sourcil se soulève quand le pointeur le survole, et l’ouvrir fixe l’encoche au bord supérieur, à sa taille habituelle. Les HUD, notifications, paroles et l’aperçu discret s’affichent sur une seule ligne, au lieu de contourner une caméra. Quand elle n’est pas utilisée, le sourcil s’abaisse comme un œil qui se ferme et la pastille s’efface ; désactivez cela ou changez le délai dans les Réglages. C’est aussi là que vous choisissez l’écran utilisé.
</details>

<details>
<summary><b>Pourquoi l’usage de l’IA affiche-t-il d’anciennes limites Claude ?</b></summary>

Par défaut, les pourcentages de 5 heures et hebdomadaires de Claude proviennent de caches écrits par d’autres outils : le HUD d’[oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) quand vous utilisez Claude Code dans un terminal, ou gjc. La carte indique la date de leur dernière mise à jour. Pour des limites toujours à jour, connectez la ligne d’état de Claude Code dans Réglages › Services › Usage de l’IA : Claude Code lui transmet vos limites à chaque réponse, et votre propre ligne d’état continue de fonctionner. Si vous utilisez Claude ailleurs, activez plutôt les limites de Claude en temps réel dans l’onglet Usage de l’IA ou dans Réglages › Services. La source la plus récente l’emporte, et l’offre et les barres par modèle restent quand elle ne les fournit pas. Les totaux de tokens sont toujours en temps réel.
</details>

<details>
<summary><b>Les touches de volume n’affichent plus le HUD de Nunsseop après une mise à jour.</b></summary>

Les versions antérieures à la 0.8.3 étaient signées d’une manière qui faisait oublier à macOS l’autorisation d’accessibilité à chaque mise à jour. Depuis la 0.8.3, elle est conservée. Si vous venez d’une version plus ancienne, retirez une fois Nunsseop de Réglages Système → Confidentialité et sécurité → Accessibilité, puis autorisez-la à nouveau ; cela prend effet sans redémarrage.
</details>

## Notifications des agents et des terminaux

Nunsseop écoute sur `127.0.0.1:47750` les notifications des outils de votre Mac. Les requêtes doivent présenter le jeton secret stocké dans `~/Library/Application Support/Nunsseop/notify-token`.

Ouvrez Réglages → Alertes et appuyez sur **Connecter** à côté de Claude Code, Codex, Gemini CLI, OpenCode, omp, omo ou pi. Seuls les outils que vous avez utilisés sur ce Mac sont listés. Nunsseop modifie le fichier de réglages de cet outil (`~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json`, `~/.gemini/settings.json`) ou ajoute un plugin dans `~/.config/opencode/plugins` ou une petite extension dans `~/.omp/agent/extensions` (`~/.omo` et `~/.pi` de même), et conserve l’ancien fichier avec l’extension `.nunsseop-backup`. Codex n’accepte qu’une seule commande `notify` : si une commande existe déjà, elle continue de s’exécuter après celle de Nunsseop. Les hooks du nombre d’agents au travail sont ajoutés dans `~/.codex/hooks.json`, à côté de ceux d’autres outils ; Codex vous demande de les approuver à son prochain démarrage (« Review hooks » permet de n’approuver que ceux de Nunsseop ; « Trust all and continue » approuve les nouveaux hooks de tous les outils) et ne les exécute pas avant ; il le redemande après une mise à jour qui change leur texte. Le hook qui permet de répondre aux approbations dans l’encoche s’approuve de la même façon ; si vous étiez déjà connecté, Codex le redemande une fois, à vérifier dans `/hooks`. **Déconnecter** annule la modification. Les sessions lancées ensuite envoient leurs notifications à l’encoche. gjc n’a pas besoin d’être connecté : ses sessions sont lues dans ses propres fichiers tant que le nombre d’agents ou l’onglet Agents est affiché.

Pour configurer Claude Code à la main, appuyez sur **Copier la commande du hook Claude Code** et ajoutez-la à `~/.claude/settings.json` :

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "<paste the copied command here>" }] }
    ]
  }
}
```

Les terminaux et les apps d’agents n’ont besoin d’aucun hook :

- **Muxy 2 :** les agents que Muxy détecte lui-même, lus avec `muxy activity list` tant que Muxy tourne. Ils s’affichent comme notifications (pas quand Muxy est au premier plan), et les sessions que seul Muxy connaît dans l’onglet Agents, tant qu’elles travaillent ou attendent. Muxy 1, qui utilisait un fichier de notifications et un socket, n’est pas pris en charge.
- **cmux :** ses propres notifications, lues via la commande cmux incluse dans l’app et non affichées quand il est au premier plan.
- **herdr :** les agents qui terminent ou attendent une réponse, dans toutes les sessions, lus depuis le socket de herdr.
- **Paseo :** les agents qui terminent ou échouent, lus dans les fichiers d’enregistrement de Paseo, donc même sans son démon. Les cartes d’approbation et ses événements exigent le démon de ce Mac, qui doit tourner sans mot de passe et que Nunsseop ne démarre jamais.
- **tmux :** les sonneries de n’importe quelle fenêtre. Nunsseop ajoute un hook au serveur tmux en cours d’exécution uniquement ; `tmux.conf` n’est pas modifié.
- **WezTerm :** les sonneries, via des lignes que vous copiez depuis Réglages › Alertes et collez dans `~/.wezterm.lua`.

Chacun a un interrupteur dans Réglages › Alertes (WezTerm a plutôt un bouton qui copie ses lignes de configuration), affiché seulement si l’outil est installé. Les outils déjà connectés par leur propre hook ne sont pas affichés deux fois. Orca n’a pas de source de notifications à lui : ses sessions n’apparaissent que par les hooks et extensions connectés plus haut (Claude Code, Codex, OpenCode, pi et consorts), qui envoient l’identifiant de son panneau.

N’importe quel script peut aussi en envoyer une :

```sh
# notify-auth contient l'en-tête Authorization, le jeton n'apparaît donc jamais dans la liste des processus.
curl -X POST http://127.0.0.1:47750/notify \
  -H @"$HOME/Library/Application Support/Nunsseop/notify-auth" \
  -d '{"title": "Build", "message": "Finished in 42 s"}'
```

### Ce qui marche où

Les boutons « Aller au terminal » et « Message » d’une ligne, ainsi que le dépôt de fichiers, fonctionnent là où Nunsseop peut être sûr du terminal dans lequel se trouve la session : il vérifie que le processus de la session y tourne bien. Le texte entre par l’API de saisie du terminal lui-même, jamais en frappes simulées. Quand un message ou un dépôt ne peut pas marcher, le bouton est en pointillés et son infobulle dit pourquoi (tmux, zellij ou screen entre les deux ; une demande attend une réponse ; plusieurs onglets Ghostty dans le même dossier ; etc.) ; « Aller au terminal » ramène alors quand même l’app du terminal au premier plan.

| Terminal | Aller à l’onglet ou au panneau | Message | Déposer des fichiers | Reprendre depuis « Récentes » |
| --- | :---: | :---: | :---: | :---: |
| Ghostty | ✓¹ | ✓¹ | ✓¹ | ✓ |
| Terminal | ✓ | ✓ | — | ✓ |
| iTerm2 | ✓ | ✓ | ✓ | ✓ |
| WezTerm | ✓ | ✓ | ✓ | ✓ |
| kitty | ✓ | ✓ | ✓ | ✓ |
| cmux | ✓ | ✓ | ✓ | ✓ |
| herdr | ✓ | ✓ | ✓ | — |
| Muxy 2 | ✓ | ✓ | ✓ | ✓ |
| Orca | ✓ | ✓ | ✓ | ✓ |
| Paseo | ✓ | ✓ | — | ✓ |

¹ Sessions Claude Code uniquement.

- **Ghostty, Terminal et iTerm2** sont pilotés par AppleScript : macOS demande donc une fois pour chacun si Nunsseop peut le contrôler (Réglages Système › Confidentialité et sécurité › Automatisation). Ghostty ne dit à aucun shell quel onglet il occupe : Nunsseop choisit l’onglet d’après le dossier de la session et le titre que Claude Code lui donne ; l’accès à l’onglet, les messages et les dépôts ne valent donc que pour les sessions Claude Code, et s’il n’est pas certain de l’onglet, il n’envoie rien. Terminal ne peut recevoir que du texte qu’il exécute : il accepte les messages mais refuse les fichiers déposés.
- **WezTerm et kitty** sont pilotés par leurs outils en ligne de commande (`wezterm cli`, `kitty @`). kitty exige que le contrôle à distance soit activé, avec un socket sur lequel il écoute.
- **Muxy 2 :** pour aller au panneau exact d’une session et reprendre des conversations dans un nouvel onglet, chargez une fois la petite extension passerelle de Nunsseop : dans Muxy, ouvrez Settings › Extensions › Load Unpacked…, choisissez `~/Library/Application Support/Nunsseop/muxy-bridge` (Réglages › Alertes › « Afficher l’extension dans le Finder » ouvre ce dossier) et activez l’extension. Sans elle, un clic sélectionne seulement le projet de la session. Les sessions que seul Muxy connaît (sans hook) peuvent être jointes, mais pas recevoir de texte.
- **Orca :** par la ligne de commande `orca` ; les conversations récentes reprennent, tant qu’Orca a une fenêtre, dans un nouvel onglet du worktree qui les contient.
- **Paseo :** les messages passent par `paseo send` et ne vont qu’aux agents qui ne travaillent pas (terminés ou attendant votre tour compris ; un agent qui travaille serait interrompu) ; un clic ouvre l’agent dans Paseo (c’est le sens de la première cellule de sa ligne), et les agents archivés reviennent depuis « Récentes ».
- **La reprise** se fait dans le terminal choisi dans Réglages › Alertes, sous « Reprendre les conversations dans » ; Terminal sert de secours. Ghostty, iTerm2 et cmux sont proposés s’ils sont installés, et lancés au besoin ; WezTerm si son outil en ligne de commande existe ; kitty seulement tant qu’existe un socket signalé par l’une de ses sessions ; Orca seulement tant qu’il tourne avec une fenêtre, et pour les dossiers qu’Orca connaît comme worktree (sinon le terminal suivant s’en charge) ; Muxy seulement tant que sa passerelle tourne. Ghostty et iTerm2 ouvrent un nouvel onglet via l’Automatisation (Ghostty une nouvelle fenêtre sans autorisation) ; cmux ouvre un nouvel espace de travail, pas un onglet. Les entrées de Paseo dans « Récentes » ignorent ce réglage et s’ouvrent dans Paseo.

## Autorisations

Nunsseop demande la plupart des autorisations seulement la première fois que vous utilisez la fonction qui en a besoin. L’exception : le dossier qu’il surveille pour les captures d’écran (par défaut le Bureau, ou celui réglé pour elles) et Téléchargements ; macOS peut les demander au premier démarrage de Nunsseop.

| Fonction | Autorisation | Quand elle est demandée |
| --- | --- | --- |
| Calendrier | Calendriers | Quand vous appuyez sur *Autoriser l’accès* dans l’onglet Accueil |
| Rappels | Rappels | Quand vous appuyez sur *Autoriser les rappels* dans l’onglet Accueil |
| Miroir | Caméra | Quand vous appuyez sur *Autoriser la caméra* dans l’onglet Miroir |
| Enregistrement de l’écran, et copie du texte des fenêtres d’autres apps | Enregistrement de l’écran | La première fois que vous lancez un enregistrement ou une capture de texte |
| Enregistrement avec le son | Micro | La première fois que vous enregistrez avec le son du micro activé |
| Prise de contrôle des touches de volume, de luminosité et de rétroéclairage du clavier | Accessibilité | Quand vous activez l’option dans les Réglages |
| Lecture en cours de secours pour Music, Spotify et les navigateurs | Automatisation | Seulement si l’assistant MediaRemote est indisponible |
| Affichage des appels Google Meet, Zoom et Teams dans un navigateur, et boutons micro et caméra de Meet | Automatisation (ce navigateur) | Quand un navigateur utilise le micro pour la première fois |
| Ajout des nouvelles captures d’écran à l’Étagère, alertes de téléchargement | Dossiers Bureau et Téléchargements | Au premier démarrage de Nunsseop, macOS peut demander (il surveille le dossier des captures, par défaut le Bureau, et celui des Téléchargements) |
| Volume par app | Enregistrement de l’audio du système | La première fois que vous baissez le volume d’une app dans l’onglet Outils |
| Bouton micro pour les appels Zoom et FaceTime, bouton caméra pour Zoom | Accessibilité | Jamais demandée d’elle-même : les boutons apparaissent une fois Nunsseop autorisé dans Accessibilité (par exemple via l’option des touches de volume ci-dessus) |
| Saisie de messages dans des sessions d’agents, passage à l’onglet d’une session, reprise de conversations dans un nouvel onglet (iTerm2 et Ghostty seulement) | Automatisation (Terminal, iTerm2, Ghostty) | La première fois que vous le faites dans cette app ; pour Ghostty, aussi quand l’onglet Agents liste pour la première fois une session qui y tourne |
| Lancement à l’ouverture de session | Ouverture | Quand vous l’activez dans les Réglages |

## Confidentialité

Nunsseop ne collecte ni n’envoie aucune donnée personnelle. Elle ne se connecte à Internet que pour :

- consulter `api.github.com` une fois par jour à la recherche d’une nouvelle version (peut être désactivé) ;
- chercher des paroles synchronisées sur `lrclib.net` (peut être désactivé) ;
- récupérer la météo auprès de `open-meteo.com` pour la ville que vous saisissez (désactivé tant que vous n’en saisissez pas), en demandant au géocodeur d’Apple les coordonnées de la ville quand Open-Meteo ne la trouve pas ;
- télécharger des pochettes en HTTPS depuis des services musicaux connus, uniquement quand l’assistant MediaRemote est indisponible ;
- demander à `api.anthropic.com` vos limites Claude environ une fois par heure, avec la connexion de Claude Code lue dans le trousseau, uniquement si vous activez les limites de Claude en temps réel.

Tout le reste demeure sur votre Mac. Le serveur de notifications n’accepte que les connexions de ce Mac. L’usage de l’IA est lu dans des fichiers locaux, y compris les limites que la ligne d’état de Claude Code conserve sur ce Mac, sauf si vous activez les limites de Claude en temps réel. Les notifications de l’onglet Notifications sont conservées en mémoire uniquement. Les enregistrements sont sauvegardés à côté de vos captures d’écran. L’aperçu de la caméra ne tourne que lorsque l’onglet Miroir est ouvert et n’est jamais enregistré. L’historique du presse-papiers est effacé quand Nunsseop quitte.

## Fonctionnement de la lecture en cours

Depuis macOS 15.4, le framework privé MediaRemote ne répond plus qu’aux processus signés par Apple. Nunsseop embarque une petite bibliothèque d’assistance (`Sources/NowPlayingHelper`) qui s’exécute dans le `/usr/bin/perl` du système, lit l’état de la lecture en cours, envoie les commandes de lecture, pause, changement de piste et positionnement, et renvoie des lignes JSON à l’app.

Cela repose sur une API privée : une future mise à jour de macOS pourrait donc le casser. Dans ce cas, Nunsseop se rabat sur AppleScript pour Music et Spotify, et sur la lecture des onglets multimédias dans les navigateurs. Ce repli exige d’activer *Autoriser JavaScript depuis les Apple Events* dans chaque navigateur. Dia n’a pas d’élément de menu pour cela : Nunsseop propose donc de le relancer avec `--enable-applescript-javascript`.

## Compiler depuis les sources

```sh
git clone https://github.com/namekun/Nunsseop.git
cd Nunsseop
./scripts/bundle.sh release      # build/Nunsseop.app
./scripts/make-dmg.sh            # build/Nunsseop-<version>.dmg
```

Vous avez besoin des outils en ligne de commande Xcode avec Swift 5.10 ou ultérieur. `scripts/bundle.sh` compile le package Swift et l’enveloppe dans un bundle d’app signé ad hoc.

## Licence

[MIT](LICENSE). Les issues et les pull requests sont les bienvenues.

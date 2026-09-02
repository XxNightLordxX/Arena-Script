/*
    crimson_arena/html/app.js

    The arena panel's behaviour. Structure is index.html, look is style.css;
    this file owns the state snapshot and every DOM change made from it.

    ONE STATE, ONE RENDER. Lua pushes a whole snapshot on every change --
    there are no partial updates on the wire -- so this file keeps exactly
    one `state` object and one `render()` that redraws from it. Every
    message handler mutates state and calls render(); nothing pokes at the
    DOM on the side. That is what makes a broadcast landing mid-click
    harmless: there is no half-applied update to collide with.

    XSS IS A HARD RULE, NOT A PREFERENCE. Player names, match labels,
    notification text, leaderboard names and scoreboard rows are all typed
    by other players and arrive here as data. NONE of them may ever go
    through innerHTML -- they are written with textContent or built as
    nodes. Static chrome may use innerHTML; anything derived from `state`
    may not. A name is not a safe string just because the server sent it.

    NOTHING HERE DECIDES ANYTHING. Every disabled button and every hint is
    a courtesy: the server re-validates the same request through Arena.*
    and refuses it with its own reason. When this file and the server
    disagree, the server is right and the next snapshot corrects the panel.

    A DISABLED CONTROL ALWAYS SAYS WHY, ON SCREEN. A `title` is an answer
    nobody hovers to find, so every refusal this file can predict -- join,
    create, start, place bet -- is also written into a visible line beside
    the control. And it only says what the SNAPSHOT proves: a rule that
    lives in config but never crosses the wire is left unsaid rather than
    assumed, because a panel that promises a rule this server does not run
    has lied at the one moment the player was relying on it.

    THE PANEL MUST NOT DIE. A thrown exception in a NUI page is invisible
    -- no console anyone reads, no error to the player, just a frozen menu
    with the mouse captured. So render sections are individually guarded
    and every fetch swallows its own rejection.

    STRINGS ARE LITERAL ENGLISH HERE, deliberately. locale() lives in the
    two Lua realms; NUI has no loader for it and the snapshot carries no
    string table. Player-visible text produced by Lua is already localised
    before it reaches this page (notifications, refusal reasons); the fixed
    chrome below matches the wording already hard-coded in index.html.

    THE KEYS ON THE WIRE ARE NOT ENGLISH. `winner_takes_all`, `last_standing`
    and `countdown` are how config spells things, not how a player reads
    them, so they go through the small maps under PLAIN ENGLISH FOR THE KEYS
    ON THE WIRE. A key nothing maps falls back to itself: a mode an operator
    added after this file was written should look unpolished, not invisible.
*/

(function () {
    'use strict';

    /* THE FOLDER NAME, ASKED FOR RATHER THAN ASSUMED. Every NUI callback
       below posts to https://<resource>/<name>, and the host has to be the
       name of the folder this resource is actually installed under -- not
       the name it was written under. Those differ the moment anyone renames
       the folder, and downloading the repository as a zip renames it for
       you. GetParentResourceName() is the page asking the game which
       resource is serving it, so the panel works under any folder name.

       The fallback is for opening this page outside the game (a browser, a
       screenshot); there the fetches go nowhere either way, and a defined
       string keeps the rest of the file running instead of throwing on the
       first click. */
    var RESOURCE = (typeof GetParentResourceName === 'function')
        ? GetParentResourceName()
        : 'crimson_arena';

    /* Config.UI.theme key -> the CSS custom property style.css reads. The
       two spellings differ on purpose: config is camelCase Lua, CSS is
       kebab-case, and neither should have to bend to the other. */
    var THEME_VARS = {
        accent: '--accent',
        accentBright: '--accent-bright',
        accentDim: '--accent-dim',
        background: '--bg',
        surface: '--surface',
        surfaceRaised: '--surface-raised',
        border: '--border',
        text: '--text',
        textMuted: '--text-muted',
        danger: '--danger',
        success: '--success'
    };

    var TABS = ['matches', 'lobby', 'loadout', 'bets', 'board'];

    /* Long enough to read a refusal, short enough that a burst of them
       clears before the player wants the screen back. */
    var TOAST_MS = 5000;
    var TOAST_MAX = 4;

    /* The overlay board is capped in CSS too; trimming here as well keeps a
       forty-player match from building forty nodes every second. */
    var HUD_SCORE_ROWS = 10;

    /* How long the end-of-match board stays up. It is drawn over gameplay
       with NUI focus released, so there is no button on it and nobody to
       press one: long enough to read a scoreboard, gone before the next
       round starts. */
    var RESULTS_MS = 12000;

    // ==================================================================
    // STATE
    //
    // `config`, `player`, `matches` and `leaderboard` are the server's.
    // Everything below them is this page's own: which tab is open, what
    // the player has typed but not yet sent. A snapshot never clears the
    // second group, or every broadcast would wipe a half-built loadout.
    // ==================================================================

    var state = {
        /* The host's radar choice for the match they are creating or
           editing. null until they touch it, so the operator default applies
           until then rather than 'off' pretending to be a choice. Seeded
           from the match itself once a lobby is open, beside createLives. */
        createRadar: null,
        /* Which account the player has chosen to pay from -- the entry fee
           and their bets both. null until they pick, which the server reads
           as "no preference" and answers with the operator's own order. */
        payAccount: null,
        open: false,
        config: null,
        player: null,
        matches: [],
        leaderboard: [],

        tab: 'matches',

        createArena: null,
        createMode: null,
        createFee: null,

        /* Declared, and that is not a formality: without the key here it is
           `undefined` rather than null, the `=== null` guard that seeds it
           from config never fires, and every match is created with the
           fallback -- one life -- whatever the operator's default says and
           whatever the host picked before touching the box. */
        createLives: null,

        /* The match the create form was last seeded from. Keyed on the id so
           the seed happens once on becoming host, not on every broadcast --
           re-seeding each push would overwrite the host mid-edit. */
        seededFromMatch: null,

        /* The match the browser has highlighted. Bets and spectating read
           it, so it survives a re-render of the list. */
        selectedMatchId: null,

        /* The FIREARMS filter, and only that -- melee is its own section on
           that screen and has no tabs of its own. A key that is no longer on
           offer reads as 'all' rather than as an empty list. */
        loadoutCategory: 'all',
        /* [{ key, ammo, ammoType }] -- the unsaved draft, in SEND ORDER,
           which is the order Arena.ResolveLoadout walks it in. Firearms and
           melee share this one list and are counted apart by isMelee(),
           because the two allowances are separate on the server and have to
           be separate here. Seeded from the
           server's loadout until the player touches it; after that it is
           theirs until they save, so a broadcast cannot undo a selection.

           `ammoType` is a KEY out of that weapon's own `ammoTypes` list, or
           null for a weapon that offers none. It is null rather than absent
           on purpose: the difference between "this weapon has no types" and
           "nobody has chosen one yet" is the difference between sending the
           field and leaving it off the wire. */
        draftWeapons: [],
        draftSupplies: null,
        loadoutDirty: false,

        betPick: null,
        betAmount: null,

        hud: null,
        hudVisible: false,

        /* What the last snapshot said about the state of the match this
           player is in. Only the sound reads it: it is how a start is heard
           once rather than on every snapshot that repeats the same word. */
        lastMatchState: null
    };

    // ==================================================================
    // SMALL HELPERS
    // ==================================================================

    function byId(id) {
        return document.getElementById(id);
    }

    /* An id that vanished from index.html must not take the whole panel
       with it -- the caller skips that piece and renders the rest. */
    function has(node) {
        return node !== null && node !== undefined;
    }

    function show(node, visible) {
        if (!has(node)) return;
        node.classList.toggle('hidden', !visible);
    }

    function clear(node) {
        if (!has(node)) return;
        while (node.firstChild) node.removeChild(node.firstChild);
    }

    /* The one place a string from the wire becomes a node. Everything
       player-authored goes through here or through .textContent. */
    function makeEl(tag, className, text) {
        var node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined && text !== null) node.textContent = String(text);
        return node;
    }

    function int(value, fallback) {
        var n = parseInt(value, 10);
        if (isNaN(n)) return fallback === undefined ? 0 : fallback;
        return n;
    }

    function clampInt(value, min, max) {
        var n = int(value, min);
        if (n < min) n = min;
        if (max !== null && max !== undefined && max > 0 && n > max) n = max;
        return n;
    }

    function arrayOf(value) {
        return Array.isArray(value) ? value : [];
    }

    /* Lua's `false` for "no match" / "no team" arrives as boolean false,
       not null, so an ordinary falsy check is the right one everywhere a
       key is read out of the player block. */
    function keyOr(value, fallback) {
        return (typeof value === 'string' && value !== '') ? value : fallback;
    }

    /* '1 player' and '2 players', because '1 player(s)' is a form, not a
       sentence, and this panel is read by somebody who has never seen it. */
    function plural(count, one, many) {
        var n = int(count, 0);
        return String(n) + ' ' + (n === 1 ? one : (many || (one + 's')));
    }

    function capitalise(text) {
        var value = String(text === undefined || text === null ? '' : text);
        return value === '' ? '' : value.charAt(0).toUpperCase() + value.slice(1);
    }

    /* ------------------------------------------------------------------
       PLAIN ENGLISH FOR THE KEYS ON THE WIRE

       `winner_takes_all`, `last_standing` and `countdown` are how config and
       the server spell these; they are not how a player reads them. An
       unknown key falls back to ITSELF rather than to a blank -- a mode an
       operator added after this file was written should look unpolished, not
       invisible.
       ------------------------------------------------------------------ */

    function labelFor(map, key, fallback) {
        if (typeof key === 'string' && Object.prototype.hasOwnProperty.call(map, key)) {
            return map[key];
        }
        if (typeof key === 'string' && key !== '') return key;
        return fallback === undefined ? '' : fallback;
    }

    /* Short enough for the badge on a match card. */
    var STATE_BADGE = {
        lobby: 'Open',
        countdown: 'Starting',
        live: 'Fighting',
        ended: 'Finished'
    };

    /* The same four states with room to say what they mean. */
    var STATE_TEXT = {
        lobby: 'Waiting for players',
        countdown: 'Starting now',
        live: 'Round in progress',
        ended: 'Finished'
    };

    /* Written as a clause so it can be dropped into a sentence about the
       pot: 'It all goes into the pot: the winner takes it.' */
    var PAYOUT_TEXT = {
        winner_takes_all: 'the winner takes the lot',
        per_kill: 'it is split by kills scored'
    };

    /* The same rule again, short enough for the big figure it sits under in
       the bets summary. */
    var PAYOUT_SHORT = {
        winner_takes_all: 'Winner takes all',
        per_kill: 'Split by kills'
    };

    var WIN_CONDITION_TEXT = {
        last_standing: 'last one standing',
        most_kills: 'most kills when the clock runs out',
        score_limit: 'first to the kill limit'
    };

    function money(amount) {
        var symbol = '$';
        if (state.config && state.config.betting && typeof state.config.betting.currencySymbol === 'string') {
            symbol = state.config.betting.currencySymbol;
        }
        var n = int(amount, 0);
        var sign = n < 0 ? '-' : '';
        return sign + symbol + String(Math.abs(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    function clock(seconds) {
        var total = Math.max(0, int(seconds, 0));
        var mins = Math.floor(total / 60);
        var secs = total % 60;
        return String(mins) + ':' + (secs < 10 ? '0' : '') + String(secs);
    }

    /* Team colours are operator-authored config, but they are still text
       arriving in a style property. Only a plain hex literal is honoured;
       anything else falls back to the theme border so a typo in config
       cannot smuggle a value into CSS. */
    function teamColor(team) {
        var color = team && team.color;
        if (typeof color === 'string' && /^#[0-9a-fA-F]{3,8}$/.test(color)) return color;
        return 'var(--border)';
    }

    // ==================================================================
    // BRIDGE
    //
    // fetch() to a NUI callback answers 'ok' and nothing else. A rejection
    // means the resource is stopping or the page is being torn down --
    // neither is something the player can act on, and an unhandled one
    // would surface as a console error nobody reads. Swallowed on purpose.
    // ==================================================================

    function post(name, body) {
        try {
            fetch('https://' + RESOURCE + '/' + name, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify(body || {})
            }).catch(function () {});
        } catch {
            /* fetch missing entirely means this page is not running inside
               NUI (a browser preview). The panel still renders. */
        }
    }

    // ==================================================================
    // THEME
    // ==================================================================

    function applyTheme(theme) {
        if (!theme || typeof theme !== 'object') return;
        var root = document.documentElement;
        Object.keys(THEME_VARS).forEach(function (key) {
            var value = theme[key];
            if (typeof value === 'string' && value !== '') {
                root.style.setProperty(THEME_VARS[key], value);
            }
        });
    }

    // ==================================================================
    // SNAPSHOT ACCESSORS
    //
    // The snapshot is trusted to exist but never trusted to be complete:
    // the first message can arrive before anything else, and a match can
    // disappear between the render that listed it and the click on it.
    // ==================================================================

    function cfg() {
        return state.config || {};
    }

    function betting() {
        return cfg().betting || {};
    }

    function bettingOn() {
        return betting().enabled === true;
    }

    function player() {
        return state.player || {};
    }

    function playerMatchId() {
        return keyOr(player().matchId, null);
    }

    function spectatingMatchId() {
        return keyOr(player().spectating, null);
    }

    /* The match this player may edit the settings of, or null.
       Only a host, and only while the lobby is still a lobby -- a round being
       fought is not a form, and the server refuses it on both counts too.
       This is the panel agreeing with that rather than deciding it. */
    function editableMatch() {
        if (player().isHost !== true) return null;

        var id = playerMatchId();
        if (!id) return null;

        var match = matchById(id);
        if (!match || match.state !== 'lobby') return null;

        return match;
    }

    function matchById(id) {
        if (!id) return null;
        var list = state.matches;
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].id === id) return list[i];
        }
        return null;
    }

    /* The match every screen other than the browser talks about: the one
       the player is in, else the one they are watching, else whatever they
       highlighted in the list. */
    function focusedMatch() {
        return matchById(playerMatchId())
            || matchById(spectatingMatchId())
            || matchById(state.selectedMatchId);
    }

    function weaponByKey(key) {
        var list = arrayOf((cfg().loadouts || {}).weapons);
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].key === key) return list[i];
        }
        return null;
    }

    function teamByKey(key) {
        var list = arrayOf((cfg().teams || {}).list);
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].key === key) return list[i];
        }
        return null;
    }

    /* ------------------------------------------------------------------
       THE THREE ALLOWANCES

       The server keeps them apart and Arena.ResolveLoadout spends them
       apart, so the panel reads them apart. Folding melee into the weapon
       count is the bug this screen was rebuilt to fix: a player fills their
       guns, reaches for a knife, and is told they are full by a panel the
       server would have disagreed with.
       ------------------------------------------------------------------ */

    /* Shootable weapons only. */
    function weaponSlots() {
        return Math.max(0, int((cfg().loadouts || {}).weaponSlots, 1));
    }

    /* Melee, counted on its own. ABSENT IS ONE, NOT ZERO -- the same
       reading Arena.ResolveLoadout takes: a field the operator never wrote
       means they have not thought about it, and silently removing every
       blade from an arena whose config still lists them is the wrong guess.
       An explicit 0 is a decision and is honoured. */
    function meleeSlots() {
        var raw = (cfg().loadouts || {}).meleeSlots;
        if (raw === undefined || raw === null) return 1;
        return Math.max(0, int(raw, 1));
    }

    /* How many DIFFERENT rounds one loadout may carry. 0 -- and a snapshot
       that does not carry the field at all -- means no cap, and every
       control this file draws for it stays off. */
    function ammoTypeSlots() {
        return Math.max(0, int((cfg().loadouts || {}).ammoTypeSlots, 0));
    }

    /* 'host' means one loadout for the whole match, picked by the host and
       carried by everybody. Anything unrecognised falls back to 'host', the
       same way the server's reader does -- the two must agree or the panel
       offers a picker whose every request comes back refused. */
    function hostPicksLoadout() {
        return (cfg().loadouts || {}).chooser !== 'player';
    }

    function canChooseLoadout() {
        /* In host mode the picker belongs to the host alone. Read-only for
           everyone else rather than hidden: what it shows is what they will
           be handed, which is worth seeing even when it cannot be changed. */
        if (hostPicksLoadout()) return player().isHost === true;

        return true;
    }

    /* What the money in this panel is called -- 'cash', 'bank', whatever the
       operator's account is named. */
    function accountName() {
        return keyOr(betting().account, 'cash');
    }

    /* THE ACCOUNTS A PLAYER MAY PAY FROM, in the operator's own order.
       The names are the framework's -- 'cash', 'bank', whatever this server
       calls them -- so they come from the snapshot and are never guessed. */
    function payAccounts() {
        return arrayOf(betting().accounts).filter(function (name) {
            return typeof name === 'string' && name.length > 0;
        });
    }

    /* Whether there is a choice to make at all. One account is not a choice,
       and a picker with a single option on it is a control that answers
       nothing. */
    function accountChoiceOffered() {
        return payAccounts().length > 1;
    }

    /* The account the player is paying from: their own pick where they have
       made one and it is still on offer, the first otherwise -- which is what
       the server would do with no preference, so the panel and the server
       agree about what is about to happen. */
    function chosenAccount() {
        var list = payAccounts();
        if (list.indexOf(state.payAccount) >= 0) return state.payAccount;
        return list[0] || accountName();
    }

    /* What this player holds in one account. Falls back to the single `money`
       figure for the account the operator settles in, so a server that sends
       no wallet still shows a number rather than zero. */
    function balanceIn(account) {
        var wallet = player().wallet;
        if (wallet && typeof wallet === 'object' && wallet[account] !== undefined) {
            return int(wallet[account], 0);
        }
        return account === accountName() ? int(player().money, 0) : 0;
    }

    /* Draws the pay-from picker into one container. Shared by the Bets tab
       and the create form on purpose: they are the same decision, and two
       copies of it would be two things to keep in step. */
    function renderAccountPicker(hostId) {
        var host = byId(hostId);
        if (!has(host)) return;
        clear(host);

        if (!accountChoiceOffered()) return;

        var chosen = chosenAccount();
        payAccounts().forEach(function (account) {
            var held = balanceIn(account);
            var chip = makeEl('button', 'chip', titleCase(account) + ' — ' + money(held));
            chip.type = 'button';
            if (account === chosen) chip.classList.add('active');
            /* NOT DISABLED WHEN IT CANNOT COVER THE STAKE. The amount changes
               while this is on screen, and a chip that greys itself out as
               you type reads as broken. The reason line below the button says
               what is wrong, which is where every other refusal is said. */
            chip.addEventListener('click', function () {
                state.payAccount = account;
                render();
            });
            host.appendChild(chip);
        });
    }

    function titleCase(text) {
        var word = String(text || '');
        return word.charAt(0).toUpperCase() + word.slice(1);
    }

    function payoutPhrase() {
        return labelFor(PAYOUT_TEXT, betting().payout, 'it is paid out at the end');
    }

    // ------------------------------------------------------------------
    // AMMO TYPES
    //
    // The snapshot carries, per weapon, `ammoTypes` -- [{ key, label }] --
    // and `defaultAmmoType`. THE EMPTY LIST IS MEANINGFUL: it is melee, or a
    // weapon an operator switched types off for, and it means the panel
    // shows no type control at all. A disabled dropdown reading 'none' is
    // worse than no dropdown, which is the same rule the ammo AMOUNT chips
    // already follow.
    //
    // An empty Lua table crosses as `{}` rather than `[]`, so every read
    // goes through arrayOf() and no caller may assume an array.
    // ------------------------------------------------------------------

    /* Whether this weapon lets a player type their own amount.

       Mirrors Arena.AllowsCustomAmmo on the server, per weapon first and then
       the global switch, so the box is never offered for a value the server
       would refuse. */
    function allowsCustomAmmo(weapon) {
        if (weapon && weapon.allowCustomAmmo !== undefined && weapon.allowCustomAmmo !== null) {
            return weapon.allowCustomAmmo === true;
        }
        return (cfg().loadouts || {}).allowCustomAmmo === true;
    }

    function ammoTypesOf(weapon) {
        return arrayOf(weapon && weapon.ammoTypes).filter(function (entry) {
            return entry && keyOr(entry.key, null) !== null;
        });
    }

    /* The key this weapon opens on: the server's own default when it is
       really on offer, else the first type it lists. */
    function defaultAmmoType(weapon) {
        var types = ammoTypesOf(weapon);
        if (types.length === 0) return null;

        var wanted = keyOr(weapon && weapon.defaultAmmoType, null);
        for (var i = 0; i < types.length; i++) {
            if (types[i].key === wanted) return wanted;
        }
        return types[0].key;
    }

    /* The label to show for a chosen key, or null when this weapon does not
       offer it -- which is also how callers test that a key is legal. */
    function ammoTypeLabel(weapon, key) {
        if (keyOr(key, null) === null) return null;
        var types = ammoTypesOf(weapon);
        for (var i = 0; i < types.length; i++) {
            if (types[i].key === key) return types[i].label || types[i].key;
        }
        return null;
    }

    /* A key off the wire or out of a stored loadout, kept only if this
       weapon still offers it. Same posture as the server's own
       Arena.ResolveAmmoType: an unknown key falls back to the default
       rather than being guessed at. */
    function resolveAmmoType(weapon, requested) {
        if (ammoTypeLabel(weapon, keyOr(requested, null)) !== null) return requested;
        return defaultAmmoType(weapon);
    }

    /* WHICH ALLOWANCE THIS WEAPON IS COUNTED AGAINST, and the one fact on
       this screen the panel must not work out for itself. The snapshot
       carries `melee` per weapon, resolved server-side by
       Arena.IsMeleeWeapon, precisely so the two cannot disagree about what a
       bat is.

       The fallback below is that same function written out again, for a
       snapshot from a server old enough not to send the flag: either test
       is enough, `category = 'melee'` being the honest declaration and a
       one-round ceiling being a bat whatever it was filed under. */
    function isMelee(weapon) {
        if (!weapon) return false;
        if (typeof weapon.melee === 'boolean') return weapon.melee;
        if (weapon.category === 'melee') return true;
        var ammo = weapon.ammo || {};
        return int(ammo.max, 0) <= 1;
    }

    // ==================================================================
    // DRAFT LOADOUT
    //
    // Seeded from the server's resolved loadout so the picker opens on
    // what the player is actually holding.
    // ==================================================================

    function seedDraft() {
        if (state.loadoutDirty) return;

        var loadout = player().loadout || {};
        var picks = [];
        /* Counted per pool, not in total: a stored loadout of two guns and
           a blade must seed as two guns and a blade, and a shared count
           would drop the blade on the floor. */
        var usedGuns = 0;
        var usedBlades = 0;

        arrayOf(loadout.weapons).forEach(function (entry) {
            if (!entry) return;
            var weapon = weaponByKey(entry.key);
            if (!weapon) return;

            var melee = isMelee(weapon);
            if (melee) {
                if (usedBlades >= meleeSlots()) return;
                usedBlades += 1;
            } else {
                if (usedGuns >= weaponSlots()) return;
                usedGuns += 1;
            }

            picks.push({
                key: weapon.key,
                ammo: int(entry.ammo, int(weapon.ammo && weapon.ammo.default, 0)),
                /* The server sends back the type it resolved, so the picker
                   opens on the round the player is actually holding rather
                   than on the catalogue default. */
                ammoType: resolveAmmoType(weapon, entry.ammoType)
            });
        });

        state.draftWeapons = picks;

        /* SEEDED FROM WHAT THE PLAYER IS ACTUALLY CARRYING, falling back to
           the operator's default per entry. A supply the server did not send
           back is one the player is not carrying, which is a 0 rather than a
           reason to re-apply the default -- otherwise a player who
           deliberately took none is handed some again every time the panel
           reopens. */
        var carried = {};
        var have = arrayOf(loadout.supplies);
        have.forEach(function (entry) {
            if (entry && entry.key) carried[entry.key] = int(entry.count, 0);
        });

        var draft = {};
        supplyCatalogue().forEach(function (supply) {
            draft[supply.key] = (have.length > 0 || loadout.supplies !== undefined)
                ? int(carried[supply.key], 0)
                : int(supply.default, 0);
        });
        state.draftSupplies = draft;
    }

    function draftIndexOf(key) {
        for (var i = 0; i < state.draftWeapons.length; i++) {
            if (state.draftWeapons[i].key === key) return i;
        }
        return -1;
    }

    function toggleWeapon(key) {
        if (!canChooseLoadout()) return;
        var weapon = weaponByKey(key);
        if (!weapon) return;

        var index = draftIndexOf(key);
        if (index >= 0) {
            state.draftWeapons.splice(index, 1);
        } else {
            /* AGAINST ITS OWN POOL, never against a total. An eleventh gun
               is refused; a blade at that same moment is not, and the server
               would have said the same. */
            var melee = isMelee(weapon);
            if (draftCount(melee) >= poolLimit(melee)) {
                toast(poolFullMessage(melee), 'warning');
                return;
            }
            state.draftWeapons.push({
                key: key,
                ammo: int(weapon.ammo && weapon.ammo.default, 0),
                ammoType: defaultAmmoType(weapon)
            });
        }

        state.loadoutDirty = true;
        render();
    }

    /* @param quiet -- true to update the draft WITHOUT re-rendering.

       Typing needs it. render() rebuilds the weapon cards from scratch, and
       the ammo box is one of them -- so a render between keystrokes destroys
       the element being typed into and takes the focus and the caret with
       it. That is why the box used to accept exactly one digit before
       needing another click: it was not the same box any more.

       Safe to skip precisely here: the amount changes nothing else on the
       screen. The slot counters read which weapons are picked, not how much
       ammunition they carry, and the box is only drawn on a weapon that is
       already picked. Everything that DOES change layout -- the preset
       chips, picking a weapon -- still renders. */
    function setWeaponAmmo(key, ammo, quiet) {
        if (!canChooseLoadout()) return;
        var index = draftIndexOf(key);
        if (index < 0) {
            /* Picking an ammo amount is a clear enough statement of intent
               to count as picking the weapon. */
            toggleWeapon(key);
            index = draftIndexOf(key);
            if (index < 0) return;
        }
        state.draftWeapons[index].ammo = int(ammo, 0);
        state.loadoutDirty = true;
        if (quiet) {
            /* The save button still has to notice. It is a static element,
               so updating it does not disturb anything being typed into. */
            renderLoadoutSaveRow();
            return;
        }
        render();
    }

    /* The type is per weapon and not global: two guns in one loadout may
       carry different rounds, so this writes into that weapon's own draft
       entry and nothing else. Picking a type counts as picking the weapon,
       the same way picking an amount does. */
    function setWeaponAmmoType(key, typeKey) {
        if (!canChooseLoadout()) return;
        var weapon = weaponByKey(key);
        /* An unknown type is a stale render clicked after a config change,
           not a choice. Dropped rather than stored: the server would refuse
           it anyway, and refuse it silently. */
        if (!weapon || ammoTypeLabel(weapon, typeKey) === null) return;

        var index = draftIndexOf(key);
        if (index < 0) {
            toggleWeapon(key);
            index = draftIndexOf(key);
            if (index < 0) return;
        }
        state.draftWeapons[index].ammoType = typeKey;
        state.loadoutDirty = true;
        render();
    }

    // ==================================================================
    // SOUND -- Config.UI.sounds
    //
    // Every tone is synthesised here. The panel ships no audio files on
    // purpose: a NUI page has no dependable way out to the network, and a
    // binary asset committed to the resource is a worse answer than a sine
    // wave that costs nothing to send.
    //
    // SHORT, LOW AND QUIET IS THE DESIGN, not an accident of tuning. These
    // fire on ordinary clicks, and a panel that chirps loudly at every one
    // is a panel an operator turns off -- so no sound runs past a fifth of
    // a second, none peaks above a twentieth of full scale, and the pitches
    // sit low enough to read as feedback rather than as an alarm.
    //
    // NONE OF IT IS LOAD-BEARING. No AudioContext, a refused one, or one
    // still suspended all mean silence and nothing else. Nothing in here
    // may throw into a render path -- a decoration that kills the panel is
    // the exact failure the file header forbids.
    // ==================================================================

    /* One entry per event, as a list of notes. `at` offsets a note from the
       start of the sound, `to` slides the pitch across it, `len` is seconds.
       Open rises and close falls because that is the pair a player learns
       without being told which is which. */
    var SOUNDS = {
        open: [{ freq: 196, len: 0.07 }, { at: 0.055, freq: 294, len: 0.10 }],
        close: [{ freq: 294, len: 0.06 }, { at: 0.050, freq: 175, len: 0.11 }],
        /* The most frequent sound in the panel, so the quietest and shortest
           of them: a tick, not a note. */
        tab: [{ freq: 330, len: 0.045, peak: 0.022 }],
        ready: [{ freq: 392, len: 0.09 }],
        confirm: [{ freq: 262, len: 0.07 }, { at: 0.070, freq: 349, len: 0.07 }, { at: 0.140, freq: 440, len: 0.16 }],
        /* The only one that is not a clean tone: a low sagging triangle,
           which reads as refusal without being loud about it. */
        error: [{ freq: 155, to: 110, len: 0.20, type: 'triangle' }]
    };

    /* Peak gain of one note unless it names its own. */
    var SOUND_PEAK = 0.045;

    /* `blocked` is remembered so a build with no audio at all is asked
       once rather than on every click for the rest of the session. */
    var audio = { ctx: null, blocked: false };

    function soundsOn() {
        /* Absent reads as on, like every other `!== false` switch in the
           snapshot. Only an operator writing `sounds = false` silences it. */
        return (cfg().ui || {}).sounds !== false;
    }

    function audioContext() {
        if (audio.blocked) return null;
        if (audio.ctx) return audio.ctx;

        var Ctor = window.AudioContext || window.webkitAudioContext;
        if (!Ctor) {
            audio.blocked = true;
            return null;
        }
        try {
            audio.ctx = new Ctor();
        } catch {
            /* No output device, or a policy this build enforces at
               construction. Either way there is no second answer to get. */
            audio.blocked = true;
        }
        return audio.ctx;
    }

    /* A context is born suspended and only a gesture inside THIS PAGE may
       resume it -- and the keypress or target interaction that opens the
       panel goes to the game, not here. So the unlock hangs off the first
       click or key the page itself sees, which is also why the very first
       open of a session can be silent. Re-checked on every gesture rather
       than once, because a browser may suspend a context again later. */
    function unlockAudio() {
        var ctx = audioContext();
        if (!ctx || ctx.state !== 'suspended') return;
        try {
            var pending = ctx.resume();
            /* resume() rejects when the gesture was not accepted. There is
               nothing to do about that and nowhere to report it. */
            if (pending && typeof pending.catch === 'function') pending.catch(function () {});
        } catch {
            /* Older shapes of resume() throw where newer ones reject. */
        }
    }

    function playNote(ctx, note) {
        var start = ctx.currentTime + (note.at || 0);
        var peak = note.peak || SOUND_PEAK;

        var osc = ctx.createOscillator();
        osc.type = note.type || 'sine';
        osc.frequency.setValueAtTime(note.freq, start);
        if (note.to) osc.frequency.exponentialRampToValueAtTime(note.to, start + note.len);

        /* An envelope rather than a raw gate: a tone switched on and off at
           full amplitude clicks, and the click is louder than the note. */
        var gain = ctx.createGain();
        gain.gain.setValueAtTime(0.0001, start);
        gain.gain.exponentialRampToValueAtTime(peak, start + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, start + note.len);

        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(start);
        osc.stop(start + note.len + 0.02);
    }

    function play(name) {
        if (!soundsOn()) return;
        var notes = SOUNDS[name];
        if (!notes) return;

        var ctx = audioContext();
        /* A suspended context does not drop what is scheduled on it -- it
           queues it and fires the lot the moment it resumes. Silence now
           beats every click the player made before their first click
           arriving as one chord. */
        if (!ctx || ctx.state !== 'running') return;

        try {
            for (var i = 0; i < notes.length; i++) playNote(ctx, notes[i]);
        } catch {
            /* A closed or exhausted context is not worth a dead panel. */
        }
    }

    /* A match starting is worth one confirm, at the moment it starts. Every
       snapshot afterwards repeats the same state, and the panel is usually
       closed by then, so this hangs off the change rather than off anything
       on screen. */
    function announceMatchState() {
        var match = matchById(playerMatchId());
        var now = match ? keyOr(match.state, null) : null;
        var was = state.lastMatchState;
        state.lastMatchState = now;

        if (now === was) return;
        /* A round that went straight to live is still a start; one that came
           through its countdown has already been announced. */
        if (now === 'countdown' || (now === 'live' && was !== 'countdown')) play('confirm');
    }

    // ==================================================================
    // TOASTS
    // ==================================================================

    function toast(message, kind) {
        var host = byId('arena-toast');
        if (!has(host) || typeof message !== 'string' || message === '') return;

        var level = (kind === 'success' || kind === 'error' || kind === 'warning') ? kind : 'info';
        /* Every refusal a player can see arrives here -- the server's, as a
           'notify' relay, and this file's own -- so this is the one place
           the error tone has to be wired to catch all of them. */
        if (level === 'error' || level === 'warning') play('error');

        var node = makeEl('div', 'toast ' + level, message);
        host.appendChild(node);

        while (host.children.length > TOAST_MAX) host.removeChild(host.firstChild);

        window.setTimeout(function () {
            if (node.parentNode === host) host.removeChild(node);
        }, TOAST_MS);
    }

    // ==================================================================
    // OPEN / CLOSE
    //
    // Closing ALWAYS tells Lua, whichever way it was triggered. A panel
    // that hides itself without posting 'close' leaves the resource
    // holding NUI focus for a menu that is no longer on screen -- the
    // player keeps their mouse captured with nothing to click.
    // ==================================================================

    function openPanel(snapshot) {
        /* After the snapshot, not before: the switch that decides whether
           this panel makes a sound at all arrives in it. */
        applySnapshot(snapshot);
        play('open');
        state.open = true;
        show(byId('arena-root'), true);
        render();
    }

    function hidePanel() {
        /* Only when there was a panel to close. This also runs once at load
           to put the page in its resting state, and a panel that greets the
           player by closing itself is not the impression to make. */
        if (state.open) play('close');
        state.open = false;
        show(byId('arena-root'), false);
    }

    function closePanel() {
        if (!state.open) return;
        hidePanel();
        post('close');
    }

    function applySnapshot(snapshot) {
        if (!snapshot || typeof snapshot !== 'object') return;

        if (snapshot.config) {
            state.config = snapshot.config;
            applyTheme((snapshot.config.ui || {}).theme);
        }
        if (snapshot.player) state.player = snapshot.player;
        if (Array.isArray(snapshot.matches)) state.matches = snapshot.matches;
        if (Array.isArray(snapshot.leaderboard)) state.leaderboard = snapshot.leaderboard;

        var config = cfg();

        if (!state.createArena) {
            var arenas = arrayOf(config.arenas);
            state.createArena = arenas.length > 0 ? arenas[0].key : null;
        }
        if (!state.createMode) {
            /* THE OPERATOR'S DEFAULT FIRST, and the first enabled mode only
               when they have not named one or have named one this server does
               not have. The panel always sends a mode, so the server-side
               fallback to Config.DefaultMode never fired and the setting did
               nothing at all. */
            var modes = arrayOf(config.modes);
            var wanted = (config.match || {}).defaultMode;
            var found = null;
            for (var m = 0; m < modes.length; m++) {
                if (modes[m] && modes[m].key === wanted) { found = modes[m].key; break; }
            }
            state.createMode = found || (modes.length > 0 ? modes[0].key : null);
        }
        if (state.createFee === null) {
            state.createFee = int(((config.betting || {}).entryFee || {}).default, 0);
        }
        /* Its own guard, not the fee's. Sharing one meant a server with
           betting off never seeded the lives box at all, and coupling two
           unrelated fields to one flag is how the second one quietly stops
           being initialised when the first changes. */
        if (state.createLives === null) {
            state.createLives = int((config.match || {}).lives, 1);
        }
        if (state.betAmount === null) {
            /* Whichever kind of bet this server actually offers. Seeding
               from the spectator minimum on a server that only lets fighters
               bet opened the box at 0 -- under the minimum, so the button was
               dead until the player found the number themselves. */
            var betCfg = (config.betting || {});
            var seedFrom = ((betCfg.spectatorBets || {}).enabled === true)
                ? betCfg.spectatorBets
                : ((betCfg.fighterBets || {}).enabled === true ? betCfg.fighterBets : {});
            state.betAmount = int(seedFrom.min, 0);
        }

        /* SEEDED FROM THE MATCH, ONCE PER MATCH. Becoming the host of a lobby
           turns the create form into that lobby's settings, so it has to
           start out showing what the match actually is rather than whatever
           was last typed into it.

           Keyed on the match id so it happens on the transition and not on
           every server push -- re-seeding each broadcast would overwrite the
           host mid-edit, which is the same class of bug as the input being
           rewritten while focused. */
        var editable = editableMatch();
        if (editable && state.seededFromMatch !== editable.id) {
            state.seededFromMatch = editable.id;
            state.createArena = editable.arenaKey || state.createArena;
            state.createMode = editable.modeKey || state.createMode;
            state.createLives = int(editable.lives, int(state.createLives, 1));
            state.createRadar = editable.radar === true;
        } else if (!editable && state.seededFromMatch !== null) {
            /* ON THE TRANSITION ONLY, keyed the same way the seeding above
               is, and for the same reason.

               Unkeyed, this ran on EVERY render -- and a render happens on
               every server broadcast, which is every join, ready, bet, match
               start and match end anywhere on the server. So a player
               sitting in the browser who pressed the radar toggle had their
               choice quietly reset to the operator default the moment
               anybody else did anything at all, and Create Match then posted
               the default they had just changed. Nothing on screen said so;
               the button simply went back.

               What this branch is FOR is forgetting the settings of a match
               the host has stopped editing, so the form does not carry one
               lobby's choices into a different one. That is a transition,
               and it happens once. */
            state.seededFromMatch = null;
            state.createRadar = null;
        }

        /* Joining a match is the moment the lobby screen becomes the
           interesting one; landing back on the browser after a join reads
           as the click having done nothing. */
        var current = playerMatchId();
        if (current && state.selectedMatchId !== current) {
            state.selectedMatchId = current;
            if (state.tab === 'matches') state.tab = 'lobby';
        }
        if (!current && state.tab === 'lobby' && !spectatingMatchId()) {
            state.tab = 'matches';
        }

        seedDraft();
        announceMatchState();
    }

    // ==================================================================
    // RENDER
    //
    // Each section is guarded on its own: a snapshot missing one block
    // costs that panel, not the whole menu.
    // ==================================================================

    function guarded(fn) {
        try {
            fn();
        } catch {
            /* Swallowed for the reason in the file header: the alternative
               is a dead panel the player cannot close. */
        }
    }

    function render() {
        if (!state.open) return;
        guarded(renderHeader);
        guarded(renderTabs);
        guarded(renderMatches);
        guarded(renderLobby);
        guarded(renderLoadout);
        guarded(renderBets);
        guarded(renderBoard);
    }

    function renderHeader() {
        var ui = cfg().ui || {};

        /* A finished logo already carries the server's name. Printing the
           title beside it says the same thing twice, in two sizes, one of
           them too small to read -- so banner mode hands the header over to
           the image and draws no text of its own. */
        var banner = ui.logoStyle === 'banner';

        var header = byId('arena-header');
        if (has(header)) header.classList.toggle('logo-banner', banner);

        var title = byId('arena-title');
        if (has(title)) {
            title.textContent = typeof ui.title === 'string' ? ui.title : 'CRIMSON';
            show(title, !banner);
        }

        var subtitle = byId('arena-subtitle');
        if (has(subtitle)) {
            subtitle.textContent = typeof ui.subtitle === 'string' ? ui.subtitle : '';
            show(subtitle, !banner);
        }

        var logo = byId('arena-logo');
        if (has(logo)) {
            var src = typeof ui.logo === 'string' && ui.logo !== '' ? ui.logo : 'images/logo.png';
            if (logo.getAttribute('src') !== src) logo.setAttribute('src', src);

            /* The title is gone in banner mode, so the logo becomes the only
               thing naming the panel. An empty alt would leave a screen
               reader with nothing at all to announce. */
            logo.setAttribute('alt', banner
                ? (typeof ui.title === 'string' ? ui.title : 'CRIMSON') + ' arena'
                : '');
        }

        var wallet = byId('arena-money');
        if (has(wallet)) {
            /* With betting off there is no wallet to speak of in this
               panel, and showing one implies a fee that will never exist. */
            show(wallet, bettingOn());
            clear(wallet);
            if (bettingOn()) {
                /* Labelled: a lone figure in the corner of a panel with a
                   pot in it reads as the pot just as easily as it reads as
                   the player's own money. */
                wallet.appendChild(makeEl('span', 'wallet-label', 'Your ' + accountName()));
                wallet.appendChild(makeEl('span', 'wallet-value', money(player().money)));
            }
        }
    }

    function renderTabs() {
        document.querySelectorAll('.arena-tab').forEach(function (button) {
            button.classList.toggle('active', button.getAttribute('data-tab') === state.tab);
        });
        TABS.forEach(function (name) {
            show(byId('tab-' + name), name === state.tab);
        });
    }

    // ------------------------------------------------------------------
    // MATCHES
    // ------------------------------------------------------------------

    /* Why this player cannot join this match, or null when they can. The
       server owns the real answer; this exists so the button is never
       silently inert -- a disabled control with no reason reads as broken. */
    function joinBlockedReason(match) {
        var mine = playerMatchId();
        if (mine === match.id) return 'You are already in this match.';
        if (mine) return 'You are already in another match. Leave that one first.';
        if (match.state === 'ended') return 'This match has finished.';
        if (match.state !== 'lobby') return 'This match has already started. Watch it, or start your own.';

        var max = int((cfg().match || {}).maxPlayers, 0);
        if (max > 0 && int(match.playerCount, 0) >= max) {
            return 'This match is full (' + plural(max, 'player') + ').';
        }

        /* THE ACCOUNT THAT WILL ACTUALLY PAY. `player().money` is a single
           figure from the operator's settlement account, so a player with the
           fee in the bank and nothing in their pocket was told they could not
           afford a match they could -- and one with it in cash, paying from a
           near-empty bank, was let through to a refusal. */
        if (bettingOn() && int(match.entryFee, 0) > balanceIn(chosenAccount())) {
            return accountChoiceOffered()
                ? 'You cannot cover the ' + money(match.entryFee) + ' entry fee from '
                    + titleCase(chosenAccount()) + '.'
                : 'You cannot cover the ' + money(match.entryFee) + ' entry fee.';
        }
        return null;
    }

    function renderMatches() {
        renderMatchList();
        renderCreatePanel();
    }

    function renderMatchList() {
        var host = byId('match-list');
        if (!has(host)) return;
        clear(host);

        if (state.matches.length === 0) {
            /* Deliberate, not broken: it says what is true and what to do
               about it. */
            var none = makeEl('div', 'muted');
            none.appendChild(makeEl('div', null, 'Nobody has started a match yet.'));
            none.appendChild(makeEl('div', 'hint', 'Create one and it appears here for everyone else to join.'));
            host.appendChild(none);
            return;
        }

        state.matches.forEach(function (match) {
            if (!match || !match.id) return;
            host.appendChild(matchCard(match));
        });
    }

    function matchCard(match) {
        var card = makeEl('div', 'match-card');
        if (match.id === state.selectedMatchId) card.classList.add('active');

        card.appendChild(makeEl('div', 'match-card-title', match.label || match.arenaLabel || match.id));

        var bits = [
            String(match.modeLabel || match.modeKey || ''),
            String(match.arenaLabel || match.arenaKey || ''),
            plural(match.playerCount, 'player') + ' in',
            'Host: ' + String(match.hostName || '')
        ];
        if (bettingOn()) {
            bits.push('Entry ' + money(match.entryFee));
            bits.push('Pot ' + money(match.pot));
        }
        card.appendChild(makeEl('div', 'match-card-meta', bits.join('  ·  ')));

        var actions = makeEl('div', 'match-card-actions');

        var stateName = typeof match.state === 'string' ? match.state : 'lobby';
        var badge = makeEl('span', 'state-badge', labelFor(STATE_BADGE, stateName, 'Open'));
        badge.title = labelFor(STATE_TEXT, stateName, '');
        if (stateName === 'live' || stateName === 'countdown') badge.classList.add('live');
        if (stateName === 'lobby') badge.classList.add('lobby');
        actions.appendChild(badge);

        var reason = joinBlockedReason(match);
        var join = makeEl('button', 'btn btn-primary', 'Join');
        /* Named after the match it joins, the same way the weapon cards are
           named after their weapon: a control the panel builds is otherwise
           unaddressable, by a test and by anything else that has to find it. */
        join.id = 'match-join-' + String(match.id);
        join.type = 'button';
        if (reason) {
            join.disabled = true;
            join.title = reason;
        } else {
            join.title = bettingOn() && int(match.entryFee, 0) > 0
                ? 'Pay ' + money(match.entryFee) + ' and take a place in this match.'
                : 'Take a place in this match.';
            join.addEventListener('click', function (event) {
                event.stopPropagation();
                post('joinMatch', { matchId: match.id, account: chosenAccount() });
            });
        }
        actions.appendChild(join);

        /* Offered to anyone not already fighting, which is the only state
           in which a player has a camera to spare. A finished match has
           nothing left to watch. */
        if (!playerMatchId() && stateName !== 'ended') {
            var watching = spectatingMatchId() === match.id;
            var spectate = makeEl('button', 'btn', watching ? 'Stop Watching' : 'Watch');
            spectate.type = 'button';
            spectate.title = watching
                ? 'Put the camera back on you.'
                : 'Watch this match from a spectator camera. You are not in the fight.';
            spectate.addEventListener('click', function (event) {
                event.stopPropagation();
                if (watching) post('stopSpectate');
                else post('spectate', { matchId: match.id });
            });
            actions.appendChild(spectate);
        }

        card.appendChild(actions);

        /* The tooltip on a disabled button is the answer nobody hovers to
           find, so the reason is written on the card as well. */
        if (reason) card.appendChild(makeEl('div', 'match-card-reason', 'Cannot join: ' + reason));

        /* Clicking a card also points the Bets tab at it, which is not a
           thing a highlight on its own says out loud. */
        if (match.id === state.selectedMatchId && bettingOn()
            && (betting().spectatorBets || {}).enabled === true) {
            card.appendChild(makeEl('div', 'match-card-meta', 'Picked — the Bets tab is showing this match.'));
        }

        card.addEventListener('click', function () {
            state.selectedMatchId = match.id;
            render();
        });

        return card;
    }

    function renderCreatePanel() {
        fillSelect(byId('create-arena'), arrayOf(cfg().arenas), state.createArena);
        fillSelect(byId('create-mode'), arrayOf(cfg().modes), state.createMode);

        /* LIVES, when the operator lets the host pick. `livesChoice` is
           absent when they have fixed it, and the row goes with it -- a
           control that cannot change anything invites a host to try. */
        var livesChoice = (cfg().match || {}).livesChoice;
        var livesUsed = !!livesChoice;
        show(byId('create-lives-row'), livesUsed);

        var livesInput = byId('create-lives');
        if (has(livesInput) && livesUsed) {
            livesInput.min = String(int(livesChoice.min, 1));
            livesInput.max = String(int(livesChoice.max, 1));
            if (document.activeElement !== livesInput) {
                livesInput.value = String(int(state.createLives, 1));
            }
        }

        var livesHint = byId('create-lives-hint');
        if (has(livesHint)) {
            livesHint.textContent = livesUsed
                ? 'How many times each player can die before they are out. '
                  + int(livesChoice.min, 1) + ' to ' + int(livesChoice.max, 1) + '.'
                : '';
        }

        var fee = (betting().entryFee) || {};
        /* A free arena has no fee to set. Leaving a blank number input on
           screen would still read as one that could be filled in. */
        var feeUsed = bettingOn() && fee.enabled === true;
        show(byId('create-fee-row'), feeUsed);

        var input = byId('create-fee');
        if (has(input) && feeUsed) {
            input.min = String(int(fee.min, 0));
            if (int(fee.max, 0) > 0) input.max = String(int(fee.max, 0));
            if (document.activeElement !== input) input.value = String(int(state.createFee, 0));
        }

        var presets = byId('create-fee-presets');
        if (has(presets)) {
            clear(presets);
            if (feeUsed) {
                arrayOf(fee.presets).forEach(function (value) {
                    var amount = int(value, 0);
                    var chip = makeEl('button', 'chip', money(amount));
                    chip.type = 'button';
                    if (amount === int(state.createFee, -1)) chip.classList.add('active');
                    chip.addEventListener('click', function () {
                        state.createFee = amount;
                        render();
                    });
                    presets.appendChild(chip);
                });
            }
        }

        renderAccountPicker('create-account');

        var feeHint = byId('create-fee-hint');
        if (has(feeHint)) {
            /* What the money buys, in the words of this server's own payout
               rule rather than an assumed one. */
            feeHint.textContent = feeUsed
                ? 'Every player pays this once to join. It all goes into the pot, and at the end of the round '
                    + payoutPhrase() + '.'
                : '';
        }

        var submit = byId('create-submit');
        var hint = byId('create-hint');

        /* HOSTING A LOBBY TURNS THIS FORM INTO AN EDIT FORM. Picking the
           wrong arena used to mean closing the lobby and opening another --
           which refunds and re-takes every stake, drops everybody who had
           joined, and costs the host their own place, for a mistake that
           takes one click to make. */
        var editing = editableMatch();

        var blocked = null;
        if (!editing && playerMatchId()) {
            blocked = 'You are already in a match. Leave it before starting another.';
        }
        if (!blocked && !state.createArena) blocked = 'This server has no arena switched on.';
        if (!blocked && !state.createMode) blocked = 'This server has no mode switched on.';

        /* The fee is the one thing an open lobby cannot change: everybody in
           it paid what was advertised when they joined. The server refuses
           it too -- this only stops the panel offering something that would
           come back rejected. */
        if (editing) show(byId('create-fee-row'), false);

        if (has(submit)) {
            submit.disabled = blocked !== null;
            submit.title = blocked || '';
            submit.textContent = editing ? 'Apply Changes' : 'Create Match';
        }
        if (has(hint)) {
            var onlyHost = (cfg().match || {}).onlyHostCanStart !== false;
            hint.textContent = blocked !== null
                ? blocked
                : editing
                    ? 'You are the host, so these are the settings of the match you are already in. '
                        + 'Changing them applies to everybody in the lobby. The entry fee cannot change -- '
                        + 'it has already been paid.'
                : 'You become the host and are put straight into the lobby. '
                    + (onlyHost
                        ? 'Only you can start the round.'
                        : 'Anyone in the lobby can start the round.');
        }

        /* Last, because it needs `blocked`. A radar button that still looks
           live to somebody who cannot submit this form is the same lie as a
           control on a server that has no radar -- worse, because pressing
           it appears to work right up until nothing happens. */
        renderRadarToggle(blocked);
    }

    /* Options are rebuilt from config every render and the selection is
       restored from state, so a broadcast landing between two clicks
       cannot reset a half-configured match. */
    function fillSelect(select, entries, selected) {
        if (!has(select)) return;
        clear(select);
        entries.forEach(function (entry) {
            if (!entry || !entry.key) return;
            var option = makeEl('option', null, entry.label || entry.key);
            option.value = entry.key;
            select.appendChild(option);
        });
        if (selected) select.value = selected;
    }

    // ------------------------------------------------------------------
    // LOBBY
    // ------------------------------------------------------------------

    function renderLobby() {
        var match = matchById(playerMatchId()) || matchById(spectatingMatchId());
        var empty = byId('lobby-empty');
        var detail = byId('lobby-detail');

        if (!match) {
            show(detail, false);
            show(empty, true);
            if (has(empty)) {
                clear(empty);
                empty.appendChild(makeEl('div', 'lobby-empty-title', 'Not in a match'));
                empty.appendChild(makeEl('div', 'lobby-empty-sub',
                    'Join one from the Matches tab, or start your own. This screen is where you '
                    + 'pick a side, tell everyone you are ready, and see the round start.'));
            }
            return;
        }

        show(empty, false);
        show(detail, true);

        var title = byId('lobby-title');
        if (has(title)) title.textContent = match.label || match.arenaLabel || match.id;

        renderLobbyMeta(match);
        renderTeamPicker(match);
        renderRoster(match);
        renderLobbyActions(match);
    }

    function renderLobbyMeta(match) {
        var host = byId('lobby-meta');
        if (!has(host)) return;
        clear(host);

        var matchCfg = cfg().match || {};
        var max = int(matchCfg.maxPlayers, 0);
        var roundTime = int(matchCfg.roundTimeSeconds, 0);

        /* THE MATCH'S OWN NUMBER FIRST, and the operator default only as a
           fallback for a match that predates the field.

           This read `matchCfg.lives`, which is the DEFAULT the server sends
           in the config block -- Arena.ResolveLives(nil) -- and never the
           number this match is actually played with. So the card said
           "3 lives each" under every match ever created, including one the
           host had correctly set to 1, and the host's own edit screen
           disagreed with the lobby card right next to it.

           Nothing was wrong with the value: `match.lives` is in the snapshot
           and always was. This line simply asked the wrong object for it. */
        var lives = int(match.lives, int(matchCfg.lives, 1));

        /* The rules of the round, spelled out here because this is the last
           screen before it starts and none of it is guessable from the
           weapons list. */
        var bits = [
            String(match.modeLabel || match.modeKey || ''),
            String(match.arenaLabel || match.arenaKey || ''),
            labelFor(STATE_TEXT, match.state, ''),
            max > 0
                ? int(match.playerCount, 0) + ' of ' + max + ' players in'
                : plural(match.playerCount, 'player') + ' in',
            'Starts at ' + plural(int(matchCfg.minPlayers, 1), 'player'),
            'Host: ' + String(match.hostName || ''),
            lives === 1
                ? 'One life — first death is elimination'
                : plural(lives, 'life', 'lives') + ' each',
            roundTime > 0 ? 'Round lasts ' + clock(roundTime) : 'No round clock',
            'Win by ' + labelFor(WIN_CONDITION_TEXT, matchCfg.winCondition, 'the mode rules')
        ];
        if (bettingOn()) {
            bits.push('Entry ' + money(match.entryFee));
            bits.push('Pot ' + money(match.pot));
        }
        bits.forEach(function (text) {
            /* A blank fact still costs a gap in the strip. */
            if (typeof text === 'string' && text !== '') host.appendChild(makeEl('span', null, text));
        });
    }

    function teamCountOf(match, key) {
        var counts = match.teamCounts;
        if (!counts || typeof counts !== 'object') return 0;
        return int(counts[key], 0);
    }

    function renderTeamPicker(match) {
        var host = byId('team-picker');
        if (!has(host)) return;
        clear(host);

        var teams = cfg().teams || {};
        if (match.teams !== true) {
            /* A free-for-all has no sides; an empty picker is hidden
               rather than left as a blank strip above the roster. */
            show(host, false);
            return;
        }
        show(host, true);

        var list = arrayOf(teams.list);
        var mine = keyOr(player().team, null);
        var occupied = 0;
        var lowest = null;
        var highest = null;

        list.forEach(function (team) {
            var count = teamCountOf(match, team.key);
            if (count > 0) occupied += 1;
            if (lowest === null || count < lowest) lowest = count;
            if (highest === null || count > highest) highest = count;

            var tile = makeEl('div', 'team-tile');
            tile.style.borderLeftColor = teamColor(team);
            if (team.key === mine) tile.classList.add('active');

            tile.appendChild(makeEl('div', 'team-tile-name', team.label || team.key));
            tile.appendChild(makeEl('div', 'team-tile-count',
                plural(count, 'player') + (team.key === mine ? ' · you' : '')));

            if (teams.allowChoose !== false && playerMatchId() === match.id) {
                tile.title = 'Fight on this side.';
                tile.addEventListener('click', function () {
                    post('setTeam', { teamKey: team.key });
                });
            } else {
                tile.style.cursor = 'default';
            }

            host.appendChild(tile);
        });

        if (teams.allowChoose === false) {
            host.appendChild(makeEl('div', 'hint', 'Sides are assigned by the server. You cannot pick one.'));
        } else if (playerMatchId() === match.id) {
            host.appendChild(makeEl('div', 'hint', 'Click a side to move to it. The one you are on is lit.'));
        }

        /* Uneven teams are legal by default -- 7v1 is a match, not an
           error -- so the counts are stated plainly and nothing is
           flagged. Only an operator who switched the allowance off wants
           to see a warning here. */
        /* AGAINST THE SERVER'S OWN ALLOWANCE, not against zero. The rule is
           "no more than maxTeamSizeDifference apart", and warning on any
           difference at all told a 3v2 lobby the round could not start when
           it perfectly well could -- so a host levelled sides the server had
           never objected to. Defaults to 1 to match the server's own
           fallback for an unset value. */
        var allowedGap = int(teams.maxTeamSizeDifference, 1);
        if (teams.allowUnequal === false && list.length > 0 && highest - lowest > allowedGap) {
            host.appendChild(makeEl('div', 'hint',
                'Sides are uneven (' + lowest + ' vs ' + highest + '). This server will not start a match '
                + 'while they differ by more than ' + plural(allowedGap, 'player') + '.'));
        }
        if (occupied < 2) {
            host.appendChild(makeEl('div', 'hint', 'Both sides need at least one player before the round can start.'));
        }
    }

    function renderRoster(match) {
        var host = byId('roster');
        if (!has(host)) return;
        clear(host);

        var players = arrayOf(match.players);
        if (players.length === 0) {
            host.appendChild(makeEl('div', 'hint', 'Nobody has joined yet. The round needs '
                + plural(int((cfg().match || {}).minPlayers, 1), 'player') + ' to start.'));
            return;
        }

        players.forEach(function (entry) {
            if (!entry) return;
            var row = makeEl('div', 'roster-row');

            var name = makeEl('span', null, entry.name || ('#' + int(entry.id, 0)));
            var team = teamByKey(entry.team);
            if (team) name.style.borderLeft = '3px solid ' + teamColor(team);
            row.appendChild(name);

            row.appendChild(makeEl('span', entry.isHost ? 'roster-host' : 'muted',
                entry.isHost ? 'Host' : (team ? (team.label || team.key) : '')));

            row.appendChild(makeEl('span', entry.ready ? 'roster-ready' : 'roster-waiting',
                entry.ready ? 'Ready' : 'Waiting'));

            host.appendChild(row);
        });
    }

    /* The sentence under the three buttons. READY UP AND START MATCH NOW ARE
       DIFFERENT THINGS and pressing the wrong one during a countdown is a
       real mistake a player makes once, so the difference is written out
       rather than left to the labels. */
    function lobbyHintText(match, inMatch, isHost, blocked) {
        if (!inMatch) {
            return 'You are watching this match, not fighting in it. Join one from the Matches tab to fight.';
        }
        if (match.state === 'countdown') {
            return isHost
                ? 'The round is starting. Stop The Countdown holds it and everyone stays in the lobby; Leave Match takes you out of the match altogether.'
                : 'The round is starting. Only the host can stop the countdown. You can still leave, which takes you out of the match.';
        }
        if (match.state === 'live' || match.state === 'ended') {
            return 'The round is under way. Leaving now gives up your place in it.';
        }
        /* WHAT READYING UP ACTUALLY DOES ON THIS SERVER. The second half was
           said unconditionally and is false wherever autoStartWhenAllReady
           is on -- which is how it ships. It is the last sentence a player
           reads before pressing the button it is wrong about. */
        var autoStart = (cfg().match || {}).autoStartWhenAllReady === true;
        var lead = player().ready === true
            ? 'You are marked ready. '
            : (autoStart
                ? 'Ready Up marks you set — and once everybody is ready the round starts on its own. '
                : 'Ready Up only tells the others you are set — it does not start the round. ');
        return blocked === null
            ? lead + 'Start Match Now begins the round for everybody in this lobby.'
            : lead + 'Start Match Now is unavailable: ' + blocked;
    }

    /* THE RADAR, A MATCH SETTING THE HOST PICKS.

       This lived in the lobby and belonged to each player: their own toggle,
       answered on their own client, never sent anywhere. That made a round
       only as dark as its least patient fighter -- anyone who wanted enemies
       on their map simply switched them on for themselves, and the sweep
       interval the setting exists for was a formality.

       So it moved up here beside Lives Each, into the box that creates and
       edits a match, and it travels with the rest of the match rules. That
       box is only ever an editor for a match you host, which is what makes
       the setting host-only without a second permission check to keep in
       step with the first.

       Nothing is posted on the click. Like the arena, the mode and the
       lives, it is applied by Create Match or Apply Changes -- so a host can
       change their mind twice before committing to either. */
    function radarSettings() {
        return (cfg().match || {}).radar || null;
    }

    function radarIsOn() {
        var settings = radarSettings();
        if (!settings) return false;
        if (state.createRadar === null || state.createRadar === undefined) {
            return settings.defaultOn === true;
        }
        return state.createRadar === true;
    }

    /* @param blocked string|null -- why this form cannot be submitted, if
       it cannot. Anything but null and the toggle is dead: whoever is
       looking at it is not the host of an open lobby. */
    function renderRadarToggle(blocked) {
        var host = byId('create-radar-row');
        if (!has(host)) return;

        var settings = radarSettings();
        /* Drawn only where the operator allows one. A dead control is worse
           than no control -- it reads as a broken feature. */
        show(host, !!settings);
        if (!settings) return;

        var button = byId('btn-radar');
        if (!has(button)) return;

        var on = radarIsOn();
        var every = int(settings.intervalSeconds, 30);
        var editable = blocked === null || blocked === undefined;

        button.textContent = on ? 'Radar On' : 'Radar Off';
        button.classList.toggle('btn-primary', on);
        button.disabled = !editable;
        button.title = editable ? '' : blocked;
        button.onclick = function () {
            if (!editable) return;
            state.createRadar = !radarIsOn();
            render();
        };

        var hint = byId('create-radar-hint');
        if (has(hint)) {
            hint.textContent = on
                ? 'Every fighter gets a sweep every ' + every + ' seconds: the other side flashes '
                    + 'onto the map for a moment and goes dark again. Your own team is always on the map.'
                : 'Off. Nobody sees the other side on the map at all — only their own team. '
                    + 'Turn it on for a sweep every ' + every + ' seconds.';
        }
    }

    function renderLobbyActions(match) {
        var inMatch = playerMatchId() === match.id;
        var isHost = inMatch && player().isHost === true;
        var counting = match.state === 'countdown';

        var ready = byId('btn-ready');
        var isReady = player().ready === true;
        if (has(ready)) {
            /* The label says what pressing it makes you, which is the only
               reading that survives being read in a hurry. */
            ready.textContent = isReady ? 'Not Ready' : 'Ready Up';
            ready.title = isReady
                ? 'Take your ready back. Nothing starts without you.'
                : 'Tell the others you are set. This does not start the round.';
            ready.classList.toggle('btn-primary', !isReady);
            ready.disabled = !inMatch || match.state !== 'lobby';
            ready.onclick = function () {
                play('ready');
                post('setReady', { ready: !isReady });
            };
        }

        /* Cancel lives on the start button during the countdown because
           that is the only window where "stop the start" is a thing a host
           can still ask for -- the server refuses it once the round is
           live. */
        var onlyHost = (cfg().match || {}).onlyHostCanStart !== false;
        var mayStart = inMatch && (isHost || !onlyHost);
        var minPlayers = int((cfg().match || {}).minPlayers, 1);
        var blocked = null;
        if (!inMatch) blocked = 'you are watching this match, not in it.';
        else if (!mayStart) blocked = 'only the host can start it.';
        else if (int(match.playerCount, 0) < minPlayers) {
            blocked = 'the round needs ' + plural(minPlayers, 'player')
                + ' and has ' + plural(match.playerCount, 'player') + '.';
        }

        var start = byId('btn-start');
        if (has(start)) {
            start.textContent = counting ? 'Stop The Countdown' : 'Start Match Now';
            if (counting) {
                start.disabled = !isHost;
                start.title = isHost
                    ? 'Hold the start. Everybody stays in the lobby and nobody loses their place.'
                    : 'Only the host can stop the countdown.';
                /* holdCountdown, NOT cancelMatch. The tooltip above promises
                   the lobby survives and nobody loses their place; the cancel
                   destroys the match, evicts the room, and on a server with
                   refundOnCancel off burns every stake in it. */
                start.onclick = function () { post('holdCountdown'); };
            } else {
                start.disabled = blocked !== null;
                start.title = blocked === null
                    ? 'Send everyone into the arena. There is a countdown first.'
                    : capitalise(blocked);
                start.onclick = function () { post('startMatch'); };
            }
        }

        var leave = byId('btn-leave');
        if (has(leave)) {
            leave.textContent = inMatch ? 'Leave Match' : 'Stop Watching';
            leave.title = inMatch
                ? 'Take yourself out of this match.'
                : 'Stop watching and put the camera back on you.';
            leave.disabled = false;
            leave.onclick = function () {
                if (inMatch) post('leaveMatch');
                else post('stopSpectate');
            };
        }

        var hint = byId('lobby-hint');
        if (has(hint)) hint.textContent = lobbyHintText(match, inMatch, isHost, blocked);
    }

    // ------------------------------------------------------------------
    // LOADOUT
    //
    // TWO POOLS, COUNTED APART, because that is how the server counts them.
    // `weaponSlots` is shootable weapons and `meleeSlots` is blades, and
    // Arena.ResolveLoadout spends the two separately -- a player whose guns
    // are full may still take a knife, and the panel has to be able to say
    // so. One filtered grid under one counter cannot: it says "you are
    // carrying 2 weapons" at the exact moment the server would have handed
    // over a third thing.
    //
    // So this is two lists with a heading and a counter each, both on screen
    // at once, each scrolling inside its own box. An operator with thirty
    // guns and twenty blades gets two readable lists rather than one long
    // one, and nothing ever pushes the page.
    //
    // WHAT THE COUNTERS ARE FOR: 'my guns are full' and 'I am full' are
    // different sentences, and the second one was never true. Both counters
    // are on the picker AND in the summary, which is the last thing read
    // before a round locks the choice in.
    // ------------------------------------------------------------------

    /* The catalogue split the way the server counts it, in config order --
       an operator who arranged their weapons deliberately keeps that order. */
    function weaponCatalogue(melee) {
        return arrayOf((cfg().loadouts || {}).weapons).filter(function (weapon) {
            return weapon && keyOr(weapon.key, null) !== null && isMelee(weapon) === melee;
        });
    }

    /* How many of one pool the draft holds. Counted rather than tracked: a
       key left over from a weapon an operator has since removed resolves to
       nothing and must not be charged to a pool it can no longer fill. */
    function draftCount(melee) {
        var used = 0;
        state.draftWeapons.forEach(function (pick) {
            var weapon = weaponByKey(pick.key);
            if (weapon && isMelee(weapon) === melee) used += 1;
        });
        return used;
    }

    function poolLimit(melee) {
        return melee ? meleeSlots() : weaponSlots();
    }

    /* 'gun' and 'blade', not 'weapon' and 'melee weapon'. Two counters that
       both say 'weapon' undo the whole point of there being two of them. */
    function poolNoun(melee) {
        return melee ? 'blade' : 'gun';
    }

    /* '2 of 2 guns'. Count first, because that is the half that moves. */
    function poolCounterText(melee) {
        return String(draftCount(melee)) + ' of ' + plural(poolLimit(melee), poolNoun(melee));
    }

    /* WHICH POOL IS FULL, SAID BY NAME. The old sentence -- 'you are already
       carrying 2 weapons' -- named a total that does not exist on this
       server, and a player who believed it dropped a rifle to make room for
       a knife that never needed the room. */
    function poolFullMessage(melee) {
        if (poolLimit(melee) <= 0) {
            return melee
                ? 'This arena has melee switched off. There is no blade slot to fill.'
                : 'This arena hands out no firearms. There is no gun slot to fill.';
        }

        var text = (melee ? 'Your melee is full' : 'Your guns are full')
            + ' — ' + poolCounterText(melee) + '. Drop '
            + (melee ? 'a blade' : 'a gun') + ' before picking another.';

        /* Only mentioned when the other pool exists to be reassured about. */
        if (poolLimit(!melee) > 0) {
            text += ' Your ' + (melee ? 'guns' : 'blades')
                + ' are counted separately and are not touched by this.';
        }
        return text;
    }

    // ------------------------------------------------------------------
    // DISTINCT AMMO TYPES -- `ammoTypeSlots`
    //
    // The cap is on how many DIFFERENT rounds one loadout carries, not on
    // the weapons. The server does not refuse a weapon over it -- losing a
    // gun because of an ammunition preference would be a surprising way to
    // be told about a limit -- it quietly swaps that weapon onto its own
    // default round instead.
    //
    // QUIETLY IS THE PROBLEM. A player who picked armour-piercing, saved,
    // and is handed standard when the round starts has been told nothing.
    // So the panel works out the same answer the server will, in the same
    // order (the draft is sent in order and Arena.ResolveLoadout walks it in
    // order), and names the round that will ACTUALLY be loaded.
    //
    // The default a weapon falls back to counts towards the cap too, exactly
    // as it does on the server -- which is why the count is taken after the
    // fallback and not before.
    // ------------------------------------------------------------------

    /* Bare maps: an ammo type key is operator-authored text, and a key like
       '__proto__' landing on an object literal is a silent wrong answer. */
    function bareMap() {
        return Object.create(null);
    }

    /* @param override {key, ammoType}|null -- a hypothetical pick, so a chip
       can be asked "what would happen if I were pressed" without the draft
       being changed to find out. */
    function ammoTypePlan(override) {
        var cap = ammoTypeSlots();
        var taken = bareMap();
        var byKey = bareMap();
        var distinct = 0;

        state.draftWeapons.forEach(function (pick) {
            var weapon = weaponByKey(pick.key);
            if (!weapon) return;

            var requested = (override && override.key === pick.key) ? override.ammoType : pick.ammoType;
            var chosen = keyOr(resolveAmmoType(weapon, requested), null);
            var loaded = chosen;

            /* A round this loadout has not already spent a slot on, with no
               slots left to spend. */
            if (chosen !== null && cap > 0 && taken[chosen] !== true && distinct >= cap) {
                loaded = keyOr(defaultAmmoType(weapon), null);
            }

            if (loaded !== null && taken[loaded] !== true) {
                taken[loaded] = true;
                distinct += 1;
            }

            byKey[pick.key] = {
                chosen: chosen,
                loaded: loaded,
                swapped: chosen !== null && loaded !== chosen
            };
        });

        return { cap: cap, taken: taken, distinct: distinct, byKey: byKey };
    }

    /* Whether pressing this type chip on a weapon ALREADY in the draft would
       get the player that round, or the default instead. Re-run rather than
       read off the current plan: changing a weapon's round can free the slot
       its old round was holding, so the standing plan would say 'no' where
       the truthful answer is 'yes'. */
    function wouldSwap(weaponKey, typeKey) {
        var entry = ammoTypePlan({ key: weaponKey, ammoType: typeKey }).byKey[weaponKey];
        return entry !== undefined && entry.swapped === true;
    }

    // ------------------------------------------------------------------

    function renderLoadout() {
        /* Worked out once and handed down: the cards and the summary have to
           name the same round, and computing it twice invites them to
           disagree. A plan that cannot be built is an empty one -- no cap,
           no claims -- rather than a dead tab. */
        var plan = { cap: 0, taken: bareMap(), distinct: 0, byKey: bareMap() };
        guarded(function () { plan = ammoTypePlan(null); });

        guarded(renderLoadoutNote);

        guarded(function () { renderWeaponSections(plan); });
        guarded(function () { renderLoadoutSlots(plan); });
        guarded(renderSuppliesPicker);
        guarded(renderLoadoutSaveRow);
    }

    /* The one sentence that is true of both lists, said once above them. */
    function renderLoadoutNote() {
        var host = byId('loadout-note');
        if (!has(host)) return;
        clear(host);

        if (!canChooseLoadout()) {
            /* One reason, and it is never permanent: the host picks, and you
               are not the host of this match. */
            host.appendChild(makeEl('div', 'hint',
                'The host picks one loadout and everyone in the match fights with it, so every '
                + 'player carries the same weapons. Into The Round below is exactly what you will '
                + 'be handed when the round starts. Host a match yourself to choose it.'));
            return;
        }

        if (hostPicksLoadout()) {
            host.appendChild(makeEl('div', 'hint',
                'You are the host, so this is the loadout EVERY player in your match will carry — '
                + 'yourself included. Anyone who joins after you pick inherits it.'));
        }

        var guns = weaponSlots();
        var blades = meleeSlots();
        var text = 'Click a weapon to carry it, and click it again to drop it. ';
        if (guns > 0 && blades > 0) {
            /* THE RULE THIS SCREEN EXISTS TO MAKE OBVIOUS. */
            text += 'Guns and melee are counted separately — ' + plural(guns, 'gun') + ' and '
                + plural(blades, 'blade') + ' — so filling one does not cost you the other.';
        } else if (blades > 0) {
            text += 'This arena is melee only: ' + plural(blades, 'blade') + '.';
        } else if (guns > 0) {
            text += 'This arena issues no melee: ' + plural(guns, 'gun') + '.';
        }
        host.appendChild(makeEl('div', 'hint', text));

        var cap = ammoTypeSlots();
        if (cap > 0) {
            host.appendChild(makeEl('div', 'hint',
                'You may carry ' + plural(cap, 'kind') + ' of round across the whole loadout. '
                + 'Past that a weapon is loaded with its own default instead of the round you picked, '
                + 'and this screen says which ones.'));
        }
    }

    function renderWeaponSections(plan) {
        /* THE PICKER GOES ENTIRELY for anybody who may not use it.

           It used to be drawn and disabled, on the reasoning that seeing the
           lists is worth something even when they cannot be touched. It is
           not: on a host-picks server somebody who joined a match was handed
           ninety-odd greyed-out weapon cards to scroll past, and the one
           thing they actually wanted -- what they will be carrying -- was
           underneath all of it. renderLoadoutNote says why the lists are
           gone and renderLoadoutSlots says what was chosen.

           DECIDED HERE, and only here. The first version of this put the
           check in renderLoadout and skipped the call, which worked and was
           a trap: this function shows `loadout-lists` too, so with the call
           restored the guard upstream would be silently overruled -- two
           places answering one question, later one wins. */
        /* THE EMPTY CATALOGUE IS THE MECHANISM, and it is the whole of it.
           Everything below reads from these two lists: the sections are
           shown only when their list has something in it, the grids are only
           built inside those same guards, and nothing else here touches the
           DOM. So a player who may not choose produces exactly the same
           render as an arena with no weapons enabled -- minus the "no
           weapons enabled" notice, which would be a fault report and this
           is not a fault.

           There was an `if (!choosing) return` under this as well. It never
           did anything -- by the time it was reached both lists were already
           empty -- and a guard that cannot be observed is a guard nobody can
           maintain. */
        var choosing = canChooseLoadout();

        var firearms = choosing ? weaponCatalogue(false) : [];
        var blades = choosing ? weaponCatalogue(true) : [];

        /* meleeSlots = 0 is an operator switching melee off, and the panel
           should look like that was the intention: the section goes
           altogether rather than standing there empty or greyed out. The
           same reading applies to firearms -- an arena with no gun slots has
           no firearms list to show. */
        var gunsOn = weaponSlots() > 0 && firearms.length > 0;
        var meleeOn = meleeSlots() > 0 && blades.length > 0;

        show(byId('loadout-firearms'), gunsOn);
        show(byId('loadout-melee'), meleeOn);
        /* The box that holds them goes too, or it would sit in the same grid
           cell as the empty state below and stack on top of it. */
        show(byId('loadout-lists'), gunsOn || meleeOn);

        var empty = byId('loadout-empty');
        /* Not for somebody who was never offered a picker: "No weapons are
           enabled on this server" is a fault report, and being handed a
           loadout by the host is not a fault. */
        var sayEmpty = choosing && !gunsOn && !meleeOn;
        show(empty, sayEmpty);
        if (has(empty)) {
            clear(empty);
            if (sayEmpty) {
                empty.appendChild(makeEl('div', 'muted', 'No weapons are enabled on this server.'));
                empty.appendChild(makeEl('div', 'hint',
                    'Nothing will be issued to you when the round starts, apart from any supplies you take in.'));
            }
        }

        if (gunsOn) {
            var cats = firearmCategories(firearms);
            var active = activeCategory(cats);
            renderCategoryChips(cats, active);
            renderSectionCount('firearms-count', false);
            renderWeaponGrid('weapon-grid', firearms.filter(function (weapon) {
                return inCategory(weapon, active);
            }), plan);
        }

        if (meleeOn) {
            renderSectionCount('melee-count', true);
            /* NO TABS HERE. Melee is one section already; a filter over one
               short list is a control that costs a click and answers
               nothing. */
            renderWeaponGrid('melee-grid', blades, plan);
        }
    }

    /* '2 of 2 guns' beside the heading, lit when that pool is full so 'no
       room left in here' reads without anyone doing the sum. */
    function renderSectionCount(id, melee) {
        var host = byId(id);
        if (!has(host)) return;

        var limit = poolLimit(melee);
        host.textContent = poolCounterText(melee);
        host.classList.toggle('full', limit > 0 && draftCount(melee) >= limit);
        host.title = melee
            ? 'Melee has its own allowance. Filling your guns does not use a blade slot.'
            : 'Firearms have their own allowance. Filling them leaves your melee slots free.';
    }

    // ------------------------------------------------------------------
    // CATEGORY TABS -- FIREARMS ONLY
    //
    // They still earn their place: an operator with thirty guns wants
    // Sidearms and Precision apart, and the list is long enough that
    // scrolling alone is not an answer. They are built from the FIREARMS
    // only, so the old 'Melee' tab -- which now filters a list melee is not
    // in -- cannot appear, and they are dropped entirely when there is only
    // one group to choose between.
    // ------------------------------------------------------------------

    function firearmCategories(firearms) {
        var declared = arrayOf((cfg().loadouts || {}).categories).slice().sort(function (a, b) {
            return int(a.order, 999) - int(b.order, 999);
        });

        var known = bareMap();
        declared.forEach(function (entry) {
            if (entry && keyOr(entry.key, null) !== null) known[entry.key] = true;
        });

        var present = bareMap();
        var hasOther = false;
        firearms.forEach(function (weapon) {
            if (known[weapon.category] === true) present[weapon.category] = true;
            else hasOther = true;
        });

        var cats = [];
        declared.forEach(function (entry) {
            if (entry && present[entry.key] === true) {
                cats.push({ key: entry.key, label: entry.label || entry.key });
            }
        });
        /* A weapon whose category an operator never declared still has to be
           reachable, so it collects under 'Other' -- but only when one
           actually exists. */
        if (hasOther) cats.push({ key: '__other', label: 'Other' });
        return cats;
    }

    /* The filter the firearms list is really under. A category that has gone
       -- an operator edit, or the old shared grid's 'Melee' tab still sitting
       in state -- reads as 'All' rather than as an empty list with no way
       back to a full one. */
    function activeCategory(cats) {
        for (var i = 0; i < cats.length; i++) {
            if (cats[i].key === state.loadoutCategory) return state.loadoutCategory;
        }
        return 'all';
    }

    function inCategory(weapon, active) {
        if (active === 'all') return true;
        if (active === '__other') {
            return !arrayOf((cfg().loadouts || {}).categories).some(function (entry) {
                return entry && entry.key === weapon.category;
            });
        }
        return weapon.category === active;
    }

    function renderCategoryChips(cats, active) {
        var host = byId('loadout-cats');
        if (!has(host)) return;
        clear(host);

        /* One group is not a filter, and neither is a picker nobody may
           touch. */
        if (!canChooseLoadout() || cats.length < 2) {
            show(host, false);
            return;
        }
        show(host, true);

        [{ key: 'all', label: 'All' }].concat(cats).forEach(function (cat) {
            var chip = makeEl('button', 'chip', cat.label);
            chip.type = 'button';
            if (cat.key === active) chip.classList.add('active');
            chip.addEventListener('click', function () {
                state.loadoutCategory = cat.key;
                render();
            });
            host.appendChild(chip);
        });
    }

    // ------------------------------------------------------------------

    function renderWeaponGrid(id, weapons, plan) {
        var host = byId(id);
        if (!has(host)) return;
        clear(host);

        if (weapons.length === 0) {
            /* Only reachable from a filter that outlived the weapons under
               it. Says so, rather than leaving a blank box. */
            host.appendChild(makeEl('div', 'muted', 'Nothing in this group.'));
            return;
        }

        weapons.forEach(function (weapon) {
            host.appendChild(weaponCard(weapon, plan));
        });
    }

    function weaponCard(weapon, plan) {
        var index = draftIndexOf(weapon.key);
        var picked = index >= 0;
        var melee = isMelee(weapon);
        /* The weapon's own pool, not a total. This is the whole change. */
        var poolFull = !picked && draftCount(melee) >= poolLimit(melee);

        var card = makeEl('div', 'weapon-card');
        /* Addressable, so a test can click the control a player clicks
           rather than reaching past the panel into its internals -- and so
           the box below can name what it belongs to. */
        card.id = 'weapon-card-' + weapon.key;
        if (picked) card.classList.add('active');
        /* Dimmed rather than hidden or disabled: the weapon is still on
           offer, it is the allowance that is spent, and clicking it says
           which allowance in words. */
        if (poolFull && canChooseLoadout()) card.classList.add('blocked');

        card.appendChild(makeEl('div', 'weapon-name', weapon.label || weapon.key));
        card.appendChild(makeEl('div', 'weapon-category', weapon.category || 'other'));

        var ammo = weapon.ammo || {};
        var options = arrayOf(ammo.options);

        if (options.length > 0) {
            var row = makeEl('div', 'weapon-ammo');
            /* Named, because a bare row of numbers on a weapon card is a
               riddle to anyone who has not used this panel before. */
            row.appendChild(makeEl('span', 'weapon-field-label', 'Rounds'));
            var chosen = picked ? state.draftWeapons[index].ammo : int(ammo.default, 0);
            options.forEach(function (value) {
                var amount = int(value, 0);
                var chip = makeEl('button', 'chip', String(amount));
                chip.type = 'button';
                if (picked && amount === chosen) chip.classList.add('active');
                chip.disabled = !canChooseLoadout();
                chip.addEventListener('click', function (event) {
                    event.stopPropagation();
                    setWeaponAmmo(weapon.key, amount);
                });
                row.appendChild(chip);
            });

            /* THE TYPED AMOUNT, when the operator allows one.

               The presets stay -- they are what most people will click --
               and this sits beside them for anyone who wants a number that
               is not on the list.

               `max` is the ceiling and the server enforces it on every
               request whatever this box says, so the input is capped here
               only to tell the player where the limit is, never to be the
               thing that holds it. */
            /* UNDER THE WEAPON YOU CHOSE, and only then.
               A box on a weapon nobody has taken is asking how much
               ammunition they want for a gun they are not carrying. */
            if (allowsCustomAmmo(weapon) && picked) {
                var box = makeEl('input', 'weapon-ammo-custom');
                box.id = 'weapon-ammo-custom-' + weapon.key;
                box.type = 'number';
                box.min = '0';
                box.max = String(int(ammo.max, 0));
                box.step = '1';
                box.value = String(chosen);
                box.disabled = !canChooseLoadout();
                box.title = 'Type any amount up to ' + int(ammo.max, 0);

                /* Clicking into the box must not toggle the weapon card
                   underneath it, which is what every other click here does. */
                box.addEventListener('click', function (event) { event.stopPropagation(); });
                box.addEventListener('input', function (event) {
                    event.stopPropagation();
                    var wanted = clampInt(event.target.value, 0, int(ammo.max, 0));
                    /* Quiet: see setWeaponAmmo. Re-rendering here is what
                       made this box accept one digit at a time. */
                    setWeaponAmmo(weapon.key, wanted, true);
                });

                /* Clicking away is the end of typing, so the panel catches
                   up then -- the chips re-light against whatever was typed,
                   and a value the box clamped is written back visibly. */
                box.addEventListener('blur', function () { render(); });

                /* ENTER LOCKS IT IN.
                   Typing already updates the draft, so Enter is not what
                   makes the number count -- it is what SAVES, so a player
                   can set an amount and commit without hunting for the save
                   button at the bottom of the panel. */
                box.addEventListener('keydown', function (event) {
                    if (event.key !== 'Enter' && event.keyCode !== 13) return;
                    event.stopPropagation();
                    event.preventDefault();
                    setWeaponAmmo(weapon.key, clampInt(event.target.value, 0, int(ammo.max, 0)));
                    saveLoadout();
                });

                row.appendChild(box);
            }

            card.appendChild(row);
        } else if (melee) {
            card.appendChild(makeEl('div', 'weapon-fixed', 'Melee — nothing to load'));
        } else {
            /* No options means no choice to make, not no ammo -- the server
               hands out the default. Rendering an empty chip row would read
               as a broken picker. */
            card.appendChild(makeEl('div', 'weapon-fixed',
                'Always ' + plural(int(ammo.default, 0), 'round')));
        }

        /* THE AMMO TYPE. An empty list means this weapon offers no choice of
           round -- melee, or a weapon the operator switched types off for --
           and it gets no control at all, not a dead one reading 'none'. */
        var types = ammoTypesOf(weapon);
        /* ONE ROUND IS NOT A CHOICE, so it gets no control.
           
           Every weapon in a config generated from the server's own
           ox_inventory data carries exactly one ammo type -- the round that
           weapon's `ammoname` names -- so the picker was a row of one button,
           permanently selected, asking a question with a single answer. The
           correlation is already done; showing it as a choice only invites
           the player to look for one that is not there.

           A weapon an operator has genuinely given two or more rounds still
           gets the full picker. */
        if (types.length > 1) {
            var typeRow = makeEl('div', 'weapon-ammo');
            typeRow.appendChild(makeEl('span', 'weapon-field-label', 'Ammo type'));

            var entry = picked ? plan.byKey[weapon.key] : undefined;
            /* Lit only once the weapon is actually in the loadout, exactly
               like the amount chips above: highlighting a type on a weapon
               nobody has picked would claim a choice that was never made. */
            var chosenType = entry !== undefined ? entry.chosen : null;
            var defaultLabel = ammoTypeLabel(weapon, defaultAmmoType(weapon));
            /* With no weapon in the draft to re-plan around, the honest test
               for an unpicked weapon is the standing one: adding a weapon
               never frees a type slot, so a round the loadout is not already
               carrying would be swapped. */
            var capSpent = plan.cap > 0 && plan.distinct >= plan.cap;

            types.forEach(function (type) {
                var chip = makeEl('button', 'chip', type.label || type.key);
                chip.type = 'button';
                if (picked && type.key === chosenType) chip.classList.add('active');

                var swaps = picked
                    ? wouldSwap(weapon.key, type.key)
                    : (capSpent && plan.taken[type.key] !== true);
                /* MARKED, NOT DISABLED. The server takes the weapon either
                   way, so a chip that cannot be pressed says less than one
                   that says what pressing it would get you. */
                if (swaps) {
                    chip.classList.add('spent');
                    chip.title = 'This loadout is already carrying its '
                        + plural(plan.cap, 'round type') + '. Picking this one loads '
                        + (defaultLabel === null ? 'the default' : defaultLabel) + ' instead.';
                }

                chip.disabled = !canChooseLoadout();
                chip.addEventListener('click', function (event) {
                    event.stopPropagation();
                    setWeaponAmmoType(weapon.key, type.key);
                });
                typeRow.appendChild(chip);
            });
            card.appendChild(typeRow);

            /* The swap, said on the card it happened to, so nobody meets it
               for the first time at the start of a round. */
            if (entry !== undefined && entry.swapped === true) {
                var loadedLabel = ammoTypeLabel(weapon, entry.loaded);
                var wantedLabel = ammoTypeLabel(weapon, entry.chosen);
                card.appendChild(makeEl('div', 'weapon-note',
                    'Loaded with ' + (loadedLabel === null ? 'the default' : loadedLabel)
                    + ', not ' + (wantedLabel === null ? 'your pick' : wantedLabel)
                    + ' — this loadout is already carrying its ' + plural(plan.cap, 'round type') + '.'));
            }
        }

        if (poolFull && canChooseLoadout()) {
            card.appendChild(makeEl('div', 'weapon-note',
                (melee ? 'Melee is full' : 'Guns are full') + ' — ' + poolCounterText(melee)
                + '. Drop one to take this.'));
        }

        if (canChooseLoadout()) {
            card.addEventListener('click', function () {
                toggleWeapon(weapon.key);
            });
        } else {
            card.style.cursor = 'default';
        }

        return card;
    }

    // ------------------------------------------------------------------
    // THE SUMMARY
    //
    // The last thing a player reads before a round locks the choice in, so
    // it carries all of it: both counters, and per weapon the weapon, the
    // amount and the round -- the round the SERVER will load, which is not
    // always the one that was clicked.
    // ------------------------------------------------------------------

    function renderLoadoutSlots(plan) {
        var host = byId('loadout-slots');
        if (!has(host)) return;
        clear(host);

        host.appendChild(makeEl('div', 'panel-heading', 'Into The Round'));

        slotGroup(host, false, plan);
        slotGroup(host, true, plan);

        /* Only when there is a cap to report against.

           OVER THE ALLOWANCE IS A REAL STATE, not an arithmetic slip. When a
           weapon falls back to its own default round, the server counts that
           default towards the cap as well -- so a loadout that spent its one
           type on FMJ and then fell a rifle back to Standard is genuinely
           carrying two. '2 of 1 kind' would read as a broken sum, so the
           over case is written out as a sentence instead. */
        if (plan.cap > 0) {
            var line = makeEl('div', 'slot-types');
            line.appendChild(makeEl('span', 'slot-group-title', 'Round types'));
            var count = makeEl('span', 'loadout-count', plan.distinct <= plan.cap
                ? String(plan.distinct) + ' of ' + plural(plan.cap, 'kind')
                : plural(plan.distinct, 'kind') + ', over an allowance of ' + String(plan.cap));
            if (plan.distinct >= plan.cap) count.classList.add('full');
            line.appendChild(count);
            host.appendChild(line);

            if (plan.distinct > plan.cap) {
                host.appendChild(makeEl('div', 'hint',
                    'A weapon that fell back to its own default is carrying that round too, '
                    + 'and it counts. Pick a round this loadout already holds to stay inside '
                    + 'the allowance.'));
            }
        }

        /* WHAT HAPPENS TO THE GUNS THEY WALKED IN WITH -- the question every
           player asks before their first round, and the one thing on this
           screen the panel must not guess at. `restoreLoadoutOnExit` is an
           operator switch, and promising a player their own weapons back on
           a server that does not do that would be a lie told at the worst
           possible moment. So it is read off the snapshot, and SAYS NOTHING
           AT ALL when the snapshot does not carry it: silence is the honest
           third answer. */
        var restore = (cfg().match || {}).restoreLoadoutOnExit;
        if (restore === true) {
            host.appendChild(makeEl('div', 'hint',
                'Your own weapons and armour are held while you fight and handed back when you leave.'));
        } else if (restore === false) {
            host.appendChild(makeEl('div', 'hint',
                'This server does NOT give your own weapons back when you leave the arena.'));
        }
    }

    /* One pool's worth of the summary: its name, its counter, and one row
       per slot it has. A pool the operator switched off gets no group at
       all -- the same silence the picker keeps about it. */
    function slotGroup(host, melee, plan) {
        var limit = poolLimit(melee);
        if (limit <= 0) return;

        var head = makeEl('div', 'slot-group-head');
        head.appendChild(makeEl('span', 'slot-group-title', melee ? 'Melee' : 'Firearms'));
        var count = makeEl('span', 'loadout-count', poolCounterText(melee));
        if (draftCount(melee) >= limit) count.classList.add('full');
        head.appendChild(count);
        host.appendChild(head);

        var picks = state.draftWeapons.filter(function (pick) {
            var weapon = weaponByKey(pick.key);
            return weapon !== null && isMelee(weapon) === melee;
        });

        for (var i = 0; i < limit; i++) {
            host.appendChild(slotRow(picks[i], melee, plan));
        }
    }

    function slotRow(pick, melee, plan) {
        var slot = makeEl('div', 'slot');

        if (!pick) {
            slot.appendChild(makeEl('span', 'muted', canChooseLoadout()
                ? ('Empty — click ' + (melee ? 'a blade' : 'a gun') + ' to fill it')
                : 'Empty'));
            return slot;
        }

        slot.classList.add('filled');
        var weapon = weaponByKey(pick.key);

        var main = makeEl('div', 'slot-main');
        main.appendChild(makeEl('div', 'slot-name',
            (weapon && (weapon.label || weapon.key)) || pick.key));

        /* WEAPON, AMOUNT AND TYPE. A number on its own does not say what is
           in the magazine, and the round type is the one of the three that
           cannot be guessed from the weapon's name. */
        var detail = [];
        if (melee) detail.push('Melee');
        else detail.push(plural(int(pick.ammo, 0), 'round'));

        var entry = plan.byKey[pick.key];
        var loadedKey = entry !== undefined ? entry.loaded : keyOr(pick.ammoType, null);
        var typeName = ammoTypeLabel(weapon, loadedKey);
        if (typeName !== null) detail.push(typeName);

        main.appendChild(makeEl('div', 'slot-meta', detail.join('  ·  ')));

        if (entry !== undefined && entry.swapped === true) {
            var wanted = ammoTypeLabel(weapon, entry.chosen);
            main.appendChild(makeEl('div', 'slot-swap',
                'Not ' + (wanted === null ? 'your pick' : wanted)
                + ' — this loadout is already carrying its ' + plural(plan.cap, 'round type') + '.'));
        }

        slot.appendChild(main);

        if (canChooseLoadout()) {
            var drop = makeEl('button', 'chip', '✕');
            drop.type = 'button';
            drop.title = 'Drop this weapon.';
            drop.addEventListener('click', (function (key) {
                return function () { toggleWeapon(key); };
            }(pick.key)));
            slot.appendChild(drop);
        }

        return slot;
    }

    function renderLoadoutSaveRow() {
        /* The whole row goes, not just the button: a lone status line under
           a picker nobody may touch explains nothing. */
        show(byId('loadout-save-row'), canChooseLoadout());

        var save = byId('loadout-save');
        if (has(save)) {
            save.disabled = !state.loadoutDirty;
            save.title = state.loadoutDirty
                ? 'Keep these weapons for your next round.'
                : 'Nothing has changed since your last save.';
        }

        var status = byId('loadout-save-status');
        if (has(status)) {
            status.textContent = state.loadoutDirty
                ? 'Unsaved — press Save Loadout or you will fight with what you had before.'
                : 'Saved. This is what you are handed when a round starts.';
        }
    }

    /* The supplies block as the server sent it, or an empty stand-in. */
    function supplyConfig() {
        return (cfg().loadouts || {}).supplies || {};
    }

    function supplyCatalogue() {
        return arrayOf(supplyConfig().items);
    }

    /* How many items the draft asks for across every supply, for the shared
       ceiling. Counted rather than tracked, so it cannot drift out of step
       with the draft it describes. */
    function suppliesTaken(exceptKey) {
        var total = 0;
        var draft = state.draftSupplies || {};
        supplyCatalogue().forEach(function (supply) {
            if (supply.key === exceptKey) return;
            total += int(draft[supply.key], 0);
        });
        return total;
    }

    function renderSuppliesPicker() {
        var host = byId('supplies-picker');
        if (!has(host)) return;
        clear(host);

        var config = supplyConfig();
        var catalogue = supplyCatalogue();
        /* Off, or nothing switched on: the section is not drawn at all
           rather than drawn empty. An empty box with a heading reads as
           something broken. */
        if (config.enabled !== true || catalogue.length === 0) return;

        host.appendChild(makeEl('span', 'field-label', 'Supplies'));

        var draft = state.draftSupplies || {};
        var picking = config.allowChoose !== false && canChooseLoadout();
        var ceiling = int(config.totalItems, 0);

        catalogue.forEach(function (supply) {
            var row = makeEl('div', 'supply-row');
            row.appendChild(makeEl('span', 'supply-name', supply.label || supply.key));

            if (!picking) {
                /* WHAT THEY WILL ACTUALLY BE HANDED, which on a host-picks
                   server is the host's choice and not the operator's default
                   -- reading the default told a player they were carrying two
                   bandages while the host had set them none. */
                row.appendChild(makeEl('span', 'muted', String(int(draft[supply.key], 0))));
                host.appendChild(row);
                return;
            }

            var options = arrayOf(supply.options);
            if (options.length === 0) options = [0, int(supply.max, 0)];

            options.forEach(function (value) {
                var amount = int(value, 0);
                var max = int(supply.max, 0);
                if (amount > max) amount = max;

                var chip = makeEl('button', 'chip', amount === 0 ? 'None' : String(amount));
                chip.type = 'button';
                if (amount === int(draft[supply.key], -1)) chip.classList.add('active');

                /* THE SHARED CEILING IS SHOWN, NOT JUST ENFORCED. The server
                   clamps the total either way; a chip that silently gives
                   less than it says is how a player learns to distrust the
                   panel. */
                var wouldTotal = suppliesTaken(supply.key) + amount;
                if (ceiling > 0 && wouldTotal > ceiling) {
                    chip.classList.add('disabled');
                    chip.disabled = true;
                    chip.title = 'That would put you over the ' + ceiling + ' item limit.';
                }

                chip.addEventListener('click', function () {
                    state.draftSupplies[supply.key] = amount;
                    state.loadoutDirty = true;
                    render();
                });
                row.appendChild(chip);
            });

            host.appendChild(row);
        });

        if (!picking) {
            host.appendChild(makeEl('div', 'hint', hostPicksLoadout() && player().isHost !== true
                ? 'Set by the host of this match.'
                : 'Set by the server.'));
            return;
        }

        var hint = 'Spare kit you carry in. You always start every life on full health and full armour.';
        if (ceiling > 0) {
            hint += ' ' + suppliesTaken(null) + ' of ' + ceiling + ' carried.';
        }
        host.appendChild(makeEl('div', 'hint', hint));
    }

    function saveLoadout() {
        if (!canChooseLoadout()) return;
        post('setLoadout', {
            weapons: state.draftWeapons.map(function (pick) {
                var entry = { key: pick.key, ammo: int(pick.ammo, 0) };
                /* ONLY WHEN THERE IS ONE TO SEND. A weapon with no types has
                   no key to name, and the server reads a missing field as
                   "whatever this weapon loads normally" -- which is the
                   right answer for melee and the wrong one to invent a
                   value for. */
                var type = keyOr(pick.ammoType, null);
                if (type !== null) entry.ammoType = type;
                return entry;
            }),
            /* NAMED, and only the ones with a count. The server reads a
               missing entry as "the operator's default for that supply",
               which is the right answer for a panel that never drew the
               section -- and the wrong one to invent for a player who chose
               none, so a zero is sent rather than left out. */
            supplies: supplyCatalogue().map(function (supply) {
                return { key: supply.key, count: int((state.draftSupplies || {})[supply.key], 0) };
            })
        });
        /* Cleared optimistically: the server's answer is the next snapshot,
           and leaving the draft dirty would stop it re-seeding from what
           the player was actually given. */
        state.loadoutDirty = false;
        render();
    }

    // ------------------------------------------------------------------
    // BETS
    // ------------------------------------------------------------------

    /* The pick a side-bet names: a team key in team modes, the fighter's
       server id as a string in a free-for-all. Matches what
       server/betting.lua's canonicalPick accepts. */
    /* WHETHER THIS PLAYER IS FIGHTING IN THE MATCH THEY ARE LOOKING AT.
       The whole bet screen branches on it: a fighter and a spectator are
       betting under different rules, out of different bands, on a different
       set of picks. */
    function betAsFighter(match) {
        return !!match && playerMatchId() === match.id;
    }

    /* The band and the switch that apply to THIS player on THIS match.
       Reading spectatorBets for a fighter is how a fighter came to be told
       the biggest bet was a number that was never theirs. */
    function betRules(match) {
        return betAsFighter(match)
            ? (betting().fighterBets || {})
            : (betting().spectatorBets || {});
    }

    /* The one side a fighter is allowed to back, or null where they may back
       anybody. Computed exactly as ownSideOf does on the server -- their team
       in a team mode, their own server id otherwise -- because a panel that
       computes it differently offers a chip the server then refuses. */
    function ownSide(match) {
        if (!betAsFighter(match)) return null;
        if ((betting().fighterBets || {}).ownSideOnly === false) return null;
        if (match.teams === true && player().team) return String(player().team);
        return String(int(player().serverId, 0));
    }

    /* HOW A WINNING BET IS PAID, for this bettor on this match.

       'pool' is a share of everything staked, split in proportion to what
       each backer put in. The figure is not knowable while bets are still
       open -- it depends on who else backs what -- so the panel must not
       quote one. 'odds' is the fixed multiplier, funded by the server.

       Defaults to 'pool', which is what the server does with an unset value:
       guessing 'odds' would put a number on screen that nothing pays. */
    function betMode(match) {
        var block = betting().betPayout || {};
        var mode = betAsFighter(match) ? block.fighters : block.spectators;
        return mode === 'odds' ? 'odds' : 'pool';
    }

    function betPickOptions(match) {
        if (!match) return [];
        if (match.teams === true) {
            return arrayOf((cfg().teams || {}).list)
                .filter(function (team) { return teamCountOf(match, team.key) > 0; })
                .map(function (team) {
                    return { pick: team.key, label: team.label || team.key, color: teamColor(team) };
                });
        }
        return arrayOf(match.players).map(function (entry) {
            return { pick: String(int(entry.id, 0)), label: entry.name || ('#' + int(entry.id, 0)), color: null };
        });
    }

    function renderBets() {
        var enabled = bettingOn();
        var disabled = byId('bet-disabled');

        show(disabled, !enabled);
        if (has(disabled) && !enabled) {
            /* Switched off is a decision an operator made, and it should
               read as one. A bare 'disabled' reads as a fault. */
            clear(disabled);
            disabled.appendChild(makeEl('div', null, 'No money in this arena'));
            disabled.appendChild(makeEl('div', 'bet-disabled-sub',
                'This server runs its matches for nothing: no entry fee, no pot and no side-bets. '
                + 'Wins and kills still count towards the leaderboard.'));
        }

        ['bet-summary', 'bet-form', 'bet-list'].forEach(function (id) {
            show(byId(id), enabled);
        });
        if (!enabled) return;

        var match = focusedMatch();
        renderBetSummary(match);
        renderBetNote();
        renderBetPick(match);
        renderBetControls(match);
        renderBetList(match);
    }

    /* Where the money on this screen comes from and where it goes. Two
       pools, and a player who thinks they are the same one will think a
       side-bet is changing what the winner takes home. */
    function renderBetNote() {
        var host = byId('bet-note');
        if (!has(host)) return;

        var spectator = betting().spectatorBets || {};
        var fighter = betting().fighterBets || {};
        /* True whichever payout rule this server runs: the stake stays in
           the pot, and what the pot then does is the clause above. */
        var text = 'Every fighter pays the entry fee into the pot, and at the end of the round '
            + payoutPhrase() + '. Being eliminated ends your round and your fee stays in the pot.';
        if (spectator.enabled === true) {
            text += ' A side-bet below is separate from the pot, and it never changes what the '
                + 'winners take.';
        }
        if (fighter.enabled === true) {
            /* Said plainly because it is the part people get wrong: a
               winning bet is a share of what everybody staked, so it is
               bigger when more people were wrong and smaller when they
               were not. Nothing is created to pay it. */
            text += ' You can also back yourself'
                + (fighter.ownSideOnly === false ? '' : ' — and only yourself')
                + ' in a match you are fighting in. Winning bets share out the whole betting pool '
                + 'in proportion to what each backer staked; the money comes from the other bets, '
                + 'never from the server.';
        }
        host.textContent = text;
    }

    function renderBetSummary(match) {
        var host = byId('bet-summary');
        if (!has(host)) return;
        clear(host);

        function stat(label, value) {
            var box = makeEl('div', 'bet-stat');
            box.appendChild(makeEl('span', 'bet-stat-label', label));
            box.appendChild(makeEl('span', 'bet-stat-value', value));
            host.appendChild(box);
        }

        /* The account they are actually paying from, and what is in it. The
           strip used to name the operator's settlement account and show its
           balance whatever the player had picked, so somebody paying from the
           bank was reading their cash. */
        var from = chosenAccount();
        stat('Your ' + titleCase(from), money(balanceIn(from)));
        stat('Pot', match ? money(match.pot) : money(0));
        stat('Entry fee', match ? money(match.entryFee) : money(0));
        /* `winner_takes_all` is how config spells it, not how anybody reads
           it. The whole rule is a sentence in the note below this strip;
           this is the two words that fit under the heading. */
        stat('Pot goes to', labelFor(PAYOUT_SHORT, betting().payout, 'The winner'));

        var spectator = betting().spectatorBets || {};
        if (spectator.enabled === true || (betting().fighterBets || {}).enabled === true) {
            /* 'x2' is only true under the fixed-odds rule. Under the pool
               rule the figure does not exist yet -- it depends on who else
               backs what -- and printing one anyway is the panel promising
               something nothing pays. */
            stat('Bets pay', betMode(match) === 'odds'
                ? 'x' + String(Number(spectator.oddsMultiplier) || 2)
                : 'Share of pool');
        }

        if (!match) {
            host.appendChild(makeEl('div', 'hint',
                'No match picked. Choose one on the Matches tab and its pot shows here.'));
        }
    }

    function renderBetPick(match) {
        var host = byId('bet-pick');
        if (!has(host)) return;
        clear(host);

        if (betRules(match).enabled !== true) {
            host.appendChild(makeEl('div', 'hint',
                betAsFighter(match)
                    ? 'Fighters cannot bet on this server. You are already playing for the pot.'
                    : 'Side-bets are switched off on this server. You can still fight for the pot: '
                        + 'join a match on the Matches tab.'));
            return;
        }
        if (!match) return;

        /* A FIGHTER HELD TO THEIR OWN SIDE IS OFFERED ONLY THAT SIDE. The
           other chips are not disabled, they are absent: a row of names you
           may not click, on a screen about money, reads as a bug. */
        var own = ownSide(match);
        var options = betPickOptions(match).filter(function (option) {
            return own === null || String(option.pick) === own;
        });
        if (options.length === 0) {
            host.appendChild(makeEl('div', 'hint',
                'Nobody has joined this match yet, so there is nobody to back.'));
            return;
        }

        /* The chips are names and team labels with nothing above them
           otherwise -- and a name on a chip does not say what clicking it
           means. */
        host.appendChild(makeEl('span', 'field-label', 'Backing'));

        options.forEach(function (option) {
            var chip = makeEl('button', 'chip', option.label);
            chip.type = 'button';
            if (option.color) chip.style.borderLeft = '3px solid ' + option.color;
            if (option.pick === state.betPick) chip.classList.add('active');
            chip.addEventListener('click', function () {
                state.betPick = option.pick;
                render();
            });
            host.appendChild(chip);
        });
    }

    /* Why this player cannot place a side-bet on this match right now, or
       null. Same courtesy as the join button: the server decides, this
       explains. */
    function betBlockedReason(match) {
        if (!match) return 'Pick a match on the Matches tab first.';

        var fighting = betAsFighter(match);
        var rules = betRules(match);

        /* THE LINE THAT USED TO BE HERE:

               if (playerMatchId() === match.id)
                   return 'You are fighting in this match. You cannot bet on yourself.'

           It was true when it was written and stopped being true when
           fighterBets shipped. server/betting.lua takes a fighter's bet,
           holds it to their own side, settles it out of the pool and pays it
           like any other -- and this refused every one before it reached the
           wire. The feature was on, correct and unreachable. */
        if (rules.enabled !== true) {
            return fighting
                ? 'Fighters cannot bet on this server. Your entry fee is already on the line.'
                : 'Side-bets are switched off on this server.';
        }

        if (match.state === 'ended') return 'This match has finished.';
        if (!state.betPick) return 'Choose who you are backing.';

        /* Held to their own side, and told so BEFORE the click rather than
           by a refusal after it. Backing the other side is being paid to
           lose on purpose, which an arena is exactly the place for. */
        var own = ownSide(match);
        if (own !== null && String(state.betPick) !== own) {
            return match.teams === true
                ? 'You are fighting in this match, so you can only back your own team.'
                : 'You are fighting in this match, so you can only back yourself.';
        }

        var amount = int(state.betAmount, 0);
        var min = int(rules.min, 0);
        var max = int(rules.max, 0);
        if (amount < min) return 'The smallest bet is ' + money(min) + '.';
        if (max > 0 && amount > max) return 'The biggest bet is ' + money(max) + '.';
        /* THE ACCOUNT THEY PICKED, not their richest one. The server tries
           only the chosen account -- spending the other would be taking money
           out of a pocket they deliberately left alone -- so the panel has to
           refuse against the same balance the server will check, or it offers
           a bet that comes back rejected. */
        var from = chosenAccount();
        if (amount > balanceIn(from)) {
            return accountChoiceOffered()
                ? 'You do not have ' + money(amount) + ' in ' + titleCase(from) + '.'
                : 'You do not have ' + money(amount) + '.';
        }
        return null;
    }

    function renderBetControls(match) {
        /* Whichever rule applies to this player. A server with spectator
           bets off and fighter bets on used to draw no form at all, so the
           fighters it was switched on for could not see it. */
        var rules = betRules(match);
        var usable = rules.enabled === true;

        var input = byId('bet-amount');
        show(byId('bet-amount-row'), usable);
        if (has(input) && usable) {
            input.min = String(int(rules.min, 0));
            if (int(rules.max, 0) > 0) input.max = String(int(rules.max, 0));
            if (document.activeElement !== input) input.value = String(int(state.betAmount, 0));
        }

        renderAccountPicker('bet-account');
        show(byId('bet-account-row'), usable && accountChoiceOffered());

        var reason = betBlockedReason(match);

        /* The reason is written under the control rather than hidden in a
           tooltip: a bet that cannot be placed and does not say why is the
           panel looking broken. */
        var hint = byId('bet-hint');
        show(hint, usable);
        if (has(hint) && usable) {
            if (reason !== null) {
                hint.textContent = reason;
            } else if (betMode(match) === 'odds') {
                var odds = Number((betting().spectatorBets || {}).oddsMultiplier) || 2;
                hint.textContent = 'If they win you are paid ' + money(int(state.betAmount, 0) * odds)
                    + '. If they lose, the stake is gone.';
            } else if (betAsFighter(match)) {
                /* "THE STAKE IS GONE" IS ONLY TRUE OF FIXED ODDS, and saying
                   it here was the panel promising a loss the settlement does
                   not take. A pool has no house behind it: a losing stake is
                   paid to whoever backed the winner, and where nobody did --
                   nobody bet against you, or nobody backed the side that won
                   -- there is nobody to pay it to and it comes back. A player
                   told their money was gone and then handed it back does not
                   read that as generosity, they read it as the arena being
                   broken, which is the same complaint from the other end. */
                hint.textContent = 'Backing yourself with ' + money(int(state.betAmount, 0))
                    + ' on top of your entry fee. If you win you take a share of the whole betting '
                    + 'pool, in proportion to what you staked — so you only profit if somebody '
                    + 'backed the other side. If you lose, your stake goes to whoever backed the '
                    + 'winner. Either way, if nobody bet against you it is handed back.';
            } else {
                hint.textContent = 'Staking ' + money(int(state.betAmount, 0))
                    + '. If they win you take a share of the whole betting pool, in proportion to '
                    + 'what you staked — so you only profit if somebody backed another side. If '
                    + 'they lose, your stake goes to whoever backed the winner. Either way, if '
                    + 'nobody backed a different side it is handed back.';
            }
        }

        /* THE BET THEY ALREADY HAVE DOWN. Without this the screen looked
           identical before and after placing one -- the entry pot does not
           move for a side-bet, by design, so there was nothing else to
           change and no way to tell a bet that was taken from one that was
           refused. */
        var mine = player().bet;
        if (has(hint) && usable && mine && int(mine.amount, 0) > 0) {
            var backed = null;
            betPickOptions(match).forEach(function (option) {
                if (String(option.pick) === String(mine.pick)) backed = option.label;
            });
            hint.textContent = 'You have ' + money(int(mine.amount, 0)) + ' on '
                + (backed || String(mine.pick)) + '.'
                + (reason === null ? '' : '  ' + reason);
        }

        var submit = byId('bet-submit');
        show(submit, usable);
        if (has(submit) && usable) {
            submit.disabled = reason !== null;
            submit.title = reason || '';
            submit.onclick = function () {
                if (!match) return;
                post('spectatorBet', {
                    matchId: match.id,
                    pick: state.betPick,
                    amount: int(state.betAmount, 0),
                    account: chosenAccount()
                });
            };
        }
    }

    /* The snapshot carries no list of placed side-bets -- betting.lua keeps
       those to itself -- so this shows what the panel can prove: who is in
       the pot and what each of them staked. */
    function renderBetList(match) {
        var host = byId('bet-list');
        if (!has(host)) return;
        clear(host);

        if (!match) {
            host.appendChild(makeEl('div', 'hint',
                'No match picked. Choose one on the Matches tab to see who has paid into its pot.'));
            return;
        }

        var header = makeEl('div', 'bet-row');
        header.appendChild(makeEl('span', 'bet-stat-label', 'Paid into the pot'));
        header.appendChild(makeEl('span', 'bet-stat-label', money(match.pot)));
        host.appendChild(header);

        var fee = int(match.entryFee, 0);
        var anyOut = false;
        arrayOf(match.players).forEach(function (entry) {
            if (!entry) return;
            var row = makeEl('div', 'bet-row');
            if (entry.alive === false) {
                row.classList.add('lost');
                anyOut = true;
            }
            row.appendChild(makeEl('span', null, entry.name || ('#' + int(entry.id, 0))));
            row.appendChild(makeEl('span', null, money(fee)));
            host.appendChild(row);
        });

        /* The dimmed rows mean something. Said once, and only when there is
           a dimmed row to explain. */
        if (anyOut) host.appendChild(makeEl('div', 'hint', 'Dimmed names are out of the round.'));
    }

    // ------------------------------------------------------------------
    // LEADERBOARD
    // ------------------------------------------------------------------

    function renderBoard() {
        var body = byId('leaderboard-body');
        if (!has(body)) return;
        clear(body);

        if (state.leaderboard.length === 0) {
            var empty = document.createElement('tr');
            var cell = makeEl('td', 'muted',
                'No match has been finished yet. Win one and you are the first name on this board.');
            cell.colSpan = 6;
            empty.appendChild(cell);
            body.appendChild(empty);
            return;
        }

        state.leaderboard.forEach(function (entry, index) {
            if (!entry) return;
            var row = document.createElement('tr');
            [
                String(index + 1),
                entry.name || '',
                String(int(entry.wins, 0)),
                String(int(entry.kills, 0)),
                String(int(entry.deaths, 0)),
                money(entry.earnings)
            ].forEach(function (text) {
                row.appendChild(makeEl('td', null, text));
            });
            body.appendChild(row);
        });
    }

    // ==================================================================
    // IN-MATCH OVERLAY
    //
    // Rendered straight from the `hud` message and NOT from `state.config`
    // or the panel's render pass: it is on screen while the player is
    // shooting and the panel is closed, so it must not depend on either.
    // ==================================================================

    function renderHud() {
        var root = byId('arena-hud');
        if (!has(root)) return;

        show(root, state.hudVisible);
        if (!state.hudVisible) return;

        var timer = byId('hud-timer');
        var alive = byId('hud-alive');
        var kills = byId('hud-kills');

        /* The overlay can be switched on before any numbers exist -- the
           sweep that fills it runs once a second. Blank fields say "not
           yet"; zeros would claim an empty arena. */
        if (!state.hud) {
            if (has(timer)) timer.textContent = '';
            if (has(alive)) alive.textContent = '';
            if (has(kills)) kills.textContent = '';
            show(byId('hud-pot'), false);
            clear(byId('hud-scoreboard'));
            return;
        }

        var hud = state.hud;

        if (has(timer)) {
            var left = hud.timeLeft;
            /* A round with no time limit has nothing to count down; an
               empty clock beats a frozen 0:00. */
            timer.textContent = (left === null || left === undefined) ? '' : clock(left);
        }

        if (has(alive)) alive.textContent = 'Alive ' + int(hud.alive, 0) + ' / ' + int(hud.total, 0);

        if (has(kills)) kills.textContent = 'Kills ' + int(hud.kills, 0) + '  Deaths ' + int(hud.deaths, 0);

        var pot = byId('hud-pot');
        if (has(pot)) {
            var amount = int(hud.pot, 0);
            show(pot, bettingOn() && amount > 0);
            pot.textContent = 'Pot ' + money(amount);
        }

        renderHudScoreboard(arrayOf(hud.scoreboard));
    }

    /* One row, name first. `entry.name` is another player's, so it is a
       text node and never markup. Shared with the end-of-match board below:
       the class is styled by a bare `.hud-score-row` rule, not by anything
       scoped to the overlay, so it draws the same in both places. */
    function scoreRow(entry, me) {
        var row = makeEl('div', 'hud-score-row');
        if (int(entry.id, -1) === me) row.classList.add('self');
        if (entry.alive === false) row.classList.add('dead');

        var team = teamByKey(entry.team);
        var name = makeEl('span', null, entry.name || ('#' + int(entry.id, 0)));
        if (team) name.style.borderLeft = '3px solid ' + teamColor(team);
        row.appendChild(name);

        row.appendChild(makeEl('span', null, String(int(entry.kills, 0))));
        row.appendChild(makeEl('span', null, String(int(entry.deaths, 0))));
        return row;
    }

    function renderHudScoreboard(rows) {
        var host = byId('hud-scoreboard');
        if (!has(host)) return;
        clear(host);

        var me = int(player().serverId, -1);
        rows.slice(0, HUD_SCORE_ROWS).forEach(function (entry) {
            if (!entry) return;
            host.appendChild(scoreRow(entry, me));
        });
    }

    /* The countdown hides ITSELF when its own clock runs out rather than
       waiting to be told to. The lobby countdown's last push is "1" and the
       round starts a second later -- there is no zero on the wire, and a
       stuck number burnt over live gameplay is not something a player can
       clear. The grace covers a late push arriving just after the tick. */
    var countdownTimer = null;

    function hideCountdown() {
        if (countdownTimer !== null) {
            window.clearTimeout(countdownTimer);
            countdownTimer = null;
        }
        show(byId('arena-countdown'), false);
    }

    function renderCountdown(seconds, label) {
        var root = byId('arena-countdown');
        if (!has(root)) return;

        var value = int(seconds, 0);
        if (value <= 0) {
            hideCountdown();
            return;
        }

        /* A new round is starting, so the last one's board has had its say --
           and a countdown drawn through it would be two overlays arguing over
           the same screen. */
        hideResults();

        var digits = byId('countdown-value');
        if (has(digits)) digits.textContent = String(value);

        var caption = byId('countdown-label');
        if (has(caption)) caption.textContent = typeof label === 'string' ? label : '';

        if (countdownTimer !== null) window.clearTimeout(countdownTimer);
        countdownTimer = window.setTimeout(hideCountdown, value * 1000 + 1500);

        show(root, true);
    }

    // ==================================================================
    // MESSAGES FROM LUA
    // ==================================================================

    window.addEventListener('message', function (event) {
        var payload = event.data;
        if (!payload || typeof payload !== 'object') return;
        var data = (payload.data && typeof payload.data === 'object') ? payload.data : {};

        guarded(function () {
            switch (payload.action) {
                case 'open':
                    openPanel(data);
                    break;

                case 'close':
                    /* Lua already knows -- this IS its close. Posting back
                       would bounce a second close at a closed panel. */
                    hidePanel();
                    break;

                case 'state':
                    applySnapshot(data);
                    render();
                    /* The overlay reads config for the pot line, so a
                       snapshot that changes it must reach the HUD too. */
                    renderHud();
                    break;

                case 'notify':
                    toast(data.message, data.type);
                    break;

                case 'hud':
                    state.hudVisible = data.visible === true;
                    /* client/match.lua nests the match payload under `hud`;
                       ArenaUI.UpdateHud sends visibility on its own. Both
                       shapes are read, and a bare visibility message leaves
                       the numbers alone instead of blanking them. */
                    if (data.hud && typeof data.hud === 'object') state.hud = data.hud;
                    else if (data.scoreboard !== undefined || data.alive !== undefined) state.hud = data;
                    if (!state.hudVisible) state.hud = null;
                    renderHud();
                    break;

                case 'countdown':
                    renderCountdown(data.seconds, data.label);
                    break;

                case 'results':
                    showResults(data.results);
                    break;

                default:
                    break;
            }
        });
    });

    /* The end-of-match board. It is built here and thrown away again rather
       than declared in index.html, because it is on screen for twelve
       seconds a match and an element that exists the rest of the time is one
       more thing that can be left showing. Styled inline from the same
       custom properties applyTheme writes, so recolouring the panel
       recolours this with it. */
    var resultsTimer = null;
    /* Held rather than looked up again: this node is the page's only one that
       is not in index.html, and the reference is what guarantees the board
       being replaced is the board that gets removed. */
    var resultsNode = null;

    function styled(node, styles) {
        Object.keys(styles).forEach(function (key) { node.style[key] = styles[key]; });
        return node;
    }

    function hideResults() {
        if (resultsTimer !== null) {
            window.clearTimeout(resultsTimer);
            resultsTimer = null;
        }
        if (resultsNode && resultsNode.parentNode) resultsNode.parentNode.removeChild(resultsNode);
        resultsNode = null;
    }

    /* Placement, kills, deaths and earnings as one line -- and only the
       parts this payload actually carries. A spectator's block has no
       placement and no kill count, and '0 kill(s), 0 death(s)' would be a
       claim about them rather than a blank. */
    function resultsSummary(results) {
        var bits = [];
        if (results.placement) bits.push('Placed #' + int(results.placement, 0));
        if (results.kills !== undefined || results.deaths !== undefined) {
            bits.push(plural(results.kills, 'kill') + ', ' + plural(results.deaths, 'death'));
        }
        /* Read off the number rather than off the betting switch: earnings
           only exist when there was a pot, and the switch lives in a
           snapshot this client may never have fetched. */
        if (int(results.earnings, 0) > 0) bits.push('Won ' + money(results.earnings));
        return bits.join('  ·  ');
    }

    /* The round is over: the live overlay and the countdown come down with
       it, and the board goes up in their place. It is inert and under the
       panel, like every other thing drawn over gameplay -- a scoreboard that
       took NUI focus would take the controls of a player who has just been
       dropped back at the lobby ped, and one drawn over the modal would be
       the failure the HUD's own z-index note is written against. */
    function showResults(results) {
        state.hudVisible = false;
        state.hud = null;
        renderHud();
        hideCountdown();
        hideResults();

        if (!results || typeof results !== 'object') return;

        var won = results.won === true;

        var root = styled(makeEl('div', null), {
            position: 'fixed',
            top: '18%',
            left: '50%',
            transform: 'translateX(-50%)',
            width: '24rem',
            maxWidth: '90vw',
            padding: '0.9rem 1.1rem',
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderLeft: '3px solid ' + (won ? 'var(--success)' : 'var(--accent)'),
            boxShadow: '0 1rem 3rem rgba(0, 0, 0, 0.75)',
            zIndex: '7',
            /* Inherited by every node below, so a click on the board goes
               into the game the way one on the HUD does. */
            pointerEvents: 'none'
        });
        root.id = 'arena-results';

        root.appendChild(styled(makeEl('div', null, won ? 'You Won' : 'Match Over'), {
            fontFamily: 'var(--font-display)',
            fontSize: '1.6rem',
            letterSpacing: '0.12em',
            textTransform: 'uppercase',
            textAlign: 'center',
            color: won ? 'var(--success)' : 'var(--accent-bright)'
        }));

        var summary = resultsSummary(results);
        if (summary !== '') {
            root.appendChild(styled(makeEl('div', null, summary), {
                marginTop: '0.3rem',
                textAlign: 'center',
                color: 'var(--text-muted)'
            }));
        }

        var rows = arrayOf(results.scoreboard);
        if (rows.length > 0) {
            var board = styled(makeEl('div', null), {
                marginTop: '0.8rem',
                borderTop: '1px solid var(--border)'
            });
            var me = int(player().serverId, -1);
            rows.slice(0, HUD_SCORE_ROWS).forEach(function (entry) {
                if (entry) board.appendChild(scoreRow(entry, me));
            });
            root.appendChild(board);
        }

        resultsNode = root;
        document.body.appendChild(root);
        resultsTimer = window.setTimeout(hideResults, RESULTS_MS);

        /* The board sits under the panel, so a player who still has the menu
           open would see nothing at all. The toast rail is inside the panel
           and is exactly what they are looking at. */
        if (state.open) {
            var said = (won ? 'You won.' : 'Match over.') + (summary === '' ? '' : '  ·  ' + summary);
            toast(said, won ? 'success' : 'info');
        }
    }

    // ==================================================================
    // INPUT
    // ==================================================================

    /* The audio unlock, on the capture phase so a handler that stops the
       event does not also silence the panel. Both are cheap enough to leave
       registered for the life of the page: unlockAudio does nothing at all
       unless there is a suspended context to resume. */
    document.addEventListener('pointerdown', unlockAudio, true);
    document.addEventListener('keydown', unlockAudio, true);

    document.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape' && event.key !== 'Esc') return;
        if (!state.open) return;
        event.preventDefault();
        closePanel();
    });

    function bind(id, type, handler) {
        var node = byId(id);
        if (has(node)) node.addEventListener(type, handler);
    }

    bind('arena-close', 'click', closePanel);

    document.querySelectorAll('.arena-tab').forEach(function (button) {
        button.addEventListener('click', function () {
            var name = button.getAttribute('data-tab');
            if (TABS.indexOf(name) < 0) return;
            if (name !== state.tab) play('tab');
            state.tab = name;
            /* Every other block of the snapshot is pushed when it changes.
               The leaderboard is the one that goes stale on a timer, so
               opening it is the one place worth asking for a fresh one --
               and the server rate-limits the ask anyway. */
            if (name === 'board') post('refresh');
            render();
        });
    });

    bind('create-arena', 'change', function (event) {
        state.createArena = event.target.value;
        render();
    });

    bind('create-mode', 'change', function (event) {
        state.createMode = event.target.value;
        render();
    });

    /* Tracked on every keystroke so render() never has to write back into
       an input the player is still typing in. */
    bind('create-lives', 'input', function (event) {
        var choice = (cfg().match || {}).livesChoice || {};
        state.createLives = clampInt(event.target.value, int(choice.min, 1), int(choice.max, 1));
    });

    bind('create-fee', 'input', function (event) {
        var fee = (betting().entryFee) || {};
        state.createFee = clampInt(event.target.value, int(fee.min, 0), int(fee.max, 0));
    });

    bind('create-submit', 'click', function () {
        /* Same form, two jobs. Hosting an open lobby makes this an edit --
           and the fee is deliberately absent from that payload rather than
           sent and ignored, so the panel is not asking for something it has
           just told the player it cannot have. */
        if (editableMatch()) {
            post('updateMatch', {
                arenaKey: state.createArena,
                modeKey: state.createMode,
                lives: int(state.createLives, 1),
                /* radarIsOn(), not state.createRadar: an untouched toggle is
                   null, and null on the wire means "leave it alone" -- which
                   is not what the host sees on a button reading Radar Off. */
                radar: radarIsOn()
            });
            return;
        }

        post('createMatch', {
            arenaKey: state.createArena,
            modeKey: state.createMode,
            entryFee: int(state.createFee, 0),
            lives: int(state.createLives, 1),
            radar: radarIsOn(),
            /* The host joins their own match through the same door as
               everybody else, so their entry fee comes out of the account
               they picked here. */
            account: chosenAccount()
        });
    });

    bind('loadout-save', 'click', saveLoadout);

    bind('bet-amount', 'input', function (event) {
        /* The ceiling that applies to THIS player on the match in front of
           them: a fighter's band is not the spectators'. The floor stays 0
           rather than the minimum, so the box can be cleared and retyped --
           betBlockedReason is what refuses an amount under the minimum, with
           a sentence saying what it is.

           Unlike the weapon ammo box this one may re-render: it is a static
           element in index.html, so nothing rebuilds it under the caret, and
           renderBetControls will not write back into it while it has focus. */
        var rules = betRules(focusedMatch());
        state.betAmount = clampInt(event.target.value, 0, int(rules.max, 0));
        render();
    });

    /* Nothing is drawn until Lua sends `open`; the page is loaded the whole
       time the resource is running, and an unopened panel must be invisible
       rather than an empty frame over the game. */
    hidePanel();
}());

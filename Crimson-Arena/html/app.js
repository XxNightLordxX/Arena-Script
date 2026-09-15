// Crimson Arena: how the panel behaves. Screens, forms, live updates.

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

    var TOAST_MS = 5000;
    var TOAST_MAX = 4;

    var HUD_SCORE_ROWS = 10;

    var RESULTS_MS = 12000;

    var state = {
        createRadar: null,
        payAccount: null,
        open: false,
        config: null,
        player: null,
        matches: [],
        leaderboard: [],
        schedule: null,

        tab: 'matches',

        createArena: null,
        createMode: null,
        createFee: null,

        createLives: null,
        createWin: null,
        /* The match you were in on the LAST snapshot, so joining one can be
           told from merely being in one. See the note in applySnapshot. */
        lastMatchId: null,
        createTiers: {},
        createLimit: null,
        createRound: null,
        /* WHETHER THE HOST HAS TOUCHED THE ROUND LENGTH BOX.
           Until they do, the box FOLLOWS THE MODE -- see seedRoundForMode.
           A plain "is it still null" test cannot stand in for this, because
           the box is seeded on the very first snapshot and is never null
           again after that. */
        createRoundTouched: false,

        seededFromMatch: null,

        selectedMatchId: null,

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
        loadoutSaving: false,

        betPick: null,
        betPickMatchId: null,
        betAmount: null,

        hud: null,
        hudVisible: false,

        lastMatchState: null
    };

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

    function keyOr(value, fallback) {
        return (typeof value === 'string' && value !== '') ? value : fallback;
    }

    function plural(count, one, many) {
        var n = int(count, 0);
        return String(n) + ' ' + (n === 1 ? one : (many || (one + 's')));
    }

    function capitalise(text) {
        var value = String(text === undefined || text === null ? '' : text);
        return value === '' ? '' : value.charAt(0).toUpperCase() + value.slice(1);
    }

    function labelFor(map, key, fallback) {
        if (typeof key === 'string' && Object.prototype.hasOwnProperty.call(map, key)) {
            return map[key];
        }
        if (typeof key === 'string' && key !== '') return key;
        return fallback === undefined ? '' : fallback;
    }

    var STATE_BADGE = {
        lobby: 'Open',
        countdown: 'Starting',
        live: 'Fighting',
        ended: 'Finished'
    };

    var STATE_TEXT = {
        lobby: 'Waiting for players',
        countdown: 'Starting now',
        live: 'Round in progress',
        ended: 'Finished'
    };

    var PAYOUT_TEXT = {
        winner_takes_all: 'the winner takes the lot',
        per_kill: 'it is split by kills scored'
    };

    var PAYOUT_SHORT = {
        winner_takes_all: 'Winner takes all',
        per_kill: 'Split by kills'
    };

    var tierSelects = {};

    var WIN_CONDITION_TEXT = {
        last_standing: 'last one standing',
        most_kills: 'most kills when the clock runs out',
        score_limit: 'first to the kill limit'
    };

    var WIN_CONDITION_TEAM_TEXT = {
        last_standing: 'last team standing',
        most_kills: 'team with the most kills when the clock runs out',
        score_limit: 'first team to the kill limit'
    };

    function winWords(teamed) {
        return teamed === true ? WIN_CONDITION_TEAM_TEXT : WIN_CONDITION_TEXT;
    }

    var WIN_CONDITIONS_WITHOUT_LIVES = {
        score_limit: true,
        most_kills: true
    };

    function winSpendsLives(key) {
        return WIN_CONDITIONS_WITHOUT_LIVES[key] !== true;
    }

    function livesFact(match, fighter) {
        if (match && match.livesSpent === false) return '';
        return ' · ' + int(fighter.lives, 0) + ' lives';
    }

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

    // ==================================================================
    // ROUND LENGTH: TYPED IN MINUTES, SENT IN SECONDS
    //
    // The host thinks in minutes -- "give it ten" -- and the box used to want
    // 600. Nothing on the screen said which unit it wanted, so a host typing
    // 10 got a ten SECOND round, and one typing 600 while reading "minutes"
    // would have got ten hours if the band allowed it.
    //
    // THE UNIT CHANGED ON THE SCREEN ONLY. `state.createRound` is still
    // seconds and still goes out as `roundTimeSeconds`, because that is what
    // Config.Match, every mode's own override and the round clock all speak.
    // The two functions below are the whole of the conversion, and they sit
    // together so neither can drift from the other.
    // ==================================================================

    // The operator's band expressed in WHOLE MINUTES, or null when no whole
    // minute fits inside it.
    //
    // Rounded INWARDS on both ends -- up for the floor, down for the ceiling
    // -- so every minute the box will accept is a number the server will too.
    // Rounding outwards would offer a host a value the create call then
    // refused, which is the worse failure: the form would be lying.
    //
    // Null is not a bug. An operator is allowed to write min = 30, max = 50,
    // and there is no whole minute in that; the caller falls back to seconds
    // and says so, rather than presenting an empty band or quietly widening
    // somebody's rule.
    function roundMinuteBand(choice) {
        if (!choice || typeof choice !== 'object') return null;
        var lo = Math.max(1, int(choice.min, 1));
        var hi = Math.max(lo, int(choice.max, lo));
        var loM = Math.max(1, Math.ceil(lo / 60));
        var hiM = Math.floor(hi / 60);
        if (hiM < loM) return null;
        return { min: loM, max: hiM };
    }

    // Seconds, snapped to something the minutes box can show without lying.
    //
    // A config default of 450 is 7.5 minutes, and a box reading 8 over a
    // state holding 450 is exactly the disagreement this whole change is
    // about -- so the snap happens on the way IN, at every point the form
    // seeds or takes a value, and the box and the state always agree.
    // Clamped last, because rounding to the nearest minute can step outside
    // a band that rounding inwards had already fitted.
    function snapRoundSeconds(seconds, choice) {
        var band = roundMinuteBand(choice);
        var wanted = Math.max(0, int(seconds, 0));
        if (!band) {
            if (!choice || typeof choice !== 'object') return wanted;
            return clampInt(wanted, Math.max(1, int(choice.min, 1)),
                Math.max(1, int(choice.max, 1)));
        }
        if (wanted <= 0) return band.min * 60;
        return clampInt(Math.round(wanted / 60), band.min, band.max) * 60;
    }

    // What the round clock would be for a mode, in seconds.
    //
    // THE MODE'S OWN NUMBER FIRST. `Arena.RoundSecondsFor` has already done
    // this resolution on the server -- gun game ships 480 against a global
    // default of 600 -- and sends the answer on each mode. Reading it is what
    // stops the panel proposing the global number for a mode that has its
    // own.
    function modeRoundSeconds(mode, config) {
        var own = mode && mode.roundTimeSeconds;
        if (own !== undefined && own !== null && int(own, 0) > 0) return int(own, 0);
        return int((config.match || {}).roundTimeSeconds, 0);
    }

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
        }
    }

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

    function schedule() {
        return state.schedule || {};
    }

    function doorsShut() {
        return schedule().open === false;
    }

    function shutSentence() {
        var opensAt = schedule().opensAt;
        return typeof opensAt === 'string' && opensAt
            ? 'The arena is shut. It opens at ' + opensAt + '.'
            : 'The arena is shut at this hour.';
    }

    function playerMatchId() {
        return keyOr(player().matchId, null);
    }

    function spectatingMatchId() {
        return keyOr(player().spectating, null);
    }

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
       THE ALLOWANCES

       ONE POOL FOR WEAPONS, and the mix is the player's. The server counts
       guns and blades together against Config.Loadouts.slots and this panel
       reads it the same way -- if the two ever disagree it is the panel the
       player believes, and they find out at the moment the round starts.

       This used to be two counts kept apart, so that reaching for a knife
       did not cost a rifle. The other half of that was a player who wanted
       a bat and nothing else being made to carry two guns as well.
       ------------------------------------------------------------------ */

    function slotLimit() {
        var raw = (cfg().loadouts || {}).slots;
        if (raw === undefined || raw === null) return 2;
        var value = int(raw, 2);
        return value < 0 ? 2 : value;
    }

    function allowFirearms() {
        return (cfg().loadouts || {}).allowFirearms !== false;
    }

    function allowMelee() {
        return (cfg().loadouts || {}).allowMelee !== false;
    }

    function kindAllowed(melee) {
        return melee ? allowMelee() : allowFirearms();
    }

    function ammoTypeSlots() {
        return Math.max(0, int((cfg().loadouts || {}).ammoTypeSlots, 0));
    }

    function hostPicksLoadout() {
        return (cfg().loadouts || {}).chooser !== 'player';
    }

    function playerMode() {
        var id = playerMatchId();
        if (!id) return null;
        var match = matchById(id);
        return match ? modeByKey(match.modeKey) : null;
    }

    function modeIssuesLoadout(mode) {
        return !!mode && int(mode.tiers, 0) > 0;
    }

    function startingKitText(mode) {
        var parts = arrayOf(mode && mode.startingKit).map(function (entry) {
            var count = int(entry && entry.count, 0);
            var label = String((entry && entry.label) || '');
            if (count <= 0 || label === '') return '';
            return plural(count, label);
        }).filter(function (text) { return text !== ''; });

        if (parts.length === 0) return '';
        if (parts.length === 1) return parts[0];
        return parts.slice(0, -1).join(', ') + ' and ' + parts[parts.length - 1];
    }

    /* HOW MANY RUNGS A PARTICULAR MATCH IS WON ON.

       THE DEFECT: three places read `mode.tiers`, which is the MODE's
       default height -- Arena.GetEnabledModes computes it with no tier plan.
       A host who drags the tier rows to melee 1 / sidearms 1 gets a real
       two-rung ladder, and the round really ends after two net kills, while
       the lobby card said "Win by topping the 30-tier ladder" and the loadout
       tab said "You open on tier 1 of 30" -- on the same screen where the
       host's own create form had just told them "2 tiers in all". Somebody
       reading the card thinks they need 29 net kills; they need 2.

       THE MATCH'S OWN NUMBER FIRST, resolved by the server against the plan,
       with the mode default as the fallback for a match that predates the
       field. Not summed from the plan here: LadderTiersFor drops a class with
       nothing playable in it, so adding the rows up in the panel would be a
       second implementation that agrees right up until a weapon is disabled. */
    function ladderRungs(match, mode) {
        var own = match && match.tiers;
        if (own !== undefined && own !== null && int(own, 0) > 0) return int(own, 0);
        return mode ? int(mode.tiers, 0) : 0;
    }

    function loadoutLockReason() {
        var mode = playerMode();
        if (modeIssuesLoadout(mode)) {
            var text = String(mode.label || 'This mode') + ' hands out its own weapons: a '
                + ladderRungs(matchById(playerMatchId()), mode) + '-tier ladder, drawn fresh every round, so there is '
                + 'nothing to pick here. Every kill climbs a tier and every death costs you '
                + 'one, and everybody starts the round on the same rung.';

            var kit = startingKitText(mode);
            if (kit !== '') text += ' Everyone is issued ' + kit + ' at the start of every round.';
            return text;
        }

        if (hostPicksLoadout() && player().isHost !== true) {
            return 'The host picks one loadout and everyone in the match fights with it, so every '
                + 'player carries the same weapons. Into The Round below is exactly what you will '
                + 'be handed when the round starts. Host a match yourself to choose it.';
        }

        var id = playerMatchId();
        if (id) {
            var match = matchById(id);
            if (!match || match.state !== 'lobby') {
                return 'This match has already kicked off — what you are carrying is locked in.';
            }
        }

        return null;
    }

    /* Whether a save would reach anywhere. The server refuses setLoadout
       from a player who is in no match (error.not_in_match) exactly as it
       refuses one whose match has started, so the button must not offer it
       in either case. */
    function loadoutIsSaveable() {
        var id = playerMatchId();
        if (!id) return false;
        var match = matchById(id);
        return !!match && match.state === 'lobby' && canChooseLoadout();
    }

    function canChooseLoadout() {
        return loadoutLockReason() === null;
    }

    function accountName() {
        return keyOr(betting().account, 'cash');
    }

    function payAccounts() {
        return arrayOf(betting().accounts).filter(function (name) {
            return typeof name === 'string' && name.length > 0;
        });
    }

    function accountChoiceOffered() {
        return payAccounts().length > 1;
    }

    function chosenAccount() {
        var list = payAccounts();
        if (list.indexOf(state.payAccount) >= 0) return state.payAccount;
        return list[0] || accountName();
    }

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

    function poolsAreShared() {
        var block = betting().betPayout || {};
        return block.includeEntryPot === true;
    }

    function payoutPhrase() {
        if (poolsAreShared()) {
            return 'it is split between everyone who backed the winning side, in proportion to what they staked';
        }
        return labelFor(PAYOUT_TEXT, betting().payout, 'it is paid out at the end');
    }

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

    function defaultAmmoType(weapon) {
        var types = ammoTypesOf(weapon);
        if (types.length === 0) return null;

        var wanted = keyOr(weapon && weapon.defaultAmmoType, null);
        for (var i = 0; i < types.length; i++) {
            if (types[i].key === wanted) return wanted;
        }
        return types[0].key;
    }

    function ammoTypeLabel(weapon, key) {
        if (keyOr(key, null) === null) return null;
        var types = ammoTypesOf(weapon);
        for (var i = 0; i < types.length; i++) {
            if (types[i].key === key) return types[i].label || types[i].key;
        }
        return null;
    }

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

    function seedDraft() {
        /* A DRAFT YOU CAN NO LONGER SAVE IS NOT A DRAFT.

           The dirty flag holds the reseed off so a broadcast cannot wipe out
           what somebody is in the middle of choosing -- right inside a lobby,
           and wrong the moment the round leaves one. The save row is hidden
           once the loadout locks, and that row holds the ONLY "Unsaved --
           press Save Loadout" warning; so a player who picked a rifle and
           did not save watched the warning vanish at the countdown while the
           rifle stayed on screen under "what you are carrying is locked in".
           The server had never been sent it. They walked into the round a
           weapon short, having been shown the opposite.

           Once it cannot be saved, the screen goes back to what the server
           actually holds. */
        if (state.loadoutDirty && !canChooseLoadout()) {
            state.loadoutDirty = false;
            state.loadoutSaving = false;
        }
        if (state.loadoutDirty) return;

        var loadout = player().loadout || {};
        var picks = [];
        var limit = slotLimit();
        var used = 0;

        arrayOf(loadout.weapons).forEach(function (entry) {
            if (!entry) return;
            var weapon = weaponByKey(entry.key);
            if (!weapon) return;

            if (!kindAllowed(isMelee(weapon))) return;
            if (limit > 0 && used >= limit) return;
            used += 1;

            var pick = {
                key: weapon.key,
                ammo: int(entry.ammo, int(weapon.ammo && weapon.ammo.default, 0)),
                ammoType: resolveAmmoType(weapon, entry.ammoType)
            };

            /* AND THE ATTACHMENTS THE PLAYER ACTUALLY CHOSE.

               Dropping these was a round trip that lost the choice every
               time. The draft was rebuilt with key/ammo/ammoType only, so
               `pick.attachments` came back undefined, attachmentsOn() fell
               back to "every kind this weapon takes", and every chip re-lit
               -- telling the player a scope they had deliberately taken off
               was fitted. Then saveLoadout only sends the key when it is an
               array, so the NEXT save omitted it entirely, and the server
               reads absent as "fit everything this server allows". Two
               saves and the player's choice was gone, with the screen
               agreeing it had never happened.

               `entry.attachments` is the list of kinds the server really
               fitted -- Arena.ResolveWeaponEntry records it now, for this.
               Only taken when it IS a list: an older server that does not
               send it leaves the default in place, which is what a loadout
               saved before attachments existed should get. */
            if (Array.isArray(entry.attachments)) {
                pick.attachments = entry.attachments.map(String);
            }

            picks.push(pick);
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
            var melee = isMelee(weapon);
            if (poolIsFull(melee)) {
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

    function setWeaponAmmo(key, ammo, quiet) {
        if (!canChooseLoadout()) return;
        var index = draftIndexOf(key);
        if (index < 0) {
            toggleWeapon(key);
            index = draftIndexOf(key);
            if (index < 0) return;
        }
        state.draftWeapons[index].ammo = int(ammo, 0);
        state.loadoutDirty = true;
        if (quiet) {
            renderLoadoutSaveRow();
            return;
        }
        render();
    }

    /* Ticks or unticks one attachment on one weapon.

       WORKS LIKE THE ROUNDS CHIPS, deliberately: clicking one on a weapon
       that is not picked yet picks the weapon first, so there is no state
       where a chip does nothing. The difference is that rounds are a choice
       of ONE and attachments are a SET -- so these toggle rather than
       replace. */
    function toggleWeaponAttachment(key, kind) {
        if (!canChooseLoadout()) return;
        var index = draftIndexOf(key);
        if (index < 0) {
            toggleWeapon(key);
            index = draftIndexOf(key);
            if (index < 0) return;
        }

        var pick = state.draftWeapons[index];
        /* ABSENT MEANS "WHATEVER THE SERVER FITS", and the first click has
           to turn that into a real list before anything can be taken out of
           it -- otherwise unticking one attachment on a fresh pick would
           send nothing, and nothing is what the server reads as "fit them
           all". The player would click and see no change. */
        if (!Array.isArray(pick.attachments)) {
            pick.attachments = defaultAttachmentsFor(key);
        }

        var at = pick.attachments.indexOf(kind);
        if (at >= 0) pick.attachments.splice(at, 1);
        else pick.attachments.push(kind);

        state.loadoutDirty = true;
        render();
    }

    /* What a weapon starts with ticked: everything it can take. The server
       fits exactly this when a pick carries no list of its own, so the
       screen and the server agree before anybody clicks anything. */
    /* DOES THIS SERVER LET THE PLAYER PICK THEIR OWN ATTACHMENTS?

       Read as `=== false` rather than `!== true`, like every other flag on
       this wire: a snapshot assembled before this setting existed has to keep
       the picker it already had rather than silently losing it. The server is
       what actually enforces the rule -- see Arena.AttachmentsAreChosen --
       and this only decides whether the chips are live. */
    function mayChooseAttachments() {
        return (cfg().loadouts || {}).chooseAttachments !== false;
    }

    function defaultAttachmentsFor(key) {
        var weapon = weaponByKey(key);
        return arrayOf(weapon && weapon.attachments).map(function (option) {
            return String(option.key);
        });
    }

    /* What is ticked on a pick right now, for drawing. */
    function attachmentsOn(key) {
        /* OPERATOR-FITTED MEANS OPERATOR-FITTED, including on a draft that was
           saved while picking was still allowed. Without this the screen would
           keep showing yesterday's ticks over a gun the server is now fitting
           in full, which is the one thing this row exists to report. */
        if (!mayChooseAttachments()) return defaultAttachmentsFor(key);

        var index = draftIndexOf(key);
        if (index < 0) return defaultAttachmentsFor(key);
        var pick = state.draftWeapons[index];
        if (!Array.isArray(pick.attachments)) return defaultAttachmentsFor(key);
        return pick.attachments;
    }

    function setWeaponAmmoType(key, typeKey) {
        if (!canChooseLoadout()) return;
        var weapon = weaponByKey(key);
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

    var SOUNDS = {
        open: [{ freq: 196, len: 0.07 }, { at: 0.055, freq: 294, len: 0.10 }],
        close: [{ freq: 294, len: 0.06 }, { at: 0.050, freq: 175, len: 0.11 }],
        tab: [{ freq: 330, len: 0.045, peak: 0.022 }],
        ready: [{ freq: 392, len: 0.09 }],
        confirm: [{ freq: 262, len: 0.07 }, { at: 0.070, freq: 349, len: 0.07 }, { at: 0.140, freq: 440, len: 0.16 }],
        error: [{ freq: 155, to: 110, len: 0.20, type: 'triangle' }]
    };

    var SOUND_PEAK = 0.045;

    var audio = { ctx: null, blocked: false };

    function soundsOn() {
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
            audio.blocked = true;
        }
        return audio.ctx;
    }

    function unlockAudio() {
        var ctx = audioContext();
        if (!ctx || ctx.state !== 'suspended') return;
        try {
            var pending = ctx.resume();
            if (pending && typeof pending.catch === 'function') pending.catch(function () {});
        } catch {
        }
    }

    function playNote(ctx, note) {
        var start = ctx.currentTime + (note.at || 0);
        var peak = note.peak || SOUND_PEAK;

        var osc = ctx.createOscillator();
        osc.type = note.type || 'sine';
        osc.frequency.setValueAtTime(note.freq, start);
        if (note.to) osc.frequency.exponentialRampToValueAtTime(note.to, start + note.len);

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
        if (!ctx || ctx.state !== 'running') return;

        try {
            for (var i = 0; i < notes.length; i++) playNote(ctx, notes[i]);
        } catch {
        }
    }

    function announceMatchState() {
        var match = matchById(playerMatchId());
        var now = match ? keyOr(match.state, null) : null;
        var was = state.lastMatchState;
        state.lastMatchState = now;

        if (now === was) return;
        if (now === 'countdown' || (now === 'live' && was !== 'countdown')) play('confirm');
    }

    function toast(message, kind) {
        var host = byId('arena-toast');
        if (!has(host) || typeof message !== 'string' || message === '') return;

        var level = (kind === 'success' || kind === 'error' || kind === 'warning') ? kind : 'info';
        if (level === 'error' || level === 'warning') play('error');

        var node = makeEl('div', 'toast ' + level, message);
        host.appendChild(node);

        while (host.children.length > TOAST_MAX) host.removeChild(host.firstChild);

        window.setTimeout(function () {
            if (node.parentNode === host) host.removeChild(node);
        }, TOAST_MS);
    }

    function openPanel(snapshot) {
        applySnapshot(snapshot);
        play('open');
        state.open = true;
        show(byId('arena-root'), true);
        render();
    }

    function hidePanel() {
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
        if (snapshot.schedule) state.schedule = snapshot.schedule;

        var config = cfg();

        if (!state.createArena) {
            var arenas = arrayOf(config.arenas);
            state.createArena = arenas.length > 0 ? arenas[0].key : null;
        }
        if (!state.createMode) {
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
        if (state.createLives === null) {
            state.createLives = int((config.match || {}).lives, 1);
        }
        /* THE ROUND LENGTH FOLLOWS THE MODE UNTIL THE HOST TAKES IT OVER.
           THE DEFECT: this seeded once, from Config.Match.roundTimeSeconds --
           the GLOBAL default -- and never looked again. The panel posts that
           number on every create, and the server reads any in-range value as
           a deliberate choice by the host, so it shadowed the mode's own
           clock. Gun game ships a designed 480-second ladder and every gun
           game ever created from this panel ran 600, and an operator who
           shortened it to 120 still got 600. The mode's own setting was
           unreachable through the only path a player can create a match by.
           SNAPPED ON THE WAY IN, not on the way to the box. A mode default of
           450 is seven and a half minutes and the minutes box can only show 7
           or 8 -- so the value the form holds is made one the box can show,
           here, rather than the two disagreeing until the host touches it. */
        if (!state.createRoundTouched) {
            var forMode = modeRoundSeconds(modeByKey(state.createMode), config);
            state.createRound = snapRoundSeconds(forMode, (config.match || {}).roundTimeChoice);
        }
        if (state.createWin === null) {
            state.createWin = keyOr((config.match || {}).winCondition, 'last_standing');
        }
        if (state.createLimit === null) {
            state.createLimit = int((config.match || {}).scoreLimit, 25);
        }
        if (state.betAmount === null) {
            var betCfg = (config.betting || {});
            var seedFrom = ((betCfg.spectatorBets || {}).enabled === true)
                ? betCfg.spectatorBets
                : ((betCfg.fighterBets || {}).enabled === true ? betCfg.fighterBets : {});
            state.betAmount = int(seedFrom.min, 0);
        }

        var editable = editableMatch();
        /* THE LOBBY, AND HOW MANY TIMES THE SERVER HAS SAID NO.
           Seeding is keyed on the match id so a broadcast in the middle of
           somebody typing does not overwrite them -- and that is right for
           every broadcast except one. A REFUSED edit means the form is now
           showing a rule the server turned down, over a lobby still fought
           under the old one, with the card beside it disagreeing. The count
           moves on each refusal, so the form seeds again from what the
           server actually holds. */
        var seedKey = editable
            ? String(editable.id) + '#' + int((state.player || {}).editRefused, 0)
            : null;
        if (editable && state.seededFromMatch !== seedKey) {
            state.seededFromMatch = seedKey;
            state.createArena = editable.arenaKey || state.createArena;
            state.createMode = editable.modeKey || state.createMode;
            state.createLives = int(editable.lives, int(state.createLives, 1));
            /* AND AN OPEN LOBBY'S LENGTH IS ALREADY SOMEBODY'S DECISION, so
               seeding from it counts as touching the box: a host who then
               changes the mode keeps the length their lobby is running, and
               does not have it silently rewritten under the players in it. */
            state.createRound = snapRoundSeconds(
                int(editable.roundTimeSeconds, int(state.createRound, 0)),
                (config.match || {}).roundTimeChoice);
            state.createRoundTouched = true;
            state.createWin = keyOr(editable.winCondition, state.createWin);
            state.createTiers = (editable.tierPlan && typeof editable.tierPlan === 'object')
                ? editable.tierPlan
                : {};
            state.createLimit = int(editable.scoreLimit, int(state.createLimit, 25));
            state.createRadar = editable.radar === true;
        } else if (!editable && state.seededFromMatch !== null) {
            state.seededFromMatch = null;
            state.createRadar = null;
            state.createTiers = {};
            /* AND THE ROUND LENGTH GOES BACK TO FOLLOWING THE MODE. The lobby
               that owned that number is gone; keeping it would carry one
               match's clock into the next host's form. */
            state.createRoundTouched = false;
        }

        /* JOINING A MATCH MOVES YOU TO THE LOBBY TAB. ONCE, ON THE JOIN.

           This fired whenever the SELECTION differed from the match you are
           in -- and clicking any card writes the selection, so a player
           sitting in a lobby who clicked another match on the Matches tab to
           read it was thrown onto Lobby by the very next broadcast, with
           nothing they did in between. Re-armed by every click, it fired
           again and again.

           What it is for is the transition, so that is what it watches now.
           The selection is free to point somewhere else afterwards: the Bets
           tab reads focusedMatch(), which prefers the match you are fighting
           in regardless, and the card that claims the tab's attention checks
           the same function before saying so. */
        var current = playerMatchId();
        if (current && state.lastMatchId !== current) {
            state.selectedMatchId = current;
            if (state.tab === 'matches') state.tab = 'lobby';
        }
        state.lastMatchId = current;
        if (!current && state.tab === 'lobby' && !spectatingMatchId()) {
            state.tab = 'matches';
        }

        seedDraft();
        announceMatchState();
    }

    function guarded(fn) {
        try {
            return fn();
        } catch {
        }
    }

    /* KEEPING THE CARET WHERE THE PLAYER PUT IT.

       Most controls on this panel live in index.html and are only updated
       by a render, so the three that take typed numbers guard their value
       against document.activeElement and that is enough -- the node itself
       survives, and so does the focus in it.

       The ones the panel BUILDS do not survive. Every render clears their
       container and makes new elements, so the input a player is typing
       into is removed from the document -- and a browser drops focus with
       the element. Renders arrive from the server, not from the typist:
       ArenaLobby.Broadcast fires on every join, ready, side change and
       elimination, so in a filling lobby the custom ammo box loses the
       caret mid-number, repeatedly, for reasons the player cannot see.

       Restoring it is one rule for every rebuilt control rather than a
       patch on the box that was noticed: focus goes back only to the SAME
       id it was on, only if the render actually took it away, and only if
       that id still exists afterwards. Nothing else can be stolen by it.

       The caret POSITION is deliberately not restored. These are
       type="number" inputs, and reading selectionStart on one throws in
       Chromium -- which is what the panel runs in. Focusing puts the caret
       at the end, which is where somebody typing a number already was. */
    function render() {
        if (!state.open) return;

        var wasFocused = document.activeElement;
        var wasFocusedId = wasFocused && wasFocused.id ? String(wasFocused.id) : null;

        guarded(renderHeader);

        if (guarded(renderShut)) return;

        guarded(renderTabs);
        guarded(renderMatches);
        guarded(renderLobby);
        guarded(renderLoadout);
        guarded(renderBets);
        guarded(renderBoard);

        if (wasFocusedId && document.activeElement !== wasFocused) {
            var again = byId(wasFocusedId);
            if (has(again) && again !== document.activeElement && typeof again.focus === 'function') {
                again.focus();
            }
        }
    }

    function renderShut() {
        var shut = doorsShut()
            && playerMatchId() === null
            && spectatingMatchId() === null;

        show(byId('arena-shut'), shut);
        show(byId('arena-nav'), !shut);
        show(byId('arena-body'), !shut);
        if (!shut) return false;

        var forced = schedule().forced;
        byId('arena-shut-why').textContent = forced === 'shut'
            ? 'An admin has closed it. It stays closed until they open it again.'
            : 'It is outside the hours this server keeps it open.';

        var line = schedule().line;
        var opensAt = schedule().opensAt;
        byId('arena-shut-hours').textContent = (typeof line === 'string' && line !== '')
            ? 'Arena hours: ' + line + '.'
              + (typeof opensAt === 'string' && opensAt ? ' Next opening ' + opensAt + '.' : '')
            : 'This server keeps no opening hours — it opens again when an admin says so.';

        return true;
    }

    function renderHeader() {
        var ui = cfg().ui || {};

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

        var hoursEl = byId('arena-hours');
        if (has(hoursEl)) {
            var line = schedule().line;
            var keeps = typeof line === 'string' && line !== '';
            if (keeps) {
                hoursEl.textContent = 'Arena hours: ' + line + '. '
                    + (doorsShut()
                        ? shutSentence()
                        : (typeof schedule().closesAt === 'string'
                            ? 'Open now, until ' + schedule().closesAt + '.'
                            : 'Open now.'));
            }
            show(hoursEl, keeps);
        }

        var logo = byId('arena-logo');
        if (has(logo)) {
            var src = typeof ui.logo === 'string' && ui.logo !== '' ? ui.logo : 'images/logo.png';
            if (logo.getAttribute('src') !== src) logo.setAttribute('src', src);

            logo.setAttribute('alt', banner
                ? (typeof ui.title === 'string' ? ui.title : 'CRIMSON') + ' arena'
                : '');
        }

        var wallet = byId('arena-money');
        if (has(wallet)) {
            show(wallet, bettingOn());
            clear(wallet);
            if (bettingOn()) {
                wallet.appendChild(makeEl('span', 'wallet-label', 'Your ' + accountName()));
                wallet.appendChild(makeEl('span', 'wallet-value', money(player().money)));
            }
        }
    }

    /* Whether a tab can do anything at all right now.

       A TAB THAT CANNOT DO ANYTHING IS A QUESTION THE PLAYER HAS TO ANSWER
       BEFORE THEY CAN IGNORE IT. Five tabs were drawn at all times: Bets on
       a server with betting switched off, and Lobby when you are not in one
       -- which the panel already knew, because joining a match moves you to
       Lobby and leaving moves you off it. Clicking either landed on a
       screen whose only content was a sentence explaining why it was empty.

       Only the two that are genuinely unreachable are taken away. Loadout
       stays even when the host picks the guns -- a player still wants to see
       what they are being handed -- and Leaderboard stays because an empty
       board is a real answer to "who is winning". */
    function tabAvailable(name) {
        if (name === 'bets') return bettingOn();
        if (name === 'lobby') return playerMatchId() !== null || spectatingMatchId() !== null;
        return true;
    }

    function renderTabs() {
        /* A TAB THAT HAS JUST GONE AWAY MUST NOT STAY SELECTED, or the panel
           shows a hidden section and every tab reads as inactive. Betting
           can be switched off under a player standing on the Bets tab. */
        if (!tabAvailable(state.tab)) state.tab = 'matches';

        /* WALKED BY NAME, NOT BY SELECTOR. Every tab button carries an id
           now, so this reads them the way the rest of the panel reads
           everything -- and a control addressed by id is one a test can
           address too. The selector walk was invisible to the test harness,
           which is how a tab could have been hidden or left behind with the
           whole suite green. */
        TABS.forEach(function (name) {
            show(byId('tab-btn-' + name), tabAvailable(name));
            var button = byId('tab-btn-' + name);
            if (has(button)) button.classList.toggle('active', name === state.tab);
            show(byId('tab-' + name), name === state.tab);
        });
    }

    function joinBlockedReason(match) {
        var mine = playerMatchId();
        if (mine === match.id) return 'You are already in this match.';
        if (mine) return 'You are already in another match. Leave that one first.';
        if (match.state === 'ended') return 'This match has finished.';
        if (match.state !== 'lobby') return 'This match has already started. Watch it, or start your own.';

        if (doorsShut()) return shutSentence();

        var max = int((cfg().match || {}).maxPlayers, 0);
        if (max > 0 && int(match.playerCount, 0) >= max) {
            return 'This match is full (' + plural(max, 'player') + ').';
        }

        if (arrayOf(player().backing).indexOf(match.id) !== -1) {
            return 'You have money on this match. Watch it or fight it, not both.';
        }

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

        if (!playerMatchId() && stateName !== 'ended') {
            var watching = spectatingMatchId() === match.id;

            /* THERE HAS TO BE SOMETHING TO SEE.

               The camera follows a fighter, and server/match.lua's bucket
               sweep only puts a watcher in a match's instance once that
               match is being fought. Watching a LOBBY teleported the body to
               the arena, showed twelve seconds of nothing, and ended with
               "Nobody left to watch." -- and BACKSPACE is unreachable for
               the whole of that wait, because every input sits inside the
               camera's `if ped then`.

               'live' and nothing else, deliberately. The server sends one
               state name for two different phases -- ArenaMatch.Begin uses
               'countdown' for the lobby countdown, where nobody has been
               moved anywhere, and Start reuses it for the frozen one after
               teleporting the room in -- so the panel cannot tell them
               apart. Offering it in the second and refusing it in the first
               is not a distinction this side can make; waiting a few seconds
               for 'live' is.

               DISABLED, NOT HIDDEN: a button that vanishes explains nothing,
               and somebody looking at a lobby wants to know they can watch
               it once it starts. Stop Watching is always live -- whatever
               state the match reached, they must be able to get out. */
            var canWatch = watching || stateName === 'live';
            var spectate = makeEl('button', 'btn', watching ? 'Stop Watching' : 'Watch');
            spectate.type = 'button';
            spectate.disabled = !canWatch;
            spectate.title = watching
                ? 'Put the camera back on you.'
                : (canWatch
                    ? 'Watch this match from a spectator camera. You are not in the fight.'
                    : 'Nothing to watch until the round starts.');
            spectate.addEventListener('click', function (event) {
                event.stopPropagation();
                if (!canWatch) return;
                if (watching) post('stopSpectate');
                else post('spectate', { matchId: match.id });
            });
            actions.appendChild(spectate);
        }

        card.appendChild(actions);

        if (reason) card.appendChild(makeEl('div', 'match-card-reason', 'Cannot join: ' + reason));

        /* AND THE BETS TAB HAS TO ACTUALLY BE SHOWING IT.

           This read `state.selectedMatchId`, which is only the LAST of three
           things focusedMatch() consults: the match you are fighting in wins,
           then the one you are watching, then the one you clicked. Being in a
           match self-corrects -- applySnapshot forces the selection back to
           your own -- but WATCHING one does not, so a spectator who clicked
           another card was told the Bets tab had followed them there while it
           sat on the match they were watching. Everything downstream agreed
           with the tab and not with the card: the heading, the chips, and the
           matchId in the bet they then placed. The claim is now made against
           the match the tab is really on. */
        var focused = focusedMatch();
        if (focused && match.id === focused.id && bettingOn()
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

        var creating = modeByKey(state.createMode);

        var laddered = modeIssuesLoadout(creating);
        var offered = (cfg().match || {}).winConditionChoice;

        var roundOffered = !!(cfg().match || {}).roundTimeChoice;
        var wouldRun = roundOffered && int(state.createRound, 0) > 0
            ? int(state.createRound, 0)
            : int(creating && creating.roundTimeSeconds,
                int((cfg().match || {}).roundTimeSeconds, 0));
        var winChoice = Array.isArray(offered) && wouldRun <= 0
            ? offered.filter(function (key) { return key !== 'most_kills'; })
            : offered;

        var winUsed = Array.isArray(winChoice) && winChoice.length > 1 && !laddered;
        show(byId('create-win-row'), winUsed);

        if (Array.isArray(winChoice) && winChoice.length > 0
            && winChoice.indexOf(state.createWin) === -1) {
            state.createWin = winChoice[0];
        }

        var winSelect = byId('create-win');
        if (has(winSelect) && winUsed) {
            var teamed = !!(creating && creating.teams === true);
            var words = winWords(teamed);
            var wanted = winChoice.join(',') + (teamed ? '|teams' : '');
            if (winSelect.getAttribute('data-options') !== wanted) {
                winSelect.setAttribute('data-options', wanted);
                clear(winSelect);
                winChoice.forEach(function (key) {
                    var option = makeEl('option', null,
                        titleCase(labelFor(words, key, key)));
                    option.value = key;
                    winSelect.appendChild(option);
                });
            }
            if (document.activeElement !== winSelect) {
                winSelect.value = keyOr(state.createWin, winChoice[0]);
            }
        }

        var winHint = byId('create-win-hint');
        if (has(winHint)) {
            var teamedHint = !!(creating && creating.teams === true);
            winHint.textContent = !winUsed ? ''
                : (state.createWin === 'score_limit'
                    ? (teamedHint ? 'First side to ' : 'First to ')
                      + int(state.createLimit, int((cfg().match || {}).scoreLimit, 25))
                      + ' kills takes it. Nobody is eliminated — everyone respawns until '
                      + (teamedHint ? 'one side gets there' : 'somebody gets there')
                      + ', so lives are not spent.'
                    : (state.createWin === 'most_kills'
                        ? (teamedHint
                            ? 'The side with the most kills between them when the clock runs '
                              + 'out takes it. Nobody is eliminated — everyone respawns until '
                              + 'the clock stops, so lives are not spent.'
                            : 'Highest kill count when the clock runs out takes it. Nobody is '
                              + 'eliminated — everyone respawns until the clock stops, so '
                              + 'lives are not spent.')
                        : (teamedHint
                            ? 'The last side with anybody still standing takes it — the whole '
                              + 'side wins it, fallen team-mates included. Run out of lives and '
                              + 'you are out for the round.'
                            : 'Last one standing takes it. Run out of lives and you are out.')));
        }

        var livesSpent = winSpendsLives(state.createWin);

        var limitChoice = (cfg().match || {}).scoreLimitChoice;

        /* GATED ON THE CONDITION THAT IS RUNNING, NOT ON THE DROPDOWN.

           This read `winUsed`, which is not "is this a kill-limit match" --
           it is "is the Win Condition dropdown on screen", and it is false
           the moment the operator FIXES the condition. Fix it the documented
           plain-string way (Config.Match.winCondition = 'score_limit') and
           Arena.WinConditionChoice returns nil, so the host was told it was a
           kill-limit match and then never shown the limit: the row was
           hidden, its hint was blank, and Create posted the default every
           time. The operator's own min/max band was unreachable on the one
           server that had committed to using it.

           `laddered` stays, and it is the part `winUsed` was carrying that
           was worth keeping: a gun game ends on the ladder or the clock, so
           a kill limit has nothing to decide there. */
        var limitUsed = !!limitChoice && !laddered && state.createWin === 'score_limit';
        show(byId('create-limit-row'), limitUsed);

        var limitInput = byId('create-limit');
        if (has(limitInput) && limitUsed) {
            limitInput.min = String(int(limitChoice.min, 1));
            limitInput.max = String(int(limitChoice.max, 1));
            if (document.activeElement !== limitInput) {
                limitInput.value = String(int(state.createLimit, 25));
            }
        }

        var limitHint = byId('create-limit-hint');
        if (has(limitHint)) {
            /* A TEAM REACHES THIS LIMIT TOGETHER. reachedScoreLimit in
               server/match.lua sums teamKills in a team mode and only falls
               back to one fighter's own kills outside one -- so "the first
               fighter to this many kills" was the wrong rule on exactly the
               modes where the number is hardest to guess, and a host setting
               25 for a 4v4 was setting a target two players reach between
               them, not one. */
            limitHint.textContent = limitUsed
                ? ((creating && creating.teams === true)
                    ? 'The first side to this many kills between them takes the round. '
                    : 'The first fighter to this many kills takes the round. ')
                  + int(limitChoice.min, 1) + ' to ' + int(limitChoice.max, 1) + '.'
                : '';
        }

        var tierClasses = arrayOf(creating && creating.tierClasses);
        var tiersUsed = laddered && tierClasses.length > 0;
        show(byId('create-tiers-row'), tiersUsed);

        var tierBox = byId('create-tiers');
        if (has(tierBox)) {
            var signature = tierClasses.map(function (row) {
                return String(row.key) + ':' + int(row.maxTiers, 0);
            }).join(',');

            if (!tiersUsed) {
                clear(tierBox);
                tierSelects = {};
                tierBox.setAttribute('data-classes', '');
            } else if (tierBox.getAttribute('data-classes') !== signature) {
                tierBox.setAttribute('data-classes', signature);
                clear(tierBox);
                tierSelects = {};
                tierClasses.forEach(function (row) {
                    var line = makeEl('div', 'tier-row');
                    line.appendChild(makeEl('span', 'tier-name', String(row.label || row.key)));

                    var select = makeEl('select');
                    select.id = 'create-tier-' + String(row.key);
                    select.setAttribute('data-class', String(row.key));
                    for (var count = 0; count <= int(row.maxTiers, 0); count += 1) {
                        var option = makeEl('option', null, String(count));
                        option.value = String(count);
                        select.appendChild(option);
                    }
                    select.addEventListener('change', function (event) {
                        var key = event.target.getAttribute('data-class');
                        var next = {};
                        Object.keys(state.createTiers).forEach(function (name) {
                            next[name] = state.createTiers[name];
                        });
                        next[key] = int(event.target.value, 0);
                        state.createTiers = next;
                        render();
                    });
                    tierSelects[String(row.key)] = select;
                    line.appendChild(select);
                    tierBox.appendChild(line);
                });
            }

            if (tiersUsed) {
                tierClasses.forEach(function (row) {
                    var select = tierSelects[String(row.key)];
                    if (!select || document.activeElement === select) return;
                    var chosen = state.createTiers[row.key];
                    select.value = String(chosen === undefined ? int(row.tiers, 0) : int(chosen, 0));
                });
            }
        }

        var tierHint = byId('create-tiers-hint');
        if (has(tierHint)) {
            if (!tiersUsed) {
                tierHint.textContent = '';
            } else {
                var rungs = 0;
                tierClasses.forEach(function (row) {
                    var chosen = state.createTiers[row.key];
                    rungs += (chosen === undefined ? int(row.tiers, 0) : int(chosen, 0));
                });
                tierHint.textContent = rungs < 2
                    ? 'A ladder needs at least two tiers — this one has '
                      + rungs + '.'
                    : 'How many rungs of each weapon class the climb has — '
                      + rungs + ' tiers in all. 0 leaves a class out.';
            }
        }

        var livesChoice = (cfg().match || {}).livesChoice;
        var livesUsed = !!livesChoice && !laddered && livesSpent;
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

        var roundChoice = (cfg().match || {}).roundTimeChoice;
        var roundUsed = !!roundChoice;
        show(byId('create-round-row'), roundUsed);

        /* MINUTES IN THE BOX WHEREVER THE OPERATOR'S BAND HOLDS A WHOLE ONE,
           which is every shipped configuration and very nearly every other.
           `roundMinuteBand` answers null only for a band too narrow to hold
           one -- min 30, max 50, say -- and there the control stays in
           seconds and the hint says seconds, because an empty minutes box
           would be worse than an honest one in the smaller unit. */
        var roundBand = roundUsed ? roundMinuteBand(roundChoice) : null;

        var roundInput = byId('create-round');
        if (has(roundInput) && roundUsed) {
            roundInput.min = String(roundBand ? roundBand.min : int(roundChoice.min, 1));
            roundInput.max = String(roundBand ? roundBand.max : int(roundChoice.max, 1));
            /* THE STEP GOES BACK TO ONE. The markup ships step="30", which was
               right for a box counting seconds and is nonsense for one
               counting minutes -- the arrows would have jumped half an hour
               at a time, and a typed 11 would have failed the browser's own
               step validation against a min of 1. */
            roundInput.step = '1';
            if (document.activeElement !== roundInput) {
                roundInput.value = String(roundBand
                    ? Math.round(int(state.createRound, 0) / 60)
                    : int(state.createRound, 0));
            }
        }

        var roundHint = byId('create-round-hint');
        if (has(roundHint)) {
            if (!roundUsed) {
                roundHint.textContent = '';
            } else if (roundBand) {
                roundHint.textContent = 'How long a round runs, in minutes \u2014 '
                    + clock(int(state.createRound, 0)) + ' on the round clock. '
                    + roundBand.min + ' to ' + roundBand.max + '.';
            } else {
                roundHint.textContent = 'How long a round runs, in seconds \u2014 '
                    + clock(int(state.createRound, 0)) + '. '
                    + int(roundChoice.min, 1) + ' to ' + int(roundChoice.max, 1) + '.';
            }
        }

        var livesNote = byId('create-lives-note');
        if (has(livesNote)) {
            show(livesNote, laddered || !livesSpent);
            if (laddered) {
                livesNote.textContent = String(creating.label || 'This mode')
                    + ' has no lives — everyone respawns until the clock stops, '
                    + 'and a death costs you a tier instead.';
            } else if (!livesSpent) {
                livesNote.textContent = state.createWin === 'most_kills'
                    ? 'Most kills has no lives — everyone respawns until the clock stops, '
                      + 'and the highest count when it does takes it.'
                    : 'A kill limit has no lives — everyone respawns '
                      + 'until somebody reaches it.';
            }
        }

        var fee = (betting().entryFee) || {};
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
            var hoursNote = typeof schedule().line === 'string' && schedule().line !== ''
                ? ' A round already being fought finishes. A lobby that has not started when the '
                    + 'arena shuts is closed and every stake goes back.'
                : '';
            feeHint.textContent = feeUsed
                ? 'Every player pays this once to join. It all goes into the pot, and at the end of the round '
                    + payoutPhrase() + '.' + hoursNote
                : '';
        }

        var submit = byId('create-submit');
        var hint = byId('create-hint');

        var editing = editableMatch();

        var blocked = null;
        if (!editing && playerMatchId()) {
            blocked = 'You are already in a match. Leave it before starting another.';
        }
        if (!blocked && !state.createArena) blocked = 'This server has no arena switched on.';
        if (!blocked && !state.createMode) blocked = 'This server has no mode switched on.';

        /* OPENING HOURS. After the two config-fault sentences on purpose: a
           player at 03:00 who was told 'This server has no arena switched
           on.' would file a bug the operator cannot reproduce at 13:00.
           Skipped while editing -- the hours refuse a NEW match, and the
           host of one that already exists is only changing its settings. */
        if (!blocked && !editing && doorsShut()) blocked = shutSentence();

        var ceiling = int((cfg().match || {}).maxConcurrentMatches, 0);
        if (!blocked && !editing && ceiling > 0 && state.matches.length >= ceiling) {
            blocked = 'This server runs ' + plural(ceiling, 'match', 'matches')
                + ' at a time and they are all going. Join one, or wait for one to finish.';
        }

        if (editing) show(byId('create-fee-row'), false);

        /* AND THE MODE LOCKS ONCE ANYBODY HAS BACKED THE MATCH.

           A side-bet names a side, so changing the mode makes every
           outstanding pick unwinnable. ArenaLobby.UpdateMatch used to answer
           that by handing the whole book back -- which put a free, repeatable
           "cancel everyone's bets" lever in the hands of a host who is
           himself a fighter with a wager on the outcome. It refuses the
           change now, and this is the panel agreeing rather than deciding.

           ONLY THE MODE, and only when it is really being changed: the arena,
           the lives and the radar do not touch anybody's pick and stay
           editable with a full book, exactly as on the server.

           `bets`, not `betPool`: an 'odds' side-bet is funded by the server
           and never enters the pool, so the pool can read zero over a book
           with money in it. int() of an absent field is 0, so a server that
           predates the field offers the change and lets the server refuse it
           -- the same benefit of the doubt betsOpen gets. */
        if (!blocked && editing && int(editing.bets, 0) > 0
            && String(state.createMode) !== String(editing.modeKey)) {
            blocked = 'Bets are down on this match — the mode is fixed. '
                + 'Close the lobby to change it and every bet goes back.';
        }

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

        renderRadarToggle(blocked);
    }

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

    function modeByKey(key) {
        var wanted = keyOr(key, null);
        if (wanted === null) return null;
        var found = null;
        arrayOf(cfg().modes).forEach(function (mode) {
            if (mode && mode.key === wanted) found = mode;
        });
        return found;
    }

    function renderLobbyMeta(match) {
        var host = byId('lobby-meta');
        if (!has(host)) return;
        clear(host);

        var matchCfg = cfg().match || {};
        var max = int(matchCfg.maxPlayers, 0);

        var mode = modeByKey(match.modeKey);
        var tiers = ladderRungs(match, mode);
        var roundTime = match.roundTimeSeconds !== undefined && match.roundTimeSeconds !== null
            ? int(match.roundTimeSeconds, 0)
            : (mode && mode.roundTimeSeconds !== undefined && mode.roundTimeSeconds !== null
                ? int(mode.roundTimeSeconds, 0)
                : int(matchCfg.roundTimeSeconds, 0));

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

        var spendsLives = match.livesSpent !== undefined && match.livesSpent !== null
            ? match.livesSpent === true
            : winSpendsLives(keyOr(match.winCondition, matchCfg.winCondition));

        var bits = [
            String(match.modeLabel || match.modeKey || ''),
            String(match.arenaLabel || match.arenaKey || ''),
            labelFor(STATE_TEXT, match.state, ''),
            max > 0
                ? int(match.playerCount, 0) + ' of ' + max + ' players in'
                : plural(match.playerCount, 'player') + ' in',
            'Starts at ' + plural(int(matchCfg.minPlayers, 1), 'player'),
            'Host: ' + String(match.hostName || ''),
            tiers > 0
                ? 'Respawn until the clock stops'
                : (!spendsLives
                    ? (keyOr(match.winCondition, matchCfg.winCondition) === 'score_limit'
                        ? 'No lives — respawn until somebody reaches the limit'
                        : 'No lives — respawn until the clock stops')
                    : (lives === 1
                        ? 'One life — first death is elimination'
                        : plural(lives, 'life', 'lives') + ' each')),
            roundTime > 0 ? 'Round lasts ' + clock(roundTime) : 'No round clock',
            tiers > 0
                ? 'Win by topping the ' + tiers + '-tier ladder — a kill climbs, a death drops'
                /* AND THE LIMIT IS A NUMBER, so say the number.
                   `match.scoreLimit` has always been on the wire and was read
                   only by the host's own edit form -- never by a display. So
                   this line and the lives line above it both said "the limit"
                   without either of them ever naming it, on the card somebody
                   reads to decide whether to join. */
                : 'Win by ' + labelFor(winWords(match.teams === true),
                    keyOr(match.winCondition, matchCfg.winCondition), 'the mode rules')
                  + (keyOr(match.winCondition, matchCfg.winCondition) === 'score_limit'
                      && int(match.scoreLimit, 0) > 0
                        ? ' (' + int(match.scoreLimit, 0) + ' kills)'
                        : '')
        ];
        if (bettingOn()) {
            bits.push('Entry ' + money(match.entryFee));
            bits.push('Pot ' + money(match.pot));
        }
        bits.forEach(function (text) {
            if (typeof text === 'string' && text !== '') host.appendChild(makeEl('span', null, text));
        });
    }

    function teamCountOf(match, key) {
        var counts = match.teamCounts;
        if (!counts || typeof counts !== 'object') return 0;
        return int(counts[key], 0);
    }

    function teamStartBlocker(match) {
        if (!match || match.teams !== true) return null;

        var teams = cfg().teams || {};
        var list = arrayOf(teams.list);
        if (list.length === 0) return 'this server has no sides switched on.';

        var cap = int(teams.maxTeamSize, 0);
        var counts = [];
        var overCap = false;
        var freeSeats = 0;

        list.forEach(function (team) {
            var count = teamCountOf(match, team.key);
            counts.push(count);
            if (cap > 0) {
                if (count > cap) overCap = true;
                freeSeats += Math.max(0, cap - count);
            }
        });

        var sideless = arrayOf(match.players).filter(function (entry) {
            return !keyOr(entry && entry.team, null);
        }).length;

        if (teams.autoAssignIfUnchosen === false && sideless > 0) {
            return plural(sideless, 'player') + ' still without a side, and this server '
                + 'will not pick one for them.';
        }
        if (overCap) {
            return 'a side is over its ' + plural(cap, 'player') + ' limit.';
        }
        if (cap > 0 && sideless > freeSeats) {
            return 'more players are without a side than the sides have seats left for them.';
        }

        /* THE SPLIT THE SERVER MAKES FIRST, and leaving it out was the whole
           of this function's first version being wrong.
           ArenaMatch.Begin runs assignMissingTeams BEFORE Arena.CanStartMatch
           -- everybody who never touched the picker is dropped onto the
           smallest side with room -- and this measured the roster as it stood
           instead. On the SHIPPED defaults that greyed out Start on any team
           lobby holding one player who had not picked, which is exactly the
           lobby autoAssignIfUnchosen exists to allow: a differential over
           18,432 rosters found 907 lobbies the panel refused and the server
           starts, and 225 it lit that the server refuses (rosters that only
           become uneven once the split lands).

           Arena.SuggestTeam's rule, in the same order: the smallest side that
           still has room, one player at a time, so the next unplaced player
           counts the last one. Its random tie-break is not modelled and does
           not need to be -- tied sides carry equal counts, so whichever wins,
           the multiset of counts is the same and occupancy and spread are all
           that is read off it.

           THE `cap` TERM AND THE `break` BELOW CANNOT CHANGE AN ANSWER, and
           are here because SuggestTeam has them rather than because a roster
           reaches them: the smallest side can only be AT the cap when every
           side is, which means no free seats at all, and the free-seats term
           above has already refused any roster with somebody left to place.
           Removing them is not observable -- so nothing below asserts on
           them, rather than a test being written that pretends to. */
        if (teams.autoAssignIfUnchosen !== false) {
            for (var placed = 0; placed < sideless; placed += 1) {
                var pick = -1;
                for (var i = 0; i < counts.length; i += 1) {
                    if (cap > 0 && counts[i] >= cap) continue;
                    if (pick === -1 || counts[i] < counts[pick]) pick = i;
                }
                if (pick === -1) break;
                counts[pick] += 1;
            }
        }

        var occupied = 0;
        var smallest = null;
        var largest = null;
        counts.forEach(function (count) {
            if (count > 0) {
                occupied += 1;
                if (smallest === null || count < smallest) smallest = count;
                if (largest === null || count > largest) largest = count;
            }
        });

        if (teams.requireBothTeamsOccupied !== false && occupied < 2) {
            return 'both sides need a body in them.';
        }
        if (teams.allowUnequal === false && smallest !== null) {
            var gap = Math.max(0, int(teams.maxTeamSizeDifference, 1));
            if (largest - smallest > gap) {
                return 'the sides are ' + smallest + ' against ' + largest + ', more than '
                    + plural(gap, 'player') + ' apart.';
            }
        }
        return null;
    }

    function renderTeamPicker(match) {
        var host = byId('team-picker');
        if (!has(host)) return;
        clear(host);

        var teams = cfg().teams || {};
        if (match.teams !== true) {
            show(host, false);
            return;
        }
        show(host, true);

        var list = arrayOf(teams.list);
        var mine = keyOr(player().team, null);

        list.forEach(function (team) {
            var count = teamCountOf(match, team.key);

            var tile = makeEl('div', 'team-tile');
            tile.style.borderLeftColor = teamColor(team);
            if (team.key === mine) tile.classList.add('active');

            tile.appendChild(makeEl('div', 'team-tile-name', team.label || team.key));
            tile.appendChild(makeEl('div', 'team-tile-count',
                plural(count, 'player') + (team.key === mine ? ' · you' : '')));

            /* WHY THIS TILE CANNOT BE CLICKED, or null. Each of these is a
               refusal server/lobby.lua already makes; the panel used to make
               none of them, so a tile that would be turned down looked
               exactly like one that would not and answered with a red toast
               after the click. */
            var locked = null;
            if (teams.allowChoose === false) {
                locked = 'Sides are assigned by the server.';
            } else if (playerMatchId() !== match.id) {
                locked = 'You are not in this match.';
            } else if (match.state !== 'lobby') {
                locked = 'This match has already kicked off — sides are locked.';
            } else if (team.key !== mine && int(teams.maxTeamSize, 0) > 0
                       && count >= int(teams.maxTeamSize, 0)) {
                locked = 'This side is full (' + plural(int(teams.maxTeamSize, 0), 'player') + ').';
            }

            if (locked === null) {
                tile.title = 'Fight on this side.';
                tile.addEventListener('click', function () {
                    post('setTeam', { teamKey: team.key });
                });
            } else {
                tile.classList.add('locked');
                tile.title = locked;
                tile.style.cursor = 'default';
            }

            host.appendChild(tile);
        });

        if (teams.allowChoose === false) {
            host.appendChild(makeEl('div', 'hint', 'Sides are assigned by the server. You cannot pick one.'));
        } else if (playerMatchId() === match.id) {
            host.appendChild(makeEl('div', 'hint', match.state === 'lobby'
                ? 'Click a side to move to it. The one you are on is lit.'
                : 'Sides are locked once the match starts. Yours is lit.'));
        }

        /* Uneven teams are legal by default -- 7v1 is a match, not an
           error -- so the counts are stated plainly and nothing is flagged
           unless the server would really refuse. Warning against zero rather
           than against the server's own allowance used to tell a 3v2 lobby
           the round could not start when it perfectly well could, and a host
           levelled sides the server had never objected to.

           THROUGH THE SAME ANSWER THE START BUTTON USES. Two hand-written
           warnings lived here, and they disagreed with the button above them
           in both directions: they stayed silent on a side over its cap and
           on a player with no side, and they told an all-unpicked lobby that
           both sides needed a body on a server that would have split it and
           started it perfectly happily. */
        var refusal = teamStartBlocker(match);
        if (refusal !== null) {
            host.appendChild(makeEl('div', 'hint',
                'The round cannot start yet: ' + refusal));
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

    function renderRadarToggle(blocked) {
        var host = byId('create-radar-row');
        if (!has(host)) return;

        var settings = radarSettings();
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
            var teamRules = cfg().teams || {};
            var needsSide = !isReady
                && match.teams === true
                && teamRules.autoAssignIfUnchosen === false
                && !keyOr(player().team, null);

            ready.textContent = isReady ? 'Not Ready' : 'Ready Up';
            var startsOnReady = (cfg().match || {}).autoStartWhenAllReady === true;
            ready.title = needsSide
                ? 'Pick a side above first — this server will not put you on one for you.'
                : (isReady
                    ? 'Take your ready back. Nothing starts without you.'
                    : (startsOnReady
                        ? 'Tell the others you are set. Once everybody is ready the round starts on its own.'
                        : 'Tell the others you are set. This does not start the round.'));
            ready.classList.toggle('btn-primary', !isReady);
            ready.disabled = !inMatch || match.state !== 'lobby' || needsSide;
            ready.onclick = function () {
                play('ready');
                post('setReady', { ready: !isReady });
            };
        }

        var onlyHost = (cfg().match || {}).onlyHostCanStart !== false;
        var mayStart = inMatch && (isHost || !onlyHost);
        var minPlayers = int((cfg().match || {}).minPlayers, 1);
        var teamRefusal = teamStartBlocker(match);
        var blocked = null;
        if (!inMatch) blocked = 'you are watching this match, not in it.';
        else if (!mayStart) blocked = 'only the host can start it.';
        else if (int(match.playerCount, 0) < minPlayers) {
            blocked = 'the round needs ' + plural(minPlayers, 'player')
                + ' and has ' + plural(match.playerCount, 'player') + '.';
        }
        else if (doorsShut()) {
            var opensAtStart = schedule().opensAt;
            blocked = typeof opensAtStart === 'string' && opensAtStart
                ? 'the arena is shut -- it opens at ' + opensAtStart + '.'
                : 'the arena is shut at this hour.';
        }
        else if (teamRefusal !== null) blocked = teamRefusal;

        var start = byId('btn-start');
        if (has(start)) {
            start.textContent = counting ? 'Stop The Countdown' : 'Start Match Now';
            if (counting) {
                start.disabled = !isHost;
                start.title = isHost
                    ? 'Hold the start. Everybody stays in the lobby and nobody loses their place.'
                    : 'Only the host can stop the countdown.';
                start.onclick = function () { post('holdCountdown'); };
            } else {
                start.disabled = blocked !== null;
                start.title = blocked === null
                    ? 'Send everyone into the arena. There is a countdown first.'
                    : capitalise(blocked);
                start.onclick = function () { post('startMatch'); };
            }
        }

        /* CLOSING THE LOBBY YOU OPENED.

           ArenaLobby.Cancel has always existed, is tested, and has a shipped
           setting of its own -- Config.Betting.refundOnCancel, documented as
           "a host closing their own lobby". Nothing could reach it. The
           panel's only cancel was the "Stop The Countdown" button, which
           posted cancelMatch while promising the lobby survived; repointing
           that at holdCountdown fixed the lie and left the capability with no
           way in, so a host who opened a lobby by mistake could only walk out
           of it or wait out idleLobbyTimeoutSeconds.

           OFFERED ONLY IN 'lobby', which is narrower than the server allows
           on purpose. Cancel also accepts a lobby countdown but refuses the
           frozen start countdown, and both are called 'countdown' -- the
           panel cannot tell them apart from the snapshot, and this is not the
           button to guess with. During a countdown the host has Stop The
           Countdown, which puts the match back to 'lobby'; this appears
           there. Two steps, each labelled honestly. */
        var close = byId('btn-close');
        if (has(close)) {
            var mayClose = isHost && String(match.state) === 'lobby';
            show(close, mayClose);
            if (mayClose) {
                var fee = int(match.entryFee, 0);
                var refunds = (betting() || {}).refundOnCancel !== false;
                close.disabled = false;
                close.title = 'Close this lobby and send everybody back. '
                    + (fee <= 0
                        ? 'Nothing was staked on it.'
                        : (refunds
                            ? 'Every entry fee is handed back.'
                            : 'Entry fees are NOT handed back on this server.'));
                close.onclick = function () { post('cancelMatch'); };
            } else {
                close.onclick = null;
            }
        }

        var leave = byId('btn-leave');
        if (has(leave)) {
            /* A LOBBY YOU HAVE MONEY ON IS NOT ONE YOU CAN WALK OUT OF.

               ArenaLobby.Leave refuses it, for the reason its twin on Join
               already gives: a bet its holder can cancel at a moment of their
               choosing is a bet with no risk in it. Walking out used to be
               that cancel, and worse than a cancel -- the fighter band is
               twice the spectator one, so a fighter kept a 50,000 position in
               a field capped at 25,000 by standing up.

               MIRRORED HERE OR THE FIX IS A LIT BUTTON AND A RED TOAST, which
               is the exact defect class three commits in this repo have
               already fixed once each. `player().bet` is the bet on the match
               this player is IN, which is precisely the one the server asks
               about.

               THE SAME NARROWINGS THE SERVER MAKES, deliberately copied
               rather than guessed: the lobby and the countdown, never a live
               round -- a fighter being shot at may always quit, and the
               server lets them -- and only for somebody who is IN the match,
               never for a watcher, whose Stop Watching this button also is.

               The countdown is not padding on either side: without it the
               whole rule is worth waiting out a ten-second countdown for. */
            var stuck = inMatch
                && (String(match.state) === 'lobby' || String(match.state) === 'countdown')
                && !!player().bet;

            leave.textContent = inMatch ? 'Leave Match' : 'Stop Watching';
            leave.title = stuck
                ? 'Your money is on this match. See the round out, or have the lobby closed — '
                    + 'that hands every bet back.'
                : (inMatch
                    ? 'Take yourself out of this match.'
                    : 'Stop watching and put the camera back on you.');
            leave.disabled = stuck;
            leave.onclick = function () {
                if (stuck) return;
                if (inMatch) post('leaveMatch');
                else post('stopSpectate');
            };
        }

        var hint = byId('lobby-hint');
        if (has(hint)) hint.textContent = lobbyHintText(match, inMatch, isHost, blocked);
    }

    /* The catalogue split by kind for the two lists, in config order -- an
       operator who arranged their weapons deliberately keeps that order.
       This is about which LIST a weapon appears in, not what it costs. */
    function weaponCatalogue(melee) {
        return arrayOf((cfg().loadouts || {}).weapons).filter(function (weapon) {
            return weapon && keyOr(weapon.key, null) !== null && isMelee(weapon) === melee;
        });
    }

    /* How many weapons the draft holds, of one kind or of all of them.
       Counted rather than tracked: a key left over from a weapon an operator
       has since removed resolves to nothing and must not be charged to a
       pool it can no longer fill. */
    function draftCount(melee) {
        var used = 0;
        state.draftWeapons.forEach(function (pick) {
            var weapon = weaponByKey(pick.key);
            if (weapon && (melee === undefined || isMelee(weapon) === melee)) used += 1;
        });
        return used;
    }

    function draftTotal() {
        return draftCount(undefined);
    }

    /* THE MOST WEAPONS THE WIRE WILL CARRY, whatever the operator's slot
       setting says. server/main.lua reads at most MAX_WEAPON_ENTRIES = 32
       entries out of a setLoadout payload and stops; the rest never reach
       Arena.ResolveLoadout, so they are not in `rejected` either and nothing
       is sent to say they were dropped.

       Config.Loadouts.slots = 0 is documented as "no limit", and the panel
       honoured that literally: a player on a 96-weapon catalogue could pick
       forty, be told "40 weapons", press Save, and have eight of them vanish
       with no message anywhere. Unlimited means unlimited up to what can be
       sent. KEEP THIS IN STEP with MAX_WEAPON_ENTRIES. */
    var WIRE_WEAPON_CAP = 32;

    function poolIsFull(melee) {
        if (!kindAllowed(melee)) return true;
        var limit = slotLimit();
        if (limit > 0) return draftTotal() >= limit;
        return draftTotal() >= WIRE_WEAPON_CAP;
    }

    function poolCounterText() {
        var limit = slotLimit();
        if (limit <= 0) return plural(draftTotal(), 'weapon');
        return String(draftTotal()) + ' of ' + plural(limit, 'weapon');
    }

    function poolFullMessage(melee) {
        if (!kindAllowed(melee)) {
            return melee
                ? 'This arena has melee switched off. Blades are not issued here.'
                : 'This arena hands out no firearms. Only melee is issued here.';
        }

        return 'You are carrying ' + poolCounterText()
            + '. Guns and melee share one count, so drop something before picking another.';
    }

    function bareMap() {
        return Object.create(null);
    }

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

    function wouldSwap(weaponKey, typeKey) {
        var entry = ammoTypePlan({ key: weaponKey, ammoType: typeKey }).byKey[weaponKey];
        return entry !== undefined && entry.swapped === true;
    }

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

    function renderLoadoutNote() {
        var host = byId('loadout-note');
        if (!has(host)) return;
        clear(host);

        var locked = loadoutLockReason();
        if (locked !== null) {
            host.appendChild(makeEl('div', 'hint', locked));
            return;
        }

        /* NOT IN A MATCH IS ITS OWN ANSWER. The host-picks sentence above
           used to be the ONLY thing this branch could say, so somebody
           standing in the lobby in no match at all was told a host they do
           not have had already chosen for them -- and that an empty preview
           was "exactly what you will be handed". The lists stay: picking
           early costs nothing and takes nothing away. */
        if (!playerMatchId()) {
            host.appendChild(makeEl('div', 'hint',
                'You are not in a match yet, so nothing here is saved. Join or create one on the '
                + 'Matches tab and this becomes what you carry into it.'));
        }

        if (hostPicksLoadout()) {
            host.appendChild(makeEl('div', 'hint',
                'You are the host, so this is the loadout EVERY player in your match will carry — '
                + 'yourself included. Anyone who joins after you pick inherits it.'));
        }

        var limit = slotLimit();
        var carry = limit > 0 ? plural(limit, 'weapon') : 'as many weapons as you like';
        var text = 'Click a weapon to carry it, and click it again to drop it. ';

        if (allowFirearms() && allowMelee()) {
            text += 'You carry ' + carry + ' in total and the mix is yours — '
                + 'all guns, all melee, or any combination.';
        } else if (allowMelee()) {
            text += 'This arena is melee only: ' + carry + '.';
        } else if (allowFirearms()) {
            text += 'This arena issues no melee: ' + carry + '.';
        } else {
            text += 'This arena issues no weapons at all.';
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
        var choosing = canChooseLoadout();

        var firearms = choosing ? weaponCatalogue(false) : [];
        var blades = choosing ? weaponCatalogue(true) : [];

        var gunsOn = allowFirearms() && firearms.length > 0;
        var meleeOn = allowMelee() && blades.length > 0;

        show(byId('loadout-firearms'), gunsOn);
        show(byId('loadout-melee'), meleeOn);
        show(byId('loadout-lists'), gunsOn || meleeOn);

        var empty = byId('loadout-empty');
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
            renderSectionCount('firearms-count');
            renderWeaponGrid('weapon-grid', firearms.filter(function (weapon) {
                return inCategory(weapon, active);
            }), plan);
        }

        if (meleeOn) {
            renderSectionCount('melee-count');
            renderWeaponGrid('melee-grid', blades, plan);
        }
    }

    /* THE SAME COUNTER OVER BOTH LISTS, because there is one pool and the
       lists are only a way of browsing ninety weapons without scrolling
       past the knives to reach the rifles. Lit when the pool is spent, so
       'no room left' reads without anyone doing the sum.

       The two headings stay -- 'Firearms' and 'Melee' -- and the counter
       under each says the same thing on purpose. A player looking at the
       melee list needs to know how full they are, and the answer is not
       specific to the list they happen to be looking at. */
    function renderSectionCount(id) {
        var host = byId(id);
        if (!has(host)) return;

        var limit = slotLimit();
        host.textContent = poolCounterText();
        host.classList.toggle('full', limit > 0 && draftTotal() >= limit);
        host.title = 'Guns and melee share one count. '
            + 'Fill it with whichever you like.';
    }

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
        if (hasOther) cats.push({ key: '__other', label: 'Other' });
        return cats;
    }

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

    function renderWeaponGrid(id, weapons, plan) {
        var host = byId(id);
        if (!has(host)) return;
        clear(host);

        if (weapons.length === 0) {
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
        var poolFull = !picked && poolIsFull(melee);

        var card = makeEl('div', 'weapon-card');
        card.id = 'weapon-card-' + weapon.key;
        if (picked) card.classList.add('active');
        if (poolFull && canChooseLoadout()) card.classList.add('blocked');

        card.appendChild(makeEl('div', 'weapon-name', weapon.label || weapon.key));
        card.appendChild(makeEl('div', 'weapon-category', weapon.category || 'other'));

        var ammo = weapon.ammo || {};
        var options = arrayOf(ammo.options);

        /* CONTROLS ONLY ON A WEAPON YOU HAVE ACTUALLY PICKED.

           THE CLUTTER THIS REMOVES. Every card drew its full set of controls
           whether or not it was in the loadout -- two rows of chips each,
           across a catalogue of ninety-six. The screen was mostly buttons
           for guns nobody had chosen, the three that WERE chosen looked
           identical to the rest, and the one thing a player needs to see at
           a glance -- what am I taking in -- was the hardest thing on it.

           An unpicked card is now a name, a class, and one quiet line saying
           what it would come with. Pick it and the controls appear. Nothing
           is hidden that you cannot get back by clicking the card you were
           going to click anyway. */
        if (options.length > 0 && !picked) {
            var summary = String(int(ammo.default, 0)) + ' rounds';
            var names = arrayOf(weapon.attachments).map(function (option) {
                return String(option.label || option.key);
            });
            if (names.length > 0) summary += ' · ' + names.join(', ');
            card.appendChild(makeEl('div', 'weapon-fixed', summary));
        } else if (options.length > 0) {
            var row = makeEl('div', 'weapon-ammo');
            row.appendChild(makeEl('span', 'weapon-field-label', 'Rounds'));
            var chosen = picked ? state.draftWeapons[index].ammo : int(ammo.default, 0);

            /* HELD ON TO, so the typed-amount box below can re-light the
               right one WITHOUT a render. See the blur handler. */
            var presetChips = [];
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
                presetChips.push({ node: chip, amount: amount });
                row.appendChild(chip);
            });

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
                /* A HINT YOU CAN SEE, not one you have to hover to find.

                   The box sat at the end of the preset chips as a bare
                   four-character field with a `title` and nothing else --
                   the operator asked outright where the custom amount had
                   gone, which is the whole answer about how discoverable it
                   was. A word in front of it and a number in it cost one
                   line each. */
                box.placeholder = String(int(ammo.max, 0));
                /* AND THE CEILING IS THIS WEAPON'S OWN. The box already held
                   this weapon's chosen amount and was already capped at this
                   weapon's own maximum -- but it said neither, so it read as
                   a general-purpose number field and the operator asked what
                   it was even for. Naming the limit turns it into an answer
                   to "how much can this gun carry". */
                row.appendChild(makeEl('span', 'weapon-ammo-or',
                    'or up to ' + int(ammo.max, 0)));

                /* Clicking into the box must not toggle the weapon card
                   underneath it, which is what every other click here does. */
                box.addEventListener('click', function (event) { event.stopPropagation(); });
                box.addEventListener('input', function (event) {
                    event.stopPropagation();
                    var wanted = clampInt(event.target.value, 0, int(ammo.max, 0));
                    setWeaponAmmo(weapon.key, wanted, true);
                });

                /* THE FIRST CLICK ON ANYTHING ELSE USED TO BE SWALLOWED.

                   This was `render()`, and a full render is the one thing
                   that must not happen here: blur fires on MOUSEDOWN, before
                   mouseup. render() clears the grid and rebuilds every card,
                   so the node the mousedown landed on was detached, the
                   browser had no common ancestor to dispatch a click to, and
                   the click never happened. Measured in a real browser --
                   with the caret in this box, the first click on a preset
                   chip, an attachment, an ammo type, another weapon card or
                   a category chip did nothing at all, and only the second
                   worked. The DOM shim the panel tests run in cannot see
                   this: it has no mousedown/mouseup split.

                   What the render was FOR is the two lines below it: the
                   typed amount has to be clamped into the box, and the
                   preset chip matching it has to light up. Both are done in
                   place now, on nodes that already exist, so nothing is
                   torn out from under a click that is already on its way. */
                box.addEventListener('blur', function (event) {
                    var wanted = clampInt(event.target.value, 0, int(ammo.max, 0));
                    setWeaponAmmo(weapon.key, wanted, true);
                    event.target.value = String(wanted);
                    presetChips.forEach(function (entry) {
                        entry.node.classList.toggle('active', entry.amount === wanted);
                    });
                });

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
            card.appendChild(makeEl('div', 'weapon-fixed',
                'Always ' + plural(int(ammo.default, 0), 'round')));
        }

        var types = ammoTypesOf(weapon);
        if (types.length > 1) {
            var typeRow = makeEl('div', 'weapon-ammo');
            typeRow.appendChild(makeEl('span', 'weapon-field-label', 'Ammo type'));

            var entry = picked ? plan.byKey[weapon.key] : undefined;
            var chosenType = entry !== undefined ? entry.chosen : null;
            var defaultLabel = ammoTypeLabel(weapon, defaultAmmoType(weapon));
            var capSpent = plan.cap > 0 && plan.distinct >= plan.cap;

            types.forEach(function (type) {
                var chip = makeEl('button', 'chip', type.label || type.key);
                chip.type = 'button';
                if (picked && type.key === chosenType) chip.classList.add('active');

                var swaps = picked
                    ? wouldSwap(weapon.key, type.key)
                    : (capSpent && plan.taken[type.key] !== true);
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

            if (entry !== undefined && entry.swapped === true) {
                var loadedLabel = ammoTypeLabel(weapon, entry.loaded);
                var wantedLabel = ammoTypeLabel(weapon, entry.chosen);
                card.appendChild(makeEl('div', 'weapon-note',
                    'Loaded with ' + (loadedLabel === null ? 'the default' : loadedLabel)
                    + ', not ' + (wantedLabel === null ? 'your pick' : wantedLabel)
                    + ' — this loadout is already carrying its ' + plural(plan.cap, 'round type') + '.'));
            }
        }

        /* THE ATTACHMENTS THIS WEAPON CAN TAKE, AND ONLY THOSE.

           The list comes from the server, resolved through the same table
           the server fits from -- so a chip can never offer something that
           would then be refused, exactly as with the ammo types above. A
           weapon that takes none draws no row at all rather than an empty
           heading. */
        var fittings = arrayOf(weapon.attachments);
        if (fittings.length > 0 && picked) {
            var fitRow = makeEl('div', 'weapon-ammo');
            fitRow.appendChild(makeEl('span', 'weapon-field-label', 'Attachments'));

            var fittedNow = attachmentsOn(weapon.key);
            fittings.forEach(function (option) {
                var kind = String(option.key);
                /* ITS OWN CLASS, because it does not behave like the row
                   above it. Rounds are a choice of ONE and read as a dial;
                   attachments are a set of switches, each independently on
                   or off. Styling them identically was asking a player to
                   learn which row behaved which way. */
                var fitChip = makeEl('button', 'chip attachment-chip',
                    String(option.label || kind));
                /* ADDRESSABLE, like the typed-ammo box above. A chip with no
                   id can only be found by a selector, and a test that leans
                   on one is testing whatever the selector engine feels like
                   returning. */
                fitChip.id = 'attachment-' + weapon.key + '-' + kind;
                fitChip.type = 'button';
                if (fittedNow.indexOf(kind) >= 0) fitChip.classList.add('active');
                fitChip.disabled = !canChooseLoadout() || !mayChooseAttachments();
                /* SAYS WHAT THIS CHIP IS, not what the row is. The second
                   branch was dead -- this whole block only runs when `picked`
                   is true -- so every chip claimed to be fitted, including
                   the ones the player had just switched off. It is the one
                   control whose entire job is to say whether a component is
                   going on the gun. */
                fitChip.title = !mayChooseAttachments()
                    ? 'Fitted by the server — every weapon is issued the same way here'
                    : (fittedNow.indexOf(kind) >= 0
                        ? 'Fitted for the match — click to take it off'
                        : 'Not fitted — click to put it on');
                fitChip.addEventListener('click', function (event) {
                    event.stopPropagation();
                    toggleWeaponAttachment(weapon.key, kind);
                });
                fitRow.appendChild(fitChip);
            });
            card.appendChild(fitRow);

            /* AND SAY SO, because a row of buttons that will not press is the
               kind of thing a player reports as broken. The label alone does
               not tell them whether the arena is fitting these or their own
               click went unheard. */
            if (!mayChooseAttachments()) {
                card.appendChild(makeEl('div', 'weapon-note',
                    'These come with the gun on this server — everybody is issued the same.'));
            }
        }

        if (poolFull && canChooseLoadout()) {
            card.appendChild(makeEl('div', 'weapon-note',
                'Full — ' + poolCounterText()
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

    function renderLoadoutSlots(plan) {
        var host = byId('loadout-slots');
        if (!has(host)) return;
        clear(host);

        host.appendChild(makeEl('div', 'panel-heading', 'Into The Round'));

        var ladderMode = playerMode();
        if (modeIssuesLoadout(ladderMode)) {
            host.appendChild(makeEl('div', 'hint',
                'You open on tier 1 of ' + ladderRungs(matchById(playerMatchId()), ladderMode) + ', like everybody else. '
                + 'What each tier is holding is drawn when the round starts, so it is not the '
                + 'same ladder twice.'));

            var issued = startingKitText(ladderMode);
            var noOpinion = (ladderMode.startingKit === undefined
                    || ladderMode.startingKit === null)
                && supplyConfig().enabled !== false;
            host.appendChild(makeEl('div', 'hint', issued !== ''
                ? 'You are issued ' + issued + ' with it.'
                : noOpinion
                    ? 'This mode issues no kit of its own, so you carry whatever this server '
                        + 'hands out by default.'
                    : 'No supplies are issued in this mode.'));

            renderRestoreNote(host);
            return;
        }

        slotGroup(host, plan);

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

        renderRestoreNote(host);
    }

    /* WHAT HAPPENS TO THE GUNS THEY WALKED IN WITH -- the question every
       player asks before their first round, and the one thing on this
       screen the panel must not guess at. `restoreLoadoutOnExit` is an
       operator switch, and promising a player their own weapons back on a
       server that does not do that would be a lie told at the worst possible
       moment. So it is read off the snapshot, and SAYS NOTHING AT ALL when
       the snapshot does not carry it: silence is the honest third answer.

       ITS OWN FUNCTION because the ladder branch above returns early and
       this is true in every mode -- a gun game takes your own weapons off
       you exactly as a free-for-all does, and that is the last thing a
       player wants left unsaid. */
    function renderRestoreNote(host) {
        var restore = (cfg().match || {}).restoreLoadoutOnExit;
        if (restore === true) {
            host.appendChild(makeEl('div', 'hint',
                'Your own weapons and armour are held while you fight and handed back when you leave.'));
        } else if (restore === false) {
            host.appendChild(makeEl('div', 'hint',
                'This server does NOT give your own weapons back when you leave the arena.'));
        }
    }

    /* THE WHOLE LOADOUT, IN ONE GROUP, because there is one pool and
       splitting the summary back into 'Firearms' and 'Melee' would be the
       panel telling the player about a division the server no longer makes.

       IN DRAFT ORDER, which is not cosmetic: Arena.ResolveLoadout walks the
       request in the order it arrives and the ammo-type plan spends its cap
       in that same order, so the first rows are the ones that keep the round
       they were given. Sorting this list would make the summary disagree
       with the loadout it describes.

       EMPTY ROWS ONLY WHERE THERE IS A LIMIT TO DRAW THEM AGAINST. With no
       limit there is no such thing as an unfilled slot, so the group is
       exactly as long as the draft. */
    function slotGroup(host, plan) {
        if (!allowFirearms() && !allowMelee()) return;

        var limit = slotLimit();
        var picks = state.draftWeapons.filter(function (pick) {
            return weaponByKey(pick.key) !== null;
        });

        var head = makeEl('div', 'slot-group-head');
        head.appendChild(makeEl('span', 'slot-group-title', 'Weapons'));
        var count = makeEl('span', 'loadout-count', poolCounterText());
        if (limit > 0 && picks.length >= limit) count.classList.add('full');
        head.appendChild(count);
        host.appendChild(head);

        var rows = limit > 0 ? limit : picks.length;
        for (var i = 0; i < rows; i++) {
            var pick = picks[i];
            var weapon = pick ? weaponByKey(pick.key) : null;
            host.appendChild(slotRow(pick, weapon !== null && isMelee(weapon), plan));
        }
    }

    function slotRow(pick, melee, plan) {
        var slot = makeEl('div', 'slot');

        if (!pick) {
            slot.appendChild(makeEl('span', 'muted', canChooseLoadout()
                ? 'Empty — click a weapon to fill it'
                : 'Empty'));
            return slot;
        }

        slot.classList.add('filled');
        var weapon = weaponByKey(pick.key);

        var main = makeEl('div', 'slot-main');
        main.appendChild(makeEl('div', 'slot-name',
            (weapon && (weapon.label || weapon.key)) || pick.key));

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
        show(byId('loadout-save-row'), canChooseLoadout());

        var saveable = loadoutIsSaveable();

        var save = byId('loadout-save');
        if (has(save)) {
            save.disabled = !state.loadoutDirty || !saveable;
            save.title = !saveable
                ? 'Join a match first — there is nothing to save this to yet.'
                : (state.loadoutDirty
                    ? 'Keep these weapons for your next round.'
                    : (state.loadoutSaving
                        ? 'Waiting for the server to confirm.'
                        : 'Nothing has changed since your last save.'));
        }

        var status = byId('loadout-save-status');
        if (has(status)) {
            if (!saveable) {
                status.textContent = 'Not in a match — pick what you like, but join one before it counts.';
            } else if (state.loadoutDirty) {
                status.textContent = 'Unsaved — press Save Loadout or you will fight with what you had before.';
            } else if (state.loadoutSaving) {
                status.textContent = 'Saving — waiting for the server.';
            } else {
                status.textContent = 'Saved. This is what you are handed when a round starts.';
            }
        }
    }

    function supplyConfig() {
        return (cfg().loadouts || {}).supplies || {};
    }

    function supplyCatalogue() {
        return arrayOf(supplyConfig().items);
    }

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

        var issuing = playerMode();
        if (modeIssuesLoadout(issuing)) {
            var kit = arrayOf(issuing.startingKit);
            if (kit.length === 0) return;

            host.appendChild(makeEl('span', 'field-label', 'Supplies'));
            kit.forEach(function (entry) {
                var row = makeEl('div', 'supply-row');
                row.appendChild(makeEl('span', 'supply-name', String(entry.label || '')));
                row.appendChild(makeEl('span', 'supply-count', String(int(entry.count, 0))));
                host.appendChild(row);
            });
            host.appendChild(makeEl('div', 'hint',
                'Issued to everyone at the start of every round in this mode. Nothing here is yours to change.'));
            return;
        }

        var config = supplyConfig();
        var catalogue = supplyCatalogue();
        if (config.enabled !== true || catalogue.length === 0) return;

        host.appendChild(makeEl('span', 'field-label', 'Supplies'));

        var draft = state.draftSupplies || {};
        var picking = config.allowChoose !== false && canChooseLoadout();
        var ceiling = int(config.totalItems, 0);

        catalogue.forEach(function (supply) {
            var row = makeEl('div', 'supply-row');
            row.appendChild(makeEl('span', 'supply-name', supply.label || supply.key));

            if (!picking) {
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
        if (!canChooseLoadout() || !loadoutIsSaveable()) return;
        post('setLoadout', {
            weapons: state.draftWeapons.map(function (pick) {
                var entry = { key: pick.key, ammo: int(pick.ammo, 0) };
                var type = keyOr(pick.ammoType, null);
                if (type !== null) entry.ammoType = type;

                /* SENT ONLY WHEN THE PLAYER TOUCHED IT. Absent means "fit
                   what this server fits by default", which is what an
                   untouched pick should get and what every loadout saved
                   before attachments existed already gets. An EMPTY list is
                   a different answer -- somebody took it all off -- and it
                   survives the trip because [] is still a list. */
                if (Array.isArray(pick.attachments)) {
                    entry.attachments = pick.attachments.map(String);
                }
                return entry;
            }),
            supplies: supplyCatalogue().map(function (supply) {
                return { key: supply.key, count: int((state.draftSupplies || {})[supply.key], 0) };
            })
        });
        state.loadoutDirty = false;
        state.loadoutSaving = true;
        render();
    }

    function betAsFighter(match) {
        return !!match && playerMatchId() === match.id;
    }

    /* A FIGHTER WHO WALKED OUT OF A LIVE ROUND, whom the roster no longer
       holds.

       THE DEFECT: it did not hold them, so the panel saw an ordinary
       onlooker. The server does not -- PlaceSpectatorBet judges a departed
       fighter against the FIGHTERS' book, which shuts the moment the round
       goes live, precisely so that walking out is not a way to open a wager
       you can cancel once it is going badly. The panel offered them the
       watcher's thirty-second grace instead: an enabled Place Bet button, the
       stake and the account written out underneath it, and `error.bets_closed`
       from the server on the click. The rule was right and invisible.

       The server now sends the list; this is the only reader. */
    function betWalkedOutOf(match) {
        if (!match) return false;
        return arrayOf(player().walkedOut).indexOf(match.id) !== -1;
    }

    /* THE STAKE BAND, WORKED OUT THE WAY THE SERVER WORKS IT OUT.

       The panel had invented a rule of its own: "max of 0 means no limit".
       shared/arena.lua does the opposite --

           local maximum = math.max(minimum, Arena.ToInt(rules.max) or minimum)

       -- so a max of 0, or a max the operator simply deleted, collapses the
       band to exactly `min`. Measured: with min 50 and max 0 the server
       accepts 50 and refuses 51, 100 and 500, while the panel offered
       everything up to the player's balance and told them "50 and up". Every
       one of those clicks came back a refusal with nothing on screen to
       explain it. */
    function betBand(match) {
        var rules = betRules(match);
        var min = Math.max(0, int(rules.min, 0));
        var max = int(rules.max, 0);
        return { min: min, max: Math.max(min, max) };
    }

    function betRules(match) {
        return betAsFighter(match)
            ? (betting().fighterBets || {})
            : (betting().spectatorBets || {});
    }

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

    /* How many players a side still has who can WIN it.

       Not teamCountOf: that reads match.teamCounts, which counts every row
       on the side because an eliminated fighter deliberately keeps theirs --
       the results board ranks off it. For the join picker and the capacity
       check that is the right number; for "is there anything here to back"
       it is not.

       `alive` on the wire already carries exactly this: server/lobby.lua
       sends `not isEliminated(...)`, so a fighter waiting out a respawn is
       still true and only somebody out of lives is false. */
    function liveTeamCountOf(match, key) {
        var live = 0;
        arrayOf(match.players).forEach(function (entry) {
            if (entry.team === key && entry.alive !== false) live += 1;
        });
        return live;
    }

    function currentPick(match) {
        if (!match || state.betPickMatchId !== match.id) return null;
        return state.betPick;
    }

    /* A NAME FOR EVERY SIDE ON THE BOOK, including the ones that can no
       longer win.

       betPickOptions below deliberately drops eliminated fighters -- the
       server refuses a bet on them, so they must not be offered. But money
       already staked on them STAYS on the book: nothing returns it on
       elimination, only on the backer leaving. Reading labels out of the
       offer list therefore left those stakes labelled with a bare server id
       -- "1,800 on 47" -- on the one screen that is about whose money is
       where. */
    function betSideLabels(match) {
        var out = {};
        if (!match) return out;

        if (match.teams === true) {
            arrayOf((cfg().teams || {}).list).forEach(function (team) {
                if (team && team.key !== undefined) out[String(team.key)] = team.label || team.key;
            });
            return out;
        }

        arrayOf(match.players).forEach(function (entry) {
            if (!entry) return;
            out[String(int(entry.id, 0))] = entry.name || ('#' + int(entry.id, 0));
        });
        return out;
    }

    function betPickOptions(match) {
        if (!match) return [];
        if (match.teams === true) {
            return arrayOf((cfg().teams || {}).list)
                .filter(function (team) { return liveTeamCountOf(match, team.key) > 0; })
                .map(function (team) {
                    return { pick: team.key, label: team.label || team.key, color: teamColor(team) };
                });
        }
        /* THE SERVER REFUSES THESE, so the panel must not offer them. The
           book stays open for 30 seconds after the round goes live, and
           inside that window this list used to include fighters who were
           already out -- a chip that took the player's money and then lost
           it to whoever backed the winner. */
        return arrayOf(match.players).filter(function (entry) {
            return entry.alive !== false;
        }).map(function (entry) {
            return { pick: String(int(entry.id, 0)), label: entry.name || ('#' + int(entry.id, 0)), color: null };
        });
    }

    function renderBets() {
        var enabled = bettingOn();
        var disabled = byId('bet-disabled');

        show(disabled, !enabled);
        if (has(disabled) && !enabled) {
            clear(disabled);
            disabled.appendChild(makeEl('div', null, 'No money in this arena'));
            disabled.appendChild(makeEl('div', 'bet-disabled-sub',
                'This server runs its matches for nothing: no entry fee, no pot and no side-bets. '
                + 'Wins and kills still count towards the leaderboard.'));
        }

        /* EVERY TOP-LEVEL BOX ON THE TAB, and `bet-note` belongs on this list
           because it is one of them. It used to sit inside `bet-form` and be
           hidden by hiding its parent; it was moved out to the column beside
           the roster, and a box that hides itself is exactly what an
           inherited rule stops being once it stops being inherited. Switch
           betting off and the rules of a game this server does not run were
           still on the screen, under the notice saying so. */
        ['bet-match', 'bet-summary', 'bet-form', 'bet-list', 'bet-note'].forEach(function (id) {
            show(byId(id), enabled);
        });
        if (!enabled) return;

        /* THE ORDER THE PLAYER READS IN, which is not the order this used to
           run in. The explanation is drawn LAST because it now sits under
           the button rather than on top of the form. */
        var match = focusedMatch();
        renderBetMatch(match);
        renderBetSummary(match);
        renderBetPick(match);
        renderBetSplit(match);
        renderBetControls(match);
        renderBetNote(match);
        renderBetList(match);
    }

    /* WHAT IS RIDING ON EACH SIDE, as pick -> amount.

       server/lobby.lua sends this beside `betPool` and builds it with the
       same filter, so the parts add up to that total and a reader can check
       the panel's arithmetic against its own summary.

       Absent on an older server, or on a match nobody has bet on: both come
       back as an empty object, which every reader below treats as "nothing
       on the board" rather than as missing data. There is nothing to tell
       apart -- no bets and no field both mean there is no money to show. */
    /* WHETHER FIGHTERS AND SPECTATORS PLAY FOR THE SAME MONEY.

       Not the same question as poolsAreShared() below it, which is about the
       entry POT joining the betting pool. This one is betPayout.sharedPool:
       with it off, SettleSpectatorBets builds one pool per KIND and pays
       each bet a share of its own and no other. */
    function poolsSplitByKind() {
        return (betting().betPayout || {}).sharedPool === false;
    }

    /* Which of those pools the person reading this screen is betting into.
       Mirrors poolKeyFor() in server/betting.lua, which is the function that
       decides it at settlement. */
    function viewerPoolKey(match) {
        if (!poolsSplitByKind()) return 'all';
        return betAsFighter(match) ? 'fighter' : 'spectator';
    }

    /* WHAT IS RIDING ON EACH SIDE OF THIS VIEWER'S OWN POOL, as pick ->
       amount.

       server/lobby.lua sends this nested by settlement pool and builds it
       with GetSideBetPool's filter, so within one pool the parts add up.

       READING THE VIEWER'S POOL AND NOT THE WHOLE BOOK IS THE POINT. Where
       betPayout.sharedPool is off, a fighter staking 1,800 on themselves and
       a spectator staking 800 against them are each alone in their own pool,
       and the settlement hands both stakes straight back. A flat book showed
       2,600 on the match and a 69/31 split -- a contest that was not
       happening, over money neither of them could win.

       Absent on an older server, or on a match nobody has bet on, or where
       this viewer's pool is empty: all three come back as an empty object,
       which every reader below treats as "nothing on the board". There is
       nothing to tell apart -- they all mean there is no money to show. */
    function betsByPick(match) {
        var raw = match && match.betsByPick;
        var out = {};
        if (!raw || typeof raw !== 'object') return out;

        var side = raw[viewerPoolKey(match)];
        if (!side || typeof side !== 'object') return out;

        Object.keys(side).forEach(function (pick) {
            var amount = int(side[pick], 0);
            if (amount > 0) out[String(pick)] = amount;
        });
        return out;
    }

    function betsOnBoard(match) {
        var total = 0;
        var byPick = betsByPick(match);
        Object.keys(byPick).forEach(function (pick) { total += byPick[pick]; });

        /* WHERE THE POOLS ARE SPLIT, `betPool` IS THE WRONG NUMBER. It is
           flat across both kinds, so quoting it here would tell a spectator
           they are contesting the fighters' stakes as well as their own. The
           sum of this viewer's own pool is the only honest figure. */
        if (poolsSplitByKind()) return total;

        /* THE SERVER'S OWN TOTAL WINS where the two disagree. `betPool` is
           what settlement will actually divide; the breakdown is a courtesy
           beside it. They are built from one filter and should never differ
           -- but if a future bet ever carries no pick, the sum above would
           quietly under-report the pool and the panel must not be the thing
           that says so. */
        return Math.max(total, int(match && match.betPool, 0));
    }

    /* Which match the whole tab is about, said out loud.

       IT NEVER SAID. The Bets tab is pointed at whatever match is focused on
       the Matches tab -- and the focus moves on its own, when you join a
       round or start watching one -- so the screen showed a pot, a fee and a
       list of fighters belonging to a match it never named. */
    function renderBetMatch(match) {
        var host = byId('bet-match');
        if (!has(host)) return;
        clear(host);

        if (!match) {
            host.appendChild(makeEl('span', 'bet-match-name', 'No match picked'));
            host.appendChild(makeEl('span', 'bet-match-sub',
                'Choose one on the Matches tab and this tab follows it.'));
            return;
        }

        host.appendChild(makeEl('span', 'bet-match-name', match.label || 'Match'));

        var bits = [];
        if (match.arenaLabel) bits.push(String(match.arenaLabel));
        if (match.modeLabel) bits.push(String(match.modeLabel));
        if (betAsFighter(match)) bits.push('you are fighting in this one');
        if (bits.length > 0) {
            host.appendChild(makeEl('span', 'bet-match-sub', bits.join('  \u00b7  ')));
        }
    }

    /* THE EXPLANATION, BROKEN UP AND MOVED UNDER THE BUTTON.

       This was one paragraph of about a hundred words sitting at the TOP of
       the form -- entry fees, the pot, elimination, side-bets, backing
       yourself, proportional payouts and where the money comes from, all run
       together in grey. It was the first thing on the tab and the first
       thing every player skipped, which meant the rules it held were, in
       practice, not on screen at all.

       Same facts, four short lines, each with the thing it is about named in
       front of it, and only the lines this server's settings make true. A
       player looking for one rule can now find the line it is on. */
    function renderBetNote(match) {
        var host = byId('bet-note');
        if (!has(host)) return;
        clear(host);

        var spectator = betting().spectatorBets || {};
        var fighter = betting().fighterBets || {};
        var lines = [];

        function line(term, text) {
            var row = makeEl('div', 'bet-note-line');
            row.appendChild(makeEl('span', 'bet-note-term', term));
            row.appendChild(makeEl('span', 'bet-note-text', text));
            lines.push(row);
        }

        line('The pot', 'Every fighter’s entry fee goes in, and at the end '
            + payoutPhrase() + '. Being knocked out ends your round and your fee stays in.');

        if (spectator.enabled === true) {
            line('A side-bet', poolsAreShared()
                ? 'Money staked on who wins, by anyone watching. It goes into that same pot.'
                : 'Money staked on who wins, by anyone watching. Separate from the pot, and it '
                    + 'never changes what the winners take.');
        }

        /* THE SERVER RUNS TWO BOOKS AND THE PANEL SAID NOTHING. Every figure
           on this tab is one pool's, and a reader has no way to know that
           unless it is written down. */
        if (poolsSplitByKind() && spectator.enabled === true && fighter.enabled === true) {
            line('Two books', 'Fighters and spectators are settled separately here, so you only '
                + 'ever win from bets of your own kind. Every figure above is your side of it.');
        }

        if (fighter.enabled === true) {
            line('Backing yourself', 'You can back yourself in a round you are fighting in'
                + (fighter.ownSideOnly === false ? '.' : ' — on your own side only.'));
        }

        /* THE PAYOUT RULE THAT IS ACTUALLY RUNNING, and only that one. The
           multiplier is quoted where the server pays one and never where it
           does not: on a pool server there is no multiplier to name, and the
           figure is not knowable in advance because it depends on who else
           backs what. See betMode(). */
        if (betMode(match) === 'odds') {
            var odds = Number(spectator.oddsMultiplier) || 2;
            line('If you win', 'Your stake comes back ×' + String(odds)
                + ', paid by the server. If you lose it, it is gone.');
        } else {
            line('If you win', 'The winning side splits everything staked, in proportion to what '
                + 'each backer put in. That money is the losing bets and never from the server, '
                + 'so backing a side nobody bet against just hands your own stake back.');
        }

        host.appendChild(makeEl('div', 'bet-note-head', 'How betting works here'));
        lines.forEach(function (row) { host.appendChild(row); });
    }

    /* THE FIVE NUMBERS THE TAB IS ABOUT.

       TWO OF THESE USED TO SAY THE SAME THING TWICE. "Pot goes to: Backers
       of the winner" sat beside "Bets pay: Share of pool" -- two labels,
       near-identical wording, describing one rule from two directions, and
       between them they used the words "pot", "pool" and "bets" for what a
       reader could not tell were two separate piles of money. The rule they
       were both circling is now one line in "How betting works here", where
       it has room to be said once and properly.

       What is left is five FIGURES, each a different fact, none of them a
       rule: what you have, what the pot holds, what a seat costs, what is
       riding on side-bets, and what a win multiplies by. */
    /* THE SIX FIGURES THE TAB IS ABOUT.

       TWO OF THESE READ AS ONE THING SAID TWICE, and the fix is not to
       delete either of them -- that was tried, and it threw away a rule.
       "Pot goes to" is about the ENTRY FEES and "Bets pay" is about the
       SIDE-BETS, and an operator sets those two independently: the pot can
       go to the winner alone on a server whose side-bets pay a pool share,
       and both spellings of both rules really run. Deleting one loses a fact
       nothing else on the tab carries.

       What was actually wrong was that neither line said WHICH PILE OF MONEY
       it was about, so they read as the same sentence twice in different
       words. Each one names its own money underneath it now, and the rules
       behind them are set out in full under "How betting works here". */
    function renderBetSummary(match) {
        var host = byId('bet-summary');
        if (!has(host)) return;
        clear(host);

        function stat(label, value, sub) {
            var box = makeEl('div', 'bet-stat');
            box.appendChild(makeEl('span', 'bet-stat-label', label));
            box.appendChild(makeEl('span', 'bet-stat-value', value));
            if (sub) box.appendChild(makeEl('span', 'bet-stat-sub', sub));
            host.appendChild(box);
        }

        var from = chosenAccount();
        stat('Your ' + titleCase(from), money(balanceIn(from)));
        stat('Pot', match ? money(match.pot) : money(0),
            match ? plural(int(match.playerCount, 0), 'fighter') + ' in' : null);
        stat('Entry fee', match ? money(match.entryFee) : money(0), 'each');

        /* ON THE BOARD, which was on the wire and shown nowhere. A pool bet
           is paid out of the other side's stakes, so "how much is bet on
           this match" is not decoration -- it is the number that decides
           whether a winning bet is worth anything at all. */
        var spectator = betting().spectatorBets || {};
        var fighterBets = betting().fighterBets || {};
        var anyBets = spectator.enabled === true || fighterBets.enabled === true;

        if (anyBets && betMode(match) === 'odds') {
            /* AN ODDS SERVER HAS NO POOL TO SHOW, and showing one read as an
               empty book on a match that had bets on it. An odds bet is paid
               by the operator, so betting.lua keeps it out of GetSideBetPool
               and out of the breakdown -- while CountSideBets counts it. Put
               side by side that was "$0 on side-bets / 3 bets", with every
               chip reading "no bets yet". The count is the figure that means
               something here. */
            stat('Bets placed', match ? String(int(match.bets, 0)) : '0',
                'each paid by the server');
        } else if (anyBets) {
            /* `match.bets` COUNTS THE WHOLE BOOK, both kinds together, so it
               cannot be quoted beside a figure that is one pool's share of
               it. Where the pools are split the sub-line names the pool
               instead -- which is the thing the reader needs anyway. */
            stat(poolsSplitByKind() ? 'In your pool' : 'On side-bets',
                money(betsOnBoard(match)),
                poolsSplitByKind()
                    ? (betAsFighter(match) ? 'fighters only' : 'spectators only')
                    : (match
                        ? (int(match.bets, 0) === 0 ? 'no bets yet' : plural(int(match.bets, 0), 'bet'))
                        : null));
        }

        stat('Pot goes to', poolsAreShared()
            ? 'Backers of the winner'
            : labelFor(PAYOUT_SHORT, betting().payout, 'The winner'), 'the entry fees');

        if (anyBets) {
            stat('Bets pay', betMode(match) === 'odds'
                ? 'x' + String(Number(spectator.oddsMultiplier) || 2)
                : 'Share of pool', 'side-bets only');
        }

        if (!match) {
            host.appendChild(makeEl('div', 'hint',
                'No match picked. Choose one on the Matches tab and its pot shows here.'));
        }
    }

    /* STEP 1: WHO WINS. Each chip now carries the money already on that side.

       THE CHIPS WERE BARE NAMES. "Rico  Marla  Teejay" told a bettor nothing
       they could act on -- and in the pool mode this arena ships with, the
       money on each side IS the decision: a winning bet is paid out of the
       stakes backing the OTHER sides, so a chip with nothing against it pays
       nothing back but the stake. The panel already said that in words at the
       bottom of the tab. Now the chips answer it. */
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

        var own = ownSide(match);
        var options = betPickOptions(match).filter(function (option) {
            return own === null || String(option.pick) === own;
        });
        if (options.length === 0) {
            host.appendChild(makeEl('div', 'hint',
                'Nobody has joined this match yet, so there is nobody to back.'));
            return;
        }

        host.appendChild(makeEl('span', 'field-label',
            own === null ? '1 · Who wins' : '1 · Backing'));

        var byPick = betsByPick(match);

        options.forEach(function (option) {
            var on = int(byPick[String(option.pick)], 0);

            /* THE LABEL IS THE BUTTON'S OWN TEXT, and the money hangs under
               it. Wrapping the name in a span of its own reads the same on
               screen and makes the chip findable only by walking into it --
               which is a chip that four existing suites, and anybody
               debugging this later, can no longer identify by the one thing
               it is: the side it backs. */
            var chip = makeEl('button', 'chip bet-chip', option.label);
            chip.type = 'button';
            /* ON AN ODDS SERVER THE POOL FIGURE IS ALWAYS ZERO by design, so
               "no bets yet" was printed under every name on a match that had
               a book. What the chip can honestly say there is the payout. */
            chip.appendChild(makeEl('span', 'bet-chip-money',
                betMode(match) === 'odds'
                    ? '\u00d7' + String(Number((betting().spectatorBets || {}).oddsMultiplier) || 2)
                        + ' if they win'
                    : (on > 0 ? money(on) + ' on them' : 'no bets yet')));

            if (option.color) chip.style.borderLeft = '3px solid ' + option.color;
            if (option.pick === currentPick(match)) chip.classList.add('active');
            chip.addEventListener('click', function () {
                state.betPick = option.pick;
                state.betPickMatchId = match.id;
                render();
            });
            host.appendChild(chip);
        });
    }

    /* THE BOOK AS A BAR: which way the money is leaning, at a glance.

       The chips above carry the same figures, and this is here because a
       proportion is the thing being asked about and a row of currency
       amounts is a poor way to show one. It draws only sides that have
       money on them, so it never fills the screen with empty slivers.

       NOTHING IS PROJECTED HERE. What a winning pool bet pays depends on
       every bet placed after yours, so the panel does not put a figure on
       it -- see betMode(). The bar says what is true right now and stops. */
    function renderBetSplit(match) {
        var host = byId('bet-split');
        if (!has(host)) return;
        clear(host);

        var usable = betRules(match).enabled === true && !!match;
        show(host, usable);
        if (!usable) return;

        /* AN ODDS SERVER HAS NOTHING TO SPLIT. Each bet is paid by the
           operator out of their own pocket, so what anybody else backs
           changes nothing about what you win -- and betting.lua keeps odds
           bets out of the pool figures entirely, which made this draw an
           empty book on a match with bets on it. */
        if (betMode(match) === 'odds') {
            var fixedOdds = Number((betting().spectatorBets || {}).oddsMultiplier) || 2;
            host.appendChild(makeEl('div', 'hint',
                'Every bet here is paid by the server at \u00d7' + String(fixedOdds)
                + ', so there is no pool to share and nothing to out-bet. What other '
                + 'people back changes nothing about what you win.'));
            return;
        }

        var byPick = betsByPick(match);
        var labels = betSideLabels(match);

        var sides = Object.keys(byPick).sort(function (a, b) { return byPick[b] - byPick[a]; });
        var total = 0;
        sides.forEach(function (pick) { total += byPick[pick]; });

        if (total <= 0) {
            host.appendChild(makeEl('div', 'hint',
                (poolsSplitByKind()
                    ? 'No bets in your pool yet. '
                    : 'No side-bets on this match yet. ')
                + 'The first one in is betting against nobody, so it only wins once somebody '
                + 'backs another side.'));
            return;
        }

        var bar = makeEl('div', 'bet-bar');
        sides.forEach(function (pick, at) {
            var share = byPick[pick] / total;
            var seg = makeEl('div', 'bet-bar-seg');
            seg.style.width = String(Math.round(share * 1000) / 10) + '%';
            if (String(pick) === String(currentPick(match))) seg.classList.add('mine');
            seg.title = (labels[pick] || pick) + ': ' + money(byPick[pick]);
            if (at % 2 === 1) seg.classList.add('alt');
            bar.appendChild(seg);
        });
        host.appendChild(bar);

        var key = makeEl('div', 'bet-bar-key');
        sides.forEach(function (pick) {
            var percent = Math.round((byPick[pick] / total) * 100);
            key.appendChild(makeEl('span', 'bet-bar-key-item',
                (labels[pick] || String(pick)) + '  ' + String(percent) + '%'));
        });
        host.appendChild(key);
    }

    function betBlockedReason(match) {
        if (!match) return 'Pick a match on the Matches tab first.';

        var fighting = betAsFighter(match);
        var rules = betRules(match);

        if (rules.enabled !== true) {
            return fighting
                ? 'Fighters cannot bet on this server. Your entry fee is already on the line.'
                : 'Side-bets are switched off on this server.';
        }

        if (match.state === 'ended') return 'This match has finished.';

        /* THE FIGHTERS' BOOK APPLIES TO A WALKER TOO, which is the rule the
           server holds them to: PlaceSpectatorBet asks betsAreOpen with the
           FIGHTER flag for anybody marked walked-out.

           MIRRORED RATHER THAN ASSUMED -- the same field the server's own
           answer is built from, not a flat refusal on the flag. Everything
           else about them really is a watcher's: the stake band, the one-bet
           limit and the own-side rule are all read as a spectator's above and
           below, exactly as the server reads them. This is the single
           question their old seat still answers.

           Said in their own words rather than the fighters'. "The book closed
           when this round went live" is true and reads as somebody else's
           message to a player standing outside the fence. */
        if (betWalkedOutOf(match) && match.fighterBetsOpen === false) {
            return 'You walked out of this round, so the book is closed to you '
                + 'the way it is to everybody still fighting it.';
        }

        if (fighting && match.fighterBetsOpen === false) {
            return 'The book closed when this round went live.';
        }
        if (!fighting && match.betsOpen === false) {
            return 'The book closed shortly after this round started.';
        }

        if (rules.oneBetPerMatch !== false
            && arrayOf(player().backing).indexOf(match.id) !== -1) {
            return 'Your bet on this match is already down — one per match.';
        }

        if (!currentPick(match)) return 'Choose who you are backing.';

        /* Held to their own side, and told so BEFORE the click rather than
           by a refusal after it. Backing the other side is being paid to
           lose on purpose, which an arena is exactly the place for. */
        var own = ownSide(match);
        if (own !== null && String(currentPick(match)) !== own) {
            return match.teams === true
                ? 'You are fighting in this match, so you can only back your own team.'
                : 'You are fighting in this match, so you can only back yourself.';
        }

        var amount = int(state.betAmount, 0);
        var band = betBand(match);
        var min = band.min;
        var max = band.max;
        if (amount < min) return 'The smallest bet is ' + money(min) + '.';
        if (amount > max) {
            return min === max
                ? 'This server takes one stake only: ' + money(min) + '.'
                : 'The biggest bet is ' + money(max) + '.';
        }
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

    /* STEP 2 AND 3: HOW MUCH, AND OUT OF WHICH POCKET.

       THE STAKE BOX WAS A BARE NUMBER FIELD. It opened on the minimum, said
       nothing about the ceiling, and offered no way to fill it except typing
       -- so a player wanting "everything I can" had to know their own
       balance, know the operator's maximum, and work out which was smaller.
       The buttons below do that sum for them, and every one of them is
       labelled with the actual money rather than with "half" or "max",
       because those words do not say half OF WHAT.

       THE HINT ABOVE THE BUTTON NOW DESCRIBES THIS BET and nothing else:
       what is being staked, on whom, out of which account. The rules it used
       to restate are in "How betting works here" at the foot of the tab,
       where they are said once. */
    function renderBetControls(match) {
        var rules = betRules(match);
        var usable = rules.enabled === true;

        var input = byId('bet-amount');
        show(byId('bet-amount-row'), usable);
        if (has(input) && usable) {
            var inputBand = betBand(match);
            input.min = String(inputBand.min);
            input.max = String(inputBand.max);
            /* NAMES THE FLOOR IN THE BOX ITSELF, so an empty field is still
               an answer to "what can I put here". */
            input.placeholder = String(int(rules.min, 0));
            if (document.activeElement !== input) input.value = String(int(state.betAmount, 0));
        }

        renderBetQuick(match);

        renderAccountPicker('bet-account');
        show(byId('bet-account-row'), usable && accountChoiceOffered());

        var reason = betBlockedReason(match);

        var hint = byId('bet-hint');
        show(hint, usable);
        if (has(hint) && usable) {
            if (reason !== null) {
                hint.textContent = reason;
            } else {
                var backing = null;
                betPickOptions(match).forEach(function (option) {
                    if (String(option.pick) === String(currentPick(match))) backing = option.label;
                });

                var text = 'Place ' + money(int(state.betAmount, 0)) + ' on '
                    + (backing || 'them')
                    + (accountChoiceOffered() ? ', from ' + titleCase(chosenAccount()) : '') + '. ';

                if (betMode(match) === 'odds') {
                    /* AND HERE THE STAKE REALLY IS GONE. Fixed odds are
                       funded by the operator, who is the counterparty and
                       keeps a losing bet. Saying so is only wrong under the
                       pool rule below. */
                    var odds = Number((betting().spectatorBets || {}).oddsMultiplier) || 2;
                    text += 'If they win you are paid ' + money(int(state.betAmount, 0) * odds)
                        + '. If they lose, the stake is gone.';
                } else if (betAsFighter(match)) {
                    text += 'If you win you take a share of the whole betting pool, in proportion '
                        + 'to what you staked — so you only profit if somebody backed the other '
                        + 'side. If you lose, your stake goes to whoever backed the winner. Either '
                        + 'way, if nobody bet against you it is handed back.';
                } else {
                    /* NO FIGURE, DELIBERATELY, and no "the stake is gone"
                       either. A pool has no counterparty: a losing stake is
                       paid to whoever backed the winner, and where nobody
                       did there is nobody to pay it to and the server hands
                       it back. A player told their money was gone and then
                       given it back reads that as the arena being broken. */
                    text += 'If they win you take a share of the whole betting pool, in proportion '
                        + 'to what you staked — so you only profit if somebody backed another '
                        + 'side. If they lose, your stake goes to whoever backed the winner. Either '
                        + 'way, if nobody backed a different side it is handed back.';
                }
                hint.textContent = text;
            }
        }

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
                    pick: currentPick(match),
                    amount: int(state.betAmount, 0),
                    account: chosenAccount()
                });
            };
        }
    }

    /* Stakes worth one click, worked out from the two ceilings that actually
       apply: the operator's maximum and what is in the chosen account.

       THE SMALLER OF THE TWO IS THE ONE THAT BINDS, and the player could not
       see either. A "max" button that offered the operator's ceiling on an
       account that cannot cover it is a button that posts a bet the server
       refuses, so the top amount here is always one the bet can actually be
       paid with.

       Re-read on every render because the account picker sits below it: a
       player switching from Cash to Bank changes what they can afford, and
       these numbers have to move with that choice. */
    function renderBetQuick(match) {
        var host = byId('bet-quick');
        if (!has(host)) return;
        clear(host);

        var rules = betRules(match);
        var usable = rules.enabled === true && !!match;
        show(host, usable);
        if (!usable) return;

        var band = betBand(match);
        var min = band.min;
        var max = band.max;
        var ceiling = Math.min(balanceIn(chosenAccount()), max);

        if (ceiling < min) {
            host.appendChild(makeEl('span', 'hint',
                'The smallest bet here is ' + money(min) + ', and '
                + (accountChoiceOffered() ? titleCase(chosenAccount()) + ' holds ' : 'you have ')
                + money(balanceIn(chosenAccount())) + '.'));
            return;
        }

        /* Tidied, so the buttons read as amounts somebody would choose
           rather than as arithmetic: 1,000 and 250, not 1,013 and 253. */
        function tidy(value) {
            var v = Math.floor(value);
            if (v >= 1000) v = Math.floor(v / 100) * 100;
            else if (v >= 100) v = Math.floor(v / 10) * 10;
            return Math.max(min, Math.min(ceiling, v));
        }

        var amounts = [];
        [min, tidy(ceiling / 4), tidy(ceiling / 2), ceiling].forEach(function (value) {
            var v = Math.max(min, Math.min(ceiling, Math.floor(value)));
            if (amounts.indexOf(v) === -1) amounts.push(v);
        });
        amounts.sort(function (a, b) { return a - b; });

        amounts.forEach(function (value) {
            var chip = makeEl('button', 'chip bet-quick-chip', money(value));
            chip.type = 'button';
            if (value === int(state.betAmount, 0)) chip.classList.add('active');
            chip.title = value === ceiling
                ? 'The most this account can cover' + (value === max ? ', and the most allowed' : '')
                : '';
            chip.addEventListener('click', function () {
                state.betAmount = value;
                render();
            });
            host.appendChild(chip);
        });

        host.appendChild(makeEl('span', 'hint bet-quick-range',
            min === max
                ? money(min) + ' exactly \u2014 this server takes no other stake'
                : money(min) + ' to ' + money(max) + ' allowed'));
    }

    /* WHO IS IN THE ROUND, WHAT THEY PAID, AND WHICH ONE YOU ARE ON.

       DIMMING WAS THE ONLY THING SAYING A FIGHTER WAS OUT. A grey row and a
       sentence under the list explaining what grey meant is a poor way to
       say "this one cannot win any more" -- it is colour carrying the whole
       message, it is one more thing to remember, and a player skim-reading
       a list of names while a round is live will not catch it. Every row
       says its own state in words now, and the dimming stays as well.

       THE ROW YOU BACKED IS MARKED, because the chips at step 1 scroll out
       of sight on a short screen and "which one did I put money on" should
       not be a question the panel makes you answer from memory. */
    function renderBetList(match) {
        var host = byId('bet-list');
        if (!has(host)) return;
        clear(host);

        if (!match) {
            host.appendChild(makeEl('div', 'hint',
                'No match picked. Choose one on the Matches tab to see who has paid into its pot.'));
            return;
        }

        /* THE ENTRY POT, WHICH IS WHAT THE ROWS BELOW ADD UP TO.

           This printed `match.pot`, and that is not the entry pot: lobby.lua
           sends it as GetPrizePool, which with `betPayout.includeEntryPot`
           -- the shipped default -- is the entry pot PLUS the whole side-bet
           pool. So the header sat over a list of entry fees and disagreed
           with their sum: measured at 3,000 above two rows of 500. The
           entry-fee-only figure was already on the wire as `entryPot` and
           nothing had ever read it.

           Falling back to `pot` keeps an older server showing the number it
           always did rather than a zero. */
        var paidIn = (match.entryPot === undefined || match.entryPot === null)
            ? int(match.pot, 0)
            : int(match.entryPot, 0);

        var header = makeEl('div', 'bet-row bet-row-head');
        header.appendChild(makeEl('span', 'bet-stat-label', 'Paid into the pot'));
        header.appendChild(makeEl('span', 'bet-stat-label', money(paidIn)));
        host.appendChild(header);

        var fee = int(match.entryFee, 0);
        var byPick = betsByPick(match);

        /* WHOSE MONEY IT IS, and in a team match it is not the fighter's own.
           A team is backed as a team, so every crimson row was carrying
           crimson's whole stake with the words "bet on them" beside it -- two
           fighters on a side with 1,800 on it read as 3,600 on the match, on
           a tab whose own summary said 2,600. The side is named instead. */
        var sideNames = betSideLabels(match);

        var mine = player().bet;
        var minePick = (mine && mine.pick !== undefined && mine.pick !== null)
            ? String(mine.pick)
            : (currentPick(match) === null ? null : String(currentPick(match)));

        var roster = arrayOf(match.players);
        if (roster.length === 0) {
            host.appendChild(makeEl('div', 'hint',
                'Nobody has joined yet. The pot fills as fighters pay in.'));
            return;
        }

        roster.forEach(function (entry) {
            if (!entry) return;

            var out = entry.alive === false;
            /* A team match is backed by TEAM, a free-for-all by server id, so
               the row is matched against whichever this match uses -- the
               same key betPickOptions builds its chips from. */
            var key = match.teams === true
                ? (entry.team === undefined || entry.team === null ? null : String(entry.team))
                : String(int(entry.id, 0));

            var row = makeEl('div', 'bet-row');
            if (out) row.classList.add('lost');
            if (minePick !== null && key === minePick) row.classList.add('backed');

            var left = makeEl('span', 'bet-row-who');
            left.appendChild(makeEl('span', 'bet-row-name', entry.name || ('#' + int(entry.id, 0))));
            left.appendChild(makeEl('span', 'bet-row-state', out ? 'Out of the round' : 'Still in'));
            row.appendChild(left);

            var right = makeEl('span', 'bet-row-money');
            right.appendChild(makeEl('span', 'bet-row-fee', money(fee)));
            if (key !== null && int(byPick[key], 0) > 0) {
                right.appendChild(makeEl('span', 'bet-row-staked',
                    money(int(byPick[key], 0)) + (match.teams === true
                        ? ' on ' + (sideNames[key] || key)
                        : ' bet on them')));
            }
            row.appendChild(right);

            host.appendChild(row);
        });

        if (minePick !== null) {
            host.appendChild(makeEl('div', 'hint', 'The highlighted row is the side you are on.'));
        }
    }

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
            timer.textContent = (left === null || left === undefined) ? '' : clock(left);
        }

        if (has(alive)) {
            alive.textContent = hud.livesSpent === false
                ? plural(int(hud.total, 0), 'fighter')
                : 'Remaining ' + int(hud.remaining, 0) + ' / ' + int(hud.total, 0);
        }

        if (has(kills)) kills.textContent = 'Kills ' + int(hud.kills, 0) + '  Deaths ' + int(hud.deaths, 0);

        var pot = byId('hud-pot');
        if (has(pot)) {
            var amount = int(hud.pot, 0);
            show(pot, bettingOn() && amount > 0);
            pot.textContent = 'Pot ' + money(amount);
        }

        renderHudScoreboard(arrayOf(hud.scoreboard));
    }

    function scoreRow(entry, me) {
        var row = makeEl('div', 'hud-score-row');
        if (int(entry.id, -1) === me) row.classList.add('self');
        if (entry.alive === false) row.classList.add('dead');

        var tiers = int(entry.tiers, 0);
        if (tiers > 0) {
            row.classList.add('tiered');
            var standing = makeEl('span', 'score-tier', int(entry.tier, 1) + '/' + tiers);
            standing.title = 'Tier ' + int(entry.tier, 1) + ' of ' + tiers;
            row.appendChild(standing);
        }

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

        hideResults();

        var digits = byId('countdown-value');
        if (has(digits)) digits.textContent = String(value);

        var caption = byId('countdown-label');
        if (has(caption)) caption.textContent = typeof label === 'string' ? label : '';

        if (countdownTimer !== null) window.clearTimeout(countdownTimer);
        countdownTimer = window.setTimeout(hideCountdown, value * 1000 + 1500);

        show(root, true);
    }

    var admin = {
        open: false,
        matches: [],
        focused: null,
        player: null,
        owed: [],
        owedKit: [],
        owedKitSaved: false,
        databaseOn: false,
        stashesFound: 0,
        stashesRead: 0,
        stashesReadable: true,
        hoursOpen: true,
        hoursForced: null,
        hoursLine: null,
        hoursOpensAt: null,
        tab: null,
        stash: null,
        /* The Tools tab: which report was asked for, and what came back.
           `toolWaiting` is not derived from `toolLines` being empty -- a
           report that genuinely has nothing to say is a real answer, and
           conflating the two would leave the screen saying "asking..."
           forever on the quietest possible server. */
        tool: null,
        toolTitle: null,
        toolLines: [],
        toolWaiting: false,
    };

    function adminRefresh() {
        post('adminState', { matchId: admin.focused ? admin.focused.id : null });
    }

    function adminPlayerRow() {
        if (!admin.focused || admin.player === null) return null;
        var rows = arrayOf(admin.focused.players);
        for (var index = 0; index < rows.length; index += 1) {
            if (int(rows[index].src, -1) === admin.player) return rows[index];
        }
        return null;
    }

    function renderAdmin() {
        var root = byId('arena-admin');
        if (!has(root)) return;
        show(root, admin.open);
        if (!admin.open) return;

        var doorState = byId('admin-doors-state');
        if (has(doorState)) {
            doorState.textContent = admin.hoursForced === 'open'
                ? 'Held OPEN past the schedule. Anyone can start or join a match.'
                : (admin.hoursForced === 'shut'
                    ? 'CLOSED by an admin. Rounds already being fought are '
                      + 'finishing; nobody new can come in.'
                    : (admin.hoursOpen
                        ? 'Open, on the schedule.'
                        : 'Shut, on the schedule — nobody can start or join a match.'));
        }

        var doorButtons = [
            { id: 'admin-doors-schedule', mode: null },
            { id: 'admin-doors-open', mode: 'open' },
            { id: 'admin-doors-shut', mode: 'shut' },
        ];
        doorButtons.forEach(function (entry) {
            var node = byId(entry.id);
            if (!has(node)) return;
            var current = admin.hoursForced === entry.mode;
            node.classList.toggle('active', current);
            node.disabled = current;
        });

        /* A CLOSED ARENA IS ONE SCREEN. Nothing else is drawn -- there are no
           matches to list, because closing destroys every lobby waiting to
           start, and a screenful of controls for a place nobody can get into
           is a screenful of ways to be confused.

           The doors strip above the tabs is deliberately NOT part of this:
           it is the way back, and putting it away with everything else would
           leave an admin looking at a closed arena with no button to open
           it. */
        /* THE TABS STAY, AND THE CLOSED SCREEN IS WHERE THE TABLET LANDS.
           Deliberately NOT what the player panel does, where a shut arena
           really is one screen because nothing else on it is true.

           An admin's screen is different. Closing the arena leaves a round
           already being fought to finish, so there can be a live match with
           people in it -- and putting the tabs away took the Stop button, the
           Revive button and every stash with them, at the exact moment an
           operator is most likely to want them. On the shipped schedule the
           arena is shut fourteen hours a day, so that was the tablet's
           ordinary state rather than an edge of it. */
        var shut = admin.hoursOpen === false && admin.tab === null;
        show(byId('admin-shut'), shut);

        if (shut) {
            show(byId('admin-list'), false);
            show(byId('admin-detail'), false);
            show(byId('admin-player'), false);
            show(byId('admin-stashes'), false);
            show(byId('admin-stash-detail'), false);

            byId('admin-shut-who').textContent = admin.hoursForced === 'shut'
                ? 'An admin closed it. It stays closed until somebody opens it '
                  + 'again — a restart counts.'
                : 'It is outside the hours this server keeps.';

            byId('admin-shut-hours').textContent = admin.hoursLine
                ? 'Arena hours: ' + admin.hoursLine + '.'
                  + (admin.hoursOpensAt ? ' Next opening ' + admin.hoursOpensAt + '.' : '')
                /* NO SCHEDULE AT ALL is its own answer, and a real one: it
                   means the closure can only be an admin's, so quoting hours
                   that do not exist would be the wrong kind of reassuring. */
                : 'This server keeps no opening hours — nothing reopens it on its own.';

            return;
        }

        var onStashes = admin.tab === 'stashes';
        var onTools = admin.tab === 'tools';
        var onMatches = !onStashes && !onTools && !shut;

        var stash = null;
        if (onStashes && admin.stash !== null) {
            arrayOf(admin.owed).forEach(function (entry) {
                if (String(entry.citizenid) === String(admin.stash)) stash = entry;
            });
        }

        var row = (onStashes || onTools) ? null : adminPlayerRow();
        var onPlayer = row !== null;
        var onMatch = !onStashes && !onTools && !onPlayer && admin.focused !== null;
        var onStash = stash !== null;

        show(byId('admin-list'), onMatches && !onPlayer && !onMatch);
        show(byId('admin-detail'), onMatches && onMatch);
        show(byId('admin-player'), onMatches && onPlayer);
        show(byId('admin-stashes'), onStashes && !onStash);
        show(byId('admin-stash-detail'), onStashes && onStash);
        show(byId('admin-tools'), onTools);

        var matchesTab = byId('admin-tab-matches');
        var stashesTab = byId('admin-tab-stashes');
        var toolsTab = byId('admin-tab-tools');
        if (has(matchesTab)) matchesTab.classList.toggle('active', onMatches);
        if (has(stashesTab)) stashesTab.classList.toggle('active', onStashes);
        if (has(toolsTab)) toolsTab.classList.toggle('active', onTools);

        if (onTools) {
            arrayOf(['isolation', 'hours', 'dispatch', 'owed', 'attachments', 'jams']).forEach(function (name) {
                var button = byId('admin-tool-' + name);
                if (has(button)) button.classList.toggle('active', admin.tool === name);
            });

            var heading = byId('admin-tool-title');
            if (has(heading)) {
                heading.textContent = admin.toolTitle || '';
                show(heading, admin.toolTitle !== null);
            }

            show(byId('admin-tool-waiting'), admin.toolWaiting);
            show(byId('admin-tool-hint'), admin.tool === null);

            var out = byId('admin-tool-out');
            if (has(out)) {
                clear(out);
                /* ONE ELEMENT PER LINE, textContent not innerHTML. These
                   lines carry player names, which are player-supplied: built
                   as markup, a name could close the tag and write its own.
                   The reports are also pre-indented with spaces, so the CSS
                   for this block preserves whitespace. */
                arrayOf(admin.toolLines).forEach(function (line) {
                    out.appendChild(makeEl('p', 'admin-tool-line', String(line)));
                });
                show(out, arrayOf(admin.toolLines).length > 0);
            }
        }

        var list = byId('admin-matches');
        if (has(list)) {
            clear(list);
            arrayOf(admin.matches).forEach(function (match) {
                var card = makeEl('button', 'admin-match');
                card.type = 'button';
                card.appendChild(makeEl('span', 'admin-match-name',
                    String(match.label || match.id)));
                card.appendChild(makeEl('span', 'admin-match-facts',
                    String(match.state) + ' · ' + plural(match.players, 'player')
                        + ' · pot ' + money(int(match.pot, 0))));
                card.addEventListener('click', function () {
                    admin.player = null;
                    admin.tab = 'matches';
                    post('adminState', { matchId: match.id });
                });
                list.appendChild(card);
            });
        }
        show(byId('admin-empty'), arrayOf(admin.matches).length === 0);

        var owed = arrayOf(admin.owed);

        /* THE ONE BUTTON, BUILT ONCE, because the row and the opened stash
           carry the same one and they must not drift. There is no live
           inventory to put items into for somebody who is not on the server,
           so for them the server QUEUES the return instead -- which is not a
           consolation prize: the retry only ever tries the people it has on
           its list, and a stash found by name after a restart is on nobody's
           list at all. Queuing is what puts it back on one. */
        function returnButton(entry, className) {
            var online = int(entry.src, 0);
            var items = arrayOf(entry.items);
            var give = makeEl('button', className,
                online > 0 ? 'Hand it back' : 'Queue for when they return');
            give.type = 'button';
            give.disabled = items.length === 0;
            give.addEventListener('click', function (event) {
                if (event && typeof event.stopPropagation === 'function') event.stopPropagation();
                post('adminReturn', {
                    target: online,
                    citizenid: entry.citizenid,
                    stash: entry.stash,
                    matchId: admin.focused ? admin.focused.id : null,
                });
            });
            return give;
        }

        function stashSummary(entry) {
            var items = arrayOf(entry.items);
            if (items.length === 0) {
                return 'the stash reads EMPTY — nothing to hand over';
            }
            var total = 0;
            items.forEach(function (item) { total += int(item.count, 0); });
            return plural(items.length, 'kind') + ' of thing, ' + plural(total, 'item') + ' in all';
        }

        /* AN EMPTY TAB SAYS SO. It is a whole screen rather than a section
           that could be left out of another one, and a blank screen reads as
           a screen that failed to load. */
        /* "THE ARENA IS HOLDING NOTHING FOR ANYBODY" IS A CLAIM, and it must
           not be made before anything has been looked at. /arenaadmin opens
           with an empty list on purpose and lets the database sweep follow,
           so pressing Stashes in the first second used to state, as fact, the
           opposite of the reason somebody opened it -- for up to the eight
           seconds the sweep is given to answer.

           A COUNT IS NOT A READ, and this used to settle it with one.
           `stashesRead` counts stash NAMES, not stashes opened: with
           ox_inventory stopped the server names every one of them, opens
           none, and still reports found = read = N. So the number said "we
           looked" at the exact moment nothing had been looked at, and this
           screen told an operator the arena was holding nothing for anybody
           while it was holding everything.

           SO THE MECHANISM ANSWERS, NOT THE TALLY. `stashesReadable` is the
           server saying whether a stash could be opened AT ALL; the counts
           then say "not yet" (zero) or "here is the answer, and it is
           nothing". The same correction the owed-kit line already carries
           further down, for the same reason. DO NOT go back to inferring a
           read from a count. */
        var readable = admin.stashesReadable !== false;
        var looked = readable
            && (int(admin.stashesRead, 0) > 0 || int(admin.stashesFound, 0) > 0);
        var kit = arrayOf(admin.owedKit);
        /* AND NO WEAPONS OUT EITHER. "The arena is holding nothing for
           anybody" is about stashes, and read alone it told an operator
           everything was settled while a list of missing guns sat directly
           underneath it. */
        show(byId('admin-stash-empty'),
            onStashes && !onStash && owed.length === 0 && kit.length === 0 && looked);
        show(byId('admin-stash-waiting'),
            onStashes && !onStash && owed.length === 0 && !looked && readable);
        /* THE THIRD ANSWER, which this screen did not have. "Nothing is
           held" and "we could not look" are different things and only one of
           them is good news. The weapons list below is deliberately NOT
           hidden with it: that debt is read out of memory rather than out of
           ox_inventory, so it is still true when the inventory is down. */
        show(byId('admin-stash-blind'), onStashes && !onStash && !readable);

        var stashLine = byId('admin-stash-line');
        if (has(stashLine)) {
            var found = int(admin.stashesFound, 0);
            var read = int(admin.stashesRead, 0);
            var unread = Math.max(0, found - read);

            var away = 0;
            owed.forEach(function (entry) {
                if (int(entry.src, 0) <= 0) away += 1;
            });

            stashLine.textContent = owed.length === 0 ? ''
                : plural(owed.length, 'stash') + ' holding somebody\'s belongings'
                  + (away > 0
                      ? ', ' + away + ' of them for somebody who is not on the server.'
                      : '. Everyone they belong to is here.')
                  + (unread > 0
                      ? ' ' + plural(unread, 'older stash', 'older stashes')
                        + ' were not opened this time — the newest ' + read + ' were.'
                      : '');
        }

        var stashBox = byId('admin-stash-list');
        if (has(stashBox)) {
            clear(stashBox);
            owed.forEach(function (entry) {
                var card = makeEl('div', 'admin-stash-row');

                var online = int(entry.src, 0);
                var open = makeEl('button', 'admin-stash-open');
                open.type = 'button';
                open.appendChild(makeEl('span', 'admin-stash-who',
                    String(entry.citizenid) + (online > 0 ? '' : ' · offline')));
                open.appendChild(makeEl('span', 'admin-stash-facts', stashSummary(entry)));
                open.addEventListener('click', function () {
                    admin.stash = entry.citizenid;
                    renderAdmin();
                });

                card.appendChild(open);
                card.appendChild(returnButton(entry, 'btn admin-owed-give'));
                stashBox.appendChild(card);
            });
        }

        var kitOut = onStashes && !onStash && kit.length > 0;
        show(byId('admin-kit-heading'), kitOut);
        show(byId('admin-kit-line'), kitOut);
        show(byId('admin-kit-list'), kitOut);

        var kitLine = byId('admin-kit-line');
        if (has(kitLine)) {
            var guns = 0;
            var stacks = 0;
            var hereNow = 0;
            kit.forEach(function (entry) {
                guns += int(entry.count, 0);
                stacks += arrayOf(entry.items).length;
                if (int(entry.src, 0) > 0) hereNow += 1;
            });

            /* NO BUTTON, DELIBERATELY. There is nothing useful to press:
               collecting needs the character on the server, and when they are
               the door and the sweep already do it. A button here would only
               invite an admin to reach into somebody's inventory by hand. */
            /* SAYS WHICH OF THE TWO IS TRUE about durability, rather than
               picking one and being wrong half the time. Whether the slate
               outlives a restart is the operator's own setting, and it is the
               single most useful thing this line can tell them. */
            var what = guns > 0 ? plural(guns, 'arena weapon') : '';
            if (stacks > 0) {
                what += (what ? ' and ' : '') + plural(stacks, 'item stack');
            }

            /* THE HEADING FOLLOWS WHAT IS ACTUALLY OUT. It was the static
               words "Arena weapons still out", which is simply wrong above a
               list of a character who owes nothing but bandages. */
            var heading = byId('admin-kit-heading');
            if (has(heading)) {
                heading.textContent = guns > 0 && stacks > 0 ? 'Arena kit still out'
                    : guns > 0 ? 'Arena weapons still out'
                    : 'Arena supplies still out';
            }

            kitLine.textContent = kit.length === 0 ? ''
                : what + ' left with ' + plural(kit.length, 'character')
                  + (hereNow > 0 ? ', ' + hereNow + ' of them on the server now' : '')
                  + '. Each is taken back the next time that character is seen \u2014 '
                  + 'nothing has to be pressed. '
                  /* WHICH OF THE TWO REASONS, because they need different
                     things done. This told everybody to turn the database on
                     -- including the operator who already had, and whose real
                     problem was that oxmysql was not running. */
                  + (admin.owedKitSaved
                      ? 'New debts are written to the database, so a restart does not lose them.'
                      : admin.databaseOn
                        ? 'It is held in memory only: Config.Database.enabled is on, but the '
                          + 'arena has not been able to use the database. Check oxmysql is '
                          + 'started and that its user may create and delete rows.'
                        : 'It is held in memory only: a restart forgets it. Turn '
                          + 'Config.Database.enabled on to keep it.');
        }

        var kitBox = byId('admin-kit-list');
        if (has(kitBox)) {
            clear(kitBox);
            kit.forEach(function (entry) {
                var card = makeEl('div', 'admin-kit-row');
                card.appendChild(makeEl('span', 'admin-stash-who',
                    String(entry.citizenid)
                    + (int(entry.src, 0) > 0 ? ' \u00b7 here now' : ' \u00b7 offline')));
                var facts = arrayOf(entry.weapons).map(function (row) {
                    return String(row.name)
                        + (row.serial ? ' (' + String(row.serial) + ')' : ' (no serial)');
                }).concat(arrayOf(entry.items).map(function (row) {
                    return String(row.name) + ' \u00d7' + int(row.amount, 0);
                }));

                card.appendChild(makeEl('span', 'admin-stash-facts', facts.join(', ')));
                kitBox.appendChild(card);
            });
        }

        if (onStash) {
            var whose = int(stash.src, 0);
            byId('admin-stash-title').textContent = String(stash.citizenid)
                + (whose > 0 ? '' : ' · offline');
            byId('admin-stash-detail-line').textContent = String(stash.stash)
                + ' · ' + stashSummary(stash)
                + (stash.remembered === false
                    ? ' · found in the database, not from this run'
                    : '');

            var doReturn = byId('admin-stash-return');
            if (has(doReturn)) {
                doReturn.textContent = whose > 0
                    ? 'Hand it back' : 'Queue for when they return';
                doReturn.disabled = arrayOf(stash.items).length === 0;
            }

            var itemBox = byId('admin-stash-items');
            if (has(itemBox)) {
                clear(itemBox);
                arrayOf(stash.items).forEach(function (item) {
                    itemBox.appendChild(makeEl('div', 'admin-escrow-row',
                        String(item.name) + ' ×' + int(item.count, 0)));
                });
                if (arrayOf(stash.items).length === 0) {
                    itemBox.appendChild(makeEl('div', 'admin-escrow-row',
                        'The stash reads EMPTY — nothing to hand over.'));
                }
            }
        }

        if (onMatch) {
            byId('admin-detail-title').textContent = String(admin.focused.label || admin.focused.id);
            byId('admin-detail-line').textContent = String(admin.focused.state)
                + ' · pot ' + money(int(admin.focused.pot, 0));

            var people = byId('admin-players');
            if (has(people)) {
                clear(people);
                arrayOf(admin.focused.players).forEach(function (fighter) {
                    var card = makeEl('button', 'admin-player-row');
                    card.type = 'button';
                    card.appendChild(makeEl('span', 'admin-player-name', String(fighter.name)));
                    card.appendChild(makeEl('span', 'admin-player-facts',
                        (fighter.alive === true ? 'alive' : 'down')
                            + ' · ' + int(fighter.kills, 0) + 'k/' + int(fighter.deaths, 0) + 'd'
                            + livesFact(admin.focused, fighter)));
                    card.addEventListener('click', function () {
                        admin.player = int(fighter.src, -1);
                        renderAdmin();
                    });
                    people.appendChild(card);
                });
            }
        }

        if (onPlayer) {
            byId('admin-player-title').textContent = String(row.name);
            byId('admin-player-line').textContent =
                (row.alive === true ? 'On their feet' : 'Down')
                + ' · ' + int(row.kills, 0) + ' kills, ' + int(row.deaths, 0) + ' deaths'
                + livesFact(admin.focused, row)
                + (row.team ? ' · ' + titleCase(String(row.team)) : '');

            var revive = byId('admin-revive');
            if (has(revive)) revive.disabled = row.alive === true;

            /* WHAT THE ARENA IS ACTUALLY HOLDING, beside what it BELIEVES it
               put away. Those two disagreeing is the whole of the bug that
               lost people their belongings, so an admin staring at an empty
               list is told which kind of empty it is. */
            var expected = int(row.escrowExpected, 0);
            var items = arrayOf(row.escrow);
            var staked = int(row.staked, 0);

            byId('admin-escrow-line').textContent =
                (staked > 0
                    ? money(staked) + ' staked from ' + String(row.stakedFrom || 'their wallet') + '. '
                    : 'No stake held. ')
                + (expected === 0
                    ? 'Nothing was put in their stash.'
                    : (items.length === expected
                        ? expected + ' item(s) held.'
                        : 'THE ARENA PUT ' + expected + ' ITEM(S) AWAY AND THE STASH HOLDS '
                          + items.length + '.'));

            var held = byId('admin-escrow');
            if (has(held)) {
                clear(held);
                items.forEach(function (item) {
                    held.appendChild(makeEl('div', 'admin-escrow-row',
                        String(item.name) + ' ×' + int(item.count, 0)));
                });
            }
        }
    }

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
                    hidePanel();
                    break;

                case 'state':
                    state.loadoutSaving = false;
                    applySnapshot(data);
                    render();
                    renderHud();
                    break;

                case 'adminOpen':
                    admin.open = true;
                    admin.matches = arrayOf(data.matches);
                    admin.owed = arrayOf(data.owed);
                    admin.owedKit = arrayOf(data.owedKit);
                    admin.owedKitSaved = data.owedKitSaved === true;
                    admin.databaseOn = data.databaseOn === true;
                    admin.stashesFound = int(data.stashesFound, 0);
                    admin.stashesRead = int(data.stashesRead, 0);
                    admin.stashesReadable = data.stashesReadable !== false;
                    admin.hoursOpen = data.hoursOpen !== false;
                    admin.hoursForced = (data.hoursForced === 'open' || data.hoursForced === 'shut')
                        ? data.hoursForced
                        : null;
                    admin.hoursLine = typeof data.hoursLine === 'string' ? data.hoursLine : null;
                    admin.hoursOpensAt = typeof data.hoursOpensAt === 'string'
                        ? data.hoursOpensAt
                        : null;
                    admin.focused = null;
                    admin.player = null;
                    admin.tab = null;
                    admin.stash = null;
                    admin.tool = null;
                    admin.toolTitle = null;
                    admin.toolLines = [];
                    admin.toolWaiting = false;
                    renderAdmin();
                    break;

                case 'adminTool':
                    if (!admin.open) break;
                    /* IGNORED IF IT IS NOT THE ONE ON SCREEN. An operator
                       who pressed Instancing, changed their mind and
                       pressed Opening hours must not have the slower of the
                       two land on top of the one they are reading. */
                    if (data.tool !== admin.tool) break;
                    admin.toolTitle = typeof data.title === 'string' ? data.title : null;
                    admin.toolLines = arrayOf(data.lines);
                    admin.toolWaiting = false;
                    renderAdmin();
                    break;

                case 'adminState':
                    if (!admin.open) break;
                    admin.matches = arrayOf(data.matches);
                    admin.owed = arrayOf(data.owed);
                    admin.owedKit = arrayOf(data.owedKit);
                    admin.owedKitSaved = data.owedKitSaved === true;
                    admin.databaseOn = data.databaseOn === true;
                    admin.stashesFound = int(data.stashesFound, 0);
                    admin.stashesRead = int(data.stashesRead, 0);
                    admin.stashesReadable = data.stashesReadable !== false;
                    admin.hoursOpen = data.hoursOpen !== false;
                    admin.hoursForced = (data.hoursForced === 'open' || data.hoursForced === 'shut')
                        ? data.hoursForced
                        : null;
                    admin.hoursLine = typeof data.hoursLine === 'string' ? data.hoursLine : null;
                    admin.hoursOpensAt = typeof data.hoursOpensAt === 'string'
                        ? data.hoursOpensAt
                        : null;
                    admin.focused = (data.focused && typeof data.focused === 'object')
                        ? data.focused
                        : null;
                    if (!admin.focused) admin.player = null;
                    renderAdmin();
                    break;

                case 'adminClose':
                    admin.open = false;
                    admin.focused = null;
                    admin.player = null;
                    renderAdmin();
                    break;

                case 'notify':
                    toast(data.message, data.type);
                    break;

                case 'hud':
                    state.hudVisible = data.visible === true;
                    if (data.hud && typeof data.hud === 'object') state.hud = data.hud;
                    else if (data.scoreboard !== undefined || data.remaining !== undefined) state.hud = data;
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

    var resultsTimer = null;
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

    // WHAT TO SAY WHEN A ROUND DID NOT COUNT TOWARDS THE LADDER.
    //
    // Only when it did not. A line on every result saying "this counted" is
    // noise nobody reads, and the warning stops being read with it -- so the
    // absence of this line is what says the win landed. See the note above
    // Config.Leaderboard for which rounds qualify.
    //
    // The reason comes from the server already written out in plain English
    // ("it lasted 12s, and the board counts 60s or more"), because the rule
    // that produced it is the only thing that knows which of the three
    // thresholds was missed and by how much.
    function ladderNote(results) {
        if (!results || results.ranked !== false) return '';
        var why = typeof results.rankedNote === 'string' ? results.rankedNote.trim() : '';
        var said = 'This round does not count towards the ladder';
        return why === '' ? said + '.' : said + ' \u2014 ' + why + '.';
    }

    function resultsSummary(results) {
        var bits = [];
        if (results.placement) bits.push('Placed #' + int(results.placement, 0));
        if (results.kills !== undefined || results.deaths !== undefined) {
            bits.push(plural(results.kills, 'kill') + ', ' + plural(results.deaths, 'death'));
        }
        if (int(results.earnings, 0) > 0) bits.push('Won ' + money(results.earnings));
        return bits.join('  ·  ');
    }

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

        var winningTeam = teamByKey(keyOr(results.winningTeam, null));
        if (winningTeam) {
            root.appendChild(styled(makeEl('div', null,
                String(winningTeam.label || winningTeam.key) + ' takes it'), {
                marginTop: '0.3rem',
                textAlign: 'center',
                fontFamily: 'var(--font-display)',
                letterSpacing: '0.08em',
                textTransform: 'uppercase',
                color: teamColor(winningTeam)
            }));
        }

        if (typeof results.reason === 'string' && results.reason !== '') {
            root.appendChild(styled(makeEl('div', null, results.reason), {
                marginTop: '0.3rem',
                textAlign: 'center',
                color: 'var(--text)'
            }));
        }

        var summary = resultsSummary(results);
        if (summary !== '') {
            root.appendChild(styled(makeEl('div', null, summary), {
                marginTop: '0.3rem',
                textAlign: 'center',
                color: 'var(--text-muted)'
            }));
        }

        var ladder = ladderNote(results);
        if (ladder !== '') {
            root.appendChild(styled(makeEl('div', null, ladder), {
                marginTop: '0.5rem',
                padding: '0.35rem 0.5rem',
                textAlign: 'center',
                fontSize: '0.85rem',
                lineHeight: '1.35',
                color: 'var(--text)',
                background: 'var(--surface-raised)',
                borderLeft: '2px solid var(--accent-bright)'
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

        if (state.open) {
            var reason = (typeof results.reason === 'string' && results.reason !== '')
                ? results.reason
                : (won ? 'You won.' : 'Match over.');
            var said = reason + (summary === '' ? '' : '  ·  ' + summary);
            if (ladder !== '') said = said + '  \u00b7  ' + ladder;
            toast(said, won ? 'success' : 'info');
        }
    }

    document.addEventListener('pointerdown', unlockAudio, true);
    document.addEventListener('keydown', unlockAudio, true);

    document.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape' && event.key !== 'Esc') return;

        if (admin.open) {
            event.preventDefault();
            post('adminClose', {});
            return;
        }

        if (!state.open) return;
        event.preventDefault();
        closePanel();
    });

    function bind(id, type, handler) {
        var node = byId(id);
        if (has(node)) node.addEventListener(type, handler);
    }

    bind('arena-close', 'click', closePanel);

    /* BOUND BY ID, WALKING TABS, like renderTabs above it.

       This was a querySelectorAll('.arena-tab') walk, and the panel's test
       harness stubs querySelectorAll to return an empty list -- so in every
       panel test ever written the tab buttons carried NO click handler at
       all. A test could press one, watch nothing happen, and have no way to
       tell that from a tab that was correctly refusing to move. renderTabs
       was moved off the same selector earlier for the same reason; this is
       the other half of it, and it is what makes a tab a thing a test can
       press.

       The name now comes from TABS rather than from a data-tab attribute, so
       the guard that checked one against the other is gone with it: there is
       nothing left to disagree. */
    TABS.forEach(function (name) {
        bind('tab-btn-' + name, 'click', function () {
            if (name !== state.tab) play('tab');
            state.tab = name;
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

        /* AND THE ROUND LENGTH MOVES WITH IT, until the host says otherwise.
           Gun game's designed clock is 480 seconds against a global default
           of 600, so picking it has to move the box -- otherwise the form
           shows, and then creates, a length the mode never asked for. Done
           here as well as in applySnapshot because changing the select does
           not wait for a broadcast, and a box that only caught up on the next
           one would be the number the host pressed Create against. */
        if (!state.createRoundTouched) {
            var config = cfg();
            state.createRound = snapRoundSeconds(
                modeRoundSeconds(modeByKey(state.createMode), config),
                (config.match || {}).roundTimeChoice);
        }

        render();
    });

    bind('create-lives', 'input', function (event) {
        var choice = (cfg().match || {}).livesChoice || {};
        state.createLives = clampInt(event.target.value, int(choice.min, 1), int(choice.max, 1));
    });

    bind('create-round', 'input', function (event) {
        var choice = (cfg().match || {}).roundTimeChoice;
        var band = roundMinuteBand(choice);
        var typed = event.target.value;

        /* WHAT THE HOST TYPED IS MINUTES, and sixty times it is what the
           server is told. Clamped in minutes and multiplied afterwards, so
           the result is always a whole minute -- clamping in seconds first
           could land on 3599 and put a number in the box that rounds to a
           minute the band does not allow. */
        state.createRound = band
            ? clampInt(typed, band.min, band.max) * 60
            : clampInt(typed, Math.max(1, int((choice || {}).min, 1)),
                Math.max(1, int((choice || {}).max, 1)));

        /* AND FROM HERE THE BOX IS THEIRS. Changing the mode afterwards must
           not throw away a number the host typed on purpose. */
        state.createRoundTouched = true;

        /* AND REDRAW, because this is the one field on the form whose hint
           quotes the value back: "How long a round runs, in minutes -- 10:00
           on the round clock". Without this the clock beside the box kept
           whatever it said at the last render, so a host typing 5 was still
           being told 10:00 -- the number they were about to rely on, wrong,
           right next to the box they had just changed. `create-limit` beside
           it already does this; `create-lives` does not need to, because its
           hint names only the band. Safe here: this input is static markup in
           index.html, so a render updates its value rather than replacing the
           node, and the caret stays where it is. */
        render();
    });

    bind('admin-close', 'click', function () {
        post('adminClose', {});
    });

    function askDoors(mode) {
        post('adminHours', {
            forced: mode,
            matchId: admin.focused ? admin.focused.id : null,
        });
    }

    bind('admin-doors-schedule', 'click', function () { askDoors(null); });
    bind('admin-doors-open', 'click', function () { askDoors('open'); });
    bind('admin-doors-shut', 'click', function () { askDoors('shut'); });

    bind('admin-tab-matches', 'click', function () {
        /* `admin.stash` is deliberately NOT cleared here. renderAdmin only
           reads it on the stashes tab, and the stashes tab clears it on the
           way back in -- so clearing it a second time here is a line no
           behaviour can tell apart from its absence, which is the kind of
           line that survives every mutation and reassures nobody. */
        admin.tab = 'matches';
        renderAdmin();
    });

    bind('admin-tab-tools', 'click', function () {
        admin.tab = 'tools';
        admin.stash = null;
        renderAdmin();
    });

    /* One binding per report rather than a loop over the five, because the
       ids are in the markup and a loop would let a renamed button fail
       silently instead of at the first press. */
    arrayOf(['isolation', 'hours', 'dispatch', 'owed', 'attachments', 'jams']).forEach(function (name) {
        bind('admin-tool-' + name, 'click', function () {
            admin.tool = name;
            admin.toolTitle = null;
            admin.toolLines = [];
            admin.toolWaiting = true;
            renderAdmin();
            post('adminTool', { tool: name });
        });
    });

    bind('admin-tab-stashes', 'click', function () {
        admin.tab = 'stashes';
        admin.stash = null;
        renderAdmin();

        /* ASKED FOR ON ARRIVAL. The stash list is a database read the server
           does not repeat on its own, so a tablet left open while somebody's
           return finally went through would show a stash that is no longer
           held. Drawing first and asking second means the tab appears at once
           with what it already had, rather than blank while the disk answers.

           Deliberately NOT `adminRefresh()`, which sends the focused match
           along: arriving here does not close whatever match was open behind
           it, and the ask must not tell the server otherwise. */
        post('adminState', { matchId: admin.focused ? admin.focused.id : null });
    });

    bind('admin-stash-back', 'click', function () {
        admin.stash = null;
        renderAdmin();
    });

    bind('admin-stash-return', 'click', function () {
        /* Read out of the CURRENT snapshot rather than captured when the
           screen was drawn: a stash handed back by somebody else in the
           meantime is one this button must not ask about again. */
        var open = null;
        arrayOf(admin.owed).forEach(function (entry) {
            if (String(entry.citizenid) === String(admin.stash)) open = entry;
        });
        if (!open) return;

        post('adminReturn', {
            target: int(open.src, 0),
            citizenid: open.citizenid,
            stash: open.stash,
            matchId: admin.focused ? admin.focused.id : null,
        });
    });

    bind('admin-back', 'click', function () {
        admin.focused = null;
        admin.player = null;
        renderAdmin();
        adminRefresh();
    });

    bind('admin-player-back', 'click', function () {
        admin.player = null;
        renderAdmin();
    });

    bind('admin-stop', 'click', function () {
        if (!admin.focused) return;
        post('adminStop', { matchId: admin.focused.id });
    });

    bind('admin-revive', 'click', function () {
        if (admin.player === null) return;
        post('adminRevive', { target: admin.player });
    });

    bind('create-limit', 'input', function (event) {
        var band = (cfg().match || {}).scoreLimitChoice || {};
        state.createLimit = clampInt(event.target.value, int(band.min, 1), int(band.max, 1));
        render();
    });

    bind('create-win', 'change', function (event) {
        state.createWin = keyOr(event.target.value, state.createWin);
        render();
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
                roundTimeSeconds: int(state.createRound, 0),
                winCondition: keyOr(state.createWin, ''),
                scoreLimit: int(state.createLimit, 0),
            tierPlan: state.createTiers,
                radar: radarIsOn()
            });
            return;
        }

        post('createMatch', {
            arenaKey: state.createArena,
            modeKey: state.createMode,
            entryFee: int(state.createFee, 0),
            lives: int(state.createLives, 1),
            roundTimeSeconds: int(state.createRound, 0),
            winCondition: keyOr(state.createWin, ''),
            scoreLimit: int(state.createLimit, 0),
            tierPlan: state.createTiers,
            radar: radarIsOn(),
            account: chosenAccount()
        });
    });

    bind('loadout-save', 'click', saveLoadout);

    bind('bet-amount', 'input', function (event) {
        var rules = betRules(focusedMatch());
        state.betAmount = clampInt(event.target.value, 0, int(rules.max, 0));
        render();
    });

    hidePanel();
}());

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

    THE PANEL MUST NOT DIE. A thrown exception in a NUI page is invisible
    -- no console anyone reads, no error to the player, just a frozen menu
    with the mouse captured. So render sections are individually guarded
    and every fetch swallows its own rejection.

    STRINGS ARE LITERAL ENGLISH HERE, deliberately. locale() lives in the
    two Lua realms; NUI has no loader for it and the snapshot carries no
    string table. Player-visible text produced by Lua is already localised
    before it reaches this page (notifications, refusal reasons); the fixed
    chrome below matches the wording already hard-coded in index.html.
*/

(function () {
    'use strict';

    var RESOURCE = 'crimson_arena';

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

    // ==================================================================
    // STATE
    //
    // `config`, `player`, `matches` and `leaderboard` are the server's.
    // Everything below them is this page's own: which tab is open, what
    // the player has typed but not yet sent. A snapshot never clears the
    // second group, or every broadcast would wipe a half-built loadout.
    // ==================================================================

    var state = {
        open: false,
        config: null,
        player: null,
        matches: [],
        leaderboard: [],

        tab: 'matches',

        createArena: null,
        createMode: null,
        createFee: null,

        /* The match the browser has highlighted. Bets and spectating read
           it, so it survives a re-render of the list. */
        selectedMatchId: null,

        loadoutCategory: 'all',
        /* [{ key, ammo }] -- the unsaved draft. Seeded from the server's
           loadout until the player touches it; after that it is theirs
           until they save, so a broadcast cannot undo a selection. */
        draftWeapons: [],
        draftArmor: null,
        loadoutDirty: false,

        betPick: null,
        betAmount: null,

        hud: null,
        hudVisible: false
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

    function weaponSlots() {
        return Math.max(0, int((cfg().loadouts || {}).weaponSlots, 1));
    }

    function canChooseLoadout() {
        return (cfg().loadouts || {}).allowChoose !== false;
    }

    // ==================================================================
    // DRAFT LOADOUT
    //
    // Seeded from the server's resolved loadout so the picker opens on
    // what the player is actually holding. `alwaysGive` entries are the
    // operator's, not the player's -- they occupy no slot and are left out
    // of the draft, or saving would try to spend a slot on the house knife.
    // ==================================================================

    function seedDraft() {
        if (state.loadoutDirty) return;

        var loadout = player().loadout || {};
        var picks = [];
        arrayOf(loadout.weapons).forEach(function (entry) {
            if (!entry || entry.alwaysGive === true) return;
            if (picks.length >= weaponSlots()) return;
            var weapon = weaponByKey(entry.key);
            if (!weapon) return;
            picks.push({ key: weapon.key, ammo: int(entry.ammo, int(weapon.ammo && weapon.ammo.default, 0)) });
        });

        var armor = (cfg().loadouts || {}).armor || {};
        state.draftWeapons = picks;
        state.draftArmor = (loadout.armor === undefined || loadout.armor === null)
            ? int(armor.default, 0)
            : int(loadout.armor, 0);
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
        } else if (state.draftWeapons.length >= weaponSlots()) {
            toast('All ' + weaponSlots() + ' weapon slot(s) are full. Drop one first.', 'warning');
            return;
        } else {
            state.draftWeapons.push({ key: key, ammo: int(weapon.ammo && weapon.ammo.default, 0) });
        }

        state.loadoutDirty = true;
        render();
    }

    function setWeaponAmmo(key, ammo) {
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
        render();
    }

    // ==================================================================
    // TOASTS
    // ==================================================================

    function toast(message, kind) {
        var host = byId('arena-toast');
        if (!has(host) || typeof message !== 'string' || message === '') return;

        var level = (kind === 'success' || kind === 'error' || kind === 'warning') ? kind : 'info';
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
        applySnapshot(snapshot);
        state.open = true;
        show(byId('arena-root'), true);
        render();
    }

    function hidePanel() {
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
            var modes = arrayOf(config.modes);
            state.createMode = modes.length > 0 ? modes[0].key : null;
        }
        if (state.createFee === null) {
            state.createFee = int(((config.betting || {}).entryFee || {}).default, 0);
        }
        if (state.betAmount === null) {
            state.betAmount = int(((config.betting || {}).spectatorBets || {}).min, 0);
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

        var title = byId('arena-title');
        if (has(title)) title.textContent = typeof ui.title === 'string' ? ui.title : 'CRIMSON';

        var subtitle = byId('arena-subtitle');
        if (has(subtitle)) subtitle.textContent = typeof ui.subtitle === 'string' ? ui.subtitle : '';

        var logo = byId('arena-logo');
        if (has(logo)) {
            var src = typeof ui.logo === 'string' && ui.logo !== '' ? ui.logo : 'images/logo.png';
            if (logo.getAttribute('src') !== src) logo.setAttribute('src', src);
        }

        var wallet = byId('arena-money');
        if (has(wallet)) {
            /* With betting off there is no wallet to speak of in this
               panel, and showing one implies a fee that will never exist. */
            show(wallet, bettingOn());
            wallet.textContent = bettingOn() ? money(player().money) : '';
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
        if (mine === match.id) return 'You are already in this match';
        if (mine) return 'Leave your current match first';
        if (match.state !== 'lobby') return 'Already under way';

        var max = int((cfg().match || {}).maxPlayers, 0);
        if (max > 0 && int(match.playerCount, 0) >= max) return 'Match is full';

        if (bettingOn() && int(match.entryFee, 0) > int(player().money, 0)) {
            return 'Entry fee is ' + money(match.entryFee);
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
            host.appendChild(makeEl('div', 'muted', 'No matches running. Create one.'));
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
            int(match.playerCount, 0) + ' player(s)',
            'Host: ' + String(match.hostName || '')
        ];
        if (bettingOn()) {
            bits.push('Fee ' + money(match.entryFee));
            bits.push('Pot ' + money(match.pot));
        }
        card.appendChild(makeEl('div', 'match-card-meta', bits.join('  ·  ')));

        var actions = makeEl('div', 'match-card-actions');

        var stateName = typeof match.state === 'string' ? match.state : 'lobby';
        var badge = makeEl('span', 'state-badge', stateName);
        if (stateName === 'live' || stateName === 'countdown') badge.classList.add('live');
        if (stateName === 'lobby') badge.classList.add('lobby');
        actions.appendChild(badge);

        var reason = joinBlockedReason(match);
        var join = makeEl('button', 'btn btn-primary', 'Join');
        join.type = 'button';
        if (reason) {
            join.disabled = true;
            join.title = reason;
        } else {
            join.addEventListener('click', function (event) {
                event.stopPropagation();
                post('joinMatch', { matchId: match.id });
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
            spectate.addEventListener('click', function (event) {
                event.stopPropagation();
                if (watching) post('stopSpectate');
                else post('spectate', { matchId: match.id });
            });
            actions.appendChild(spectate);
        }

        card.appendChild(actions);

        if (reason) card.appendChild(makeEl('div', 'match-card-meta', reason));

        card.addEventListener('click', function () {
            state.selectedMatchId = match.id;
            render();
        });

        return card;
    }

    function renderCreatePanel() {
        fillSelect(byId('create-arena'), arrayOf(cfg().arenas), state.createArena);
        fillSelect(byId('create-mode'), arrayOf(cfg().modes), state.createMode);

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

        var submit = byId('create-submit');
        if (has(submit)) {
            var blocked = playerMatchId() ? 'Leave your current match first' : null;
            if (!blocked && !state.createArena) blocked = 'No arena is enabled';
            if (!blocked && !state.createMode) blocked = 'No mode is enabled';
            submit.disabled = blocked !== null;
            submit.title = blocked || '';
        }
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
            if (has(empty)) empty.textContent = 'You are not in a match';
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

        var bits = [
            String(match.modeLabel || match.modeKey || ''),
            String(match.arenaLabel || match.arenaKey || ''),
            'State: ' + String(match.state || ''),
            int(match.playerCount, 0) + (max > 0 ? ' / ' + max : '') + ' player(s)',
            'Minimum ' + int(matchCfg.minPlayers, 1),
            'Host: ' + String(match.hostName || '')
        ];
        if (bettingOn()) {
            bits.push('Fee ' + money(match.entryFee));
            bits.push('Pot ' + money(match.pot));
        }
        bits.forEach(function (text) {
            host.appendChild(makeEl('span', null, text));
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
            tile.appendChild(makeEl('div', 'team-tile-count', count + ' player(s)'));

            if (teams.allowChoose !== false && playerMatchId() === match.id) {
                tile.addEventListener('click', function () {
                    post('setTeam', { teamKey: team.key });
                });
            } else {
                tile.style.cursor = 'default';
            }

            host.appendChild(tile);
        });

        if (teams.allowChoose === false) {
            host.appendChild(makeEl('div', 'muted', 'Sides are assigned by the server.'));
        }

        /* Uneven teams are legal by default -- 7v1 is a match, not an
           error -- so the counts are stated plainly and nothing is
           flagged. Only an operator who switched the allowance off wants
           to see a warning here. */
        if (teams.allowUnequal === false && list.length > 0 && highest - lowest > 0) {
            host.appendChild(makeEl('div', 'muted',
                'Sides are uneven (' + lowest + ' vs ' + highest + '). This server requires balanced teams to start.'));
        }
        if (occupied < 2) {
            host.appendChild(makeEl('div', 'muted', 'Both sides need at least one player.'));
        }
    }

    function renderRoster(match) {
        var host = byId('roster');
        if (!has(host)) return;
        clear(host);

        var players = arrayOf(match.players);
        if (players.length === 0) {
            host.appendChild(makeEl('div', 'muted', 'Nobody has joined yet.'));
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

    function renderLobbyActions(match) {
        var inMatch = playerMatchId() === match.id;
        var isHost = inMatch && player().isHost === true;
        var counting = match.state === 'countdown';

        var ready = byId('btn-ready');
        if (has(ready)) {
            var isReady = player().ready === true;
            ready.textContent = isReady ? 'Not Ready' : 'Ready';
            ready.classList.toggle('btn-primary', !isReady);
            ready.disabled = !inMatch || match.state !== 'lobby';
            ready.onclick = function () {
                post('setReady', { ready: !isReady });
            };
        }

        var start = byId('btn-start');
        if (has(start)) {
            /* Cancel lives on this button during the countdown because
               that is the only window where "stop the start" is a thing a
               host can still ask for -- the server refuses it once the
               round is live. */
            var onlyHost = (cfg().match || {}).onlyHostCanStart !== false;
            var mayStart = inMatch && (isHost || !onlyHost);
            var blocked = null;
            if (!inMatch) blocked = 'You are watching this match';
            else if (!mayStart) blocked = 'Only the host can start this match';
            else if (int(match.playerCount, 0) < int((cfg().match || {}).minPlayers, 1)) {
                blocked = 'Needs ' + int((cfg().match || {}).minPlayers, 1) + ' player(s)';
            }

            start.textContent = counting ? 'Cancel Start' : 'Start Match';
            if (counting) {
                start.disabled = !isHost;
                start.title = isHost ? '' : 'Only the host can cancel';
                start.onclick = function () { post('cancelMatch'); };
            } else {
                start.disabled = blocked !== null;
                start.title = blocked || '';
                start.onclick = function () { post('startMatch'); };
            }
        }

        var leave = byId('btn-leave');
        if (has(leave)) {
            leave.textContent = inMatch ? 'Leave' : 'Stop Watching';
            leave.disabled = false;
            leave.onclick = function () {
                if (inMatch) post('leaveMatch');
                else post('stopSpectate');
            };
        }
    }

    // ------------------------------------------------------------------
    // LOADOUT
    // ------------------------------------------------------------------

    function categoriesInUse() {
        var loadouts = cfg().loadouts || {};
        var declared = arrayOf(loadouts.categories).slice().sort(function (a, b) {
            return int(a.order, 999) - int(b.order, 999);
        });

        var known = {};
        declared.forEach(function (entry) { known[entry.key] = true; });

        var cats = [{ key: 'all', label: 'All' }];
        declared.forEach(function (entry) {
            cats.push({ key: entry.key, label: entry.label || entry.key });
        });

        /* A weapon whose category an operator never declared still has to
           be reachable, so it collects under 'Other' -- but only when one
           actually exists. */
        var hasOther = arrayOf(loadouts.weapons).some(function (weapon) {
            return weapon && !known[weapon.category];
        });
        if (hasOther) cats.push({ key: '__other', label: 'Other' });

        return cats;
    }

    function renderLoadout() {
        renderLoadoutCategories();
        renderWeaponGrid();
        renderLoadoutSlots();
        renderArmorPicker();

        var save = byId('loadout-save');
        if (has(save)) {
            show(save, canChooseLoadout());
            save.disabled = !state.loadoutDirty;
            save.title = state.loadoutDirty ? '' : 'Nothing changed since your last save';
        }
    }

    function renderLoadoutCategories() {
        var host = byId('loadout-cats');
        if (!has(host)) return;
        clear(host);

        if (!canChooseLoadout()) {
            host.appendChild(makeEl('div', 'muted', 'This server issues a fixed loadout.'));
            return;
        }

        categoriesInUse().forEach(function (cat) {
            var chip = makeEl('button', 'chip', cat.label);
            chip.type = 'button';
            if (cat.key === state.loadoutCategory) chip.classList.add('active');
            chip.addEventListener('click', function () {
                state.loadoutCategory = cat.key;
                render();
            });
            host.appendChild(chip);
        });
    }

    function weaponInCategory(weapon) {
        if (state.loadoutCategory === 'all') return true;
        if (state.loadoutCategory === '__other') {
            var declared = arrayOf((cfg().loadouts || {}).categories);
            return !declared.some(function (entry) { return entry.key === weapon.category; });
        }
        return weapon.category === state.loadoutCategory;
    }

    function renderWeaponGrid() {
        var host = byId('weapon-grid');
        if (!has(host)) return;
        clear(host);

        var weapons = arrayOf((cfg().loadouts || {}).weapons);
        if (weapons.length === 0) {
            host.appendChild(makeEl('div', 'muted', 'No weapons are enabled on this server.'));
            return;
        }

        weapons.forEach(function (weapon) {
            if (!weapon || !weapon.key || !weaponInCategory(weapon)) return;
            host.appendChild(weaponCard(weapon));
        });
    }

    function weaponCard(weapon) {
        var index = draftIndexOf(weapon.key);
        var card = makeEl('div', 'weapon-card');
        if (index >= 0) card.classList.add('active');

        card.appendChild(makeEl('div', 'weapon-name', weapon.label || weapon.key));
        card.appendChild(makeEl('div', 'weapon-category', weapon.category || 'other'));

        var ammo = weapon.ammo || {};
        var options = arrayOf(ammo.options);

        if (options.length > 0) {
            var row = makeEl('div', 'weapon-ammo');
            var chosen = index >= 0 ? state.draftWeapons[index].ammo : int(ammo.default, 0);
            options.forEach(function (value) {
                var amount = int(value, 0);
                var chip = makeEl('button', 'chip', String(amount));
                chip.type = 'button';
                if (index >= 0 && amount === chosen) chip.classList.add('active');
                chip.disabled = !canChooseLoadout();
                chip.addEventListener('click', function (event) {
                    event.stopPropagation();
                    setWeaponAmmo(weapon.key, amount);
                });
                row.appendChild(chip);
            });
            card.appendChild(row);
        } else {
            /* No options means no choice to make (melee), not no ammo --
               the server hands out the default. Rendering an empty chip
               row would read as a broken picker. */
            card.appendChild(makeEl('div', 'weapon-category', int(ammo.default, 0) + ' rounds, fixed'));
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

    function renderLoadoutSlots() {
        var host = byId('loadout-slots');
        if (!has(host)) return;
        clear(host);

        var slots = weaponSlots();
        host.appendChild(makeEl('div', 'weapon-category', 'Loadout · ' + state.draftWeapons.length + ' / ' + slots));

        for (var i = 0; i < slots; i++) {
            var pick = state.draftWeapons[i];
            var slot = makeEl('div', 'slot');

            if (pick) {
                slot.classList.add('filled');
                var weapon = weaponByKey(pick.key);
                slot.appendChild(makeEl('span', null, (weapon && (weapon.label || weapon.key)) || pick.key));
                slot.appendChild(makeEl('span', 'muted', String(int(pick.ammo, 0))));

                if (canChooseLoadout()) {
                    var drop = makeEl('button', 'chip', '✕');
                    drop.type = 'button';
                    drop.addEventListener('click', (function (key) {
                        return function () { toggleWeapon(key); };
                    }(pick.key)));
                    slot.appendChild(drop);
                }
            } else {
                slot.appendChild(makeEl('span', 'muted', 'Empty slot'));
            }

            host.appendChild(slot);
        }
    }

    function renderArmorPicker() {
        var host = byId('armor-picker');
        if (!has(host)) return;
        clear(host);

        var armor = (cfg().loadouts || {}).armor || {};
        host.appendChild(makeEl('span', 'field-label', 'Armour'));

        var options = arrayOf(armor.options);
        if (armor.allowChoose === false || !canChooseLoadout() || options.length === 0) {
            host.appendChild(makeEl('span', 'muted', String(int(armor.default, 0))));
            return;
        }

        options.forEach(function (value) {
            var amount = int(value, 0);
            var chip = makeEl('button', 'chip', String(amount));
            chip.type = 'button';
            if (amount === int(state.draftArmor, -1)) chip.classList.add('active');
            chip.addEventListener('click', function () {
                state.draftArmor = amount;
                state.loadoutDirty = true;
                render();
            });
            host.appendChild(chip);
        });
    }

    function saveLoadout() {
        if (!canChooseLoadout()) return;
        post('setLoadout', {
            weapons: state.draftWeapons.map(function (pick) {
                return { key: pick.key, ammo: int(pick.ammo, 0) };
            }),
            armor: int(state.draftArmor, 0)
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
        if (has(disabled) && !enabled) disabled.textContent = 'Betting is switched off on this server';

        ['bet-summary', 'bet-pick', 'bet-amount', 'bet-submit', 'bet-list'].forEach(function (id) {
            show(byId(id), enabled);
        });
        if (!enabled) return;

        var match = focusedMatch();
        renderBetSummary(match);
        renderBetPick(match);
        renderBetControls(match);
        renderBetList(match);
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

        stat('Your ' + String(betting().account || 'cash'), money(player().money));
        stat('Pot', match ? money(match.pot) : money(0));
        stat('Entry fee', match ? money(match.entryFee) : money(0));
        stat('Payout', String(betting().payout || ''));

        var spectator = betting().spectatorBets || {};
        if (spectator.enabled === true) {
            stat('Side-bet pays', 'x' + String(Number(spectator.oddsMultiplier) || 2));
        }

        if (!match) {
            host.appendChild(makeEl('div', 'muted', 'Pick a match on the Matches tab to bet on it.'));
        }
    }

    function renderBetPick(match) {
        var host = byId('bet-pick');
        if (!has(host)) return;
        clear(host);

        var spectator = betting().spectatorBets || {};
        if (spectator.enabled !== true) {
            host.appendChild(makeEl('div', 'muted', 'Spectator side-bets are switched off. The pot below is the entry fees.'));
            return;
        }
        if (!match) return;

        var options = betPickOptions(match);
        if (options.length === 0) {
            host.appendChild(makeEl('div', 'muted', 'Nothing to back in this match yet.'));
            return;
        }

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
        var spectator = betting().spectatorBets || {};
        if (spectator.enabled !== true) return 'Side-bets are switched off';
        if (!match) return 'No match selected';
        if (playerMatchId() === match.id) return 'You are fighting in this match';
        if (match.state === 'ended') return 'This match has finished';
        if (!state.betPick) return 'Pick who you are backing';

        var amount = int(state.betAmount, 0);
        var min = int(spectator.min, 0);
        var max = int(spectator.max, 0);
        if (amount < min) return 'Minimum bet is ' + money(min);
        if (max > 0 && amount > max) return 'Maximum bet is ' + money(max);
        if (amount > int(player().money, 0)) return 'You cannot cover that';
        return null;
    }

    function renderBetControls(match) {
        var spectator = betting().spectatorBets || {};
        var usable = spectator.enabled === true;

        var input = byId('bet-amount');
        show(input, usable);
        if (has(input) && usable) {
            input.min = String(int(spectator.min, 0));
            if (int(spectator.max, 0) > 0) input.max = String(int(spectator.max, 0));
            if (document.activeElement !== input) input.value = String(int(state.betAmount, 0));
        }

        var submit = byId('bet-submit');
        show(submit, usable);
        if (has(submit) && usable) {
            var reason = betBlockedReason(match);
            submit.disabled = reason !== null;
            submit.title = reason || '';
            submit.onclick = function () {
                if (!match) return;
                post('spectatorBet', {
                    matchId: match.id,
                    pick: state.betPick,
                    amount: int(state.betAmount, 0)
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
            host.appendChild(makeEl('div', 'muted', 'No match selected.'));
            return;
        }

        var header = makeEl('div', 'bet-row');
        header.appendChild(makeEl('span', 'bet-stat-label', 'In the pot'));
        header.appendChild(makeEl('span', 'bet-stat-label', money(match.pot)));
        host.appendChild(header);

        var fee = int(match.entryFee, 0);
        arrayOf(match.players).forEach(function (entry) {
            if (!entry) return;
            var row = makeEl('div', 'bet-row');
            if (entry.alive === false) row.classList.add('lost');
            row.appendChild(makeEl('span', null, entry.name || ('#' + int(entry.id, 0))));
            row.appendChild(makeEl('span', null, money(fee)));
            host.appendChild(row);
        });
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
            var cell = makeEl('td', 'muted', 'No results recorded yet.');
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

    function renderHudScoreboard(rows) {
        var host = byId('hud-scoreboard');
        if (!has(host)) return;
        clear(host);

        var me = int(player().serverId, -1);
        rows.slice(0, HUD_SCORE_ROWS).forEach(function (entry) {
            if (!entry) return;
            var row = makeEl('div', 'hud-score-row');
            if (int(entry.id, -1) === me) row.classList.add('self');
            if (entry.alive === false) row.classList.add('dead');

            var team = teamByKey(entry.team);
            var name = makeEl('span', null, entry.name || ('#' + int(entry.id, 0)));
            if (team) name.style.borderLeft = '3px solid ' + teamColor(team);
            row.appendChild(name);

            row.appendChild(makeEl('span', null, String(int(entry.kills, 0))));
            row.appendChild(makeEl('span', null, String(int(entry.deaths, 0))));
            host.appendChild(row);
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
                       ArenaUI.ShowHud sends visibility on its own. Both
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

    /* The round is over: the overlay comes down with it, and the outcome is
       said once as a notification. There is no results element in the
       page -- a modal scoreboard would need NUI focus, and taking focus
       from a player who has just been dropped back at the lobby ped is
       exactly the wrong moment. */
    function showResults(results) {
        state.hudVisible = false;
        state.hud = null;
        renderHud();
        hideCountdown();

        if (!results || typeof results !== 'object') return;

        var bits = [results.won === true ? 'You won.' : 'Match over.'];
        if (results.placement) bits.push('Placed #' + int(results.placement, 0));
        bits.push(int(results.kills, 0) + ' kill(s), ' + int(results.deaths, 0) + ' death(s)');
        if (bettingOn() && int(results.earnings, 0) > 0) bits.push('Won ' + money(results.earnings));

        toast(bits.join('  ·  '), results.won === true ? 'success' : 'info');
    }

    // ==================================================================
    // INPUT
    // ==================================================================

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
    bind('create-fee', 'input', function (event) {
        var fee = (betting().entryFee) || {};
        state.createFee = clampInt(event.target.value, int(fee.min, 0), int(fee.max, 0));
    });

    bind('create-submit', 'click', function () {
        post('createMatch', {
            arenaKey: state.createArena,
            modeKey: state.createMode,
            entryFee: int(state.createFee, 0)
        });
    });

    bind('loadout-save', 'click', saveLoadout);

    bind('bet-amount', 'input', function (event) {
        var spectator = betting().spectatorBets || {};
        state.betAmount = clampInt(event.target.value, 0, int(spectator.max, 0));
        render();
    });

    /* Nothing is drawn until Lua sends `open`; the page is loaded the whole
       time the resource is running, and an unopened panel must be invisible
       rather than an empty frame over the game. */
    hidePanel();
}());

/*
    crimson_arena/tests/panel/harness.js

    A DOM shim thin enough to run html/app.js for real.

    WHY THIS EXISTS. Every other panel test in this suite reads app.js as
    TEXT and asserts that the right words are in it. That catches a wire
    that was never connected and cannot catch a wire connected to the wrong
    thing -- and the bug that prompted this was exactly the second kind: a
    state key that was never declared, so the guard seeding it from config
    never fired and every match was created with a fallback of one life. The
    text was all present and correct.

    So this runs the file. Not a browser -- just enough of one that app.js
    loads, receives a snapshot the way FiveM sends it, and posts what a
    button click would post. What is asserted is the PAYLOAD, because that
    is the thing the server acts on and the thing a reader cannot verify by
    looking at the source.
*/

const fs = require('fs');
const path = require('path');

function makeNode(id) {
    return {
        id,
        value: '',
        textContent: '',
        min: '',
        max: '',
        disabled: false,
        title: '',
        hidden: false,
        children: [],
        firstChild: null,
        listeners: {},
        classList: {
            _set: new Set(),
            toggle(name, on) { if (on === false) this._set.delete(name); else if (on === true) this._set.add(name); },
            add(n) { this._set.add(n); },
            remove(n) { this._set.delete(n); },
            contains(n) { return this._set.has(n); },
        },
        style: {},
        addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
        removeChild() {},
        appendChild(child) { this.children.push(child); return child; },
        setAttribute(name, value) { this[name] = value; },
        getAttribute(name) { return this[name] === undefined ? null : this[name]; },
        querySelectorAll() { return []; },
        focus() {},
    };
}

/**
 * Loads html/app.js into a shim and returns handles for driving it.
 * @param {string} root -- the Crimson-Arena directory
 */
function loadPanel(root) {
    const source = fs.readFileSync(path.join(root, 'html', 'app.js'), 'utf8');

    const nodes = {};
    const posted = [];
    const listeners = {};

    const context = {
        document: {
            getElementById: (id) => nodes[id] || (nodes[id] = makeNode(id)),
            querySelectorAll: () => [],
            /*
             * Elements the panel BUILDS, registered under whatever id it
             * gives them -- which is what a real document does, and what
             * makes a control the panel created addressable by a test.
             *
             * Without this only the ids the panel LOOKED UP existed, so a
             * card or an input it created was unreachable: node() would
             * conjure a fresh detached one and every assertion against it
             * passed for the wrong reason.
             */
            createElement: (tag) => {
                const node = makeNode('el:' + tag);
                let assigned = '';
                Object.defineProperty(node, 'id', {
                    get() { return assigned; },
                    set(value) {
                        assigned = String(value);
                        if (assigned) nodes[assigned] = node;
                    },
                    enumerable: true,
                    configurable: true,
                });
                return node;
            },
            addEventListener() {},
            activeElement: null,
            body: makeNode('body'),
        },
        window: {
            addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
            removeEventListener() {},
            setTimeout: () => 0,
            clearTimeout() {},
            AudioContext: null,
            webkitAudioContext: null,
        },
        GetParentResourceName: () => 'Crimson-Arena',
        fetch: (url, options) => {
            posted.push({
                name: String(url).split('/').pop(),
                body: options && options.body ? JSON.parse(options.body) : null,
            });
            return Promise.resolve({ json: () => Promise.resolve({}) });
        },
        setTimeout: () => 0,
        clearTimeout() {},
        console,
    };

    // The file reads `window.x` and bare globals interchangeably, as browser
    // code does, so both have to resolve to the same shim.
    Object.assign(context.window, {
        document: context.document,
        fetch: context.fetch,
        GetParentResourceName: context.GetParentResourceName,
    });

    const vm = require('vm');
    vm.createContext(context);
    vm.runInContext(source, context, { filename: 'app.js' });

    return {
        nodes,
        posted,
        /** Delivers a NUI message in the shape FiveM sends it. */
        send(action, data) {
            (listeners.message || []).forEach((fn) => fn({ data: { action, data } }));
        },
        /** @returns {object} the node, created on demand like the real DOM lookup */
        node(id) { return nodes[id] || (nodes[id] = makeNode(id)); },
        /**
         * Whether the PANEL built a node with this id, as opposed to a test
         * having conjured one by asking for it.
         *
         * node() creates on demand, which is right for driving controls and
         * useless for asking whether a control exists -- every id "exists"
         * the moment you look. This asks the real question.
         */
        built(id) { return Object.prototype.hasOwnProperty.call(nodes, id); },
        /** Fires one DOM event on a node, the way a player would. */
        fire(id, type, event) {
            const node = this.node(id);
            // A real event carries these and the panel calls them: controls
            // that sit inside a clickable card stop propagation so clicking
            // them does not also toggle the card. An event object without
            // them throws instead of testing anything.
            const detail = Object.assign({
                target: node,
                stopPropagation() {},
                preventDefault() {},
            }, event || {});
            (node.listeners[type] || []).forEach((fn) => fn(detail));
        },
        /**
         * All text rendered inside a node, children included.
         *
         * The panel builds screens by appending elements rather than by
         * setting innerHTML, so what a player actually READS is spread across
         * a tree. A test that only checks textContent on the container sees
         * an empty string and passes for the wrong reason.
         */
        text(id) {
            const walk = (node) => (node.textContent || '')
                + (node.children || []).map(walk).join(' ');
            return walk(this.node(id)).trim();
        },
        /** Types into an input and fires the input event, as a player does. */
        type(id, value) {
            const node = this.node(id);
            node.value = String(value);
            this.fire(id, 'input', { target: { value: String(value) } });
        },
    };
}

module.exports = { loadPanel, makeNode };

import $ from 'jquery';
import LZString from 'lz-string';

let lastHash;
function save(code, options) {
    let hash = LZString.compressToBase64(code);
    const flags = stringifyFlags(options);
    if (flags)
        hash = 'f:' + flags + '/' + hash;

    if (options.branchId)
        hash = 'b:' + options.branchId + '/' + hash;

    lastHash = hash;
    window.location.hash = hash;
}

function loadInternal(onlyIfChanged) {
    let hash = window.location.hash;
    if (!hash)
        return null;

    hash = hash.replace(/^#/, '');
    if (!hash || (onlyIfChanged && hash === lastHash))
        return null;

    lastHash = hash;
    const match = /(?:b:([^\/]+)\/)?(?:f:([^\/]+)\/)?(.+)/.exec(hash);
    if (match === null)
        return null;

    const result = {
        options: Object.assign({ branchId: match[1] }, parseFlags(match[2]))
    };

    try {
        result.code = LZString.decompressFromBase64(match[3]);
    }
    catch (e) {
        return null;
    }

    return result;
}

function load() {
    return loadInternal(false);
}

function onchange(callback) {
    $(window).on('hashchange', () => {
        const loaded = loadInternal(true);
        if (loaded !== null)
            callback(loaded);
    });
}

var targetMap = { csharp: '', vbnet: '>vb', il: '>il' };
var targetMapReverse = (() => {
    const result = {};
    for (let key in targetMap) {
        result[targetMap[key]] = key;
    }
    return result;
})();

function stringifyFlags(options) {
    return [
        options.language === 'vbnet' ? 'vb' : '',
        targetMap[options.target],
        options.mode === 'script' ? 's' : '',
        options.optimizations ? 'r' : ''
    ].join('');
}

function parseFlags(flags) {
    if (!flags)
        return {};

    let target = targetMapReverse[''];
    for (var key in targetMapReverse) {
        if (key === '')
            continue;

        if (flags.indexOf(key) > -1)
            target = targetMapReverse[key];
    }

    return {
        language:      /(^|[a-z])vb/.test(flags) ? 'vbnet'  : 'csharp',
        target:        target,
        mode:          flags.indexOf('s') > -1   ? 'script' : 'regular',
        optimizations: flags.indexOf('r') > -1
    };
}

export default {
    save,
    load,
    onchange
};
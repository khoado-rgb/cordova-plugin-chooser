var MIME_TYPE = /^[a-z0-9][a-z0-9!#$&^_.+-]*\/([a-z0-9][a-z0-9!#$&^_.+-]*|\*)$/;

/**
 * Trims, lowercases and dedupes the comma-separated MIME filter. Malformed
 * tokens are dropped. Returns undefined if tokens were given but none are valid.
 */
function normalizeAccept (accept) {
    if (typeof accept !== 'string') {
        return '*/*';
    }

    var tokens = accept.split(',').map(function (token) {
        return token.trim().toLowerCase();
    }).filter(function (token) {
        return token.length > 0;
    });

    if (tokens.length === 0 || tokens.indexOf('*/*') >= 0) {
        return '*/*';
    }

    var mimeTypes = tokens.filter(function (token, i) {
        return MIME_TYPE.test(token) && tokens.indexOf(token) === i;
    });

    return mimeTypes.length > 0 ? mimeTypes.join(',') : undefined;
}

function pick (action, accept, successCallback, failureCallback) {
    var result = new Promise(function (resolve, reject) {
        var mimeTypes = normalizeAccept(accept);
        if (mimeTypes === undefined) {
            reject('INVALID_ACCEPT');
            return;
        }

        cordova.exec(
            function (json) {
                if (json === 'RESULT_CANCELED') {
                    resolve();
                    return;
                }

                try {
                    resolve(JSON.parse(json));
                }
                catch (err) {
                    reject('Failed to parse chooser result: ' + err.message);
                }
            },
            reject,
            'LowcodeChooser',
            action,
            [mimeTypes]
        );
    });

    if (typeof successCallback === 'function' || typeof failureCallback === 'function') {
        result.then(successCallback, failureCallback);
    }

    return result;
}

module.exports = {
    getFile: function (accept, successCallback, failureCallback) {
        return pick('getFile', accept, successCallback, failureCallback);
    },

    getFiles: function (accept, successCallback, failureCallback) {
        return pick('getFiles', accept, successCallback, failureCallback);
    }
};

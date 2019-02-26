/**
 *    Adds a new user account ready to be used.
 *    Run from commandline using npm: `js add-user.js`
 */

/* display usage */
if (['--help', '-help', '-h'].indexOf(process.argv[2]) > -1 || process.argv.length < 6 || process.argv.length > 8) {
    console.log("Usage: " + process.argv[0] + " " + process.argv[1] + " admin:password database username password rev_db-user rev_aam-user");
    console.log("If a user_rev is given, only the existing user in the helgo_db database is updated instead of creating a new user.");
    process.exit();
}
// curl localhost:5984/dev/user:demo


http = require('http');
querystring = require('querystring');

path = require('path');
CryptoJS = require(path.resolve( __dirname, "crypto-js"));

var adminAuth = process.argv[2];
var database = process.argv[3];
var username = process.argv[4];
var password = process.argv[5];
var rev_user_db;
var rev_user_aam;
if (process.argv.length == 8) {
    rev_user_db = process.argv[6];
    rev_user_aam = process.argv[7];
}

/**
 * Encrypts the password to be saved into the helgo_db user database.
 */
function encrypt(password) {
    var cryptKeySize = 256 / 32;
    var cryptIterations = 128;
    var cryptSalt = CryptoJS.lib.WordArray.random(128 / 8).toString();
    var hash = CryptoJS.PBKDF2(password, cryptSalt, {keySize: cryptKeySize, iterations: cryptIterations}).toString();
    return {"hash": hash, "salt": cryptSalt, "iterations": cryptIterations, "keysize": cryptKeySize};
}


/**
 * Sends a HTTP PUT request to the CouchDB server.
 */
function couchPut(dataPath, data) {
    var postData = JSON.stringify(data);
    var options = {
        hostname: 'localhost',
        port: 5984,
        path: "/" + dataPath,
        method: 'PUT',
        headers: {
            'Content-Type': 'application/json'
        },
        auth: adminAuth
    };

    var req = http.request(options, function (res) {
        console.log('STATUS: ' + res.statusCode);
        res.setEncoding('utf8');
        res.on('data', function (chunk) {
            console.log('RESPONSE: ' + chunk);
        });
        res.on('end', function () {
            //console.log('No more data in response.')
        })
    });

    req.on('error', function (e) {
        console.log('problem with request: ' + e.message);
    });

    // write data to request body
    req.write(postData);
    req.end();
}


// Add CouchDB User
var couchData = {'name': username, 'password': password, 'roles': ['user_' + database], 'type': 'user'};
    // database is configured to be accessible for user role "user_$DB"
if (rev_user_db) {
    couchData._rev = rev_user_db;
}
couchPut("_users/org.couchdb.user:" + username, couchData);
console.log("Updating user '" + username + "' to CouchDB");

// Add helgo_db User in application database
var hdbData = {'_id': 'User:' + username, 'name': username, 'password': encrypt(password)};
if (rev_user_aam) {
    hdbData._rev = rev_user_aam;
}
couchPut(database + "/User:" + username, hdbData);
console.log("Updating helgo_db database '" + database + "' for user '" + username + "'");

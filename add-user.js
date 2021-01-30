/**
 *    Adds a new user account ready to be used.
 *    Run from commandline using npm: `js add-user.js`
 */

https = require('https');
querystring = require('querystring');
path = require('path');
CryptoJS = require(path.resolve( __dirname, "lib/crypto-js"));


/* display usage */
if (['--help', '-help', '-h'].indexOf(process.argv[2]) > -1 || process.argv.length < 6 || process.argv.length > 8) {
    console.log("Usage to create an account: " + process.argv[0] + " " + process.argv[1] + " domain admin:password username password");
    console.log("Usage to edit an account: " + process.argv[0] + " " + process.argv[1] + " domain admin:password username password rev_db-user rev_aam-user");
    console.log("    where 'rev_db-user' and 'rev_aam-user' are the couchdb '_rev' values of the user document in the '_users' and 'app' database respectively");
    console.log("---");
    console.log("Example: " + process.argv[0] + " " + process.argv[1] + " demo.aam-digital.com admin:password123 User1 password0");
    process.exit();
}


var domain = process.argv[2];
var database = 'app';
var adminAuth = process.argv[3];
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
        hostname: domain,
        path: "/db/" + dataPath,
        method: 'PUT',
        headers: {
            'Content-Type': 'application/json'
        },
        auth: adminAuth
    };

    var req = https.request(options, function (res) {
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

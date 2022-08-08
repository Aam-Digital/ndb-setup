if (['--help', '-help', '-h'].indexOf(process.argv[2]) > -1 || process.argv.length < 7 || process.argv.length > 7) {
    console.log("Usage to migrate users: " + process.argv[0] + " " + process.argv[1] + " domain db-password keycloak-url keycloak-realm keycloak-password");
    console.log("Example: " + process.argv[0] + " " + process.argv[1] + " demo.aam-digital.com password123 keycloak.aam-digital.com myrealm password123");
    process.exit();
}

https = require('https');

const domain = process.argv[2];
const dbPassword = process.argv[3];
const keycloakUrl = process.argv[4];
const realm = process.argv[5];
const keycloakPassword = process.argv[6];

function request(host, url, operation, password, body = "", contentType = "application/json") {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: host,
            path: url,
            method: operation,
            headers: {
                'Content-Type': contentType
            },
            port: 443
        }
        if (password.startsWith("admin:")) {
            options.auth = password;
        } else {
            options.headers.Authorization = "Bearer " + password;
        }

        const req = https.request(options, (res) => {
            let resultData = "";

            res.setEncoding('utf8');
            res.on('data', (chunk) => resultData = resultData + chunk);
            res.on('end', () => resolve(resultData ? JSON.parse(resultData) : resultData));
        });
        req.on('error', (err) => reject(err));
        req.on('timeout', () => { req.abort() });
        req.end(body);
})}

request(domain, "/db/_users/_all_docs?include_docs=true", "GET", "admin:" +dbPassword)
    .then(async data => {
        // get admin access token
        const params = new URLSearchParams();
        params.set('grant_type', 'password');
        params.set('client_id', 'admin-cli');
        params.set('username', "admin");
        params.set('password', keycloakPassword);
        const token = await request(
            keycloakUrl,
            `/realms/master/protocol/openid-connect/token`,
            "POST",
            keycloakPassword,
            params.toString(),
            "application/x-www-form-urlencoded"
        ).then(token => token.access_token);

        // parse users and get unique roles
        const users = data.rows
            .map(row => row.doc)
            .filter(doc => doc.type === "user");
        const uniqueRoles = new Set();
        users.forEach(user => user.roles.forEach(role => uniqueRoles.add(role)));
        const roleNames = Array.from(uniqueRoles);

        // create all roles
        let requests = roleNames.map((role) => request(keycloakUrl, `/admin/realms/${realm}/roles`, "POST", token, JSON.stringify({name: role})));
        await Promise.all(requests)
        requests = roleNames.map((role) => request(keycloakUrl, `/admin/realms/${realm}/roles/${role}`, "GET", token));
        const roles = await Promise.all(requests);

        requests = users.map((user) => {
            // create user
            const derivedKey = Buffer.from(user.derived_key, "hex").toString("base64")
            const salt = Buffer.from(user.salt, "utf8").toString("base64")
            const keycloakUser = {
                username: user.name,
                email: "",
                enabled: true,
                attributes: {},
                emailVerified: "",
                credentials: [
                    {
                        credentialData: `{"hashIterations": "10","algorithm": "${user.password_scheme}"}`,
                        secretData: `{"salt": "${salt}","value": "${derivedKey}"}`,
                        type: "password"
                    }
                ]
            }
            return request(keycloakUrl, `/admin/realms/${realm}/users`, "POST", token, JSON.stringify(keycloakUser))
                .then(() => request(keycloakUrl, `/admin/realms/${realm}/users?username=${user.name}`, "GET", token))
                .then(([keycloakUser]) => {
                    // add roles to user
                    const userRoles = roles.filter(role => user.roles.includes(role.name));
                    return request(keycloakUrl, `/admin/realms/${realm}/users/${keycloakUser.id}/role-mappings/realm`, "POST", token, JSON.stringify(userRoles))
                })
                .catch((err) => console.log("error migrating user: " + user.name, err))
        })
        await Promise.all(requests).then(() => console.log("done"));
    })



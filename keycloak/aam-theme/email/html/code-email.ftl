<html>
<body>
<h1 style="color: #ff9800">Aam Digital - ${realmName}</h1>
${kcSanitize(msg("emailCodeBodyHtml", ttl))}
<h2>${code}</h2>
${kcSanitize(msg("emailFooterHtml"))?no_esc}
</body>
</html>

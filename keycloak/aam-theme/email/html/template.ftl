<#macro emailLayout>
<html>
<body>
    <h1 style="color: #ff9800">${realmName}</h1>
    <#nested>
    ${kcSanitize(msg("emailFooterHtml"))?no_esc}
</body>
</html>
</#macro>

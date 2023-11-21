<#import "template.ftl" as layout>
<@layout.emailLayout>
${kcSanitize(msg("emailCodeBodyHtml", ttl))}
<h2>${code}</h2>
</@layout.emailLayout>


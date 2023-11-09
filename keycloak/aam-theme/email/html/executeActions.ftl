<#outputformat "plainText">
<#assign requiredActionsText><#if requiredActions??><#list requiredActions><#items as reqActionItem>${msg("requiredAction.${reqActionItem}")}<#sep>, </#sep></#items></#list></#if></#assign>
<#assign requiredActionsValues><#if requiredActions??><#list requiredActions><#items as reqActionItem>${reqActionItem}<#sep>, </#sep></#items></#list></#if></#assign>
</#outputformat>

<#import "template.ftl" as layout>
<@layout.emailLayout>
<#if requiredActionsValues == "VERIFY_EMAIL">
${kcSanitize(msg("emailVerificationBodyHtml", link, user.getAttributes().exact_username, link?keep_after("realms/")?keep_before("/"), linkExpirationFormatter(linkExpiration)))?no_esc}
<#elseif requiredActionsValues == "UPDATE_PASSWORD">
${kcSanitize(msg("passwordResetBodyHtml", link, user.getAttributes().exact_username, link?keep_after("realms/")?keep_before("/"), linkExpirationFormatter(linkExpiration)))?no_esc}
<#else>
${kcSanitize(msg("executeActionsBodyHtml", link, linkExpiration, realmName, requiredActionsText, linkExpirationFormatter(linkExpiration)))?no_esc}
</#if>
</@layout.emailLayout>

<#ftl output_format="plainText">
<#assign requiredActionsText><#if requiredActions??><#list requiredActions><#items as reqActionItem>${msg("requiredAction.${reqActionItem}")}<#sep>, </#sep></#items></#list><#else></#if></#assign>
<#assign requiredActionsValues><#if requiredActions??><#list requiredActions><#items as reqActionItem>${reqActionItem}<#sep>, </#sep></#items></#list></#if></#assign>


<#if requiredActionsValues == "VERIFY_EMAIL">
${msg("emailVerificationBody",link, linkExpiration, realmName, linkExpirationFormatter(linkExpiration))}
<#elseif requiredActionsValues == "UPDATE_PASSWORD">
${msg("passwordResetBody",link, linkExpiration, realmName, linkExpirationFormatter(linkExpiration))}
<#else>
${msg("executeActionsBody",link, linkExpiration, realmName, requiredActionsText, linkExpirationFormatter(linkExpiration))}
</#if>
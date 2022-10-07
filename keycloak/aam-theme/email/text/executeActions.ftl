<#ftl output_format="plainText">
<#assign requiredActionsText><#if requiredActions??><#list requiredActions><#items as reqActionItem>${msg("requiredAction.${reqActionItem}")}<#sep>, </#sep></#items></#list><#else></#if></#assign>
<#assign requiredActionsValues><#if requiredActions??><#list requiredActions><#items as reqActionItem>${reqActionItem}<#sep>, </#sep></#items></#list></#if></#assign>

Aam Digital - ${realmName}\n\n
<#if requiredActionsValues == "VERIFY_EMAIL">
${msg("emailVerificationBody",link, user.username, linkExpirationFormatter(linkExpiration))}
<#elseif requiredActionsValues == "UPDATE_PASSWORD">
${msg("passwordResetBody",link, user.username, linkExpirationFormatter(linkExpiration))}
<#else>
${msg("executeActionsBody",link, linkExpiration, realmName, requiredActionsText, linkExpirationFormatter(linkExpiration))}
</#if>
\n\n
If you have any problems or questions, don’t hesitate to get in touch with us at support@aam-digital.com .\n\n
   Best regards,\n\n
Your Aam Digital Team

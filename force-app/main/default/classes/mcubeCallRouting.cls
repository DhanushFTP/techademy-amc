/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : mcubeCallRouting
 * Author          : Tharun
 * Created Date    : Jun 23, 2026
 * Last Modified By: Tharun
 * Last Modified On: Jun 23, 2026
 * Description     : Call-routing REST API for MCube telephony. Given a
 *                   customerNumber + landingNumber it:
 *                     1. resolves the MCube configuration from the landing number
 *                        (highest priority when a number maps to several configs),
 *                     2. runs the config's stored duplication-rule SOQL,
 *                     3. returns the matched record Id, or creates a Lead and
 *                        returns its Id (when creation is enabled),
 *                     4. writes an MCube_Apex_Log__c record (when logging is enabled).
 *
 *                   Endpoint : POST /services/apexrest/mcubeCallRouting
 *                   Body     : { "customerNumber": "...", "landingNumber": "..." }
 *
 * Change History  :
 *  Date          │   Author   │   Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  Jun 23, 2026  │ Tharun    │ Initial version
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */
@RestResource(urlMapping='/mcubeCallRouting/*')
global without sharing class mcubeCallRouting {

    private static final String CLASS_NAME = 'mcubeCallRouting';
    private static final String EVENT_TYPE = 'Call Routing';

    @HttpPost
    global static RoutingResponse route(String customerNumber, String landingNumber) {

        RoutingResponse resp = new RoutingResponse();
        resp.hasError = false;

        // Whole body wrapped so ANY error (incl. param resolution) is caught and
        // returned with the exact message instead of escaping as a raw 500.
        try {
            // Allow query-string params as a fallback when no JSON body params were sent
            if (String.isBlank(customerNumber) && RestContext.request != null) {
                customerNumber = RestContext.request.params.get('customerNumber');
            }
            if (String.isBlank(landingNumber) && RestContext.request != null) {
                landingNumber = RestContext.request.params.get('landingNumber');
            }

            System.debug(LoggingLevel.INFO,
                '[MCube] mcubeCallRouting.route TRIGGERED — customerNumber=' + customerNumber
                + ', landingNumber=' + landingNumber);

            resp.request = 'customerNumber=' + customerNumber + ', landingNumber=' + landingNumber;

            if (String.isBlank(landingNumber)) {
                resp.status  = 'NO_CONFIG';
                resp.message = 'landingNumber is required.';
                writeLog(resp, null);
                return resp;
            }

            // ── Validate / normalize the customer number to 10 digits ──────
            // Accepts separators ( ) - spaces and a 91 / +91 prefix; rejects
            // anything that isn't 10 digits after cleaning.
            String normalized = normalizeMobile(customerNumber);
            if (normalized == null) {
                resp.status   = 'INVALID_NUMBER';
                resp.hasError = true;
                resp.message  = 'Customer number must be 10 digits (optionally prefixed with 91 or +91).';
                writeLog(resp, null);
                return resp;
            }
            customerNumber = normalized;

            // ── 1. Resolve config from the landing number ──────────────────
            // The same landing number can be linked to several configs; pick the
            // active one with the lowest numeric Priority__c (1 beats 2 beats 3).
            List<Mcube_Landing_Number__c> lns = [
                SELECT Id, Number__c,
                       MCube_Configuration__c,
                       MCube_Configuration__r.Name,
                       MCube_Configuration__r.Priority__c,
                       MCube_Configuration__r.Source_Object__c,
                       MCube_Configuration__r.Duplication_rule__c,
                       MCube_Configuration__r.Default_Values__c,
                       MCube_Configuration__r.Create_If_Not_Found__c,
                       MCube_Configuration__r.Is_Active__c
                FROM Mcube_Landing_Number__c
                WHERE Number__c = :landingNumber
            ];

            // Collect active configs that have a dedup rule, de-duplicated by Id,
            // then order them by priority (lowest Priority__c first).
            List<PrioritizedConfig> candidates = new List<PrioritizedConfig>();
            Set<Id> seen = new Set<Id>();
            for (Mcube_Landing_Number__c cand : lns) {
                MCube_Configuration__c c = cand.MCube_Configuration__r;
                if (c == null || c.Is_Active__c != true || String.isBlank(c.Duplication_rule__c)) continue;
                if (seen.contains(c.Id)) continue;
                seen.add(c.Id);
                candidates.add(new PrioritizedConfig(c, priorityOf(c)));
            }

            if (candidates.isEmpty()) {
                resp.status  = 'NO_CONFIG';
                resp.message = 'No active MCube configuration found for landing number ' + landingNumber + '.';
                writeLog(resp, null);
                return resp;
            }

            candidates.sort();   // ascending by priority (see PrioritizedConfig.compareTo)
            List<String> configErrors = new List<String>();

            // ── 2a. Check the landing number's NON-Lead configs, by priority ──
            // First duplicate wins. Any Lead config mapped to this landing number is
            // remembered (highest priority) and handled below; the Lead config is a
            // global last resort, so it need not be mapped to this landing number.
            PrioritizedConfig landingLead = null;
            for (PrioritizedConfig pc : candidates) {
                if (pc.cfg.Source_Object__c == 'Lead') {
                    if (landingLead == null) landingLead = pc;   // highest-priority landing Lead config
                    continue;
                }
                Id matchId = checkDedup(pc.cfg, customerNumber, landingNumber, resp, configErrors);
                if (matchId != null) {
                    resp.relatedToId = matchId;
                    resp.status      = 'DUPLICATE_FOUND';
                    resp.message     = 'Existing record matched config "' + pc.cfg.Name + '".';
                    writeLog(resp, null);
                    return resp;
                }
            }

            // ── 2b. Lead config = global last resort ───────────────────────
            // Prefer a Lead config mapped to this landing number; otherwise fall back
            // to the active Lead config org-wide (even if unmapped).
            MCube_Configuration__c leadCfg = (landingLead != null) ? landingLead.cfg : loadActiveLeadConfig();

            if (leadCfg == null) {
                resp.status  = 'NOT_CREATED';
                resp.message = 'No duplicate found and no active Lead configuration is available to create a lead.'
                    + skippedNote(configErrors);
                writeLog(resp, null);
                return resp;
            }

            // Run the Lead config's own duplication check before creating.
            Id leadMatch = checkDedup(leadCfg, customerNumber, landingNumber, resp, configErrors);
            if (leadMatch != null) {
                resp.relatedToId = leadMatch;
                resp.status      = 'DUPLICATE_FOUND';
                resp.message     = 'Existing record matched Lead config "' + leadCfg.Name + '".';
                writeLog(resp, null);
                return resp;
            }

            // ── 3. No duplicate anywhere → create a Lead from the Lead config ──
            MCube_Configuration__c createCfg = leadCfg;
            String  defaultValues = createCfg.Default_Values__c;
            Boolean createIfNF    = createCfg.Create_If_Not_Found__c == true;

            if (!createIfNF) {
                resp.status  = 'NOT_CREATED';
                resp.message = 'No duplicate found and record creation is disabled.' + skippedNote(configErrors);
                writeLog(resp, null);
                return resp;
            }

            Lead ld = new Lead();

            // Apply the config's default values to createable Lead fields.
            // Bad Default_Values__c JSON is NOT swallowed — it propagates to the
            // route() catch so the exact parse error is returned and logged.
            if (String.isNotBlank(defaultValues)) {
                Map<String, Schema.SObjectField> leadFields = Schema.SObjectType.Lead.fields.getMap();
                for (Object o : (List<Object>) JSON.deserializeUntyped(defaultValues)) {
                    Map<String, Object> row = (Map<String, Object>) o;
                    String fieldApi = (String) row.get('field');
                    Object fieldVal = row.get('value');
                    if (String.isBlank(fieldApi)) continue;
                    Schema.SObjectField sf = leadFields.get(fieldApi.toLowerCase());
                    if (sf != null && sf.getDescribe().isCreateable()) {
                        ld.put(sf, fieldVal);
                    }
                }
            }

            // Caller's number → Lead MobilePhone
            ld.MobilePhone = customerNumber;

            // Lead requires LastName + Company — guarantee non-blank
            if (String.isBlank((String) ld.get('LastName'))) ld.put('LastName', 'Unknown');
            if (String.isBlank((String) ld.get('Company')))  ld.put('Company', 'Unknown');

            insert ld;

            resp.relatedToId = ld.Id;
            resp.status      = 'LEAD_CREATED';
            resp.message     = 'No duplicate found; new Lead created.' + skippedNote(configErrors);
            writeLog(resp, null);
            return resp;

        } catch (Exception ex) {
            resp.hasError = true;
            resp.status   = 'ERROR';
            resp.message  = ex.getMessage();
            writeLog(resp, ex);
            return resp;
        }
    }

    // Logging is enabled only when MCube_Config__mdt.Default.Enable_Mcube_Apex_Logs__c is true.
    @TestVisible private static Boolean apexLogsEnabledOverride;   // null in production

    private static Boolean apexLogsEnabled() {
        if (apexLogsEnabledOverride != null) return apexLogsEnabledOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return cfg != null && cfg.Enable_Mcube_Apex_Logs__c == true;
    }

    // ── Logging (self-contained; never throws) ─────────────────────────────
    private static void writeLog(RoutingResponse resp, Exception ex) {
        try {
            // Errors are always logged so failures are never invisible; only
            // success logs are gated by the Enable_Mcube_Apex_Logs__c flag.
            Boolean isError = (resp != null && resp.hasError == true) || ex != null;
            if (!isError && !apexLogsEnabled()) return;
            MCube_Apex_Log__c log = new MCube_Apex_Log__c();
            log.Event_Type__c = EVENT_TYPE;
            log.Class_Name__c = CLASS_NAME;
            log.Call_Type__c  = EVENT_TYPE;
            log.Request__c    = resp.request;
            log.Response__c   = JSON.serialize(resp);
            log.Status__c     = resp.status;
            log.Has_Error__c  = resp.hasError;
            log.Related_To__c = resp.relatedToId;
            if (String.isNotBlank(resp.relatedToId)) {
                log.URL__c = URL.getOrgDomainUrl().toExternalForm() + '/' + resp.relatedToId;
            }
            if (ex != null) {
                log.Error_Message__c = ex.getMessage();
                log.Stack_Trace__c   = ex.getStackTraceString();
                log.Line_Number__c   = extractLineNumber(ex);
            }
            insert log;
        } catch (Exception ignore) {
            System.debug(LoggingLevel.ERROR, 'mcubeCallRouting: failed to insert log: ' + ignore.getMessage());
        }
    }

    // Returns the 10-digit number, or null if it isn't a valid 10-digit number.
    // Strips all non-digits first (handles ( ) - spaces and a leading +), then
    // removes a 91 prefix only when that leaves exactly 10 digits.
    private static String normalizeMobile(String raw) {
        String digits = (raw == null) ? '' : raw.replaceAll('[^0-9]', '');
        if (digits.length() == 12 && digits.startsWith('91')) {
            digits = digits.substring(2);
        }
        return digits.length() == 10 ? digits : null;
    }

    // Lower number = higher priority; blank/non-numeric sorts last.
    private static Integer priorityOf(MCube_Configuration__c cfg) {
        if (cfg == null || String.isBlank(cfg.Priority__c)) return 2147483647;
        try { return Integer.valueOf(cfg.Priority__c.trim()); }
        catch (Exception e) { return 2147483647; }
    }

    // Builds the bind map for a stored duplication-rule SOQL. The caller's number
    // and the landing number each have MCube aliases (callFrom / callTo) so configs
    // authored with MCube field names resolve correctly. Unknown / lookupId_* binds
    // resolve to null (and are skipped by the caller so they can't false-match).
    private static Map<String, Object> buildBinds(String dupRule, String customerNumber, String landingNumber) {
        Map<String, Object> binds = new Map<String, Object>();
        Matcher mm = Pattern.compile(':(\\w+)').matcher(dupRule);
        while (mm.find()) {
            String v = mm.group(1);
            if (v == 'customerNumber' || v == 'callFrom')    binds.put(v, customerNumber);
            else if (v == 'landingNumber' || v == 'callTo')  binds.put(v, landingNumber);
            else                                             binds.put(v, null);  // unknown / lookupId_* binds
        }
        return binds;
    }

    // Runs one config's duplication rule and returns the matched record Id, or null
    // when it finds nothing, has no rule, or is skipped because a bind can't be
    // resolved. A broken rule (SOQL throws) is logged as CONFIG_ERROR and skipped.
    private static Id checkDedup(MCube_Configuration__c cfg, String customerNumber,
                                 String landingNumber, RoutingResponse ctx, List<String> configErrors) {
        if (String.isBlank(cfg.Duplication_rule__c)) return null;   // no rule → nothing to match
        try {
            Map<String, Object> binds = buildBinds(cfg.Duplication_rule__c, customerNumber, landingNumber);

            // A bind we can't resolve (a Lookup :lookupId_* row, or an MCube field
            // not provided on this call) would degrade the rule to "field = null" and
            // match unrelated records — skip instead of returning a false duplicate.
            if (binds.values().contains(null)) return null;

            List<SObject> dups = Database.queryWithBinds(cfg.Duplication_rule__c, binds, AccessLevel.SYSTEM_MODE);
            return dups.isEmpty() ? null : dups[0].Id;
        } catch (Exception cfgEx) {
            // Broken dedup rule ONLY — log this config's exact error and move on.
            RoutingResponse ce = new RoutingResponse();
            ce.request  = ctx.request;
            ce.hasError = true;
            ce.status   = 'CONFIG_ERROR';
            ce.message  = 'Config "' + cfg.Name + '" dedup rule failed: ' + cfgEx.getMessage();
            writeLog(ce, cfgEx);
            configErrors.add(ce.message);
            return null;
        }
    }

    // The active Lead configuration used as the global dedup/creation fallback when a
    // landing number has no Lead config of its own. Picks the lowest Priority__c.
    private static MCube_Configuration__c loadActiveLeadConfig() {
        MCube_Configuration__c best = null;
        Integer bestP = null;
        for (MCube_Configuration__c c : [
            SELECT Id, Name, Priority__c, Source_Object__c, Duplication_rule__c,
                   Default_Values__c, Create_If_Not_Found__c, Is_Active__c
            FROM MCube_Configuration__c
            WHERE Source_Object__c = 'Lead' AND Is_Active__c = true
        ]) {
            Integer p = priorityOf(c);
            if (best == null || p < bestP) { best = c; bestP = p; }
        }
        return best;
    }

    // Suffix noting how many configs were skipped for broken dedup rules (see logs).
    private static String skippedNote(List<String> configErrors) {
        return configErrors.isEmpty()
            ? ''
            : ' (' + configErrors.size() + ' config(s) skipped due to errors — see logs)';
    }

    // Pairs a config with its numeric priority so a list can be sorted
    // ascending (lowest Priority__c = highest priority = checked first).
    private class PrioritizedConfig implements Comparable {
        MCube_Configuration__c cfg;
        Integer priority;
        PrioritizedConfig(MCube_Configuration__c cfg, Integer priority) {
            this.cfg = cfg;
            this.priority = priority;
        }
        public Integer compareTo(Object other) {
            Integer op = ((PrioritizedConfig) other).priority;
            return (priority == op) ? 0 : (priority < op ? -1 : 1);
        }
    }

    private static Integer extractLineNumber(Exception ex) {
        if (ex == null) return null;
        String stackTrace = ex.getStackTraceString();
        if (String.isBlank(stackTrace)) return null;
        Matcher m = Pattern.compile('line\\s+(\\d+)').matcher(stackTrace);
        return m.find() ? Integer.valueOf(m.group(1)) : null;
    }

    global class RoutingResponse {
        global String  relatedToId;
        global Boolean hasError;
        global String  status;
        global String  request;
        global String  message;
    }
}
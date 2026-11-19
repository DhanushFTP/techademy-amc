/****************************************************************
* Class Name   : mcubeCallActivityController
* Company      : Fingertipplus
* Created Date : 29-06-2026
* @author      : Tharun
* Used By      : MCube telephony webhook (REST)
*                POST /services/apexrest/mcubeCallActivityController
* @description : Call-event REST API for MCube telephony. Accepts a
*                McubeConfigDTO payload (the JSON value of the "data"
*                form field) and:
*                  1. creates/updates a Call_Details__c keyed by
*                     Call_Id__c — a connecting/originate event starts the
*                     record; a hangup event with the same Call_Id__c
*                     updates End Time / Status / Recording / Duration; no
*                     matching Call_Id__c creates a new record,
*                  2. resolves the active MCube_Configuration__c from the
*                     landing number (highest Priority__c),
*                  3. when that config's Call_Activity_Mapping is enabled,
*                     creates the mapped record (any object) once per call
*                     and links it on the Call_Details__c,
*                  4. writes an MCube_Apex_Log__c when logging is enabled.
*                Dependencies : McubeConfigDTO, Call_Details__c,
*                MCube_Configuration__c, Mcube_Landing_Number__c,
*                MCube_Apex_Log__c, Custom Metadata MCube_Config__mdt.Default
*                (Enable_Mcube_Apex_Logs__c gates audit logging).
* -----------------------------------------------------------------------------
* Ver | Author             | Date        | Description
* -----------------------------------------------------------------------------
* 1.0 | Tharun             | 29-06-2026  | Initial version
* -----------------------------------------------------------------------------
****************************************************************/
@RestResource(urlMapping='/mcubeCallActivityController/*')
global without sharing class mcubeCallActivityController {

    private static final String CLASS_NAME = 'mcubeCallActivityController';
    private static final String EVENT_TYPE = 'Call Activity';

    // Raised when the request payload is missing or cannot be deserialized,
    // so the exact cause is surfaced instead of a misleading "callId required".
    public class CallActivityException extends Exception {}

    // Entire inbound request, captured once per invocation so the audit log's
    // Request field stores the complete payload rather than a few picked fields.
    // Null when process() is invoked directly (tests) — the DTO is serialized then.
    @TestVisible private static String rawRequest;

    /***************************************************************
    *  Method Name : handleEvent
    *  Parameters  : none
    *  Return      : CallActivityResponse - outcome of processing the event
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: REST entry point (synchronous, @HttpPost). Reads the
    *                McubeConfigDTO from the request and delegates to process().
    *                A blank or malformed payload is surfaced as PAYLOAD_ERROR with
    *                the exact deserialization error (and logged), instead of being
    *                swallowed into a misleading "callId is required".
    ****************************************************************/
    @HttpPost
    global static CallActivityResponse handleEvent() {
        String payload;
        McubeConfigDTO dto;
        try {
            rawRequest = readRawRequest();   // whole payload, for the audit log
            payload    = readDataValue();
            if (String.isBlank(payload)) {
                throw new CallActivityException('No "data" payload found in the request.');
            }
            dto = (McubeConfigDTO) JSON.deserialize(payload, McubeConfigDTO.class);
        } catch (Exception ex) {
            CallActivityResponse resp = new CallActivityResponse();
            resp.hasError = true;
            resp.status   = 'PAYLOAD_ERROR';
            resp.request  = String.isNotBlank(rawRequest) ? rawRequest : payload; // whole raw request for diagnosis
            resp.message  = ex.getMessage();      // exact error
            resp.validJson          = ex.getMessage();            // JSON stage failed — exact error
            resp.callDetailsResult  = 'Skipped (invalid JSON).';
            resp.callActivityResult = 'Skipped (invalid JSON).';
            resp.successSummary     = 'FAILED at JSON parsing: ' + ex.getMessage();
            writeLog(resp, ex);                   // stack trace + line captured in the log
            return resp;
        }
        return process(dto);
    }

    /***************************************************************
    *  Method Name : process
    *  Parameters  : McubeConfigDTO dto - the deserialized call event
    *  Return      : CallActivityResponse - status (LOGGED / LOGGED_WITH_ACTIVITY
    *                / INVALID / ERROR), record ids and a message
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Core flow (synchronous). Validates callId, matches the
    *                Call_Details__c by Call_Id__c (inserts a new record or
    *                updates the existing one), resolves the config, creates the
    *                mapped call-activity once per call, and writes an audit log.
    *                @TestVisible so tests can invoke it directly with a DTO.
    ****************************************************************/
    @TestVisible
    private static CallActivityResponse process(McubeConfigDTO dto) {
        CallActivityResponse resp = new CallActivityResponse();
        resp.hasError = false;
        // Entire payload — the raw inbound request when called over REST, otherwise
        // the full serialized DTO (direct process() calls, e.g. tests).
        resp.request  = String.isNotBlank(rawRequest) ? rawRequest
            : (dto == null ? null : JSON.serialize(dto));

        // Stage 1 — reaching process() means the payload deserialized successfully.
        resp.validJson = 'Received JSON is valid.';

        // ── Validation ─────────────────────────────────────────────────────
        if (dto == null || String.isBlank(dto.callId)) {
            resp.status   = 'INVALID';
            resp.hasError = true;
            resp.message  = 'callId is required.';
            resp.callDetailsResult  = 'Skipped (callId is required).';
            resp.callActivityResult = 'Skipped (callId is required).';
            resp.successSummary     = 'FAILED at validation: callId is required.';
            writeLog(resp, null);
            return resp;
        }

        // Related record + its object type — resolved once and shared by both the
        // Call Details mapping (Stage 2) and the Call Activity config resolution
        // (Stage 3), which selects the config matching this record's object.
        String relatedTo         = dto.relatedTo;
        String relatedObjectType = relatedObjectTypeOf(relatedTo);

        // ── Stage 2 — Call Details creation (upsert first, so it stands alone) ──
        Call_Details__c cd;
        Boolean isNew;
        try {
            List<Call_Details__c> existing = [
                SELECT Id, Call_Activity_Record_Id__c, Call_Activity_Object__c
                FROM Call_Details__c WHERE Call_Id__c = :dto.callId LIMIT 1
            ];
            isNew = existing.isEmpty();
            cd = isNew ? new Call_Details__c(Call_Id__c = dto.callId) : existing[0];
            cd.Call_Id__c = dto.callId; // ensure the unique external Id is set for upsert

            applyCallDetails(cd, dto, relatedTo, relatedObjectType);
            upsert cd Call_Id__c;

            resp.callDetailsId     = cd.Id;
            resp.callDetailsResult = 'Call details ' + (isNew ? 'created' : 'updated')
                + ' successfully (' + cd.Id + ').';
        } catch (Exception ex) {
            resp.hasError           = true;
            resp.status             = 'ERROR';
            resp.message            = ex.getMessage();
            resp.callDetailsResult  = 'FAILED: ' + ex.getMessage();
            resp.callActivityResult = 'Skipped (call details failed).';
            resp.successSummary     = 'FAILED at Call Details creation: ' + ex.getMessage();
            writeLog(resp, ex);
            return resp;                       // stop at first failure
        }

        // ── Stage 3 — Call Activity creation (once per call) ───────────────
        try {
            String activityId = null;
            String skipReason = null;
            // Resolve the config for THIS call's related record based ONLY on the
            // recordId's object type (landing number is not used): a Lead refid → the
            // Lead config, an Account refid → the Account config. No related record or
            // no matching config → no activity (cfg == null).
            MCube_Configuration__c cfg = resolveConfig(relatedObjectType);

            if (cfg == null) {
                skipReason = String.isBlank(relatedObjectType)
                    ? 'the call has no related record to match a configuration.'
                    : 'no active configuration exists for the "' + relatedObjectType + '" object.';
            } else if (String.isBlank(cfg.Call_Activity_Mapping__c)) {
                skipReason = 'call activity capture is not configured for the "' + cfg.Source_Object__c + '" config.';
            } else if (String.isNotBlank(cd.Call_Activity_Record_Id__c)) {
                skipReason = 'activity already created for this call.';
            } else {
                Map<String, Object> mapping =
                    (Map<String, Object>) JSON.deserializeUntyped(cfg.Call_Activity_Mapping__c);
                Boolean enabled = mapping.get('enabled') == true;
                String  obj     = (String) mapping.get('object');

                if (!enabled) {
                    skipReason = 'call activity capture is not enabled for the "' + cfg.Source_Object__c + '" config.';
                } else if (String.isBlank(obj)) {
                    skipReason = 'no object is mapped for call activity.';
                } else if (!Schema.getGlobalDescribe().containsKey(obj)) {
                    skipReason = 'mapped object "' + obj + '" does not exist.';
                } else {
                    SObject rec = createMappedRecord(obj, mapping, dto);
                    if (rec == null) {
                        skipReason = 'no fields are mapped for the "' + obj + '" object.';
                    } else {
                        insert rec;
                        activityId = rec.Id;
                        cd.Call_Activity_Record_Id__c = rec.Id;
                        cd.Call_Activity_Object__c    = obj;
                        update cd;   // link the activity onto the already-upserted call details
                    }
                }
            }

            resp.activityId = activityId;
            if (activityId != null) {
                resp.status             = 'LOGGED_WITH_ACTIVITY';
                resp.message            = 'Call details upserted and activity created.';
                resp.callActivityResult = 'Call activity created successfully (' + activityId + ').';
                resp.successSummary     = 'Call Details: SUCCESS | Call Activity: SUCCESS';
            } else {
                resp.status             = 'LOGGED';
                resp.message            = 'Call details upserted.';
                resp.callActivityResult = 'Skipped (' + skipReason + ')';
                resp.successSummary     = 'Call Details: SUCCESS | Call Activity: SKIPPED (' + skipReason + ')';
            }
            writeLog(resp, null);
            return resp;

        } catch (Exception ex) {
            resp.hasError           = true;
            resp.status             = 'ERROR';
            resp.message            = ex.getMessage();
            resp.callActivityResult = 'FAILED: ' + ex.getMessage();
            resp.successSummary     = 'Call Details: SUCCESS | Call Activity: FAILED (' + ex.getMessage() + ')';
            writeLog(resp, ex);
            return resp;                       // stop; call details already persisted
        }
    }

    /***************************************************************
    *  Method Name : applyCallDetails
    *  Parameters  : Call_Details__c cd        - record being populated
    *                McubeConfigDTO  dto        - source call data
    *                String relatedTo           - the refid (related record Id)
    *                String relatedObjectType   - SObject type of the refid
    *  Return      : void
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Maps present DTO values onto the Call_Details__c (blanks are
    *                skipped so a later hangup never wipes connecting data).
    *                Call_Type__c/Status__c are validated against their restricted
    *                picklists; start/end times are converted IST→GMT; the typed
    *                lookup (Lead/Contact/Account/Case) is set from the refid type.
    ****************************************************************/
    private static void applyCallDetails(Call_Details__c cd, McubeConfigDTO dto,
                                         String relatedTo, String relatedObjectType) {
        String status = dto.callStatus == null ? '' : dto.callStatus.toLowerCase();
        Boolean isConnecting = (status == 'connecting');
        Boolean isOriginate  = (status == 'originate');

        // Call_Type__c / Status__c are RESTRICTED picklists — only set valid values
        // (so connecting/originate don't break Status, while a hangup disposition does set it).
        String callType = dto.callType;
        if (String.isBlank(callType)) {
            if (isConnecting)     callType = 'Inbound';
            else if (isOriginate) callType = 'Outbound';
        }
        setIfValidPicklist(cd, Call_Details__c.Call_Type__c, callType);
        setIfValidPicklist(cd, Call_Details__c.Status__c, dto.callStatus);

        if (String.isNotBlank(dto.customerNumber))  cd.Customer_Number__c   = dto.customerNumber;
        if (String.isNotBlank(dto.agentNumber))     cd.Executive_Number__c  = dto.agentNumber;
        if (String.isNotBlank(dto.recordUrl))       cd.Recording_URL__c     = dto.recordUrl;
        if (String.isNotBlank(dto.landingNumber))   cd.Landing_Number__c    = dto.landingNumber;
        if (String.isNotBlank(dto.groupName))       cd.Source__c            = dto.groupName;

        // Agent / disposition detail — written on connect and refreshed on hangup;
        // blanks are skipped so a later event never wipes an earlier value.
        if (String.isNotBlank(dto.agentStatus))         cd.agentStatus__c         = dto.agentStatus;
        if (String.isNotBlank(dto.customStatus))        cd.customStatus__c        = dto.customStatus;
        if (String.isNotBlank(dto.dispositionStatus))   cd.dispositionStatus__c   = dto.dispositionStatus;
        if (String.isNotBlank(dto.dispositionComments)) cd.dispositionComments__c = dto.dispositionComments;
        if (String.isNotBlank(dto.answeredDuration))    cd.answeredDuration__c    = dto.answeredDuration;
        if (String.isNotBlank(dto.disconnectedBy))      cd.DisconnectedBy__c      = dto.disconnectedBy;
        // isCallback: stringify whatever was received (JSON boolean true/false, a
        // string "true"/"1", blank, or null) and treat "true"/"1" as true; anything
        // else → false. String.valueOf works whether the DTO field is Object or
        // String, so this compiles regardless of that field's declared type.
        String cbVal = String.valueOf(dto.isCallback);
        cd.isCallback__c = ('true'.equalsIgnoreCase(cbVal) || cbVal == '1');

        if (String.isNotBlank(dto.callDuration)) {
            try { cd.Duration__c = Integer.valueOf(dto.callDuration); } catch (Exception e) { /* ignore */ }
        }
        if (String.isNotBlank(dto.startTime)) {
            Datetime st = parseTime(dto.startTime); if (st != null) cd.Start_Time__c = st;
        }
        if (String.isNotBlank(dto.endTime)) {
            Datetime et = parseTime(dto.endTime);   if (et != null) cd.End_Time__c = et;
        }

        if (String.isNotBlank(relatedTo)) {
            // Generic single-field capture for ANY object (guarded so it never throws).
            putRelatedValue(cd, Call_Details__c.Related_Record_Id__c, relatedTo);
            if (String.isNotBlank(relatedObjectType)) {
                putRelatedValue(cd, Call_Details__c.Related_Object_Type__c, relatedObjectType);
                // Typed lookup only for objects that have a dedicated field on Call_Details__c;
                // any other object is already stored in Related_Record_Id__c above.
                if      (relatedObjectType == 'Lead')    cd.Lead__c    = relatedTo;
                else if (relatedObjectType == 'Contact') cd.Contact__c = relatedTo;
                else if (relatedObjectType == 'Account') cd.Account__c = relatedTo;
                else if (relatedObjectType == 'Case')    cd.Case__c    = relatedTo;
            }
        }
    }

    /***************************************************************
    *  Method Name : putRelatedValue
    *  Parameters  : Call_Details__c cd        - record being populated
    *                Schema.SObjectField field - target text/picklist field
    *                String value              - value to store
    *  Return      : void
    *  @author     : Tharun
    *  @description: Sets a text/picklist field defensively so an oversized value
    *                or a restricted picklist can never abort the Call_Details write.
    *                Picklist → only valid values; text → only when it fits the
    *                field length. Keeps the generic related-record capture safe for
    *                objects that have no dedicated lookup field.
    ****************************************************************/
    private static void putRelatedValue(Call_Details__c cd, Schema.SObjectField field, String value) {
        if (String.isBlank(value)) return;
        Schema.DescribeFieldResult d = field.getDescribe();
        if (d.getType() == Schema.DisplayType.Picklist) {
            setIfValidPicklist(cd, field, value);
        } else if (value.length() <= d.getLength()) {
            cd.put(field, value);
        }
    }

    /***************************************************************
    *  Method Name : createMappedRecord
    *  Parameters  : String obj                  - target SObject API name
    *                Map<String,Object> mapping  - Call_Activity_Mapping JSON
    *                McubeConfigDTO dto           - incoming call data
    *  Return      : SObject - the new (un-inserted) record, or null when the
    *                mapping has no 'mappings' list
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Builds the call-activity record from the config mapping. For
    *                each {field,value}: a value naming a DTO field resolves to the
    *                incoming data, otherwise it is treated as a static literal;
    *                only createable fields on the target object are set.
    ****************************************************************/
    private static SObject createMappedRecord(String obj, Map<String, Object> mapping, McubeConfigDTO dto) {
        Object rawMappings = mapping.get('mappings');
        if (!(rawMappings instanceof List<Object>)) return null;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(obj);
        Map<String, Schema.SObjectField> objFields = sot.getDescribe().fields.getMap();
        Map<String, Object> dtoMap = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(dto));

        SObject rec = sot.newSObject();
        for (Object mo : (List<Object>) rawMappings) {
            Map<String, Object> m = (Map<String, Object>) mo;
            String fieldApi = (String) m.get('field');
            Object value    = m.get('value');
            if (String.isBlank(fieldApi)) continue;

            // value that names a DTO field → the incoming data; otherwise static
            Object resolved = (value instanceof String && dtoMap.containsKey((String) value))
                ? dtoMap.get((String) value)
                : value;

            Schema.SObjectField sf = objFields.get(fieldApi.toLowerCase());
            if (sf != null && sf.getDescribe().isCreateable() && resolved != null) {
                rec.put(sf, resolved);
            }
        }
        return rec;
    }

    /***************************************************************
    *  Method Name : resolveConfig
    *  Parameters  : String relatedObjectType - SObject type of the refid record
    *  Return      : MCube_Configuration__c - active config for that object, or null
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Chooses the config that drives Call Activity for THIS call based
    *                ONLY on the related record's object type (from the refid) — the
    *                landing number is NOT considered. Returns the active config whose
    *                Source_Object__c matches relatedObjectType (lowest Priority__c on
    *                ties), or null when the refid is blank or no active config exists
    *                for its object.
    ****************************************************************/
    private static MCube_Configuration__c resolveConfig(String relatedObjectType) {
        System.debug(LoggingLevel.INFO, '[MCube] resolveConfig — relatedObjectType=' + relatedObjectType);
        if (String.isBlank(relatedObjectType)) return null;

        MCube_Configuration__c best = null;
        Integer bestP = null;
        for (MCube_Configuration__c c : [
            SELECT Id, Name, Priority__c, Source_Object__c, Call_Activity_Mapping__c
            FROM MCube_Configuration__c
            WHERE Source_Object__c = :relatedObjectType AND Is_Active__c = true
        ]) {
            Integer p = priorityOf(c);
            if (best == null || p < bestP) { best = c; bestP = p; }
        }
        System.debug(LoggingLevel.INFO, '[MCube] resolveConfig — match: ' + describeCfg(best));
        return best;
    }

    // Compact one-line description of a resolved config for debug logs.
    private static String describeCfg(MCube_Configuration__c c) {
        return (c == null) ? 'none'
            : c.Name + ' (Id=' + c.Id + ', Source=' + c.Source_Object__c
                + ', Priority=' + c.Priority__c
                + ', ActivityMapping=' + c.Call_Activity_Mapping__c + ')';
    }

    /***************************************************************
    *  Method Name : priorityOf
    *  Parameters  : MCube_Configuration__c cfg - the config to rank
    *  Return      : Integer - numeric Priority__c (blank/non-numeric sorts last)
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Parses the text Priority__c into an Integer for ordering.
    ****************************************************************/
    private static Integer priorityOf(MCube_Configuration__c cfg) {
        if (cfg == null || String.isBlank(cfg.Priority__c)) return 2147483647;
        try { return Integer.valueOf(cfg.Priority__c.trim()); }
        catch (Exception e) { return 2147483647; }
    }

    /***************************************************************
    *  Method Name : setIfValidPicklist
    *  Parameters  : SObject rec               - record being populated
    *                Schema.SObjectField field - the (restricted) picklist field
    *                String value              - candidate value
    *  Return      : void
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Sets a restricted-picklist field only when value matches an
    *                active entry (case-insensitive); unexpected values (e.g.
    *                'connecting') are skipped instead of failing the DML.
    ****************************************************************/
    private static void setIfValidPicklist(SObject rec, Schema.SObjectField field, String value) {
        if (String.isBlank(value)) return;
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive() && e.getValue().equalsIgnoreCase(value)) {
                rec.put(field, e.getValue());
                return;
            }
        }
    }

    /***************************************************************
    *  Method Name : relatedObjectTypeOf
    *  Parameters  : String recordId - a Salesforce record Id
    *  Return      : String - the SObject API name, or null if not a valid Id
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Derives the SObject type (Lead/Contact/Account/Case/…) from
    *                the refid so the right typed lookup can be populated.
    ****************************************************************/
    private static String relatedObjectTypeOf(String recordId) {
        if (String.isBlank(recordId)) return null;
        try { return Id.valueOf(recordId).getSObjectType().getDescribe().getName(); }
        catch (Exception e) { return null; }
    }

    /***************************************************************
    *  Method Name : parseTime
    *  Parameters  : String s - an MCube date-time string (local IST)
    *  Return      : Datetime - the value converted to GMT, or null on parse error
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: MCube sends local IST date-times; parse and subtract 5:30 for
    *                GMT storage, matching the existing call-logging behaviour.
    *                No longer swallows parse errors — an unparseable value throws
    *                and surfaces via the process() catch as ERROR + exact message.
    ****************************************************************/
    private static Datetime parseTime(String s) {
        return Datetime.valueOf(s.replace('T', ' ').substringBefore('.'))
                       .addHours(-5).addMinutes(-30);
    }

    /***************************************************************
    *  Method Name : readRawRequest
    *  Parameters  : none
    *  Return      : String - the complete inbound request payload, or null
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Captures the ENTIRE incoming request so the audit log's
    *                Request field holds the whole payload (raw JSON body,
    *                form-urlencoded/multipart body as received, or — when the call
    *                carries no body — the full query-parameter map). Never throws;
    *                an unreadable body degrades to the params map / null.
    ****************************************************************/
    private static String readRawRequest() {
        try {
            RestRequest req = RestContext.request;
            if (req == null) return null;
            String body = (req.requestBody != null) ? req.requestBody.toString() : null;
            if (String.isNotBlank(body)) return body;
            if (req.params != null && !req.params.isEmpty()) return JSON.serialize(req.params);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, CLASS_NAME + ': failed to read raw request: ' + e.getMessage());
        }
        return null;
    }

    /***************************************************************
    *  Method Name : readDataValue
    *  Parameters  : none
    *  Return      : String - the JSON value of the "data" field, or null
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Extracts the "data" value from the request, supporting a query
    *                parameter, a raw JSON body, a multipart/form-data part, or an
    *                x-www-form-urlencoded body. (Note: Apex REST itself rejects
    *                multipart/form-data with 415 before this runs.)
    ****************************************************************/
    private static String readDataValue() {
        RestRequest req = RestContext.request;
        if (req == null) return null;

        // 'data' as a query/auto-parsed param
        if (req.params != null && String.isNotBlank(req.params.get('data'))) {
            return req.params.get('data');
        }

        String body = (req.requestBody != null) ? req.requestBody.toString() : null;
        if (String.isBlank(body)) return null;

        String trimmed = body.trim();
        if (trimmed.startsWith('{')) return trimmed;          // raw JSON body

        if (body.contains('name="data"')) {                    // multipart/form-data
            Integer i = body.indexOf('name="data"');
            Integer skip = 4;
            Integer s = body.indexOf('\r\n\r\n', i);
            if (s < 0) { s = body.indexOf('\n\n', i); skip = 2; }
            if (s < 0) return null;
            s += skip;
            Integer e = body.indexOf('\r\n--', s);
            if (e < 0) e = body.indexOf('\n--', s);
            if (e < 0) e = body.length();
            return body.substring(s, e).trim();
        }

        // x-www-form-urlencoded: data=<urlencoded json>&...
        for (String pair : body.split('&')) {
            List<String> kv = pair.split('=', 2);
            if (kv.size() == 2 && safeUrlDecode(kv[0]) == 'data') return safeUrlDecode(kv[1]);
        }
        return null;
    }

    /***************************************************************
    *  Method Name : safeUrlDecode
    *  Parameters  : String s - a possibly URL-encoded value
    *  Return      : String - the decoded value (original string on failure)
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Null-safe UTF-8 URL decode used when parsing form-urlencoded
    *                bodies.
    ****************************************************************/
    private static String safeUrlDecode(String s) {
        try { return EncodingUtil.urlDecode(s, 'UTF-8'); }
        catch (Exception e) { return s; }
    }

    // ── Logging — gated by MCube_Config__mdt.Default.Enable_Mcube_Apex_Logs__c ──
    @TestVisible private static Boolean apexLogsEnabledOverride;

    /***************************************************************
    *  Method Name : apexLogsEnabled
    *  Parameters  : none
    *  Return      : Boolean - true when Apex audit logging is enabled
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Returns the test override when set, otherwise the
    *                MCube_Config__mdt.Default.Enable_Mcube_Apex_Logs__c flag.
    ****************************************************************/
    private static Boolean apexLogsEnabled() {
        if (apexLogsEnabledOverride != null) return apexLogsEnabledOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return cfg != null && cfg.Enable_Mcube_Apex_Logs__c == true;
    }

    /***************************************************************
    *  Method Name : writeLog
    *  Parameters  : CallActivityResponse resp - the response to record
    *                Exception ex               - the caught error, or null
    *  Return      : void
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Inserts an MCube_Apex_Log__c (request/response/status and, on
    *                failure, error message + stack trace + line) when logging is
    *                enabled. Never throws — logging failures are swallowed so they
    *                cannot break the call-event processing.
    ****************************************************************/
    private static void writeLog(CallActivityResponse resp, Exception ex) {
        try {
            // Errors are always logged so failures are never invisible; only
            // success logs are gated by the Enable_Mcube_Apex_Logs__c flag.
            Boolean isError = (resp != null && resp.hasError == true) || ex != null;
            if (!isError && !apexLogsEnabled()) return;
            MCube_Apex_Log__c log = new MCube_Apex_Log__c();
            log.Event_Type__c = EVENT_TYPE;
            log.Class_Name__c = CLASS_NAME;
            log.Call_Type__c  = EVENT_TYPE;
            log.Request__c    = clip(resp.request);   // full payload, capped at the field max
            log.Response__c   = clip(JSON.serialize(resp));
            log.Status__c     = resp.status;
            log.Has_Error__c  = resp.hasError;
            log.Related_To__c = resp.callDetailsId;

            // Per-stage outcomes (Long Text Area; clipped so the insert can't fail on length)
            log.Valid_Json_Received__c    = clip(resp.validJson);
            log.Call_Details_Creation__c  = clip(resp.callDetailsResult);
            log.Call_Activity_Creation__c = clip(resp.callActivityResult);
            log.Success__c                = clip(resp.successSummary);
            if (ex != null) {
                log.Error_Message__c = ex.getMessage();
                log.Stack_Trace__c   = ex.getStackTraceString();
                log.Line_Number__c   = extractLineNumber(ex);
            }
            insert log;
        } catch (Exception ignore) {
            System.debug(LoggingLevel.ERROR, 'mcubeCallActivityController: failed to insert log: ' + ignore.getMessage());
        }
    }

    /***************************************************************
    *  Method Name : extractLineNumber
    *  Parameters  : Exception ex - the caught exception
    *  Return      : Integer - the first "line N" in the stack trace, or null
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: Pulls the first line number out of the exception stack trace
    *                for the audit log.
    ****************************************************************/
    private static Integer extractLineNumber(Exception ex) {
        if (ex == null) return null;
        String stackTrace = ex.getStackTraceString();
        if (String.isBlank(stackTrace)) return null;
        Matcher m = Pattern.compile('line\\s+(\\d+)').matcher(stackTrace);
        return m.find() ? Integer.valueOf(m.group(1)) : null;
    }

    // Caps a stage message at the fields' Long Text Area max (131,072) so a
    // writeLog insert can never fail on field length.
    private static String clip(String s) {
        if (s == null) return null;
        return s.length() > 131070 ? s.substring(0, 131070) : s;
    }

    /***************************************************************
    *  Class Name  : CallActivityResponse
    *  @author     : Tharun
    *  Date        : 29-06-2026
    *  @description: REST response wrapper returned to MCube — outcome flag,
    *                status, message, the echoed request and the created/updated
    *                record ids.
    ****************************************************************/
    global class CallActivityResponse {
        global Boolean hasError;
        global String  status;          // LOGGED | LOGGED_WITH_ACTIVITY | INVALID | ERROR | PAYLOAD_ERROR
        global String  message;
        global String  request;
        global String  callDetailsId;
        global String  activityId;

        // Per-stage outcomes mirrored onto MCube_Apex_Log__c stage fields
        global String  validJson;           // → Valid_Json_Received__c
        global String  callDetailsResult;   // → Call_Details_Creation__c
        global String  callActivityResult;  // → Call_Activity_Creation__c
        global String  successSummary;      // → Success__c
    }
}
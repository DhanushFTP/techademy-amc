/**
 * ============================================================================
 * MCubeSoftphoneController
 * ============================================================================
 *
 * Controller for the MCube Softphone CTI adapter (Visualforce page).
 *
 * Responsibilities:
 *   1. Build the authenticated MCube widget iframe URL for the softphone panel.
 *   2. Search for existing records by phone number on incoming/outbound calls.
 *   3. Auto-create records when no match is found (delegated to mcubeCallRouting).
 *   4. Log call activity as Task records and Call_Details__c records.
 *   5. Provide phone lookup for the universal Click2Call Aura Quick Action.
 *   6. Log all operations to MCube_Apex_Log__c for debugging and audit.
 *
 * Configuration:
 *   - MCube_Config__mdt        → Stores the MCube auth token.
 *   - MCube_Configuration__c   → Landing-number routing + dedup rules, read via
 *                                mcubeCallRouting (not by this class directly).
 *   - MCube_Apex_Log__c        → Centralized Apex operation logs.
 *
 * @author  MCube Integration Team
 * @since   2026-03-27
 * @see     mcubeSoftphoneCTI (Visualforce page)
 * @see     mcubeClick2Call (Aura quick action component)
 */
public with sharing class MCubeSoftphoneController {

    // ── Constants ────────────────────────────────────────────────────────

    private static final String MCUBE_WIDGET_BASE_URL =
        'https://mcube.vmc.in/salesforce-widget/Phone/auth';

    private static final String CLASS_NAME = 'MCubeSoftphoneController';

    // ── Properties (exposed to Visualforce) ──────────────────────────────

    /** Authenticated MCube iframe URL. Empty string if user is not CTI-enabled. */
    public String mcubeIframeUrl { get; private set; }

    /** Trusted origin for postMessage validation (e.g. https://mcube.vmc.in). */
    public String mcubeOrigin { get; private set; }

    // ── Constructor ──────────────────────────────────────────────────────

    /**
     * Builds the MCube widget URL using the current user's CTI credentials.
     * Non-CTI users receive an empty URL (the VF page shows a "not enabled" message).
     */
    public MCubeSoftphoneController() {
        this.mcubeOrigin = 'https://mcube.vmc.in';

        User currentUser = [
            SELECT Id, CTI_User__c, Mcube_Username__c
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];

        if (currentUser.CTI_User__c && String.isNotBlank(currentUser.Mcube_Username__c)) {
            String authToken = configAuthToken();

            this.mcubeIframeUrl = MCUBE_WIDGET_BASE_URL
                + '?username=' + EncodingUtil.urlEncode(currentUser.Mcube_Username__c, 'UTF-8')
                + '&auth_token=' + EncodingUtil.urlEncode(authToken == null ? '' : authToken, 'UTF-8');
            System.debug(this.mcubeIframeUrl);
        } else {
            this.mcubeIframeUrl = '';
        }
    }

    // ── Logging Helpers ──────────────────────────────────────────────────

    /**
     * Creates an MCube_Apex_Log__c record for audit and debugging.
     * Self-protected: logging failures never crash the calling method.
     *
     * @param  request       The input/request payload.
     * @param  response      The output/response payload.
     * @param  url           The endpoint or context URL.
     * @param  status        'Success' or 'Error'.
     * @param  errorMessage  Error details (null for success).
     * @param  lineNumber    Source line number where error occurred (null for success).
     * @param  className     The Apex class name.
     * @param  callType      Inbound/Outbound/Internal/Click2Call.
     */
    private static void insertLog(String request, String response, String url,
                                   String status, String errorMessage,
                                   Integer lineNumber, String className,
                                   String callType) {
        try {
            MCube_Apex_Log__c log = new MCube_Apex_Log__c();
            log.Request__c       = request;
            log.Response__c      = response;
            log.URL__c           = url;
            log.Status__c        = status;
            log.Error_Message__c = errorMessage;
            log.Line_Number__c   = lineNumber;
            log.Class_Name__c    = className;
            log.Call_Type__c     = callType;
            insert log;
        } catch (Exception ex) {
            // Logging failure must never block the main operation
            System.debug(LoggingLevel.ERROR,
                'MCube: Failed to insert apex log: ' + ex.getMessage());
        }
    }

    /**
     * Extracts the line number from an exception's stack trace.
     *
     * @param  ex  The caught exception.
     * @return     The line number as Integer, or null if not parseable.
     */
    private static Integer extractLineNumber(Exception ex) {
        if (ex == null) return null;
        String stackTrace = ex.getStackTraceString();
        if (String.isBlank(stackTrace)) return null;

        // Pattern: "line 42, column 1"
        Pattern p = Pattern.compile('line\\s+(\\d+)');
        Matcher m = p.matcher(stackTrace);
        if (m.find()) {
            return Integer.valueOf(m.group(1));
        }
        return null;
    }

    /**
     * Helper to build a consistent JSON response for searchOrCreateFromCall.
     *
     * @param  recordId      The Salesforce record ID (null if no record).
     * @param  objectApiName The SObject API name (e.g. 'Lead', 'Case').
     * @param  created       True if a new record was inserted.
     * @param  error         Error message, or null if successful.
     * @return               Serialized JSON string.
     */
    private static String buildResponse(String recordId, String objectApiName,
                                         Boolean created, String error) {
        Map<String, Object> response = new Map<String, Object>{
            'recordId'      => recordId,
            'objectApiName' => objectApiName,
            'created'       => created
        };
        if (String.isNotBlank(error)) {
            response.put('error', error);
        }
        return JSON.serialize(response);
    }

    // ── Remote Actions (called from Visualforce JavaScript) ──────────────

    /**
     * Searches for a Contact, Lead, or Account by phone number using SOSL.
     * Used as a fallback when routing resolves no record for the landing number.
     *
     * Priority order: Contact → Lead → Account (first match wins).
     *
     * @param  phoneNumber  Caller's phone number (any format).
     * @return              Salesforce record ID of the first match, or 'NOT_FOUND'.
     */
    @RemoteAction
    public static String searchByPhone(String phoneNumber) {
        if (String.isBlank(phoneNumber)) {
            return 'NOT_FOUND';
        }

        String sanitized = phoneNumber.replaceAll('[^0-9+]', '');

        List<List<SObject>> results = [
            FIND :sanitized
            IN PHONE FIELDS
            RETURNING
                Contact(Id, Name, Phone ORDER BY LastModifiedDate DESC LIMIT 1),
                Lead(Id, Name, Phone ORDER BY LastModifiedDate DESC LIMIT 1),
                Account(Id, Name, Phone ORDER BY LastModifiedDate DESC LIMIT 1)
        ];

        for (List<SObject> sObjList : results) {
            if (!sObjList.isEmpty()) {
                return sObjList[0].Id;
            }
        }

        return 'NOT_FOUND';
    }

    /**
     * Main inbound call handler. Resolves (or creates) the record for a call by
     * delegating to {@link mcubeCallRouting}, which owns landing-number routing
     * against the active MCube_Configuration__c records and their dedup rules.
     *
     * Flow:
     *   1. Blank caller number → error response.
     *   2. Delegate to mcubeCallRouting.route(); a routing error is surfaced as-is.
     *   3. Routing matched or created a record → return it (created is true only
     *      when routing reports LEAD_CREATED).
     *   4. Routing resolved nothing (no config / creation disabled) → fall back to
     *      a generic SOSL search via searchByPhone().
     *
     * @param  callerPhoneNumber  The caller's phone number.
     * @param  landingNumber      The DID/landing number from the MCube payload.
     * @return  JSON: {"recordId":"...", "objectApiName":"...", "created":true/false}
     */
    @RemoteAction
    public static String searchOrCreateFromCall(String callerPhoneNumber, String landingNumber) {
        String requestPayload = 'callerPhone=' + callerPhoneNumber + ', landingNumber=' + landingNumber;

        try {
            if (String.isBlank(callerPhoneNumber)) {
                String resp = buildResponse(null, null, false, 'Phone number is blank');
                insertLog(requestPayload, resp, null, 'Error', 'Phone number is blank', null, CLASS_NAME, 'Inbound');
                return resp;
            }

            // Step 1: Delegate routing (match + optional create) to mcubeCallRouting,
            // which owns the MCube_Configuration__c landing-number model.
            mcubeCallRouting.RoutingResponse routingResp =
                mcubeCallRouting.route(callerPhoneNumber, landingNumber);

            if (routingResp.hasError) {
                String resp = buildResponse(null, null, false, routingResp.message);
                insertLog(requestPayload, resp, null, 'Error', routingResp.message, null, CLASS_NAME, 'Inbound');
                return resp;
            }

            // Step 2: Routing matched an existing record or created a new one
            if (String.isNotBlank(routingResp.relatedToId)) {
                String objName = Id.valueOf(routingResp.relatedToId)
                                   .getSObjectType().getDescribe().getName();
                Boolean created = (routingResp.status == 'LEAD_CREATED');
                String resp = buildResponse(routingResp.relatedToId, objName, created, null);
                insertLog(requestPayload, resp, null, 'Success', null, null, CLASS_NAME, 'Inbound');
                return resp;
            }

            // Step 3: Routing resolved nothing (no config for the landing number, or
            // creation disabled) → fall back to a generic SOSL search.
            String existingId = searchByPhone(callerPhoneNumber);
            if (existingId != 'NOT_FOUND') {
                String objName = Id.valueOf(existingId).getSObjectType().getDescribe().getName();
                String resp = buildResponse(existingId, objName, false, null);
                insertLog(requestPayload, resp, null, 'Success', null, null, CLASS_NAME, 'Inbound');
                return resp;
            }

            String resp = buildResponse(null, null, false, null);
            insertLog(requestPayload, resp, null, 'Success',
                'Routing status ' + routingResp.status + ' and no SOSL match',
                null, CLASS_NAME, 'Inbound');
            return resp;

        } catch (Exception ex) {
            String resp = buildResponse(null, null, false, 'Failed to resolve record: ' + ex.getMessage());
            insertLog(requestPayload, resp, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, 'Inbound');
            return resp;
        }
    }

    /**
     * Persists a raw MCube event to MCube_Apex_Log__c for audit / debugging.
     * Called from the VF page for EVERY MCUBE envelope received, so every
     * telephony event is captured server-side regardless of which screen-pop
     * path it later takes (or whether it routes at all).
     *
     * Fire-and-forget: failures never surface to the page (insertLog swallows
     * its own errors).
     *
     * @param  action     The envelope Action (e.g. 'OpenPanel').
     * @param  callType   The Data.type (e.g. 'outbound_call', 'inbound_call').
     * @param  eventJson  The full envelope serialized as JSON.
     */
    @RemoteAction
    public static void logMcubeEvent(String action, String callType, String eventJson) {
        System.debug(LoggingLevel.INFO,
            '[MCube] EVENT — action=' + action + ', type=' + callType + ', payload=' + eventJson);
        insertLog(
            eventJson,
            null,
            null,
            String.isNotBlank(action) ? 'Event - ' + action : 'Event',
            null,
            null,
            CLASS_NAME,
            String.isNotBlank(callType) ? callType : 'Event'
        );
    }

    /**
     * Resolves the Salesforce record for a telephony "OpenPanel" event by
     * delegating to the {@link mcubeCallRouting} REST service.
     *
     * Called from the VF page when an MCube { Type:'MCUBE', Action:'OpenPanel' }
     * envelope arrives WITHOUT an echoed record id (refid). The routing service
     * resolves the configuration from the landing number (DID), runs its
     * duplication rule, and returns a matched record id — creating a Lead when
     * the config allows it.
     *
     * @param  customerNumber  The customer's phone number from the call payload.
     * @param  landingNumber   The DID/landing number (Data.didId) from the payload.
     * @return  JSON serialization of mcubeCallRouting.RoutingResponse, e.g.
     *          {"relatedToId":"00Q...","hasError":false,"status":"DUPLICATE_FOUND", ...}
     */
    @RemoteAction
    public static String routeCall(String customerNumber, String landingNumber) {
        String requestPayload = 'customerNumber=' + customerNumber + ', landingNumber=' + landingNumber;
        System.debug(LoggingLevel.INFO,
            '[MCube] routeCall TRIGGERED — ' + requestPayload);

        try {
            mcubeCallRouting.RoutingResponse routingResp =
                mcubeCallRouting.route(customerNumber, landingNumber);

            String resp = JSON.serialize(routingResp);
            System.debug(LoggingLevel.INFO,
                '[MCube] routeCall RESULT — status=' + routingResp.status
                + ', relatedToId=' + routingResp.relatedToId
                + ', hasError=' + routingResp.hasError
                + ', message=' + routingResp.message);

            insertLog(requestPayload, resp, null,
                routingResp.hasError ? 'Error' : 'Success',
                routingResp.hasError ? routingResp.message : null,
                null, CLASS_NAME, 'Outbound');
            return resp;

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                '[MCube] routeCall EXCEPTION — ' + ex.getMessage()
                + '\n' + ex.getStackTraceString());
            insertLog(requestPayload, null, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, 'Outbound');
            return JSON.serialize(new Map<String, Object>{
                'relatedToId' => null,
                'hasError'    => true,
                'status'      => 'ERROR',
                'message'     => ex.getMessage()
            });
        }
    }

    /**
     * Retrieves the phone number and display name for any Salesforce record.
     * Used by the universal Click2Call Aura Quick Action.
     *
     * Phone field resolution:
     *   1. Read the standard 'Phone' field when the object has one.
     *   2. Fall back to 'MobilePhone' if the primary phone field is empty.
     *
     * @param  recordId  The Salesforce record ID to look up.
     * @return  JSON: {"phone":"...", "name":"...", "objectType":"..."}
     */
    @AuraEnabled(cacheable=true)
    public static String getRecordPhone(Id recordId) {
        String requestPayload = 'recordId=' + recordId;

        try {
            if (recordId == null) {
                String resp = JSON.serialize(new Map<String, Object>{
                    'phone' => null, 'name' => null, 'objectType' => null,
                    'error' => 'Record ID is null'
                });
                insertLog(requestPayload, resp, null, 'Error', 'Record ID is null', null, CLASS_NAME, 'Click2Call');
                return resp;
            }

            String objectApiName = recordId.getSObjectType().getDescribe().getName();
            Schema.DescribeSObjectResult objDescribe = recordId.getSObjectType().getDescribe();

            // Standard phone field; MobilePhone is used as a fallback below
            String phoneFieldApiName = 'Phone';

            // Build dynamic query
            Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();
            List<String> queryFields = new List<String>{ 'Id' };

            if (fieldMap.containsKey(phoneFieldApiName.toLowerCase())) {
                queryFields.add(phoneFieldApiName);
            }

            if (fieldMap.containsKey('name')) {
                queryFields.add('Name');
            } else if (fieldMap.containsKey('casenumber')) {
                queryFields.add('CaseNumber');
            }

            Boolean hasMobile = false;
            if (fieldMap.containsKey('mobilephone') && !phoneFieldApiName.equalsIgnoreCase('MobilePhone')) {
                queryFields.add('MobilePhone');
                hasMobile = true;
            }

            String query = 'SELECT ' + String.join(queryFields, ', ')
                         + ' FROM ' + String.escapeSingleQuotes(objectApiName)
                         + ' WHERE Id = :recordId LIMIT 1';

            List<SObject> records = Database.query(query);
            if (records.isEmpty()) {
                String resp = JSON.serialize(new Map<String, Object>{
                    'phone' => null, 'name' => null, 'objectType' => objectApiName,
                    'error' => 'Record not found'
                });
                insertLog(requestPayload, resp, null, 'Error', 'Record not found', null, CLASS_NAME, 'Click2Call');
                return resp;
            }

            SObject rec = records[0];
            String phone = (String) rec.get(phoneFieldApiName);

            if (String.isBlank(phone) && hasMobile) {
                phone = (String) rec.get('MobilePhone');
            }

            String recName = null;
            if (fieldMap.containsKey('name')) {
                recName = (String) rec.get('Name');
            } else if (fieldMap.containsKey('casenumber')) {
                recName = (String) rec.get('CaseNumber');
            }

            String resp = JSON.serialize(new Map<String, Object>{
                'phone' => phone,
                'name' => recName,
                'objectType' => objectApiName
            });
            insertLog(requestPayload, resp, null, 'Success', null, null, CLASS_NAME, 'Click2Call');
            return resp;

        } catch (Exception ex) {
            String resp = JSON.serialize(new Map<String, Object>{
                'phone' => null, 'name' => null, 'objectType' => null,
                'error' => ex.getMessage()
            });
            insertLog(requestPayload, resp, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, 'Click2Call');
            return resp;
        }
    }

    /**
     * Retrieves ALL phone-type field values from a record.
     * Used by the Aura Click2Call component to populate the phone number dropdown.
     *
     * Discovery logic:
     *   1. Scans all fields on the record's object for DisplayType.PHONE.
     *   2. Returns a deduplicated list of non-blank phone values.
     *
     * @param  recordId  The Salesforce record ID.
     * @return           List of phone number strings found on the record.
     */
    @AuraEnabled
    public static List<String> getPhoneNumbers(Id recordId) {
        String requestPayload = 'recordId=' + recordId;

        try {
            if (recordId == null) {
                insertLog(requestPayload, '[]', null, 'Error', 'Record ID is null', null, CLASS_NAME, 'Click2Call');
                return new List<String>();
            }

            String objectApiName = recordId.getSObjectType().getDescribe().getName();
            Schema.DescribeSObjectResult objDescribe = recordId.getSObjectType().getDescribe();
            Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();

            // Collect all Phone-type field API names
            Set<String> phoneFieldNames = new Set<String>();
            for (String fieldName : fieldMap.keySet()) {
                Schema.DescribeFieldResult fdr = fieldMap.get(fieldName).getDescribe();
                if (fdr.getType() == Schema.DisplayType.PHONE && fdr.isAccessible()) {
                    phoneFieldNames.add(fdr.getName());
                }
            }

            if (phoneFieldNames.isEmpty()) {
                insertLog(requestPayload, '[]', null, 'Success', 'No phone fields found', null, CLASS_NAME, 'Click2Call');
                return new List<String>();
            }

            // Query all phone fields in one SOQL
            String query = 'SELECT ' + String.join(new List<String>(phoneFieldNames), ', ')
                         + ' FROM ' + String.escapeSingleQuotes(objectApiName)
                         + ' WHERE Id = :recordId LIMIT 1';

            List<SObject> records = Database.query(query);
            if (records.isEmpty()) {
                insertLog(requestPayload, '[]', null, 'Error', 'Record not found', null, CLASS_NAME, 'Click2Call');
                return new List<String>();
            }

            // Extract non-blank, deduplicated phone values
            SObject rec = records[0];
            Set<String> uniquePhones = new Set<String>();
            List<String> result = new List<String>();

            for (String fieldName : phoneFieldNames) {
                String val = (String) rec.get(fieldName);
                if (String.isNotBlank(val) && !uniquePhones.contains(val)) {
                    uniquePhones.add(val);
                    result.add(val);
                }
            }

            insertLog(requestPayload, JSON.serialize(result), null, 'Success', null, null, CLASS_NAME, 'Click2Call');
            return result;

        } catch (Exception ex) {
            insertLog(requestPayload, '[]', null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, 'Click2Call');
            return new List<String>();
        }
    }

    /**
     * Creates a Task record to log a completed call.
     * Called from the VF page as a fallback when sforce.opencti.saveLog() fails.
     *
     * @param  whoId        Contact or Lead ID (Task.WhoId).
     * @param  whatId       Account or Opportunity ID (Task.WhatId).
     * @param  callType     'Inbound' or 'Outbound'.
     * @param  duration     Call duration in seconds.
     * @param  subject      Task subject line.
     * @param  description  Call notes or description.
     * @return              The ID of the newly created Task record.
     */
    @RemoteAction
    public static String logCallActivity(
        String whoId,
        String whatId,
        String callType,
        Integer duration,
        String subject,
        String description
    ) {
        String requestPayload = 'whoId=' + whoId + ', callType=' + callType + ', duration=' + duration;

        try {
            Task callLog = new Task();
            callLog.Subject              = String.isNotBlank(subject) ? subject : callType + ' Call';
            callLog.Description          = description;
            callLog.CallType             = callType;
            callLog.CallDurationInSeconds = duration;
            callLog.Status               = 'Completed';
            callLog.Priority             = 'Normal';
            callLog.ActivityDate         = Date.today();
            callLog.TaskSubtype          = 'Call';

            if (String.isNotBlank(whoId)) {
                callLog.WhoId = whoId;
            }
            if (String.isNotBlank(whatId)) {
                callLog.WhatId = whatId;
            }

            insert callLog;

            insertLog(requestPayload, callLog.Id, null, 'Success', null, null, CLASS_NAME, callType);
            return callLog.Id;

        } catch (Exception ex) {
            insertLog(requestPayload, null, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, callType);
            throw ex;
        }
    }

    /**
     * Creates or updates a Call_Details__c record with full call metadata.
     * Uses upsert on Call_Id__c to prevent duplicate records.
     *
     * Lookup resolution:
     *   - Sets Lead__c, Contact__c, Account__c, or Case__c based on relatedObjectType.
     *   - Always stores relatedRecordId + relatedObjectType for universal tracking.
     *
     * @param  callId             Unique MCube call identifier.
     * @param  callType           'Inbound', 'Outbound', or 'Internal'.
     * @param  startTimeISO       Call start time (ISO 8601 from JavaScript).
     * @param  endTimeISO         Call end time (ISO 8601 from JavaScript).
     * @param  duration           Call duration in seconds.
     * @param  customerNumber     Customer's phone number.
     * @param  executiveNumber    Agent's phone number or extension.
     * @param  recordingUrl       URL to the call recording on MCube.
     * @param  parentId           Parent call ID (for transfers/conferences).
     * @param  status             Call status (Completed, Missed, etc.).
     * @param  source             Call source.
     * @param  subSource          Call sub-source.
     * @param  leadId             Lead record ID (direct, for backward compatibility).
     * @param  relatedRecordId    Universal related record ID (any object).
     * @param  relatedObjectType  SObject API name of the related record.
     * @param  landingNumber      DID/landing number the call came in on.
     * @return                    The ID of the upserted Call_Details__c record.
     */
    @RemoteAction
    public static String logCallDetails(
        String callId,
        String callType,
        String startTimeISO,
        String endTimeISO,
        Integer duration,
        String customerNumber,
        String executiveNumber,
        String recordingUrl,
        String parentId,
        String status,
        String source,
        String subSource,
        String leadId,
        String relatedRecordId,
        String relatedObjectType,
        String landingNumber
    ) {
        String requestPayload = 'callId=' + callId + ', callType=' + callType
            + ', customerNumber=' + customerNumber + ', relatedObjectType=' + relatedObjectType;

        try {
            Call_Details__c cd = new Call_Details__c();

            // Core call fields
            cd.Call_Id__c          = callId;
            cd.Call_Type__c        = callType;
            cd.Duration__c         = duration;
            cd.Customer_Number__c  = customerNumber;
            cd.Executive_Number__c = executiveNumber;
            cd.Recording_URL__c    = recordingUrl;
            cd.Parent_Id__c        = parentId;
            cd.Status__c           = String.isNotBlank(status) ? status : 'Completed';
            cd.Source__c           = source;
            cd.Sub_Source__c       = subSource;

            // Parse ISO 8601 datetime strings from JavaScript
            if (String.isNotBlank(startTimeISO)) {
                cd.Start_Time__c = DateTime.valueOf(
                    startTimeISO.replace('T', ' ').substringBefore('.')
                );
            }
            if (String.isNotBlank(endTimeISO)) {
                cd.End_Time__c = DateTime.valueOf(
                    endTimeISO.replace('T', ' ').substringBefore('.')
                );
            }

            // Direct Lead link (backward compatibility)
            if (String.isNotBlank(leadId)) {
                cd.Lead__c = leadId;
            }

            // Universal related record tracking
            if (String.isNotBlank(relatedRecordId)) {
                cd.Related_Record_Id__c = relatedRecordId;
            }
            if (String.isNotBlank(relatedObjectType)) {
                cd.Related_Object_Type__c = relatedObjectType;
            }
            if (String.isNotBlank(landingNumber)) {
                cd.Landing_Number__c = landingNumber;
            }

            // Set the appropriate lookup based on object type
            if (String.isNotBlank(relatedRecordId) && String.isNotBlank(relatedObjectType)) {
                if (relatedObjectType == 'Lead' && String.isBlank(leadId)) {
                    cd.Lead__c = relatedRecordId;
                } else if (relatedObjectType == 'Contact') {
                    cd.Contact__c = relatedRecordId;
                } else if (relatedObjectType == 'Account') {
                    cd.Account__c = relatedRecordId;
                } else if (relatedObjectType == 'Case') {
                    cd.Case__c = relatedRecordId;
                }
            }

            upsert cd Call_Id__c;

            insertLog(requestPayload, cd.Id, null, 'Success', null, null, CLASS_NAME, callType);
            return cd.Id;

        } catch (Exception ex) {
            insertLog(requestPayload, null, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, callType);
            throw ex;
        }
    }

    // ────────────────────────────────────────────────────────────────────
    //  CLICK-TO-CALL — Direct MCube outbound API callout
    // ────────────────────────────────────────────────────────────────────

    /**
     * Initiates an outbound call through MCube by calling the MCube outbound
     * API directly (no softphone-widget round trip). Ported from the MCube 1.0
     * clickToCall webservice and mapped to the 2.0 configuration model.
     *
     *   exenumber  = running user's MobilePhone (fallback Phone)
     *   custnumber = the phone number the agent clicked (customerNumber)
     *   refid      = recordId
     *
     * The base endpoint is read from MCube_Config__mdt.Default.Click_To_Call_URL__c;
     * if that field is blank the call is not attempted and an error is returned.
     *
     * The request format is derived from the configured endpoint host (not the
     * Version__c flag):
     *   api.mcube.com → POST multipart/form-data with Authorization: Bearer
     *                   &lt;New_Auth_Token__c&gt;
     *   mcube.vmc.in  → POST query-string params &lt;Click_To_Call_URL__c&gt;?apikey=
     *                   &lt;API_Key__c&gt;&amp;exenumber=...&amp;url=&lt;CallBack_URL__c&gt;/calland...
     *
     * @param  recordId        The record the call is placed from (refid).
     * @param  customerNumber   The customer number to dial (the clicked value).
     * @return ClickToCallResult { success, message }
     */
    @AuraEnabled
    public static ClickToCallResult clickToCall(Id recordId, String customerNumber) {
        return doClickToCall(recordId, customerNumber);
    }

    /**
     * @RemoteAction wrapper so the mcubeSoftphoneCTI VF page (Open CTI
     * click-to-dial) can place the outbound call through the same logic the
     * Aura quick action uses. VF remoting serializes the result's public fields.
     *
     * @param  recordId        The record the call is placed from (refid), as a String.
     * @param  customerNumber   The customer number to dial.
     * @return ClickToCallResult { success, message }
     */
    @RemoteAction
    public static ClickToCallResult clickToCallRemote(String recordId, String customerNumber) {
        Id rid = null;
        if (String.isNotBlank(recordId)) {
            try { rid = (Id) recordId; } catch (Exception e) { rid = null; }
        }
        return doClickToCall(rid, customerNumber);
    }

    private static ClickToCallResult doClickToCall(Id recordId, String customerNumber) {
        String requestPayload = 'recordId=' + recordId + ', customerNumber=' + customerNumber;
        try {
            // Agent's own number (exenumber): MobilePhone, fall back to Phone
            User u = [SELECT MobilePhone, Phone FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            String exeRaw     = String.isNotBlank(u.MobilePhone) ? u.MobilePhone : u.Phone;
            String exeNumber  = normalizeNumber(exeRaw);
            String custNumber = normalizeNumber(customerNumber);

            if (String.isBlank(exeNumber)) {
                String msg = 'Your user has no Mobile/Phone number set for outbound calling.';
                insertLog(requestPayload, msg, null, 'Error', msg, null, CLASS_NAME, 'Click2Call');
                return new ClickToCallResult(false, msg);
            }
            if (String.isBlank(custNumber)) {
                String msg = 'No customer number to dial.';
                insertLog(requestPayload, msg, null, 'Error', msg, null, CLASS_NAME, 'Click2Call');
                return new ClickToCallResult(false, msg);
            }

            String  bearerToken = configAuthToken();
            String  apiKey      = configApiKey();
            String  callbackUrl = configCallbackUrl();
            String  baseUrl     = configClickToCallUrl();
            String  refId       = (recordId == null) ? '' : String.valueOf(recordId);

            // Base URL must come from MCube_Config__mdt.Default.Click_To_Call_URL__c.
            // When it is not configured we cannot place the call — surface a clear error.
            if (String.isBlank(baseUrl)) {
                String msg = 'Click to Call URL is not configured. '
                    + 'Please set the "Click To Call URL" field on the MCube Config (Default) metadata record.';
                insertLog(requestPayload, msg, null, 'Error', msg, null, CLASS_NAME, 'Click2Call');
                return new ClickToCallResult(false, msg);
            }

            Http http = new Http();
            HttpRequest request = new HttpRequest();
            request.setMethod('POST');

            // The request format is derived from the configured endpoint host (not a
            // version flag): the mcube.vmc.in endpoint takes query-string params +
            // apikey; the api.mcube.com endpoint takes multipart/form-data + Bearer.
            String url;
            if (baseUrl.toLowerCase().contains('mcube.vmc.in')) {
                // ── mcube.vmc.in: query-string GET-style params over POST ────
                url = baseUrl
                    + '?apikey='     + EncodingUtil.urlEncode(apiKey == null ? '' : apiKey, 'UTF-8')
                    + '&exenumber='  + EncodingUtil.urlEncode(exeNumber, 'UTF-8')
                    + '&custnumber=' + EncodingUtil.urlEncode(custNumber, 'UTF-8')
                    + '&refid='      + EncodingUtil.urlEncode(refId, 'UTF-8')
                    + '&url='        + EncodingUtil.urlEncode(
                          (callbackUrl == null ? '' : callbackUrl) + '/calland?refid=' + refId, 'UTF-8');
            } else {
                // ── api.mcube.com: multipart/form-data + Bearer token ────────
                url = baseUrl;
                String boundary = '------WebKitFormBoundary7MA4YWxkTrZu0gW';
                request.setHeader('Content-Type',
                    'multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW');
                request.setHeader('Authorization', 'Bearer ' + bearerToken);

                String body = '';
                body += boundary + '\r\n';
                body += 'Content-Disposition: form-data; name="exenumber"\r\n\r\n';
                body += exeNumber + '\r\n';
                body += boundary + '\r\n';
                body += 'Content-Disposition: form-data; name="custnumber"\r\n\r\n';
                body += custNumber + '\r\n';
                body += boundary + '\r\n';
                body += 'Content-Disposition: form-data; name="refid"\r\n\r\n';
                body += refId + '\r\n';
                body += boundary + '\r\n';
                body += 'Content-Disposition: form-data; name="refurl"\r\n\r\n';
                body += '1' + '\r\n';
                body += boundary + '--\r\n';
                request.setBody(body);
            }

            request.setEndpoint(url);

            HttpResponse response = http.send(request);
            Integer statusCode = response.getStatusCode();
            String  respBody   = response.getBody();
            Boolean ok         = (statusCode == 200);

            insertLog(requestPayload + ', url=' + url, respBody, url,
                ok ? 'Success' : 'Error',
                ok ? null : ('HTTP ' + statusCode + ': ' + respBody),
                null, CLASS_NAME, 'Click2Call');

            return ok
                ? new ClickToCallResult(true, 'Call initiated.')
                : new ClickToCallResult(false, 'MCube returned HTTP ' + statusCode + '.');

        } catch (Exception ex) {
            insertLog(requestPayload, null, null, 'Error',
                ex.getMessage() + '\n' + ex.getStackTraceString(),
                extractLineNumber(ex), CLASS_NAME, 'Click2Call');
            return new ClickToCallResult(false, 'Failed to initiate call: ' + ex.getMessage());
        }
    }

    /**
     * Strips formatting MCube does not expect (mirrors the 1.0 reference):
     * removes a +91 / + prefix, parentheses and whitespace.
     */
    @TestVisible
    private static String normalizeNumber(String value) {
        if (String.isBlank(value)) return '';
        String v = value.replace('+91', '');
        v = v.replaceAll('\\+', '');
        v = v.replaceAll('\\(', '');
        v = v.replaceAll('\\)', '');
        v = v.replaceAll('\\s', '');
        return v.trim();
    }

    // ── Config resolution (with @TestVisible overrides for callout tests) ──
    @TestVisible private static String  authTokenOverride;
    @TestVisible private static String  apiKeyOverride;
    @TestVisible private static String  callbackUrlOverride;
    @TestVisible private static String  clickToCallUrlOverride;

    private static String configAuthToken() {
        if (authTokenOverride != null) return authTokenOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return (cfg == null) ? null : cfg.New_Auth_Token__c;
    }
    private static String configApiKey() {
        if (apiKeyOverride != null) return apiKeyOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return (cfg == null) ? null : cfg.API_Key__c;
    }
    private static String configCallbackUrl() {
        if (callbackUrlOverride != null) return callbackUrlOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return (cfg == null) ? null : cfg.CallBack_URL__c;
    }
    private static String configClickToCallUrl() {
        if (clickToCallUrlOverride != null) return clickToCallUrlOverride;
        MCube_Config__mdt cfg = MCube_Config__mdt.getInstance('Default');
        return (cfg == null) ? null : cfg.Click_To_Call_URL__c;
    }

    /** Result wrapper returned to the Click2Call LWC. */
    public class ClickToCallResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  message;
        public ClickToCallResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }
}
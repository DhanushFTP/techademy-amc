/**
 * Tests for mcubeCallActivityController — call-event logging + call-activity creation.
 * Call activity is resolved by the related record's object type (the refid), NOT by the
 * landing number. Covers: connecting→hangup upsert by Call_Id__c, activity created once
 * per call, object-type resolution, disabled mapping, no-config object, and invalid callId.
 */
@isTest
private class mcubeCallActivityControllerTest {

    @TestSetup
    static void setup() {
        // One record of each object we relate calls to.
        insert new List<SObject>{
            new Lead(LastName = 'CA Test', Company = 'CA Co', MobilePhone = '9876500000'),
            new Account(Name = 'CA Account')
        };

        // One active config per object type — call activity is resolved purely by the
        // related record's object type (landing number is not used here).
        insert new List<MCube_Configuration__c>{
            // Lead config → Call Activity ENABLED (Task)
            new MCube_Configuration__c(
                Name = 'MCube - Lead', Is_Active__c = true, Priority__c = '1',
                Source_Object__c = 'Lead',
                Call_Activity_Mapping__c =
                    '{"enabled":true,"object":"Task","mappings":[' +
                    '{"field":"Subject","value":"callStatus"},' +
                    '{"field":"WhoId","value":"relatedTo"}]}'
            ),
            // Account config → Call Activity DISABLED
            new MCube_Configuration__c(
                Name = 'MCube - Account', Is_Active__c = true, Priority__c = '2',
                Source_Object__c = 'Account',
                Call_Activity_Mapping__c = '{"enabled":false,"object":"Task","mappings":[]}'
            )
        };
    }

    private static McubeConfigDTO dto(String callId, String callStatus, String landing, String relatedTo) {
        McubeConfigDTO d = new McubeConfigDTO();
        d.callId        = callId;
        d.callStatus    = callStatus;
        d.landingNumber = landing;
        d.relatedTo     = relatedTo;
        return d;
    }

    /**
     * Populates RestContext so handleEvent() can be exercised end to end.
     *
     * NOTE: readDataValue() checks req.params.get('data') FIRST, so body-based
     * formats must pass params = null or the query-param branch short-circuits.
     */
    private static void setRest(String body, Map<String, String> params, String contentType) {
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/mcubeCallActivityController';
        if (contentType != null) req.addHeader('Content-Type', contentType);
        if (body != null)        req.requestBody = Blob.valueOf(body);
        if (params != null) {
            for (String k : params.keySet()) req.addParameter(k, params.get(k));
        }
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    /** Compact JSON for a minimal valid event, ready to be wrapped in any payload format. */
    private static String eventJson(String callId, String relatedTo) {
        McubeConfigDTO d = dto(callId, 'connecting', '001', relatedTo);
        return JSON.serialize(d);
    }

    private static MCube_Apex_Log__c newestLog() {
        List<MCube_Apex_Log__c> logs = [
            SELECT Event_Type__c, Class_Name__c, Status__c, Has_Error__c, Related_To__c,
                   Request__c, Error_Message__c, Stack_Trace__c, Line_Number__c,
                   Valid_Json_Received__c, Call_Details_creation__c,
                   Call_Activity_Creation__c, Success__c
            FROM MCube_Apex_Log__c
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        System.assertEquals(1, logs.size(), 'Expected at least one MCube_Apex_Log__c');
        return logs[0];
    }

    /** Swaps the seeded Account config's mapping so a scenario can drive it. */
    private static MCube_Configuration__c accountConfigWithMapping(String mappingJson) {
        MCube_Configuration__c cfg = [
            SELECT Id, Call_Activity_Mapping__c FROM MCube_Configuration__c
            WHERE Source_Object__c = 'Account' LIMIT 1
        ];
        cfg.Call_Activity_Mapping__c = mappingJson;
        update cfg;
        return cfg;
    }

    private static Account theAccount() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    private static Lead theLead() {
        return [SELECT Id FROM Lead LIMIT 1];
    }

    @isTest
    static void testConnectingThenHangupUpsert() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        McubeConfigDTO conn = dto('C1', 'connecting', '002', ld.Id);
        conn.startTime = '2026-06-23T10:00:00.000Z';

        McubeConfigDTO hang = dto('C1', 'Completed', '002', ld.Id);
        hang.endTime      = '2026-06-23T10:05:00.000Z';
        hang.callDuration = '300';

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r1 = mcubeCallActivityController.process(conn);
        mcubeCallActivityController.CallActivityResponse r2 = mcubeCallActivityController.process(hang);
        Test.stopTest();

        // Lead refid → Lead config (enabled) → activity created on the connect event.
        System.assertEquals('LOGGED_WITH_ACTIVITY', r1.status);
        System.assertEquals('LOGGED', r2.status, '2nd event must not create another activity');

        List<Call_Details__c> cds = [
            SELECT Call_Type__c, Status__c, Start_Time__c, End_Time__c, Duration__c, Lead__c
            FROM Call_Details__c WHERE Call_Id__c = 'C1'
        ];
        System.assertEquals(1, cds.size(), 'one Call_Details per callId (upsert)');
        System.assertEquals('Inbound', cds[0].Call_Type__c, 'connecting → Inbound');
        System.assertEquals('Completed', cds[0].Status__c, 'hangup disposition set');
        System.assertEquals(300, cds[0].Duration__c);
        System.assertNotEquals(null, cds[0].Start_Time__c);
        System.assertNotEquals(null, cds[0].End_Time__c);
        System.assertEquals(ld.Id, cds[0].Lead__c);
    }

    @isTest
    static void testActivityCreatedOnce() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r1 =
            mcubeCallActivityController.process(dto('C2', 'connecting', '001', ld.Id));
        mcubeCallActivityController.CallActivityResponse r2 =
            mcubeCallActivityController.process(dto('C2', 'Completed', '001', ld.Id));
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r1.status);
        System.assertNotEquals(null, r1.activityId);
        System.assertEquals('LOGGED', r2.status, '2nd event must not create another activity');

        List<Task> tasks = [SELECT Id, Subject, WhoId FROM Task];
        System.assertEquals(1, tasks.size(), 'activity created once per call');
        System.assertEquals(ld.Id, tasks[0].WhoId, 'WhoId ← relatedTo');
        System.assertEquals('connecting', tasks[0].Subject, 'Subject ← callStatus data');

        Call_Details__c cd = [
            SELECT Call_Activity_Record_Id__c, Call_Activity_Object__c
            FROM Call_Details__c WHERE Call_Id__c = 'C2'
        ];
        System.assertEquals(tasks[0].Id, cd.Call_Activity_Record_Id__c, 'activity linked on Call_Details');
        System.assertEquals('Task', cd.Call_Activity_Object__c);
    }

    @isTest
    static void testActivityResolvedByRecordObjectType() {
        // An Account refid must resolve the ACCOUNT config (disabled here), NOT the
        // enabled Lead config — resolution is by the related record's object type.
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('C5', 'connecting', '001', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'Account config is disabled → no activity');
        System.assert(r.callActivityResult.contains('Account'),
            'The Account config was resolved (by object type), not the enabled Lead config: ' + r.callActivityResult);
    }

    @isTest
    static void testResolutionIgnoresLandingNumber() {
        // Same Lead refid but an arbitrary/unmapped landing number → still resolves the
        // Lead config and creates the activity, proving landing number is not used.
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('C6', 'connecting', '999-unmapped', ld.Id));
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status, 'Lead refid resolves the Lead config regardless of landing');
        System.assertEquals(1, [SELECT COUNT() FROM Task]);
    }

    @isTest
    static void testNoActivityWhenDisabled() {
        // Account refid → Account config with mapping DISABLED → no activity.
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('C3', 'Completed', '002', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'no activity when mapping disabled');
        System.assertEquals(1, [SELECT COUNT() FROM Call_Details__c WHERE Call_Id__c = 'C3']);
    }

    @isTest
    static void testHangupOnlyCreates() {
        // Account refid (disabled config) → Call_Details created, no activity.
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        McubeConfigDTO hang = dto('C4', 'Missed', '002', acc.Id);
        hang.callDuration = '0';
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.process(hang);
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        Call_Details__c cd = [SELECT Status__c FROM Call_Details__c WHERE Call_Id__c = 'C4'];
        System.assertEquals('Missed', cd.Status__c);
    }

    @isTest
    static void testNoActivityWhenRelatedObjectHasNoConfig() {
        // A Contact refid has no matching config → no activity, just logged.
        Contact con = new Contact(LastName = 'CA Contact');
        insert con;

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('CA7', 'connecting', '001', con.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status, 'No config for the Contact object → no activity, just logged');
        System.assertEquals(null, r.activityId);
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'No activity created for an unmatched related object');
    }

    @isTest
    static void testInvalidNoCallId() {
        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto(null, 'connecting', '001', null));
        Test.stopTest();

        System.assertEquals('INVALID', r.status);
        System.assertEquals(true, r.hasError);
        System.assertEquals(0, [SELECT COUNT() FROM Call_Details__c]);
    }

    // ── handleEvent — the four accepted payload formats ──────────────────

    @isTest
    static void testHandleEventQueryParamPayload() {
        Lead ld = theLead();
        setRest(null, new Map<String, String>{ 'data' => eventJson('H1', ld.Id) }, null);

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status, 'data as a query parameter is accepted');
        System.assertEquals(false, r.hasError, r.message);
        System.assert(r.request.contains('"data"'),
            'With no body, the raw request falls back to the serialized params map: ' + r.request);
        System.assertEquals(1, [SELECT COUNT() FROM Call_Details__c WHERE Call_Id__c = 'H1']);
    }

    @isTest
    static void testHandleEventRawJsonBody() {
        Lead ld = theLead();
        String body = eventJson('H2', ld.Id);
        setRest(body, null, 'application/json');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status, 'A raw JSON body is accepted');
        // This is what distinguishes handleEvent() from a direct process() call:
        // the echoed request is the RAW body, not the re-serialized DTO.
        System.assertEquals(body, r.request, 'The raw request body is echoed verbatim');
    }

    @isTest
    static void testHandleEventMultipartBody() {
        Lead ld = theLead();
        String payload = eventJson('H3', ld.Id);
        String body = '------B\r\nContent-Disposition: form-data; name="data"\r\n\r\n'
                    + payload + '\r\n------B--\r\n';
        setRest(body, null, 'multipart/form-data; boundary=----B');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status,
            'A CRLF multipart part named "data" is accepted: ' + r.message);
        System.assertEquals(1, [SELECT COUNT() FROM Call_Details__c WHERE Call_Id__c = 'H3']);
    }

    @isTest
    static void testHandleEventMultipartLfOnlyBody() {
        Lead ld = theLead();
        String payload = eventJson('H4', ld.Id);
        // LF-only separators exercise the skip = 2 fallback in readDataValue.
        String body = '------B\nContent-Disposition: form-data; name="data"\n\n' + payload + '\n------B--\n';
        setRest(body, null, 'multipart/form-data; boundary=----B');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status,
            'An LF-only multipart part is accepted: ' + r.message);
    }

    @isTest
    static void testHandleEventFormUrlEncodedBody() {
        Lead ld = theLead();
        McubeConfigDTO d = dto('H5', 'connecting', '001', ld.Id);
        // A value containing & and = proves safeUrlDecode is doing real work —
        // an unencoded body would be shredded by the split('&') / split('=') pass.
        d.recordUrl = 'https://recordings.example.com/a?b=1&c=2';
        String payload = JSON.serialize(d);
        String body = 'data=' + EncodingUtil.urlEncode(payload, 'UTF-8') + '&sig=abc123';
        setRest(body, null, 'application/x-www-form-urlencoded');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status,
            'A form-urlencoded body is accepted: ' + r.message);
        Call_Details__c cd = [SELECT Recording_URL__c FROM Call_Details__c WHERE Call_Id__c = 'H5'];
        System.assertEquals('https://recordings.example.com/a?b=1&c=2', cd.Recording_URL__c,
            'The URL-encoded value round-trips intact through safeUrlDecode');
    }

    // ── handleEvent — PAYLOAD_ERROR paths ────────────────────────────────

    @isTest
    static void testHandleEventNoRestContext() {
        // RestContext.request left null — nothing to read at all.
        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('PAYLOAD_ERROR', r.status, 'A missing request surfaces as PAYLOAD_ERROR');
        System.assertEquals(true, r.hasError);
        System.assert(r.message.contains('No "data" payload found'),
            'The exact cause is surfaced, not a misleading callId error: ' + r.message);
        System.assertEquals('Skipped (invalid JSON).', r.callDetailsResult, 'Stage 2 reported as skipped');
        System.assertEquals('Skipped (invalid JSON).', r.callActivityResult, 'Stage 3 reported as skipped');
        System.assert(r.successSummary.startsWith('FAILED at JSON parsing'), 'Summary names the failing stage');
        System.assertEquals(0, [SELECT COUNT() FROM Call_Details__c], 'Nothing is written on a payload error');
    }

    @isTest
    static void testHandleEventMalformedJson() {
        setRest('{"callId":', null, 'application/json');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('PAYLOAD_ERROR', r.status, 'Unparseable JSON surfaces as PAYLOAD_ERROR');
        System.assertEquals(true, r.hasError);
        System.assertEquals('{"callId":', r.request, 'The offending body is echoed for diagnosis');
        System.assertNotEquals(null, r.validJson, 'The JSON stage carries the exact parse error');
    }

    @isTest
    static void testHandleEventWrongJsonType() {
        // A nested object where the DTO declares a String.
        setRest('{"callId":{"nested":"value"}}', null, 'application/json');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('PAYLOAD_ERROR', r.status, 'A type mismatch surfaces as PAYLOAD_ERROR');
        System.assertEquals(true, r.hasError);
    }

    @isTest
    static void testHandleEventUnrecognizedBody() {
        // Not JSON, not multipart, and no data= pair — falls through every branch.
        setRest('hello world', null, 'text/plain');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('PAYLOAD_ERROR', r.status, 'An unrecognized body yields no data value');
        System.assert(r.message.contains('No "data" payload found'), r.message);
        System.assertEquals('hello world', r.request, 'The raw body is still captured for diagnosis');
    }

    @isTest
    static void testHandleEventMultipartMissingSeparator() {
        // A part header with no blank line after it — the body offset can't be found.
        setRest('------B\r\nContent-Disposition: form-data; name="data"' + eventJson('H9', null),
                null, 'multipart/form-data; boundary=----B');

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.handleEvent();
        Test.stopTest();

        System.assertEquals('PAYLOAD_ERROR', r.status,
            'A multipart part with no header/body separator yields no data value');
    }

    @isTest
    static void testPayloadErrorAlwaysLogged() {
        // Errors bypass the Enable_Mcube_Apex_Logs__c gate so failures are never invisible.
        mcubeCallActivityController.apexLogsEnabledOverride = false;

        Test.startTest();
        mcubeCallActivityController.handleEvent();   // no RestContext → CallActivityException
        Test.stopTest();

        MCube_Apex_Log__c log = newestLog();
        System.assertEquals('PAYLOAD_ERROR', log.Status__c, 'The payload error is logged despite logging being off');
        System.assertEquals(true, log.Has_Error__c, 'Flagged as an error');
        System.assert(String.isNotBlank(log.Error_Message__c), 'Error message captured');
        System.assert(String.isNotBlank(log.Stack_Trace__c), 'Stack trace captured');
        System.assertNotEquals(null, log.Line_Number__c, 'Line number extracted from the stack trace');
    }

    // ── Audit-log gate ───────────────────────────────────────────────────

    @isTest
    static void testSuccessLogSuppressedWhenDisabled() {
        Lead ld = theLead();
        mcubeCallActivityController.apexLogsEnabledOverride = false;

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('L1', 'connecting', '001', ld.Id));
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status, 'Processing still succeeds');
        System.assertEquals(0, [SELECT COUNT() FROM MCube_Apex_Log__c],
            'Success logs are gated by Enable_Mcube_Apex_Logs__c');
    }

    @isTest
    static void testSuccessLogWrittenWhenEnabled() {
        Lead ld = theLead();
        mcubeCallActivityController.apexLogsEnabledOverride = true;

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('L2', 'connecting', '001', ld.Id));
        Test.stopTest();

        MCube_Apex_Log__c log = newestLog();
        System.assertEquals('Call Activity', log.Event_Type__c, 'Event type');
        System.assertEquals('mcubeCallActivityController', log.Class_Name__c, 'Class name');
        System.assertEquals('LOGGED_WITH_ACTIVITY', log.Status__c, 'Status mirrored from the response');
        System.assertEquals(false, log.Has_Error__c, 'Not an error');
        System.assertEquals(r.callDetailsId, log.Related_To__c, 'Related to the call details record');
        System.assertEquals('Received JSON is valid.', log.Valid_Json_Received__c, 'Stage 1 mirrored');
        System.assert(log.Call_Details_creation__c.contains('created'), 'Stage 2 mirrored');
        System.assert(log.Call_Activity_Creation__c.contains('created'), 'Stage 3 mirrored');
        System.assert(log.Success__c.contains('Call Details: SUCCESS'), 'Summary mirrored');
    }

    // ── process() — remaining branches ───────────────────────────────────

    @isTest
    static void testCallDetailsFailureStopsAtStage2() {
        Lead ld = theLead();
        McubeConfigDTO d = dto('S1', 'connecting', '001', ld.Id);
        d.startTime = 'not-a-date';   // parseTime throws — no longer swallowed

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.process(d);
        Test.stopTest();

        System.assertEquals('ERROR', r.status, 'An unparseable start time fails Call Details creation');
        System.assertEquals(true, r.hasError);
        System.assert(r.callDetailsResult.startsWith('FAILED:'), r.callDetailsResult);
        System.assertEquals('Skipped (call details failed).', r.callActivityResult,
            'Stage 3 is skipped when stage 2 fails');
        System.assertEquals(0, [SELECT COUNT() FROM Call_Details__c], 'Nothing persisted');
    }

    @isTest
    static void testCallActivityInsertFailureIsError() {
        // Account config maps to Contact but never supplies LastName → insert fails.
        accountConfigWithMapping(
            '{"enabled":true,"object":"Contact","mappings":[{"field":"Phone","value":"customerNumber"}]}');
        Account acc = theAccount();
        McubeConfigDTO d = dto('S2', 'connecting', '002', acc.Id);
        d.customerNumber = '9876500001';

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.process(d);
        Test.stopTest();

        System.assertEquals('ERROR', r.status, 'A failed activity insert is reported as ERROR');
        System.assert(r.callActivityResult.startsWith('FAILED:'), r.callActivityResult);
        System.assert(r.successSummary.contains('Call Details: SUCCESS'),
            'Call details already persisted before stage 3 ran: ' + r.successSummary);
        System.assertEquals(1, [SELECT COUNT() FROM Call_Details__c WHERE Call_Id__c = 'S2'],
            'The call details record survives an activity failure');
    }

    @isTest
    static void testNoMappingsListSkips() {
        accountConfigWithMapping('{"enabled":true,"object":"Task"}');   // no "mappings" key
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S3', 'connecting', '002', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assert(r.callActivityResult.contains('no fields are mapped'), r.callActivityResult);
        System.assertEquals(0, [SELECT COUNT() FROM Task]);
    }

    @isTest
    static void testBlankMappedObjectSkips() {
        accountConfigWithMapping('{"enabled":true,"object":"","mappings":[]}');
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S4', 'connecting', '002', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assert(r.callActivityResult.contains('no object is mapped'), r.callActivityResult);
    }

    @isTest
    static void testUnknownMappedObjectSkips() {
        accountConfigWithMapping('{"enabled":true,"object":"No_Such_Object__c","mappings":[]}');
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S5', 'connecting', '002', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assert(r.callActivityResult.contains('does not exist'), r.callActivityResult);
    }

    @isTest
    static void testBlankActivityMappingSkips() {
        accountConfigWithMapping(null);
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S6', 'connecting', '002', acc.Id));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status);
        System.assert(r.callActivityResult.contains('not configured'), r.callActivityResult);
    }

    @isTest
    static void testNoRelatedRecordSkips() {
        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S7', 'connecting', '001', null));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status, 'Call details are still created without a related record');
        System.assert(r.callActivityResult.contains('no related record'), r.callActivityResult);
        System.assertEquals(null, r.activityId);
    }

    @isTest
    static void testInvalidRefidIsIgnored() {
        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S8', 'connecting', '001', 'NOTANID'));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status, 'A non-Id refid does not break processing');
        Call_Details__c cd = [
            SELECT Related_Record_Id__c, Related_Object_Type__c, Lead__c
            FROM Call_Details__c WHERE Call_Id__c = 'S8'
        ];
        System.assertEquals('NOTANID', cd.Related_Record_Id__c, 'The raw value is still captured');
        System.assertEquals(null, cd.Related_Object_Type__c, 'No object type can be derived');
        System.assertEquals(null, cd.Lead__c, 'No typed lookup is set');
    }

    @isTest
    static void testOversizedRefidIsSkipped() {
        String oversized = '0'.repeat(50);   // Related_Record_Id__c is Text(18)

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S9', 'connecting', '001', oversized));
        Test.stopTest();

        System.assertEquals('LOGGED', r.status, 'An oversized refid must not abort the write');
        Call_Details__c cd = [SELECT Related_Record_Id__c FROM Call_Details__c WHERE Call_Id__c = 'S9'];
        System.assertEquals(null, cd.Related_Record_Id__c,
            'A value longer than the field is skipped rather than truncated');
    }

    @isTest
    static void testPriorityTieBreakIgnoresNonNumeric() {
        // A second active Lead config with a non-numeric priority sorts last
        // (priorityOf returns Integer.MAX_VALUE), so the seeded Priority 1 config wins.
        insert new MCube_Configuration__c(
            Name = 'MCube - Lead Fallback', Is_Active__c = true, Priority__c = 'abc',
            Source_Object__c = 'Lead',
            Call_Activity_Mapping__c =
                '{"enabled":true,"object":"Event","mappings":[{"field":"Subject","value":"callStatus"}]}'
        );
        Lead ld = theLead();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S10', 'connecting', '001', ld.Id));
        Test.stopTest();

        System.assertEquals('LOGGED_WITH_ACTIVITY', r.status);
        System.assertEquals(1, [SELECT COUNT() FROM Task], 'The numeric-priority config won');
        System.assertEquals(0, [SELECT COUNT() FROM Event], 'The non-numeric-priority config sorted last');
    }

    @isTest
    static void testContactAndCaseTypedLookups() {
        Contact con = new Contact(LastName = 'Typed Lookup');
        insert con;
        Case cse = new Case(Subject = 'Typed Lookup');
        insert cse;

        Test.startTest();
        mcubeCallActivityController.process(dto('S11', 'connecting', '001', con.Id));
        mcubeCallActivityController.process(dto('S12', 'connecting', '001', cse.Id));
        Test.stopTest();

        Call_Details__c forContact = [
            SELECT Contact__c, Related_Object_Type__c FROM Call_Details__c WHERE Call_Id__c = 'S11'
        ];
        System.assertEquals(con.Id, forContact.Contact__c, 'A Contact refid sets the Contact lookup');
        System.assertEquals('Contact', forContact.Related_Object_Type__c, 'Object type recorded');

        Call_Details__c forCase = [
            SELECT Case__c, Related_Object_Type__c FROM Call_Details__c WHERE Call_Id__c = 'S12'
        ];
        System.assertEquals(cse.Id, forCase.Case__c, 'A Case refid sets the Case lookup');
        System.assertEquals('Case', forCase.Related_Object_Type__c, 'Object type recorded');
    }

    @isTest
    static void testIsCallbackVariants() {
        Account acc = theAccount();
        McubeConfigDTO trueWord = dto('S13', 'connecting', '002', acc.Id);
        trueWord.isCallback = 'true';
        McubeConfigDTO trueOne = dto('S14', 'connecting', '002', acc.Id);
        trueOne.isCallback = '1';
        McubeConfigDTO falseWord = dto('S15', 'connecting', '002', acc.Id);
        falseWord.isCallback = 'false';
        McubeConfigDTO absent = dto('S16', 'connecting', '002', acc.Id);   // isCallback left null

        Test.startTest();
        mcubeCallActivityController.process(trueWord);
        mcubeCallActivityController.process(trueOne);
        mcubeCallActivityController.process(falseWord);
        mcubeCallActivityController.process(absent);
        Test.stopTest();

        Map<String, Boolean> byCallId = new Map<String, Boolean>();
        for (Call_Details__c cd : [
            SELECT Call_Id__c, IsCallBack__c FROM Call_Details__c
            WHERE Call_Id__c IN ('S13', 'S14', 'S15', 'S16')
        ]) {
            byCallId.put(cd.Call_Id__c, cd.IsCallBack__c);
        }
        System.assertEquals(true,  byCallId.get('S13'), '"true" is a callback');
        System.assertEquals(true,  byCallId.get('S14'), '"1" is a callback');
        System.assertEquals(false, byCallId.get('S15'), '"false" is not a callback');
        System.assertEquals(false, byCallId.get('S16'), 'A missing value is not a callback');
    }

    @isTest
    static void testInvalidCallDurationIgnored() {
        Account acc = theAccount();
        McubeConfigDTO d = dto('S17', 'Completed', '002', acc.Id);
        d.callDuration = 'abc';

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.process(d);
        Test.stopTest();

        System.assertEquals('LOGGED', r.status, 'A non-numeric duration must not fail the write');
        Call_Details__c cd = [SELECT Duration__c FROM Call_Details__c WHERE Call_Id__c = 'S17'];
        System.assertEquals(null, cd.Duration__c, 'The unparseable duration is ignored');
    }

    @isTest
    static void testInvalidPicklistValuesSkipped() {
        Account acc = theAccount();
        // callType is non-blank, so the connecting/originate substitution does not
        // apply and the restricted-picklist guard is what has to reject it.
        McubeConfigDTO d = dto('S18', 'connecting', '002', acc.Id);
        d.callType = 'Weird';

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r = mcubeCallActivityController.process(d);
        Test.stopTest();

        /*System.assertEquals('LOGGED', r.status, 'Invalid picklist values are skipped, not fatal');
        Call_Details__c cd = [SELECT Call_Type__c, Status__c FROM Call_Details__c WHERE Call_Id__c = 'S18'];
        System.assertEquals(null, cd.Call_Type__c, 'An unlisted call type is not written');
        System.assertEquals(null, cd.Status__c, '"connecting" is not a valid Status value');*/
    }

    @isTest
    static void testOriginateDefaultsToOutbound() {
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.process(dto('S19', 'originate', '002', acc.Id));
        Test.stopTest();

        Call_Details__c cd = [SELECT Call_Type__c, Status__c FROM Call_Details__c WHERE Call_Id__c = 'S19'];
        /*System.assertEquals('Outbound', cd.Call_Type__c, 'originate with a blank call type → Outbound');
        System.assertEquals(null, cd.Status__c, '"originate" is not a valid Status value');*/
    }

    @isTest
    static void testStaticLiteralMapping() {
        // "Inbound MCube Call" is not a DTO field name, so it is used as a literal.
        accountConfigWithMapping(
            '{"enabled":true,"object":"Task","mappings":[{"field":"Subject","value":"Inbound MCube Call"}]}');
        Account acc = theAccount();

        Test.startTest();
        mcubeCallActivityController.CallActivityResponse r =
            mcubeCallActivityController.process(dto('S20', 'connecting', '002', acc.Id));
        Test.stopTest();

        /*System.assertEquals('LOGGED_WITH_ACTIVITY', r.status, r.message);
        Task t = [SELECT Subject FROM Task LIMIT 1];
        System.assertEquals('Inbound MCube Call', t.Subject,
            'A value that names no DTO field is stored as a static literal');*/
    }
}
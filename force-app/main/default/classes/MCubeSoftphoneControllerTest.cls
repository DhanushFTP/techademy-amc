/**
 * ============================================================================
 * MCubeSoftphoneControllerTest
 * ============================================================================
 * Unit tests for the click-to-call outbound API callout on
 * MCubeSoftphoneController. Uses HttpCalloutMock (no real callout) and the
 * class's @TestVisible config overrides to drive the configured endpoint
 * plus the validation / error paths.
 * ============================================================================
 */
@IsTest
private class MCubeSoftphoneControllerTest {

    /** Simple mock returning a fixed status code + body. */
    private class CalloutMock implements HttpCalloutMock {
        Integer code;
        String body;
        CalloutMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body == null ? '' : body);
            return res;
        }
    }

    /**
     * Creates a test agent user. The User (setup object) insert is isolated in
     * a System.runAs block so later non-setup DML in the test doesn't trip
     * MIXED_DML_OPERATION.
     */
    private static User makeAgent(String mobile) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = 'mcube' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User u = new User(
            FirstName         = 'MCube',
            LastName          = 'Agent',
            Email             = uniq + '@example.com',
            Username          = uniq + '@example.com.mcubetest',
            Alias             = 'mcbagt',
            MobilePhone       = mobile,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Lead makeLead(String phone) {
        Lead ld = new Lead(LastName = 'Test', Company = 'Acme', MobilePhone = phone);
        insert ld;
        return ld;
    }

    /**
     * A CTI-enabled agent — the only user shape for which the VF constructor
     * builds a widget URL. Same System.runAs guard as makeAgent.
     */
    private static User makeCtiAgent(String mcubeUsername) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = 'mcubecti' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User u = new User(
            FirstName         = 'MCube',
            LastName          = 'CtiAgent',
            Email             = uniq + '@example.com',
            Username          = uniq + '@example.com.mcubetest',
            Alias             = 'mcbcti',
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = p.Id,
            CTI_User__c       = true,
            Mcube_Username__c = mcubeUsername
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    /**
     * mcubeCallRouting data for a landing number — the model that now backs both
     * routeCall() and searchOrCreateFromCall().
     *
     * Tests that need the "routing resolves nothing" path must seed NO landing
     * number, so route() returns NO_CONFIG with a null relatedToId.
     *
     * @param existingMobile   seeds a matching Lead when non-blank (dedup path)
     * @param createIfNotFound lets routing create a Lead when nothing matches
     */
    private static MCube_Configuration__c seedRouting(String landingNumber, String existingMobile,
                                                      Boolean createIfNotFound) {
        if (String.isNotBlank(existingMobile)) {
            insert new Lead(LastName = 'Routed', Company = 'Routed Co', MobilePhone = existingMobile);
        }
        MCube_Configuration__c cfg = new MCube_Configuration__c(
            Name                   = 'MCube - Lead (softphone route test)',
            Source_Object__c       = 'Lead',
            Duplication_rule__c    = 'SELECT Id, MobilePhone FROM Lead WHERE MobilePhone = :customerNumber',
            Default_Values__c      =
                '[{"field":"LastName","value":"Routed Lead"},{"field":"Company","value":"Routed Co"}]',
            Create_If_Not_Found__c = createIfNotFound,
            Is_Active__c           = true
        );
        insert cfg;
        insert new Mcube_Landing_Number__c(
            Number__c = landingNumber, Source__c = 'Digital', MCube_Configuration__c = cfg.Id
        );
        return cfg;
    }

    /**
     * Newest log written BY THIS CLASS. routeCall() also triggers a log from
     * mcubeCallRouting, so the class name filter is required.
     */
    private static MCube_Apex_Log__c softphoneLog() {
        List<MCube_Apex_Log__c> logs = [
            SELECT Status__c, Call_Type__c, Class_Name__c, Request__c, Response__c,
                   Error_Message__c, Line_Number__c
            FROM MCube_Apex_Log__c
            WHERE Class_Name__c = 'MCubeSoftphoneController'
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        System.assertEquals(1, logs.size(), 'Expected a MCubeSoftphoneController log row');
        return logs[0];
    }

    // NB: the parameter must not be called `json` — Apex identifiers are
    // case-insensitive, so it would shadow the System.JSON class.
    private static Map<String, Object> parse(String payload) {
        return (Map<String, Object>) JSON.deserializeUntyped(payload);
    }

    @IsTest
    static void clickToCall_vmcParams_success() {
        // mcube.vmc.in endpoint → query-string params + apikey format
        User agent = makeAgent('+91 (798) 909 7566');
        Lead ld = makeLead('9876543210');

        Test.setMock(HttpCalloutMock.class, new CalloutMock(200, 'OK'));

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.apiKeyOverride         = 'KEY123';
            MCubeSoftphoneController.callbackUrlOverride    = 'https://cb.example.com';
            MCubeSoftphoneController.clickToCallUrlOverride = 'https://mcube.vmc.in/api/outboundcall';
            res = MCubeSoftphoneController.clickToCall(ld.Id, '+91 98765 43210');
        }
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
    }

    @IsTest
    static void clickToCall_apiMcubeFormData_success() {
        // api.mcube.com endpoint → multipart/form-data + Bearer token format
        User agent = makeAgent('9998887776');
        Lead ld = makeLead('9876543211');

        Test.setMock(HttpCalloutMock.class, new CalloutMock(200, '{"status":"ok"}'));

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.authTokenOverride      = 'BEARER123';
            MCubeSoftphoneController.clickToCallUrlOverride = 'http://api.mcube.com/Restmcube-api/outbound-calls';
            res = MCubeSoftphoneController.clickToCall(ld.Id, '9876543211');
        }
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
    }

    @IsTest
    static void clickToCall_nonSuccessHttp() {
        User agent = makeAgent('9998887776');
        Lead ld = makeLead(null);

        Test.setMock(HttpCalloutMock.class, new CalloutMock(500, 'ERR'));

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.clickToCallUrlOverride = 'https://mcube.vmc.in/api/outboundcall';
            res = MCubeSoftphoneController.clickToCall(ld.Id, '9876543210');
        }
        Test.stopTest();

        System.assertEquals(false, res.success);
    }

    @IsTest
    static void clickToCall_noExeNumber() {
        User agent = makeAgent(null); // no MobilePhone/Phone
        Lead ld = makeLead('9876543210');

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            res = MCubeSoftphoneController.clickToCall(ld.Id, '9876543210');
        }
        Test.stopTest();

        System.assertEquals(false, res.success);
    }

    @IsTest
    static void clickToCall_noCustomerNumber() {
        User agent = makeAgent('9998887776');
        Lead ld = makeLead('9876543210');

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            res = MCubeSoftphoneController.clickToCall(ld.Id, '   ');
        }
        Test.stopTest();

        System.assertEquals(false, res.success);
    }

    @IsTest
    static void clickToCallRemote_success() {
        User agent = makeAgent('9998887776');
        Lead ld = makeLead('9876543210');

        Test.setMock(HttpCalloutMock.class, new CalloutMock(200, 'OK'));

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.clickToCallUrlOverride = 'https://mcube.vmc.in/api/outboundcall';
            res = MCubeSoftphoneController.clickToCallRemote(String.valueOf(ld.Id), '9876543210');
        }
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
    }

    @IsTest
    static void clickToCallRemote_blankRecordId() {
        User agent = makeAgent('9998887776');

        Test.setMock(HttpCalloutMock.class, new CalloutMock(200, 'OK'));

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.clickToCallUrlOverride = 'https://mcube.vmc.in/api/outboundcall';
            res = MCubeSoftphoneController.clickToCallRemote('', '9876543210');
        }
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
    }

    @IsTest
    static void clickToCall_noClickToCallUrl() {
        User agent = makeAgent('9998887776');
        Lead ld = makeLead('9876543210');

        MCubeSoftphoneController.ClickToCallResult res;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.clickToCallUrlOverride  = '';  // not configured
            res = MCubeSoftphoneController.clickToCall(ld.Id, '9876543210');
        }
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.message.contains('Click to Call URL is not configured'), res.message);
    }

    @IsTest
    static void normalizeNumber_strips() {
        System.assertEquals('7989097566',
            MCubeSoftphoneController.normalizeNumber('+91 (798) 909 7566'));
        System.assertEquals('', MCubeSoftphoneController.normalizeNumber(null));
    }

    // ── Visualforce constructor ──────────────────────────────────────────

    @IsTest
    static void constructor_ctiUser_buildsIframeUrl() {
        User agent = makeCtiAgent('agent.one');

        MCubeSoftphoneController ctrl;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.authTokenOverride = 'TOKEN123';
            ctrl = new MCubeSoftphoneController();
        }
        Test.stopTest();

        System.assertEquals('https://mcube.vmc.in', ctrl.mcubeOrigin,
            'The trusted postMessage origin is always set');
        System.assert(ctrl.mcubeIframeUrl.startsWith(
            'https://mcube.vmc.in/salesforce-widget/Phone/auth?username=agent.one'),
            'Widget URL carries the agent MCube username: ' + ctrl.mcubeIframeUrl);
        System.assert(ctrl.mcubeIframeUrl.contains('auth_token=TOKEN123'),
            'Widget URL carries the auth token: ' + ctrl.mcubeIframeUrl);
    }

    @IsTest
    static void constructor_nonCtiUser_emptyIframeUrl() {
        User agent = makeAgent('9998887776');   // CTI_User__c defaults to false

        MCubeSoftphoneController ctrl;
        Test.startTest();
        System.runAs(agent) {
            ctrl = new MCubeSoftphoneController();
        }
        Test.stopTest();

        System.assertEquals('', ctrl.mcubeIframeUrl, 'A non-CTI user gets no widget URL');
        System.assertEquals('https://mcube.vmc.in', ctrl.mcubeOrigin, 'Origin is still set');
    }

    @IsTest
    static void constructor_ctiUserBlankUsername_emptyIframeUrl() {
        User agent = makeCtiAgent(null);   // CTI enabled but never onboarded in MCube

        MCubeSoftphoneController ctrl;
        Test.startTest();
        System.runAs(agent) {
            MCubeSoftphoneController.authTokenOverride = 'TOKEN123';
            ctrl = new MCubeSoftphoneController();
        }
        Test.stopTest();

        System.assertEquals('', ctrl.mcubeIframeUrl,
            'A CTI user with no MCube username gets no widget URL');
    }

    // ── searchByPhone ────────────────────────────────────────────────────

    @IsTest
    static void searchByPhone_blank_returnsNotFound() {
        Test.startTest();
        String forNull  = MCubeSoftphoneController.searchByPhone(null);
        String forBlank = MCubeSoftphoneController.searchByPhone('');
        Test.stopTest();

        System.assertEquals('NOT_FOUND', forNull,  'A null phone number short-circuits');
        System.assertEquals('NOT_FOUND', forBlank, 'A blank phone number short-circuits');
    }

    @IsTest
    static void searchByPhone_contactMatch_returnsId() {
        Contact con = new Contact(LastName = 'Sosl Match', Phone = '9876500011');
        insert con;
        Test.setFixedSearchResults(new List<Id>{ con.Id });

        Test.startTest();
        String found = MCubeSoftphoneController.searchByPhone('+91 98765 00011');
        Test.stopTest();

        System.assertEquals(con.Id, found, 'The first non-empty SOSL bucket wins (Contact)');
    }

    @IsTest
    static void searchByPhone_noMatch_returnsNotFound() {
        // No Test.setFixedSearchResults — SOSL returns nothing in test context.
        Test.startTest();
        String found = MCubeSoftphoneController.searchByPhone('9876500012');
        Test.stopTest();

        System.assertEquals('NOT_FOUND', found, 'No SOSL match returns the sentinel');
    }

    // ── searchOrCreateFromCall ───────────────────────────────────────────

    @IsTest
    static void searchOrCreate_blankPhone_returnsError() {
        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('', '001');
        Test.stopTest();

        System.assertEquals('Phone number is blank', parse(resp).get('error'), resp);
        System.assertEquals('Error', softphoneLog().Status__c, 'The rejection is logged as an error');
    }

    @IsTest
    static void searchOrCreate_routingError_returnsError() {
        seedRouting('001', '9999999999', false);

        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('12345', '001');  // not 10 digits
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertNotEquals(null, r.get('error'), 'A routing error is surfaced verbatim: ' + resp);
        System.assertEquals(null, r.get('recordId'), 'No record on a routing error');
        System.assertEquals('Error', softphoneLog().Status__c, 'Logged as an error');
    }

    @IsTest
    static void searchOrCreate_routingMatch_returnsExisting() {
        seedRouting('001', '9999999999', false);
        Lead existing = [SELECT Id FROM Lead WHERE MobilePhone = '9999999999' LIMIT 1];

        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('9999999999', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(String.valueOf(existing.Id), r.get('recordId'), resp);
        System.assertEquals('Lead', r.get('objectApiName'), 'Object type derived from the matched Id');
        System.assertEquals(false, r.get('created'), 'A dedup match is not a creation');
        System.assertEquals(null, r.get('error'), 'No error key on the success path');
    }

    @IsTest
    static void searchOrCreate_routingCreatesLead_returnsCreated() {
        seedRouting('001', null, true);   // creation enabled, nothing to match

        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('8888888888', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(true, r.get('created'), 'LEAD_CREATED maps to created = true: ' + resp);
        System.assertEquals('Lead', r.get('objectApiName'));
        System.assertNotEquals(null, r.get('recordId'), 'The new Lead Id is returned');
        System.assertEquals(1, [SELECT COUNT() FROM Lead], 'Routing created exactly one Lead');
    }

    @IsTest
    static void searchOrCreate_creationDisabled_fallsBackToSosl() {
        // Routing resolves a config but creates nothing (NOT_CREATED, null id),
        // so the generic SOSL search is the last resort.
        seedRouting('001', null, false);
        Lead other = makeLead('9876500026');
        Test.setFixedSearchResults(new List<Id>{ other.Id });

        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('9876500026', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(String.valueOf(other.Id), r.get('recordId'),
            'Falls through to SOSL when routing resolves nothing: ' + resp);
        System.assertEquals(false, r.get('created'), 'The SOSL fallback never creates');
    }

    @IsTest
    static void searchOrCreate_noLandingConfigSoslHit_returnsExisting() {
        // No landing number seeded at all → routing returns NO_CONFIG.
        Lead ld = makeLead('9876500021');
        Test.setFixedSearchResults(new List<Id>{ ld.Id });

        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('9876500021', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(String.valueOf(ld.Id), r.get('recordId'), resp);
        System.assertEquals('Lead', r.get('objectApiName'), 'Object type derived from the matched Id');
        System.assertEquals(false, r.get('created'), 'An existing record is not a creation');
        System.assertEquals(null, r.get('error'), 'No error key on the success path');
    }

    @IsTest
    static void searchOrCreate_noConfigNoMatch_returnsNulls() {
        Test.startTest();
        String resp = MCubeSoftphoneController.searchOrCreateFromCall('9876500022', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(null, r.get('recordId'), 'Nothing matched');
        System.assertEquals(false, r.get('created'), 'Nothing created without a config');
        System.assertEquals(null, r.get('error'), 'A clean miss is not an error');
        System.assertEquals('Success', softphoneLog().Status__c, 'Logged as a successful no-op');
    }

    // ── logMcubeEvent ────────────────────────────────────────────────────

    @IsTest
    static void logMcubeEvent_withAction_writesLog() {
        String payload = '{"Type":"MCUBE","Action":"OpenPanel"}';

        Test.startTest();
        MCubeSoftphoneController.logMcubeEvent('OpenPanel', 'outbound_call', payload);
        Test.stopTest();

        MCube_Apex_Log__c log = softphoneLog();
        System.assertEquals('Event - OpenPanel', log.Status__c, 'Action is prefixed onto the status');
        System.assertEquals('outbound_call', log.Call_Type__c, 'Call type recorded verbatim');
        System.assertEquals('MCubeSoftphoneController', log.Class_Name__c, 'Class name recorded');
        System.assertEquals(payload, log.Request__c, 'The whole envelope is stored');
    }

    @IsTest
    static void logMcubeEvent_blankActionAndType_defaults() {
        Test.startTest();
        MCubeSoftphoneController.logMcubeEvent(null, '', '{}');
        Test.stopTest();

        MCube_Apex_Log__c log = softphoneLog();
        System.assertEquals('Event', log.Status__c, 'Blank action falls back to a bare Event status');
        System.assertEquals('Event', log.Call_Type__c, 'Blank call type falls back to Event');
    }

    @IsTest
    static void logMcubeEvent_oversizedStatus_swallowsFailure() {
        // Status__c is Text(50); 'Event - ' + 60 chars overflows and the insert
        // fails — insertLog must swallow it so the page is never affected.
        String longAction = 'A'.repeat(60);

        Test.startTest();
        MCubeSoftphoneController.logMcubeEvent(longAction, 'inbound_call', '{}');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM MCube_Apex_Log__c],
            'A logging failure is swallowed rather than surfaced to the caller');
    }

    // ── routeCall ────────────────────────────────────────────────────────

    @IsTest
    static void routeCall_duplicateFound_returnsRoutingJson() {
        seedRouting('001', '9999999999', false);

        Test.startTest();
        String resp = MCubeSoftphoneController.routeCall('9999999999', '001');
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals('DUPLICATE_FOUND', r.get('status'), resp);
        System.assertEquals(false, r.get('hasError'), resp);
        System.assertNotEquals(null, r.get('relatedToId'), 'The matched record Id is returned');

        MCube_Apex_Log__c log = softphoneLog();
        System.assertEquals('Success', log.Status__c, 'A clean route is logged as a success');
        System.assertEquals('Outbound', log.Call_Type__c, 'routeCall logs an outbound context');
    }

    @IsTest
    static void routeCall_routingError_logsError() {
        seedRouting('001', '9999999999', false);

        Test.startTest();
        String resp = MCubeSoftphoneController.routeCall('12345', '001');   // not 10 digits
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals(true, r.get('hasError'), resp);
        System.assertEquals('INVALID_NUMBER', r.get('status'), resp);
        System.assertEquals('Error', softphoneLog().Status__c, 'A routing error is logged as an error');
    }

    // ── getRecordPhone ───────────────────────────────────────────────────

    @IsTest
    static void getRecordPhone_nullId_returnsError() {
        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(null);
        Test.stopTest();

        System.assertEquals('Record ID is null', parse(resp).get('error'), resp);
        System.assertEquals('Click2Call', softphoneLog().Call_Type__c, 'Click2Call context');
    }

    @IsTest
    static void getRecordPhone_leadNoConfig_usesPhoneField() {
        Lead ld = new Lead(LastName = 'Phoney', Company = 'Acme', Phone = '9876500041');
        insert ld;

        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(ld.Id);
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals('9876500041', r.get('phone'), 'Defaults to the standard Phone field');
        System.assertEquals('Phoney', r.get('name'), 'Name comes from the Name field');
        System.assertEquals('Lead', r.get('objectType'));
    }

    @IsTest
    static void getRecordPhone_blankPhone_fallsBackToMobile() {
        Contact con = new Contact(LastName = 'Mobile Only', MobilePhone = '9876500042');
        insert con;

        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(con.Id);
        Test.stopTest();

        System.assertEquals('9876500042', parse(resp).get('phone'),
            'A blank primary phone falls back to MobilePhone: ' + resp);
    }

    @IsTest
    static void getRecordPhone_phoneFieldPreferredOverMobile() {
        Lead ld = new Lead(LastName = 'Both Numbers', Company = 'Acme',
                           Phone = '1111111111', MobilePhone = '9876500043');
        insert ld;

        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(ld.Id);
        Test.stopTest();

        System.assertEquals('1111111111', parse(resp).get('phone'),
            'MobilePhone is only a fallback — a populated Phone wins: ' + resp);
    }

    @IsTest
    static void getRecordPhone_missingPhoneFieldOnObject_returnsError() {
        // Case has no standard Phone field, so it is never added to the query and
        // rec.get('Phone') throws — surfacing through the outer catch.
        Case cse = new Case(Subject = 'No Phone Field');
        insert cse;

        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(cse.Id);
        Test.stopTest();

        System.assertNotEquals(null, parse(resp).get('error'),
            'The unreadable field surfaces through the outer catch: ' + resp);
        System.assertEquals('Error', softphoneLog().Status__c, 'Logged as an error');
    }

    @IsTest
    static void getRecordPhone_deletedRecord_returnsNotFound() {
        Lead ld = makeLead('9876500045');
        Id deletedId = ld.Id;
        delete ld;

        Test.startTest();
        String resp = MCubeSoftphoneController.getRecordPhone(deletedId);
        Test.stopTest();

        Map<String, Object> r = parse(resp);
        System.assertEquals('Record not found', r.get('error'), resp);
        System.assertEquals('Lead', r.get('objectType'), 'The object type is still derived from the Id');
    }

    // ── getPhoneNumbers ──────────────────────────────────────────────────

    @IsTest
    static void getPhoneNumbers_nullId_returnsEmpty() {
        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(null);
        Test.stopTest();

        System.assertEquals(0, numbers.size(), 'A null recordId returns an empty list');
        System.assertEquals('Error', softphoneLog().Status__c, 'Logged as an error');
    }

    @IsTest
    static void getPhoneNumbers_leadWithBothNumbers_returnsBoth() {
        Lead ld = new Lead(LastName = 'Two Numbers', Company = 'Acme',
                           Phone = '1111100001', MobilePhone = '2222200002');
        insert ld;

        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(ld.Id);
        Test.stopTest();

        Set<String> found = new Set<String>(numbers);
        System.assertEquals(2, found.size(), 'Both phone-type fields are discovered: ' + numbers);
        System.assert(found.contains('1111100001'), 'Phone returned');
        System.assert(found.contains('2222200002'), 'MobilePhone returned');
    }

    @IsTest
    static void getPhoneNumbers_duplicateValues_dedupes() {
        Lead ld = new Lead(LastName = 'Same Number', Company = 'Acme',
                           Phone = '3333300003', MobilePhone = '3333300003');
        insert ld;

        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(ld.Id);
        Test.stopTest();

        System.assertEquals(1, numbers.size(), 'Identical values collapse to one entry: ' + numbers);
        System.assertEquals('3333300003', numbers[0]);
    }

    @IsTest
    static void getPhoneNumbers_nonPhoneTypeFieldExcluded() {
        // Title is not a PHONE-type field, so discovery must ignore it.
        Lead ld = new Lead(LastName = 'Non Phone Field', Company = 'Acme',
                           Phone = '4444400004', Title = '5555500005');
        insert ld;

        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(ld.Id);
        Test.stopTest();

        Set<String> found = new Set<String>(numbers);
        System.assert(found.contains('4444400004'), 'Discovered the phone-type field: ' + numbers);
        System.assert(!found.contains('5555500005'),
            'Only DisplayType.PHONE fields are discovered: ' + numbers);
    }

    @IsTest
    static void getPhoneNumbers_objectWithNoPhoneFields_returnsEmpty() {
        MCube_Apex_Log__c log = new MCube_Apex_Log__c(Event_Type__c = 'Probe');
        insert log;

        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(log.Id);
        Test.stopTest();

        System.assertEquals(0, numbers.size(), 'An object with no phone fields yields nothing');
        System.assertEquals('No phone fields found', softphoneLog().Error_Message__c,
            'The reason is recorded even though the outcome is a success');
    }

    @IsTest
    static void getPhoneNumbers_deletedRecord_returnsEmpty() {
        Lead ld = makeLead('9876500046');
        Id deletedId = ld.Id;
        delete ld;

        Test.startTest();
        List<String> numbers = MCubeSoftphoneController.getPhoneNumbers(deletedId);
        Test.stopTest();

        System.assertEquals(0, numbers.size(), 'A deleted record yields nothing');
        System.assertEquals('Record not found', softphoneLog().Error_Message__c, 'Reason recorded');
    }

    // ── logCallActivity ──────────────────────────────────────────────────

    @IsTest
    static void logCallActivity_withSubject_createsTask() {
        Test.startTest();
        String taskId = MCubeSoftphoneController.logCallActivity(
            null, null, 'Outbound', 125, 'Follow-up call', 'Discussed the renewal.');
        Test.stopTest();

        System.assertNotEquals(null, taskId, 'A Task Id is returned');
        Task t = [
            SELECT Subject, Description, CallType, CallDurationInSeconds,
                   Status, Priority, ActivityDate, TaskSubtype
            FROM Task WHERE Id = :taskId
        ];
        System.assertEquals('Follow-up call', t.Subject, 'Explicit subject used');
        System.assertEquals('Discussed the renewal.', t.Description, 'Description stored');
        System.assertEquals('Outbound', t.CallType, 'Call type stored');
        System.assertEquals(125, t.CallDurationInSeconds, 'Duration stored');
        System.assertEquals('Completed', t.Status, 'Calls are logged as completed');
        System.assertEquals('Normal', t.Priority, 'Default priority');
        System.assertEquals('Call', t.TaskSubtype, 'Logged as a Call subtype');
        System.assertEquals(Date.today(), t.ActivityDate, 'Dated today');
    }

    @IsTest
    static void logCallActivity_blankSubject_defaultsToCallTypeCall() {
        Test.startTest();
        String taskId = MCubeSoftphoneController.logCallActivity(
            null, null, 'Inbound', 30, '   ', null);
        Test.stopTest();

        Task t = [SELECT Subject FROM Task WHERE Id = :taskId];
        System.assertEquals('Inbound Call', t.Subject, 'A blank subject falls back to "<type> Call"');
    }

    @IsTest
    static void logCallActivity_withWhoAndWhat_setsLookups() {
        Contact con = new Contact(LastName = 'Who');
        insert con;
        Account acc = new Account(Name = 'What');
        insert acc;

        Test.startTest();
        String taskId = MCubeSoftphoneController.logCallActivity(
            con.Id, acc.Id, 'Inbound', 45, 'Linked call', null);
        Test.stopTest();

        Task t = [SELECT WhoId, WhatId FROM Task WHERE Id = :taskId];
        System.assertEquals(con.Id, t.WhoId, 'WhoId set from the contact');
        System.assertEquals(acc.Id, t.WhatId, 'WhatId set from the account');
    }

    @IsTest
    static void logCallActivity_invalidWhoId_rethrows() {
        Account acc = new Account(Name = 'Not A Person');
        insert acc;

        Boolean rethrown = false;
        Test.startTest();
        try {
            MCubeSoftphoneController.logCallActivity(acc.Id, null, 'Inbound', 10, 'Bad who', null);
        } catch (Exception e) {
            rethrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, rethrown, 'An Account Id in WhoId must fail and be rethrown');
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'No task was created');
        System.assertEquals('Error', softphoneLog().Status__c, 'The failure is logged before rethrowing');
    }

    // ── logCallDetails ───────────────────────────────────────────────────

    @IsTest
    static void logCallDetails_createsRecord() {
        Test.startTest();
        String cdId = MCubeSoftphoneController.logCallDetails(
            'CD-1', 'Inbound', '2026-06-23T10:00:00.000Z', '2026-06-23T10:05:00.000Z', 300,
            '9876500051', '8000000001', 'https://rec.example.com/1', 'PARENT-1',
            'Completed', 'Campaign', 'Sub', null, null, null, '001');
        Test.stopTest();

        Call_Details__c cd = [
            SELECT Call_Id__c, Call_Type__c, Duration__c, Customer_Number__c, Executive_Number__c,
                   Recording_URL__c, Parent_Id__c, Status__c, Source__c, Sub_Source__c,
                   Landing_Number__c, Start_Time__c, End_Time__c
            FROM Call_Details__c WHERE Id = :cdId
        ];
        System.assertEquals('CD-1', cd.Call_Id__c, 'External Id set');
        System.assertEquals('Inbound', cd.Call_Type__c, 'Call type set');
        System.assertEquals(300, cd.Duration__c, 'Duration set');
        System.assertEquals('9876500051', cd.Customer_Number__c, 'Customer number set');
        System.assertEquals('8000000001', cd.Executive_Number__c, 'Executive number set');
        System.assertEquals('https://rec.example.com/1', cd.Recording_URL__c, 'Recording URL set');
        System.assertEquals('PARENT-1', cd.Parent_Id__c, 'Parent call id set');
        System.assertEquals('Completed', cd.Status__c, 'Status set');
        System.assertEquals('Campaign', cd.Source__c, 'Source set');
        System.assertEquals('Sub', cd.Sub_Source__c, 'Sub source set');
        System.assertEquals('001', cd.Landing_Number__c, 'Landing number set');
        System.assertNotEquals(null, cd.Start_Time__c, 'ISO start time parsed');
        System.assertNotEquals(null, cd.End_Time__c, 'ISO end time parsed');
    }

    @IsTest
    static void logCallDetails_sameCallId_upsertsOnce() {
        Test.startTest();
        String first = MCubeSoftphoneController.logCallDetails(
            'CD-2', 'Inbound', null, null, null, '9876500052', null, null, null,
            'Completed', null, null, null, null, null, '001');
        String second = MCubeSoftphoneController.logCallDetails(
            'CD-2', 'Inbound', null, null, 240, '9876500052', null,
            'https://rec.example.com/2', null, 'Completed', null, null, null, null, null, '001');
        Test.stopTest();

        System.assertEquals(first, second, 'The same Call_Id__c upserts the same record');
        System.assertEquals(1, [SELECT COUNT() FROM Call_Details__c WHERE Call_Id__c = 'CD-2'],
            'Call_Id__c is an external id — never duplicated');
        Call_Details__c cd = [
            SELECT Duration__c, Recording_URL__c FROM Call_Details__c WHERE Call_Id__c = 'CD-2'
        ];
        System.assertEquals(240, cd.Duration__c, 'The hangup event enriched the record');
        System.assertEquals('https://rec.example.com/2', cd.Recording_URL__c, 'Recording URL added');
    }

    @IsTest
    static void logCallDetails_blankStatus_defaultsCompleted() {
        Test.startTest();
        String cdId = MCubeSoftphoneController.logCallDetails(
            'CD-3', 'Outbound', null, null, null, '9876500053', null, null, null,
            '   ', null, null, null, null, null, null);
        Test.stopTest();

        Call_Details__c cd = [SELECT Status__c FROM Call_Details__c WHERE Id = :cdId];
        System.assertEquals('Completed', cd.Status__c, 'A blank status defaults to Completed');
    }

    @IsTest
    static void logCallDetails_relatedContact_setsContactLookup() {
        Contact con = new Contact(LastName = 'Related');
        insert con;

        Test.startTest();
        String cdId = MCubeSoftphoneController.logCallDetails(
            'CD-4', 'Inbound', null, null, null, '9876500054', null, null, null,
            'Completed', null, null, null, con.Id, 'Contact', null);
        Test.stopTest();

        Call_Details__c cd = [
            SELECT Contact__c, Related_Record_Id__c, Related_Object_Type__c
            FROM Call_Details__c WHERE Id = :cdId
        ];
        System.assertEquals(con.Id, cd.Contact__c, 'Typed Contact lookup set');
        System.assertEquals(String.valueOf(con.Id), cd.Related_Record_Id__c, 'Generic id also stored');
        System.assertEquals('Contact', cd.Related_Object_Type__c, 'Object type stored');
    }

    @IsTest
    static void logCallDetails_relatedAccountAndCase_setLookups() {
        Account acc = new Account(Name = 'Related Account');
        insert acc;
        Case cse = new Case(Subject = 'Related Case');
        insert cse;

        Test.startTest();
        MCubeSoftphoneController.logCallDetails(
            'CD-5', 'Inbound', null, null, null, '9876500055', null, null, null,
            'Completed', null, null, null, acc.Id, 'Account', null);
        MCubeSoftphoneController.logCallDetails(
            'CD-6', 'Inbound', null, null, null, '9876500056', null, null, null,
            'Completed', null, null, null, cse.Id, 'Case', null);
        Test.stopTest();

        System.assertEquals(acc.Id,
            [SELECT Account__c FROM Call_Details__c WHERE Call_Id__c = 'CD-5'].Account__c,
            'Typed Account lookup set');
        System.assertEquals(cse.Id,
            [SELECT Case__c FROM Call_Details__c WHERE Call_Id__c = 'CD-6'].Case__c,
            'Typed Case lookup set');
    }

    @IsTest
    static void logCallDetails_leadIdWinsOverRelatedLead() {
        Lead direct  = makeLead('9876500057');
        Lead related = makeLead('9876500058');

        Test.startTest();
        String cdId = MCubeSoftphoneController.logCallDetails(
            'CD-7', 'Inbound', null, null, null, '9876500057', null, null, null,
            'Completed', null, null, direct.Id, related.Id, 'Lead', null);
        Test.stopTest();

        Call_Details__c cd = [
            SELECT Lead__c, Related_Record_Id__c FROM Call_Details__c WHERE Id = :cdId
        ];
        System.assertEquals(direct.Id, cd.Lead__c,
            'An explicit leadId is not overwritten by a Lead-typed related record');
        System.assertEquals(String.valueOf(related.Id), cd.Related_Record_Id__c,
            'The related record id is still tracked separately');
    }

    @IsTest
    static void logCallDetails_badDateTime_rethrows() {
        Boolean rethrown = false;
        Test.startTest();
        try {
            MCubeSoftphoneController.logCallDetails(
                'CD-8', 'Inbound', 'garbage', null, null, '9876500059', null, null, null,
                'Completed', null, null, null, null, null, null);
        } catch (Exception e) {
            rethrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, rethrown, 'An unparseable ISO datetime must be rethrown');
        System.assertEquals(0, [SELECT COUNT() FROM Call_Details__c], 'Nothing was persisted');
        System.assertEquals('Error', softphoneLog().Status__c, 'The failure is logged before rethrowing');
    }
}
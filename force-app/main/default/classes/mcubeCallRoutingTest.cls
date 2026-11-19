/**
 * Tests for mcubeCallRouting — the MCube call-routing REST API.
 * Covers: duplicate found, lead created, no-config, creation-disabled, and error paths,
 * plus verification that an MCube_Apex_Log__c row is written for each call.
 */
@isTest
private class mcubeCallRoutingTest {

    private static final String DUP_RULE = 'SELECT Id, MobilePhone FROM Lead WHERE MobilePhone = :customerNumber';
    private static final String DEFAULTS = '[{"field":"LastName","value":"Routed Lead"},{"field":"Company","value":"Routed Co"}]';

    @TestSetup
    static void setup() {
        // Existing Lead used for the duplicate-match scenario
        insert new Lead(LastName = 'Existing', Company = 'Existing Co', MobilePhone = '9999999999');

        // Config 1 — active, creation enabled
        MCube_Configuration__c cfg1 = new MCube_Configuration__c(
            Name = 'MCube - Lead (route test 1)',
            Source_Object__c       = 'Lead',
            Duplication_rule__c    = DUP_RULE,
            Default_Values__c      = DEFAULTS,
            Create_If_Not_Found__c = true,
            Is_Active__c           = true
        );
        // Config 2 — active, creation DISABLED
        MCube_Configuration__c cfg2 = new MCube_Configuration__c(
            Name = 'MCube - Lead (route test 2)',
            Source_Object__c       = 'Lead',
            Duplication_rule__c    = DUP_RULE,
            Create_If_Not_Found__c = false,
            Is_Active__c           = true
        );
        // Config 3 — invalid SOQL to exercise the error path
        MCube_Configuration__c cfg3 = new MCube_Configuration__c(
            Name = 'MCube - Lead (route test 3)',
            Source_Object__c       = 'Lead',
            Duplication_rule__c    = 'SELECT Id FROM Lead WHERE',
            Create_If_Not_Found__c = true,
            Is_Active__c           = true
        );
        insert new List<MCube_Configuration__c>{ cfg1, cfg2, cfg3 };

        insert new List<Mcube_Landing_Number__c>{
            new Mcube_Landing_Number__c(Number__c = '001', Source__c = 'Newspaper', MCube_Configuration__c = cfg1.Id),
            new Mcube_Landing_Number__c(Number__c = '002', Source__c = 'Hoarding',  MCube_Configuration__c = cfg2.Id),
            new Mcube_Landing_Number__c(Number__c = '003', Source__c = 'Digital',   MCube_Configuration__c = cfg3.Id)
        };
    }

    @isTest
    static void testDuplicateFound() {
        Lead existing = [SELECT Id FROM Lead WHERE MobilePhone = '9999999999' LIMIT 1];

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('9999999999', '001');
        Test.stopTest();

        System.assertEquals('DUPLICATE_FOUND', resp.status, 'Should match the existing Lead');
        System.assertEquals(existing.Id, resp.relatedToId, 'Should return the existing Lead Id');
        System.assertEquals(false, resp.hasError);
        assertLogged('DUPLICATE_FOUND', false);
    }

    @isTest
    static void testLeadCreated() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('8888888888', '001');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status);
        System.assertNotEquals(null, resp.relatedToId, 'A new Lead Id should be returned');
        System.assertEquals(false, resp.hasError);

        Lead created = [SELECT MobilePhone, LastName, Company FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('8888888888', created.MobilePhone, 'customerNumber → MobilePhone');
        System.assertEquals('Routed Lead', created.LastName, 'default LastName applied');
        System.assertEquals('Routed Co',   created.Company,  'default Company applied');
        assertLogged('LEAD_CREATED', false);
    }

    @isTest
    static void testNoConfig() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('7777777777', '999');
        Test.stopTest();

        System.assertEquals('NO_CONFIG', resp.status);
        System.assertEquals(null, resp.relatedToId);
        assertLogged('NO_CONFIG', false);
    }

    @isTest
    static void testCreationDisabled() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('6666666666', '002');
        Test.stopTest();

        System.assertEquals('NOT_CREATED', resp.status);
        System.assertEquals(null, resp.relatedToId);
        assertLogged('NOT_CREATED', false);
    }

    @isTest
    static void testErrorPath() {
        // cfg3 (landing '003') has an invalid dedup rule and is the only config for
        // that landing number. The broken rule is logged as CONFIG_ERROR and skipped;
        // with no other config and creation enabled, a Lead is then created.
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('5555555555', '003');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status, 'Broken rule is skipped, then Lead is created');
        System.assertEquals(false, resp.hasError);
        System.assertNotEquals(null, resp.relatedToId, 'A new Lead Id should be returned');

        // A CONFIG_ERROR audit row is written for the broken dedup rule.
        List<MCube_Apex_Log__c> errLogs = [
            SELECT Status__c, Has_Error__c FROM MCube_Apex_Log__c WHERE Status__c = 'CONFIG_ERROR'
        ];
        System.assertEquals(1, errLogs.size(), 'Broken config should log a CONFIG_ERROR row');
        System.assertEquals(true, errLogs[0].Has_Error__c);
    }

    @isTest
    static void testNonLeadMissThenLeadMatches() {
        // Landing '021' has an Account config (priority 1) that won't match, and a
        // Lead config (priority 2). After the Account config misses, the Lead config
        // matches the caller → returns the existing Lead.
        Lead existing = [SELECT Id FROM Lead WHERE MobilePhone = '9999999999' LIMIT 1];

        MCube_Configuration__c acct = new MCube_Configuration__c(
            Name = 'MCube - Account 021', Source_Object__c = 'Account',
            Duplication_rule__c = 'SELECT Id, Phone FROM Account WHERE Phone = :customerNumber',
            Create_If_Not_Found__c = false, Is_Active__c = true, Priority__c = '1'
        );
        MCube_Configuration__c leadCfg = new MCube_Configuration__c(
            Name = 'MCube - Lead 021', Source_Object__c = 'Lead',
            Duplication_rule__c = DUP_RULE, Create_If_Not_Found__c = true, Is_Active__c = true, Priority__c = '2'
        );
        insert new List<MCube_Configuration__c>{ acct, leadCfg };
        insert new List<Mcube_Landing_Number__c>{
            new Mcube_Landing_Number__c(Number__c = '021', Source__c = 'Digital', MCube_Configuration__c = acct.Id),
            new Mcube_Landing_Number__c(Number__c = '021', Source__c = 'Digital', MCube_Configuration__c = leadCfg.Id)
        };

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('9999999999', '021');
        Test.stopTest();

        System.assertEquals('DUPLICATE_FOUND', resp.status, 'Lead config should match after the Account config misses');
        System.assertEquals(existing.Id, resp.relatedToId, 'Should return the Lead matched by the Lead config');
    }

    @isTest
    static void testGlobalLeadConfigFallback() {
        // Landing '050' maps ONLY to an Account config (no Lead config attached).
        // After the Account config misses, the active Lead config org-wide (priority
        // '0', unmapped to this landing) must be used to dedup and create the Lead.
        MCube_Configuration__c acct = new MCube_Configuration__c(
            Name = 'MCube - Account 050', Source_Object__c = 'Account',
            Duplication_rule__c = 'SELECT Id, Phone FROM Account WHERE Phone = :customerNumber',
            Create_If_Not_Found__c = false, Is_Active__c = true, Priority__c = '1'
        );
        MCube_Configuration__c globalLead = new MCube_Configuration__c(
            Name = 'MCube - Global Lead', Source_Object__c = 'Lead',
            Duplication_rule__c = DUP_RULE, Create_If_Not_Found__c = true, Is_Active__c = true, Priority__c = '0',
            Default_Values__c = '[{"field":"LastName","value":"Global Fallback"},{"field":"Company","value":"Global Co"}]'
        );
        insert new List<MCube_Configuration__c>{ acct, globalLead };
        // Only the Account config is mapped to landing '050' — the Lead config is NOT.
        insert new Mcube_Landing_Number__c(Number__c = '050', Source__c = 'Digital', MCube_Configuration__c = acct.Id);

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('7778889992', '050');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status, 'Global Lead config must be the fallback creator');
        Lead created = [SELECT LastName, Company FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('Global Fallback', created.LastName, 'Must create from the global Lead config defaults');
    }

    @isTest
    static void testPriorityResolution() {
        // Two active configs share landing number '010'; the priority-'1' config
        // must win over the priority-'2' config.
        MCube_Configuration__c high = new MCube_Configuration__c(
            Name = 'MCube - priority high', Source_Object__c = 'Lead',
            Duplication_rule__c = DUP_RULE, Create_If_Not_Found__c = true, Is_Active__c = true,
            Priority__c = '1',
            Default_Values__c = '[{"field":"LastName","value":"HighPri"},{"field":"Company","value":"Co"}]'
        );
        MCube_Configuration__c low = new MCube_Configuration__c(
            Name = 'MCube - priority low', Source_Object__c = 'Lead',
            Duplication_rule__c = DUP_RULE, Create_If_Not_Found__c = true, Is_Active__c = true,
            Priority__c = '2',
            Default_Values__c = '[{"field":"LastName","value":"LowPri"},{"field":"Company","value":"Co"}]'
        );
        insert new List<MCube_Configuration__c>{ high, low };
        insert new List<Mcube_Landing_Number__c>{
            new Mcube_Landing_Number__c(Number__c = '010', Source__c = 'Digital', MCube_Configuration__c = high.Id),
            new Mcube_Landing_Number__c(Number__c = '010', Source__c = 'Digital', MCube_Configuration__c = low.Id)
        };

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('1212121212', '010');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status);
        Lead created = [SELECT LastName FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('HighPri', created.LastName, 'Priority-1 config should be chosen');
    }

    @isTest
    static void testLeadConfigIsLastResortAndCreationSource() {
        // Landing '030' has an Account config (priority 1) and a Lead config
        // (priority 2). The caller matches neither → the Account config is checked
        // first, the Lead config last, and the new Lead uses the LEAD config's
        // default values (not the Account config's).
        MCube_Configuration__c acct = new MCube_Configuration__c(
            Name = 'MCube - Account 030', Source_Object__c = 'Account',
            Duplication_rule__c = 'SELECT Id, Phone FROM Account WHERE Phone = :customerNumber',
            Create_If_Not_Found__c = false, Is_Active__c = true, Priority__c = '1',
            Default_Values__c = '[{"field":"LastName","value":"ShouldNotUse"},{"field":"Company","value":"AcctCo"}]'
        );
        MCube_Configuration__c leadCfg = new MCube_Configuration__c(
            Name = 'MCube - Lead 030', Source_Object__c = 'Lead',
            Duplication_rule__c = DUP_RULE, Create_If_Not_Found__c = true, Is_Active__c = true, Priority__c = '2',
            Default_Values__c = '[{"field":"LastName","value":"Fallback Lead"},{"field":"Company","value":"Fallback Co"}]'
        );
        insert new List<MCube_Configuration__c>{ acct, leadCfg };
        insert new List<Mcube_Landing_Number__c>{
            new Mcube_Landing_Number__c(Number__c = '030', Source__c = 'Digital', MCube_Configuration__c = acct.Id),
            new Mcube_Landing_Number__c(Number__c = '030', Source__c = 'Digital', MCube_Configuration__c = leadCfg.Id)
        };

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('7778889990', '030');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status, 'Neither config matches → Lead created');
        Lead created = [SELECT LastName, Company FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('Fallback Lead', created.LastName, 'Creation must use the LEAD config defaults');
        System.assertEquals('Fallback Co',   created.Company,  'Creation must use the LEAD config defaults');
    }

    @isTest
    static void testCallFromAliasDedups() {
        // A config authored with MCube field names (:callFrom) must resolve to the
        // caller's number so it dedups instead of being skipped as a null bind.
        Lead existing = [SELECT Id FROM Lead WHERE MobilePhone = '9999999999' LIMIT 1];

        MCube_Configuration__c cfg = new MCube_Configuration__c(
            Name = 'MCube - Lead callFrom', Source_Object__c = 'Lead',
            Duplication_rule__c = 'SELECT Id, MobilePhone FROM Lead WHERE MobilePhone = :callFrom',
            Create_If_Not_Found__c = true, Is_Active__c = true, Priority__c = '1'
        );
        insert cfg;
        insert new Mcube_Landing_Number__c(Number__c = '040', Source__c = 'Digital', MCube_Configuration__c = cfg.Id);

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('9999999999', '040');
        Test.stopTest();

        System.assertEquals('DUPLICATE_FOUND', resp.status, ':callFrom must resolve and match the existing Lead');
        System.assertEquals(existing.Id, resp.relatedToId);
    }

    @isTest
    static void testBlankLanding() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('5555555555', '');
        Test.stopTest();

        System.assertEquals('NO_CONFIG', resp.status);
    }

    @isTest
    static void testNormalizePlus91Duplicate() {
        // '+919999999999' → '9999999999' → matches the existing setup Lead
        Lead existing = [SELECT Id FROM Lead WHERE MobilePhone = '9999999999' LIMIT 1];

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('+919999999999', '001');
        Test.stopTest();

        System.assertEquals('DUPLICATE_FOUND', resp.status, '+91 prefix should be stripped and matched');
        System.assertEquals(existing.Id, resp.relatedToId);
    }

    @isTest
    static void testNormalize91Create() {
        // '918888888888' → '8888888888' (no existing match) → new Lead
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('918888888888', '001');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status);
        Lead created = [SELECT MobilePhone FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('8888888888', created.MobilePhone, '91 prefix stripped to 10 digits');
    }

    @isTest
    static void testNormalizeSeparators() {
        // '(799) 346-3758' → '7993463758'
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('(799) 346-3758', '001');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status);
        Lead created = [SELECT MobilePhone FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('7993463758', created.MobilePhone, 'separators stripped to 10 digits');
    }

    @isTest
    static void testTenDigitStartingWith91NotTruncated() {
        // '9123456789' is already 10 digits (starts with 91) — must NOT be stripped
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('9123456789', '001');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status);
        Lead created = [SELECT MobilePhone FROM Lead WHERE Id = :resp.relatedToId];
        System.assertEquals('9123456789', created.MobilePhone, '10-digit number starting 91 kept intact');
    }

    @isTest
    static void testInvalidNumber() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('12345', '001');
        Test.stopTest();

        System.assertEquals('INVALID_NUMBER', resp.status);
        System.assertEquals(true, resp.hasError);
        System.assertEquals(null, resp.relatedToId);
        assertLogged('INVALID_NUMBER', true);
    }

    @isTest
    static void testBlankNumber() {
        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('', '001');
        Test.stopTest();

        System.assertEquals('INVALID_NUMBER', resp.status);
        System.assertEquals(true, resp.hasError);
    }

    @isTest
    static void testLoggingDisabled() {
        // MCube_Config__mdt flag off → routing still works but no log is written
        mcubeCallRouting.apexLogsEnabledOverride = false;

        Test.startTest();
        mcubeCallRouting.RoutingResponse resp = mcubeCallRouting.route('8888888888', '001');
        Test.stopTest();

        System.assertEquals('LEAD_CREATED', resp.status, 'Routing still works when logging is disabled');
        System.assertEquals(0, [SELECT COUNT() FROM MCube_Apex_Log__c], 'No log should be written when disabled');
    }

    private static void assertLogged(String expectedStatus, Boolean expectedHasError) {
        List<MCube_Apex_Log__c> logs = [
            SELECT Event_Type__c, Status__c, Has_Error__c
            FROM MCube_Apex_Log__c
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals(1, logs.size(), 'A log row should be written');
        System.assertEquals('Call Routing', logs[0].Event_Type__c);
        System.assertEquals(expectedStatus, logs[0].Status__c);
        System.assertEquals(expectedHasError, logs[0].Has_Error__c);
    }
}
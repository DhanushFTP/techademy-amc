/**
 * Tests for McubeConfigController — the config-wizard server controller.
 *
 * No @TestSetup on purpose: nearly every saveConfig scenario needs a DIFFERENT
 * starting DB state (empty / one active config / one inactive config / edit by
 * Id), and a shared setup would fight every merge-vs-create assertion.
 *
 * Two hard data constraints this class works around:
 *   1. MCube_Configuration__c.Priority__c is unique=true — every seeded row uses
 *      a distinct value.
 *   2. The "Duplicate landing number" rule on Mcube_Landing_Number__c is ACTIVE
 *      and blocks on insert AND update (exact match on Number__c) — every test
 *      uses its own number prefix so numbers stay unique within a transaction.
 */
@isTest
private class McubeConfigControllerTest {

    // Landing_Number__c and Outbound_Fields__c are TextArea (255 chars) — keep
    // the JSON in these constants short.
    private static final String DUP_RULE   =
        'SELECT Id FROM Lead WHERE MobilePhone = :customerNumber LIMIT 1';
    private static final String DEFAULTS   = '[{"field":"LastName","value":"New"}]';
    private static final String OUTBOUND   = '[{"order":1,"field":"Phone","label":"Phone"}]';
    private static final String ACTIVITY   =
        '{"enabled":true,"object":"Task","mappings":[{"field":"Subject","value":"callStatus"}]}';

    // ── Helpers ──────────────────────────────────────────────────────────

    private static MCube_Configuration__c seedConfig(String sourceObject, String priority, Boolean isActive) {
        MCube_Configuration__c c = new MCube_Configuration__c(
            Name             = 'MCube - ' + sourceObject,
            Source_Object__c = sourceObject,
            Priority__c      = priority,
            Is_Active__c     = isActive
        );
        insert c;
        return c;
    }

    private static Mcube_Landing_Number__c seedLanding(String num, Id configId) {
        Mcube_Landing_Number__c ln = new Mcube_Landing_Number__c(
            Number__c              = num,
            Source__c              = 'Digital',
            Campaign_Name__c       = 'Seeded',
            MCube_Configuration__c = configId
        );
        insert ln;
        return ln;
    }

    /** saveConfig in BOTH mode — the wizard's normal inbound+outbound path. */
    private static void saveBoth(String sourceObject, String dupRule, String defaults,
                                 String landingNumbers, String landingDetails, String outboundFields,
                                 String activityMapping, Boolean createIfNotFound, Boolean isActive,
                                 Boolean isDefault, String recordId, String priority) {
        McubeConfigController.saveConfig(
            'Wizard Config', sourceObject, dupRule, defaults, landingNumbers, landingDetails,
            outboundFields, activityMapping, createIfNotFound, isActive, isDefault,
            recordId, 'BOTH', priority
        );
    }

    /** saveConfig in OUTBOUND_ONLY mode — click-to-call configs. */
    private static void saveOutbound(String sourceObject, String landingDetails, String outboundFields,
                                     String activityMapping, Boolean isActive, Boolean isDefault,
                                     String recordId, String priority) {
        McubeConfigController.saveConfig(
            'Wizard Config', sourceObject, DUP_RULE, DEFAULTS, '{"Digital":["9999"]}', landingDetails,
            outboundFields, activityMapping, true, isActive, isDefault,
            recordId, 'OUTBOUND_ONLY', priority
        );
    }

    private static List<MCube_Configuration__c> allConfigs() {
        return [
            SELECT Id, Name, Source_Object__c, Configuration_Mode__c, Duplication_rule__c,
                   Default_Values__c, Landing_Number__c, Outbound_Fields__c,
                   Call_Activity_Mapping__c, Priority__c, Create_If_Not_Found__c,
                   Is_Active__c, Is_Default__c
            FROM MCube_Configuration__c
            ORDER BY CreatedDate
        ];
    }

    /** Asserts exactly one configuration exists and returns it. */
    private static MCube_Configuration__c onlyConfig() {
        List<MCube_Configuration__c> all = allConfigs();
        System.assertEquals(1, all.size(), 'Expected exactly one MCube_Configuration__c');
        return all[0];
    }

    private static List<Mcube_Landing_Number__c> allLandings() {
        return [
            SELECT Id, Number__c, Source__c, Campaign_Name__c, MCube_Configuration__c
            FROM Mcube_Landing_Number__c
            ORDER BY CreatedDate
        ];
    }

    /**
     * Structural readers — JSON.deserializeUntyped returns an unordered Map, so
     * asserting on the serialized string is fragile. Compare structure instead.
     */
    // NB: these parameters must not be called `json` — Apex identifiers are
    // case-insensitive, so that would shadow the System.JSON class.
    private static Map<String, Object> asMap(String payload) {
        return (Map<String, Object>) JSON.deserializeUntyped(payload);
    }

    private static Map<String, String> fieldValues(String payload) {
        Map<String, String> out = new Map<String, String>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(payload)) {
            Map<String, Object> m = (Map<String, Object>) o;
            out.put(String.valueOf(m.get('field')), String.valueOf(m.get('value')));
        }
        return out;
    }

    private static List<String> fieldOrder(String payload) {
        List<String> out = new List<String>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(payload)) {
            out.add(String.valueOf(((Map<String, Object>) o).get('field')));
        }
        return out;
    }

    /** Numbers configured for one source in the merged landing-number map. */
    private static List<String> numbersFor(String payload, String source) {
        List<String> out = new List<String>();
        Object raw = asMap(payload).get(source);
        if (raw instanceof List<Object>) {
            for (Object o : (List<Object>) raw) out.add(String.valueOf(o));
        }
        return out;
    }

    // ── saveConfig — create path ─────────────────────────────────────────

    @isTest
    static void saveConfig_newBothMode_createsRecordAndLandingNumbers() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Newspaper":["7101"]}',
                 '[{"source":"Newspaper","num":"7101","campaign":"Camp A"}]',
                 OUTBOUND, ACTIVITY, true, true, true, null, '101');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals('MCube - Lead', c.Name, 'Name is derived from the source object');
        System.assertEquals('Lead', c.Source_Object__c, 'Source object');
        System.assertEquals('BOTH', c.Configuration_Mode__c, 'Configuration mode');
        System.assertEquals(DUP_RULE, c.Duplication_rule__c, 'Dedup SOQL written verbatim');
        System.assertEquals(DEFAULTS, c.Default_Values__c, 'Defaults written verbatim');
        System.assertEquals('{"Newspaper":["7101"]}', c.Landing_Number__c, 'Landing map written verbatim');
        System.assertEquals(OUTBOUND, c.Outbound_Fields__c, 'Outbound fields written verbatim');
        System.assertEquals(ACTIVITY, c.Call_Activity_Mapping__c, 'Activity mapping written verbatim');
        System.assertEquals('101', c.Priority__c, 'Priority');
        System.assertEquals(true, c.Create_If_Not_Found__c, 'Create-if-not-found');
        System.assertEquals(true, c.Is_Active__c, 'Is active');
        System.assertEquals(true, c.Is_Default__c, 'Is default');

        List<Mcube_Landing_Number__c> lns = allLandings();
        System.assertEquals(1, lns.size(), 'Landing number synced');
        System.assertEquals('7101', lns[0].Number__c, 'Landing number value');
        System.assertEquals('Newspaper', lns[0].Source__c, 'Landing source');
        System.assertEquals('Camp A', lns[0].Campaign_Name__c, 'Campaign name');
        System.assertEquals(c.Id, lns[0].MCube_Configuration__c, 'Linked to the new config');
    }

    @isTest
    static void saveConfig_blankConfigMode_defaultsToBoth() {
        Test.startTest();
        McubeConfigController.saveConfig(
            'Wizard Config', 'Contact', DUP_RULE, DEFAULTS, '{"Digital":["7111"]}',
            '[{"source":"Digital","num":"7111","campaign":"C"}]', OUTBOUND, ACTIVITY,
            false, true, false, null, null, '111'
        );
        Test.stopTest();

        System.assertEquals('BOTH', onlyConfig().Configuration_Mode__c,
            'Blank configMode falls back to BOTH');
        System.assertEquals(1, allLandings().size(),
            'BOTH mode still syncs landing numbers when configMode was blank');
    }

    // ── saveConfig — merge path (existing ACTIVE config, no recordId) ─────

    @isTest
    static void saveConfig_existingActiveConfig_mergesInsteadOfCreating() {
        MCube_Configuration__c existing = seedConfig('Lead', '120', true);
        existing.Landing_Number__c        = '{"Newspaper":["7201"]}';
        existing.Default_Values__c        = '[{"field":"LastName","value":"Old"},{"field":"Status","value":"Open"}]';
        existing.Outbound_Fields__c       = '[{"order":1,"field":"Phone","label":"Old"}]';
        existing.Duplication_rule__c      = 'SELECT Id FROM Lead LIMIT 1';
        existing.Call_Activity_Mapping__c = '{"enabled":false}';
        existing.Create_If_Not_Found__c   = false;
        existing.Is_Default__c            = false;
        update existing;

        Test.startTest();
        saveBoth('Lead', DUP_RULE,
                 '[{"field":"LastName","value":"New"},{"field":"Company","value":"Acme"}]',
                 '{"Newspaper":["7202"],"Digital":["7203"]}',
                 null,
                 '[{"order":1,"field":"Phone","label":"New"},{"order":2,"field":"Fax","label":"Fax"}]',
                 ACTIVITY, true, true, true, null, '121');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(existing.Id, c.Id, 'Merged into the existing record, no new record created');

        // Landing numbers: sources union'd, numbers within a source union'd
        System.assertEquals(new List<String>{ '7201', '7202' }, numbersFor(c.Landing_Number__c, 'Newspaper'),
            'Existing Newspaper number kept and the new one appended');
        System.assertEquals(new List<String>{ '7203' }, numbersFor(c.Landing_Number__c, 'Digital'),
            'New source added');

        // Default values: new overrides old by `field`, new-only appended, old order kept
        Map<String, String> defaults = fieldValues(c.Default_Values__c);
        System.assertEquals('New', defaults.get('LastName'), 'New value overrides old for the same field');
        System.assertEquals('Open', defaults.get('Status'),  'Old-only entry preserved');
        System.assertEquals('Acme', defaults.get('Company'), 'New-only entry appended');
        System.assertEquals(new List<String>{ 'LastName', 'Status', 'Company' }, fieldOrder(c.Default_Values__c),
            'Old order preserved, new-only entries appended');

        // Outbound fields merge the same way
        Map<String, String> outbound = new Map<String, String>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(c.Outbound_Fields__c)) {
            Map<String, Object> m = (Map<String, Object>) o;
            outbound.put(String.valueOf(m.get('field')), String.valueOf(m.get('label')));
        }
        System.assertEquals('New', outbound.get('Phone'), 'Outbound entry overridden by field key');
        System.assertEquals('Fax', outbound.get('Fax'),   'New outbound entry appended');

        // Replaced, not merged
        System.assertEquals(DUP_RULE, c.Duplication_rule__c, 'Dedup SOQL is replaced, not merged');
        System.assertEquals(ACTIVITY, c.Call_Activity_Mapping__c, 'Activity mapping is replaced');
        System.assertEquals('121', c.Priority__c, 'Priority prefers the new value');
        System.assertEquals(true, c.Create_If_Not_Found__c, 'Flags prefer the new values');
        System.assertEquals(true, c.Is_Default__c, 'Is default prefers the new value');
    }

    @isTest
    static void saveConfig_mergeDedupesRepeatedNumbers() {
        MCube_Configuration__c existing = seedConfig('Lead', '130', true);
        existing.Landing_Number__c = '{"Digital":["7301"]}';
        update existing;

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["7301","7302"]}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '131');
        Test.stopTest();

        System.assertEquals(new List<String>{ '7301', '7302' },
            numbersFor(onlyConfig().Landing_Number__c, 'Digital'),
            'A number already present is not duplicated');
    }

    @isTest
    static void saveConfig_mergeWithBlankExisting_usesNewOnly() {
        seedConfig('Lead', '140', true);   // all JSON fields left null

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["7401"]}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '141');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(new List<String>{ '7401' }, numbersFor(c.Landing_Number__c, 'Digital'),
            'Blank existing landing map yields the new values only');
        System.assertEquals('New', fieldValues(c.Default_Values__c).get('LastName'),
            'Blank existing defaults yield the new values only');
    }

    @isTest
    static void saveConfig_mergeWithCorruptExistingJson_usesNewOnly() {
        MCube_Configuration__c existing = seedConfig('Lead', '150', true);
        existing.Landing_Number__c  = 'not json at all';
        existing.Default_Values__c  = '{{{ broken';
        existing.Outbound_Fields__c = 'also broken';
        update existing;

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["7501"]}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '151');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(new List<String>{ '7501' }, numbersFor(c.Landing_Number__c, 'Digital'),
            'Unparseable existing landing map is discarded, not fatal');
        System.assertEquals('New', fieldValues(c.Default_Values__c).get('LastName'),
            'Unparseable existing defaults are discarded, not fatal');
        System.assertEquals('Phone', fieldOrder(c.Outbound_Fields__c)[0],
            'Unparseable existing outbound fields are discarded, not fatal');
    }

    @isTest
    static void saveConfig_mergeScalarLandingMap_dropsNumbers() {
        // KNOWN BUG — McubeConfigController.cls:339-345 (toStringList) only unwraps
        // List<Object>, but mcubeConfigWizard.js:990-995 sends one SCALAR string per
        // source: {"Newspaper":"7601"}. On merge every landing number is dropped.
        // This test pins current behaviour so a future fix fails loudly here.
        MCube_Configuration__c existing = seedConfig('Lead', '160', true);
        existing.Landing_Number__c = '{"Newspaper":"7601"}';
        update existing;

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Newspaper":"7602"}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '161');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assert(asMap(c.Landing_Number__c).containsKey('Newspaper'),
            'The source key survives the merge');
        System.assertEquals(0, numbersFor(c.Landing_Number__c, 'Newspaper').size(),
            'KNOWN BUG: scalar landing values are dropped on merge (toStringList only handles arrays)');
    }

    @isTest
    static void saveConfig_inactiveExistingConfig_createsNew() {
        seedConfig('Lead', '170', false);   // inactive — the merge lookup filters Is_Active__c = true

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["7701"]}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '171');
        Test.stopTest();

        System.assertEquals(2, allConfigs().size(),
            'An inactive config is not merged into — a second record is created');
    }

    // ── saveConfig — edit by recordId (full replace, never merge) ─────────

    @isTest
    static void saveConfig_editByRecordId_fullReplaceNotMerge() {
        MCube_Configuration__c existing = seedConfig('Lead', '180', true);
        existing.Landing_Number__c = '{"Newspaper":["7801"]}';
        existing.Default_Values__c = '[{"field":"Status","value":"Old"}]';
        update existing;

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["7802"]}', null,
                 OUTBOUND, ACTIVITY, false, true, false, existing.Id, '181');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(existing.Id, c.Id, 'Edited in place');
        System.assertEquals('{"Digital":["7802"]}', c.Landing_Number__c,
            'Edit mode replaces the landing map instead of merging it');
        System.assertEquals(DEFAULTS, c.Default_Values__c,
            'Edit mode replaces the defaults instead of merging them');
        System.assertEquals(false, c.Create_If_Not_Found__c, 'Flags replaced');
    }

    @isTest
    static void saveConfig_editByUnknownRecordId_throwsQueryException() {
        MCube_Configuration__c doomed = seedConfig('Lead', '190', true);
        Id deletedId = doomed.Id;
        delete doomed;

        Boolean threw = false;
        Test.startTest();
        try {
            saveBoth('Lead', DUP_RULE, DEFAULTS, null, null, OUTBOUND, ACTIVITY,
                     true, true, false, deletedId, '191');
        } catch (QueryException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw,
            'The single-row assignment in edit mode throws when the record is gone');
        System.assertEquals(0, allConfigs().size(), 'Nothing was created as a side effect');
    }

    // ── saveConfig — OUTBOUND_ONLY mode ──────────────────────────────────

    @isTest
    static void saveConfig_outboundOnlyNew_writesOnlyOutboundFields() {
        Test.startTest();
        saveOutbound('Lead', '[{"source":"Digital","num":"7901","campaign":"X"}]',
                     OUTBOUND, ACTIVITY, true, false, null, '201');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals('OUTBOUND_ONLY', c.Configuration_Mode__c, 'Configuration mode');
        System.assertEquals(OUTBOUND, c.Outbound_Fields__c, 'Outbound fields written');
        System.assertEquals(ACTIVITY, c.Call_Activity_Mapping__c, 'Activity mapping written');
        System.assertEquals(true, c.Is_Active__c, 'Is active written');
        System.assertEquals(null, c.Duplication_rule__c, 'Inbound dedup SOQL untouched');
        System.assertEquals(null, c.Default_Values__c,   'Inbound defaults untouched');
        System.assertEquals(null, c.Landing_Number__c,   'Inbound landing map untouched');
        System.assertEquals(null, c.Priority__c,         'Priority is a BOTH-mode-only field');
        System.assertEquals(false, c.Create_If_Not_Found__c, 'Create-if-not-found untouched');

        System.assertEquals(0, allLandings().size(),
            'Outbound-only configs never sync landing numbers, even with a populated payload');
    }

    @isTest
    static void saveConfig_outboundOnlyOverExisting_preservesInboundFields() {
        MCube_Configuration__c existing = seedConfig('Lead', '210', true);
        existing.Duplication_rule__c      = DUP_RULE;
        existing.Default_Values__c        = '[{"field":"Status","value":"Keep"}]';
        existing.Landing_Number__c        = '{"Newspaper":["8001"]}';
        existing.Outbound_Fields__c       = '[{"order":1,"field":"Phone","label":"Old"}]';
        existing.Call_Activity_Mapping__c = '{"enabled":false}';
        existing.Create_If_Not_Found__c   = true;
        update existing;

        Test.startTest();
        saveOutbound('Lead', '[{"source":"Digital","num":"8002","campaign":"Y"}]',
                     OUTBOUND, ACTIVITY, true, false, null, '211');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(existing.Id, c.Id, 'Reused the existing config');
        System.assertEquals(DUP_RULE, c.Duplication_rule__c, 'Inbound dedup SOQL preserved');
        System.assertEquals('[{"field":"Status","value":"Keep"}]', c.Default_Values__c,
            'Inbound defaults preserved');
        System.assertEquals('{"Newspaper":["8001"]}', c.Landing_Number__c,
            'Inbound landing map preserved');
        System.assertEquals('210', c.Priority__c, 'Priority preserved — not a BOTH-mode write');
        System.assertEquals(true, c.Create_If_Not_Found__c, 'Create-if-not-found preserved');
        System.assertEquals(OUTBOUND, c.Outbound_Fields__c,
            'Outbound fields are REPLACED in outbound-only mode, not merged');
        System.assertEquals(ACTIVITY, c.Call_Activity_Mapping__c, 'Activity mapping replaced');
        System.assertEquals(0, allLandings().size(), 'No landing numbers synced');
    }

    @isTest
    static void saveConfig_outboundOnlyByRecordId_updates() {
        MCube_Configuration__c existing = seedConfig('Account', '220', true);

        Test.startTest();
        saveOutbound('Account', null, OUTBOUND, ACTIVITY, true, true, existing.Id, '221');
        Test.stopTest();

        MCube_Configuration__c c = onlyConfig();
        System.assertEquals(existing.Id, c.Id, 'Updated the record identified by recordId');
        System.assertEquals('OUTBOUND_ONLY', c.Configuration_Mode__c, 'Configuration mode');
        System.assertEquals(OUTBOUND, c.Outbound_Fields__c, 'Outbound fields written');
        System.assertEquals(true, c.Is_Default__c, 'Is default written');
    }

    // ── syncLandingNumbers ───────────────────────────────────────────────

    @isTest
    static void saveConfig_blankLandingDetails_noLandingRows() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["8101"]}', null,
                 OUTBOUND, ACTIVITY, true, true, false, null, '231');
        Test.stopTest();

        System.assertEquals(1, allConfigs().size(), 'Config still saved');
        System.assertEquals(0, allLandings().size(), 'Blank landingDetails syncs nothing');
    }

    @isTest
    static void saveConfig_malformedLandingDetails_noLandingRows() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, null, 'not json',
                 OUTBOUND, ACTIVITY, true, true, false, null, '241');
        Test.stopTest();

        System.assertEquals(1, allConfigs().size(),
            'Malformed landingDetails must not roll back the config save');
        System.assertEquals(0, allLandings().size(), 'Malformed landingDetails syncs nothing');
    }

    @isTest
    static void saveConfig_emptyLandingArray_noLandingRows() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, null, '[]',
                 OUTBOUND, ACTIVITY, true, true, false, null, '251');
        Test.stopTest();

        System.assertEquals(1, allConfigs().size(), 'Config still saved');
        System.assertEquals(0, allLandings().size(), 'An empty landing array syncs nothing');
    }

    @isTest
    static void saveConfig_allBlankNumbers_noLandingRows() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, null,
                 '[{"source":"Digital","num":"","campaign":"C"}]',
                 OUTBOUND, ACTIVITY, true, true, false, null, '261');
        Test.stopTest();

        System.assertEquals(1, allConfigs().size(), 'Config still saved');
        System.assertEquals(0, allLandings().size(), 'Rows with a blank number are skipped');
    }

    @isTest
    static void saveConfig_existingLandingNumberIsUpdatedNotDuplicated() {
        MCube_Configuration__c other = seedConfig('Account', '270', true);
        seedLanding('8301', other.Id);

        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Newspaper":["8301"]}',
                 '[{"source":"Newspaper","num":"8301","campaign":"Reassigned"}]',
                 OUTBOUND, ACTIVITY, true, true, false, null, '271');
        Test.stopTest();

        MCube_Configuration__c leadConfig =
            [SELECT Id FROM MCube_Configuration__c WHERE Source_Object__c = 'Lead' LIMIT 1];

        List<Mcube_Landing_Number__c> lns = allLandings();
        System.assertEquals(1, lns.size(), 'The existing landing number is updated, not duplicated');
        System.assertEquals('Newspaper', lns[0].Source__c, 'Source updated');
        System.assertEquals('Reassigned', lns[0].Campaign_Name__c, 'Campaign updated');
        System.assertEquals(leadConfig.Id, lns[0].MCube_Configuration__c,
            'Re-parented to the config that just claimed the number');
    }

    @isTest
    static void saveConfig_repeatedNumberInPayload_upsertsOnce() {
        Test.startTest();
        saveBoth('Lead', DUP_RULE, DEFAULTS, '{"Digital":["8401"]}',
                 '[{"source":"Digital","num":"8401","campaign":"First"},' +
                 '{"source":"Newspaper","num":"8401","campaign":"Second"}]',
                 OUTBOUND, ACTIVITY, true, true, false, null, '281');
        Test.stopTest();

        List<Mcube_Landing_Number__c> lns = allLandings();
        System.assertEquals(1, lns.size(),
            'A number repeated in one payload collapses to a single row');
        System.assertEquals('Second', lns[0].Campaign_Name__c, 'The last entry for a number wins');
    }

    // ── getLandingNumbers ────────────────────────────────────────────────

    @isTest
    static void getLandingNumbers_blankRecordId_returnsEmpty() {
        Test.startTest();
        List<McubeConfigController.LandingDetail> forNull  = McubeConfigController.getLandingNumbers(null);
        List<McubeConfigController.LandingDetail> forBlank = McubeConfigController.getLandingNumbers('');
        Test.stopTest();

        System.assertEquals(0, forNull.size(),  'A null recordId returns an empty list');
        System.assertEquals(0, forBlank.size(), 'A blank recordId returns an empty list');
    }

    @isTest
    static void getLandingNumbers_returnsMappedRows() {
        MCube_Configuration__c c = seedConfig('Lead', '290', true);
        seedLanding('8501', c.Id);

        Test.startTest();
        List<McubeConfigController.LandingDetail> rows = McubeConfigController.getLandingNumbers(c.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'One landing row for the config');
        System.assertEquals('8501', rows[0].num, 'Number maps to num (number is a reserved word)');
        System.assertEquals('Digital', rows[0].source, 'Source mapped');
        System.assertEquals('Seeded', rows[0].campaign, 'Campaign mapped');
    }

    @isTest
    static void getLandingNumbers_configWithNoRows_returnsEmpty() {
        MCube_Configuration__c c = seedConfig('Lead', '300', true);

        Test.startTest();
        List<McubeConfigController.LandingDetail> rows = McubeConfigController.getLandingNumbers(c.Id);
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'A config with no landing numbers returns an empty list');
    }

    // ── checkExistingConfig ──────────────────────────────────────────────

    @isTest
    static void checkExistingConfig_activeConfig_returnsId() {
        MCube_Configuration__c c = seedConfig('Lead', '310', true);

        Test.startTest();
        Id found = McubeConfigController.checkExistingConfig('Lead');
        Test.stopTest();

        System.assertEquals(c.Id, found, 'The active config for the source object is returned');
    }

    @isTest
    static void checkExistingConfig_noConfig_returnsNull() {
        Test.startTest();
        Id found = McubeConfigController.checkExistingConfig('Lead');
        Test.stopTest();

        System.assertEquals(null, found, 'No config for the source object returns null');
    }

    @isTest
    static void checkExistingConfig_inactiveOnly_returnsNull() {
        seedConfig('Lead', '320', false);

        Test.startTest();
        Id found = McubeConfigController.checkExistingConfig('Lead');
        Test.stopTest();

        System.assertEquals(null, found, 'An inactive config does not count as existing');
    }

    // ── Schema methods (asserted structurally, never on org-specific data) ─

    @isTest
    static void getAllObjects_returnsSortedCreateableObjects() {
        // getGlobalDescribe() + a full describe of every object is the most
        // CPU-expensive call in the codebase — give it its own limit budget and
        // do nothing else in this method.
        Test.startTest();
        List<McubeConfigController.ObjectInfo> objects = McubeConfigController.getAllObjects();
        Test.stopTest();

        System.assert(!objects.isEmpty(), 'Every org has createable objects');

        Set<String> apiNames = new Set<String>();
        for (McubeConfigController.ObjectInfo oi : objects) {
            System.assert(String.isNotBlank(oi.apiName), 'Every entry has an API name');
            System.assert(String.isNotBlank(oi.label),   'Every entry has a label');
            apiNames.add(oi.apiName);
        }
        System.assert(apiNames.contains('Account'), 'Account is createable and updateable');
        System.assert(apiNames.contains('Lead'),    'Lead is createable and updateable');
        System.assert(!apiNames.contains('AsyncApexJob'),
            'Read-only system objects are filtered out by the isCreateable check');

        for (Integer i = 1; i < objects.size(); i++) {
            System.assert(objects[i - 1].label.compareTo(objects[i].label) <= 0,
                'Results are sorted ascending by label (ObjectInfo.compareTo)');
        }
    }

    @isTest
    static void getObjectFields_blankName_returnsEmpty() {
        Test.startTest();
        List<McubeConfigController.FieldInfo> forNull  = McubeConfigController.getObjectFields(null);
        List<McubeConfigController.FieldInfo> forBlank = McubeConfigController.getObjectFields('');
        Test.stopTest();

        System.assertEquals(0, forNull.size(),  'A null object name returns an empty list');
        System.assertEquals(0, forBlank.size(), 'A blank object name returns an empty list');
    }

    @isTest
    static void getObjectFields_unknownObject_returnsEmpty() {
        Test.startTest();
        List<McubeConfigController.FieldInfo> fields =
            McubeConfigController.getObjectFields('No_Such_Object__c');
        Test.stopTest();

        System.assertEquals(0, fields.size(), 'An unknown object name returns an empty list');
    }

    @isTest
    static void getObjectFields_leadFields_shapeAndSkipList() {
        Test.startTest();
        List<McubeConfigController.FieldInfo> fields = McubeConfigController.getObjectFields('Lead');
        Test.stopTest();

        Map<String, McubeConfigController.FieldInfo> byName =
            new Map<String, McubeConfigController.FieldInfo>();
        for (McubeConfigController.FieldInfo fi : fields) byName.put(fi.apiName, fi);

        System.assert(byName.containsKey('LastName'), 'Lead.LastName is returned');
        System.assertEquals(true, byName.get('LastName').isRequired,
            'A non-nillable createable field is flagged required');
        System.assertEquals('STRING', byName.get('LastName').type, 'Field type is the DisplayType name');
        System.assertEquals(false, byName.get('LastName').isLookup, 'LastName is not a lookup');

        System.assert(byName.containsKey('Description'), 'Lead.Description is returned');
        System.assertEquals(false, byName.get('Description').isRequired,
            'A nillable field is not flagged required');

        for (String skipped : new List<String>{
            'CreatedDate', 'CreatedById', 'LastModifiedDate', 'LastModifiedById',
            'SystemModstamp', 'IsDeleted', 'LastActivityDate'
        }) {
            System.assert(!byName.containsKey(skipped), 'Audit field ' + skipped + ' is skipped');
        }

        for (Integer i = 1; i < fields.size(); i++) {
            System.assert(fields[i - 1].label.compareTo(fields[i].label) <= 0,
                'Results are sorted ascending by label (FieldInfo.compareTo)');
        }
    }

    @isTest
    static void getObjectFields_polymorphicLookup_prefersUser() {
        Test.startTest();
        List<McubeConfigController.FieldInfo> fields = McubeConfigController.getObjectFields('Lead');
        Test.stopTest();

        for (McubeConfigController.FieldInfo fi : fields) {
            if (fi.apiName == 'OwnerId') {
                System.assertEquals(true, fi.isLookup, 'OwnerId is a reference field');
                System.assertEquals('User', fi.referenceTo,
                    'A polymorphic owner lookup resolves to User, not Group');
                return;
            }
        }
        System.assert(false, 'Lead.OwnerId was not returned');
    }

    @isTest
    static void getObjectFields_singleTargetLookup_usesFirst() {
        Test.startTest();
        List<McubeConfigController.FieldInfo> fields = McubeConfigController.getObjectFields('Contact');
        Test.stopTest();

        for (McubeConfigController.FieldInfo fi : fields) {
            if (fi.apiName == 'AccountId') {
                System.assertEquals(true, fi.isLookup, 'AccountId is a reference field');
                System.assertEquals('Account', fi.referenceTo,
                    'A single-target lookup falls back to its only referenceTo');
                return;
            }
        }
        System.assert(false, 'Contact.AccountId was not returned');
    }

    @isTest
    static void getMcubeFields_returnsAllDtoFields() {
        Test.startTest();
        List<String> names = McubeConfigController.getMcubeFields();
        Test.stopTest();

        // Order is not guaranteed — JSON.deserializeUntyped returns an unordered Map.
        Set<String> asSet = new Set<String>(names);
        System.assertEquals(20, asSet.size(), 'All 20 McubeConfigDTO fields are exposed');
        for (String expected : new List<String>{
            'callId', 'callType', 'relatedTo', 'landingNumber',
            'dispositionStatus', 'disconnectedBy'
        }) {
            System.assert(asSet.contains(expected), 'Expected DTO field ' + expected);
        }
    }

    // ── getCallActivityMapping ───────────────────────────────────────────

    @isTest
    static void getCallActivityMapping_blankId_returnsNull() {
        Test.startTest();
        String forNull  = McubeConfigController.getCallActivityMapping(null);
        String forBlank = McubeConfigController.getCallActivityMapping('');
        Test.stopTest();

        System.assertEquals(null, forNull,  'A null recordId returns null');
        System.assertEquals(null, forBlank, 'A blank recordId returns null');
    }

    @isTest
    static void getCallActivityMapping_returnsJson() {
        MCube_Configuration__c c = seedConfig('Lead', '330', true);
        c.Call_Activity_Mapping__c = ACTIVITY;
        update c;

        Test.startTest();
        String mapping = McubeConfigController.getCallActivityMapping(c.Id);
        Test.stopTest();

        System.assertEquals(ACTIVITY, mapping, 'The stored mapping JSON is returned verbatim');
    }

    @isTest
    static void getCallActivityMapping_deletedId_returnsNull() {
        MCube_Configuration__c c = seedConfig('Lead', '340', true);
        Id deletedId = c.Id;
        delete c;

        Test.startTest();
        String mapping = McubeConfigController.getCallActivityMapping(deletedId);
        Test.stopTest();

        System.assertEquals(null, mapping, 'A recordId with no matching row returns null');
    }
}
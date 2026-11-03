@isTest
private class ForecastEnhancedControllerTest {

    /** Create a minimal valid Opportunity for the running user. */
    private static Opportunity makeOpp(Id accountId, String stage, String forecastCat, Date closeDate) {
        return new Opportunity(
            Name                  = 'Test Deal',
            AccountId             = accountId,
            StageName             = stage,
            CloseDate             = closeDate,
            Amount                = 100000,
            ForecastCategoryName  = forecastCat,
            Expected_Start_Date__c = DateTime.now(),
            End_Date__c            = DateTime.now().addDays(5)
        );
    }

    /** Create a minimal active User with the given role. */
    private static User makeUser(String suffix, Id roleId) {
        return new User(
            Username           = 'testuser' + suffix + System.currentTimeMillis() + '@forecasttest.com.invalid',
            LastName           = 'ForecastTest' + suffix,
            Email              = 'testuser' + suffix + '@forecasttest.com.invalid',
            Alias              = 'ft' + suffix.left(6),
            TimeZoneSidKey     = 'America/New_York',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            ProfileId          = UserInfo.getProfileId(),
            LanguageLocaleKey  = 'en_US',
            UserRoleId         = roleId
        );
    }

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp = makeOpp(acc.Id, 'Prospecting', 'Pipeline', Date.today());
        insert opp;
    }

    // ─── getUsers ─────────────────────────────────────────────────────────────

    @isTest
    static void testGetUsers() {
        Test.startTest();
        List<Map<String,String>> users = ForecastEnhancedController.getUsers();
        Test.stopTest();

        System.assertNotEquals(null, users);
        System.assert(users.size() > 0, 'Should return at least one active user');
        System.assert(users[0].containsKey('value'));
        System.assert(users[0].containsKey('label'));
    }

    // ─── Conversion rate ──────────────────────────────────────────────────────

    @isTest
    static void testSaveAndGetConversionRate() {
        Test.startTest();
        ForecastEnhancedController.saveConversionRate(29.00, 'FY 2027', null);
        Decimal rate = ForecastEnhancedController.getConversionRate('FY 2027', null);
        Test.stopTest();

        System.assertEquals(29.00, rate);
    }

    @isTest
    static void testUpsertConversionRate() {
        ForecastEnhancedController.saveConversionRate(25.00, 'FY 2027', null);
        ForecastEnhancedController.saveConversionRate(30.00, 'FY 2027', null);

        Decimal rate = ForecastEnhancedController.getConversionRate('FY 2027', null);
        System.assertEquals(30.00, rate, 'Second save should overwrite the first');

        List<ForecastConversionRate__c> recs = [
            SELECT Id FROM ForecastConversionRate__c
            WHERE User__c = :UserInfo.getUserId() AND FiscalYear__c = 'FY 2027'
        ];
        System.assertEquals(1, recs.size(), 'Should only be one record per user per FY');
    }

    @isTest
    static void testGetConversionRateReturnsNullWhenNoneExists() {
        Decimal rate = ForecastEnhancedController.getConversionRate('FY 2099', null);
        System.assertEquals(null, rate);
    }

    // ─── getForecastData — single user (no role) ──────────────────────────────

    @isTest
    static void testGetForecastDataReturnsCorrectMonthCount() {
        Test.startTest();
        Map<String, Object> result = ForecastEnhancedController.getForecastData('2026-04-01', '2027-03-01', null);
        Test.stopTest();

        System.assertNotEquals(null, result);
        List<Object> rows = (List<Object>) result.get('rows');
        System.assertNotEquals(null, rows);
        System.assertEquals(12, rows.size(), 'Should return 12 monthly rows for April-March FY');
    }

    @isTest
    static void testGetForecastDataWithExplicitUserId() {
        Id userId = UserInfo.getUserId();
        Test.startTest();
        Map<String, Object> result = ForecastEnhancedController.getForecastData('2026-04-01', '2027-03-01', userId);
        Test.stopTest();

        System.assertNotEquals(null, result);
        List<Object> rows = (List<Object>) result.get('rows');
        System.assertEquals(12, rows.size());
    }

    // ─── getForecastData — manager with role hierarchy ────────────────────────

    @isTest
    static void testGetForecastDataForUserWithRoleButNoSubordinates() {
        // User has a role but no child roles → isManager remains false
        UserRole parentRole = new UserRole(Name = 'FE Test Solo Role ' + System.currentTimeMillis());
        insert parentRole;

        User solo = makeUser('s', parentRole.Id);
        insert solo;

        Test.startTest();
        System.runAs(solo) {
            Map<String, Object> result = ForecastEnhancedController.getForecastData('2026-04-01', '2027-03-01', null);
            System.assertNotEquals(null, result);
            System.assertEquals(null, result.get('isManager'), 'No child roles → not a manager');
            List<Object> rows = (List<Object>) result.get('rows');
            System.assertEquals(12, rows.size());
        }
        Test.stopTest();
    }

    @isTest
    static void testGetForecastDataForManagerWithTeam() {
        // Manager role → child role → reporter user
        UserRole parentRole = new UserRole(Name = 'FE Test Mgr Role ' + System.currentTimeMillis());
        insert parentRole;

        UserRole childRole  = new UserRole(
            Name         = 'FE Test Rep Role ' + System.currentTimeMillis(),
            ParentRoleId = parentRole.Id
        );
        insert childRole;

        User reporter = makeUser('r', childRole.Id);
        User mgr      = makeUser('m', parentRole.Id);
        insert new List<User>{ reporter, mgr };

        Test.startTest();
        System.runAs(mgr) {
            Map<String, Object> result = ForecastEnhancedController.getForecastData('2026-04-01', '2027-03-01', null);
            System.assertNotEquals(null, result);
            System.assertEquals(true, result.get('isManager'), 'Should detect as manager');
            List<Object> rows = (List<Object>) result.get('rows');
            System.assertEquals(12, rows.size());
            // Each row should include a members array
            Map<String, Object> firstRow = (Map<String, Object>) rows[0];
            System.assert(firstRow.containsKey('members'), 'Manager rows should have members');
        }
        Test.stopTest();
    }

    // ─── getDealsForCell ──────────────────────────────────────────────────────

    @isTest
    static void testGetDealsForCellPipeline() {
        Test.startTest();
        String startDate = String.valueOf(Date.today().toStartOfMonth());
        List<Map<String,Object>> deals = ForecastEnhancedController.getDealsForCell(null, startDate, 'Pipeline');
        Test.stopTest();

        System.assertNotEquals(null, deals);
        System.assert(deals.size() >= 1, 'Should return the test opp in Pipeline');
        System.assert(deals[0].containsKey('id'));
        System.assert(deals[0].containsKey('name'));
        System.assert(deals[0].containsKey('amount'));
        System.assert(deals[0].containsKey('rowNum'));
    }

    @isTest
    static void testGetDealsForCellCommit() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = makeOpp(acc.Id, 'Proposal/Price Quote', 'Commit', Date.today());
        insert opp;

        Test.startTest();
        String startDate = String.valueOf(Date.today().toStartOfMonth());
        List<Map<String,Object>> deals = ForecastEnhancedController.getDealsForCell(null, startDate, 'Commit');
        Test.stopTest();

        System.assertNotEquals(null, deals);
        // Commit includes Closed + Commit cumulative
        System.assert(deals.size() >= 1, 'Should return at least the Commit opp');
    }

    @isTest
    static void testGetDealsForCellBestCase() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity opp = makeOpp(acc.Id, 'Value Proposition', 'Best Case', Date.today());
        insert opp;

        Test.startTest();
        String startDate = String.valueOf(Date.today().toStartOfMonth());
        List<Map<String,Object>> deals = ForecastEnhancedController.getDealsForCell(null, startDate, 'BestCase');
        Test.stopTest();

        System.assertNotEquals(null, deals);
        System.assert(deals.size() >= 1);
    }

    @isTest
    static void testGetDealsForCellClosedReturnsNoOpenOpps() {
        Test.startTest();
        String startDate = String.valueOf(Date.today().toStartOfMonth());
        List<Map<String,Object>> deals = ForecastEnhancedController.getDealsForCell(null, startDate, 'Closed');
        Test.stopTest();

        System.assertNotEquals(null, deals);
        // Pipeline opp from setup should NOT appear in Closed filter
        System.assertEquals(0, deals.size(), 'Closed filter should exclude Pipeline opportunities');
    }

    @isTest
    static void testGetDealsForCellAsManager() {
        // Manager + reporter: drill-down should include both users' deals
        UserRole parentRole = new UserRole(Name = 'FE Drill Mgr Role ' + System.currentTimeMillis());
        insert parentRole;

        UserRole childRole = new UserRole(
            Name         = 'FE Drill Rep Role ' + System.currentTimeMillis(),
            ParentRoleId = parentRole.Id
        );
        insert childRole;

        User reporter = makeUser('dr', childRole.Id);
        User mgr      = makeUser('dm', parentRole.Id);
        insert new List<User>{ reporter, mgr };

        Account acc = [SELECT Id FROM Account LIMIT 1];
        Opportunity reporterOpp = new Opportunity(
            Name = 'Reporter Deal', AccountId = acc.Id, OwnerId = reporter.Id,
            StageName = 'Prospecting', CloseDate = Date.today(),
            Amount = 50000, ForecastCategoryName = 'Pipeline',
            Expected_Start_Date__c = DateTime.now(), End_Date__c = DateTime.now().addDays(3)
        );
        insert reporterOpp;

        Test.startTest();
        System.runAs(mgr) {
            String startDate = String.valueOf(Date.today().toStartOfMonth());
            List<Map<String,Object>> deals = ForecastEnhancedController.getDealsForCell(null, startDate, 'Pipeline');
            System.assertNotEquals(null, deals);
            // Should include reporter's deal
            Boolean foundReporterDeal = false;
            for (Map<String,Object> d : deals) {
                if (d.get('name') == 'Reporter Deal') foundReporterDeal = true;
            }
            System.assert(foundReporterDeal, 'Manager drill-down should include reporter deals');
        }
        Test.stopTest();
    }
}
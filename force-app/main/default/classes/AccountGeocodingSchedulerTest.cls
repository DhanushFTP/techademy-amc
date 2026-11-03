@IsTest
private class AccountGeocodingSchedulerTest {

    // Mock HTTP callout - successful geocode response
    private class GeocodeMockSuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('[{"lat":"28.6234","lon":"77.4521","display_name":"Test Location"}]');
            return res;
        }
    }

    // Mock HTTP callout - empty result (no match found)
    private class GeocodeMockEmpty implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('[]');
            return res;
        }
    }

    // Mock HTTP callout - server error
    private class GeocodeMockError implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        // Account that should be picked up (College, has address, no coordinates)
        Account acc1 = new Account(
            Name = 'Test Engineering College',
            Type = 'College',
            BillingStreet = '123 Main Road',
            BillingCity = 'New Delhi',
            BillingState = 'Delhi',
            BillingPostalCode = '110001'
        );

        // Account that should be picked up (University, has city only)
        Account acc2 = new Account(
            Name = 'Test University',
            Type = 'University',
            BillingCity = 'Mumbai'
        );

        // Account that should NOT be picked up (already geocoded)
        Account acc3 = new Account(
            Name = 'Already Geocoded College',
            Type = 'College',
            BillingCity = 'Chennai',
            Account_Location__Latitude__s = 13.0827,
            Account_Location__Longitude__s = 80.2707
        );

        // Account that should NOT be picked up (wrong type)
        Account acc4 = new Account(
            Name = 'Regular Company',
            Type = 'Customer',
            BillingCity = 'Bangalore'
        );

        insert new List<Account>{ acc1, acc2, acc3, acc4 };
    }

    // ── Batch start should only query eligible accounts ──
    @IsTest
    static void testBatchStartQuery() {
        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();

        Test.startTest();
        Database.QueryLocator ql = scheduler.start(null);
        Database.QueryLocatorIterator it = ql.iterator();
        Integer count = 0;
        while (it.hasNext()) {
            it.next();
            count++;
        }
        Test.stopTest();

        System.assertEquals(2, count, 'Should find 2 accounts needing geocoding (College + University without coords)');
    }

    // ── Successful geocoding should update account coordinates ──
    @IsTest
    static void testBatchExecuteSuccess() {
        Account acc = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                              Account_Location__Latitude__s, Account_Location__Longitude__s
                       FROM Account WHERE Name = 'Test Engineering College' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new GeocodeMockSuccess());

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();

        Test.startTest();
        scheduler.execute(null, new List<Account>{ acc });
        Test.stopTest();

        Account updated = [SELECT Account_Location__Latitude__s, Account_Location__Longitude__s
                           FROM Account WHERE Id = :acc.Id];
        System.assertEquals(28.6234, updated.Account_Location__Latitude__s, 'Latitude should be updated');
        System.assertEquals(77.4521, updated.Account_Location__Longitude__s, 'Longitude should be updated');

        List<AccountGeocodingLog__c> logs = [SELECT Log_Text__c FROM AccountGeocodingLog__c WHERE Run_Date__c = TODAY];
        System.assertEquals(1, logs.size(), 'Should create one log record');
        System.assert(logs[0].Log_Text__c.contains('Updated:'), 'Log should contain success entry');
    }

    // ── Empty geocode result should log failure ──
    @IsTest
    static void testBatchExecuteNoResult() {
        Account acc = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                              Account_Location__Latitude__s, Account_Location__Longitude__s
                       FROM Account WHERE Name = 'Test Engineering College' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new GeocodeMockEmpty());

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();

        Test.startTest();
        scheduler.execute(null, new List<Account>{ acc });
        Test.stopTest();

        Account unchanged = [SELECT Account_Location__Latitude__s FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, unchanged.Account_Location__Latitude__s, 'Latitude should remain null');

        List<AccountGeocodingLog__c> logs = [SELECT Log_Text__c FROM AccountGeocodingLog__c WHERE Run_Date__c = TODAY];
        System.assert(logs[0].Log_Text__c.contains('Failed:'), 'Log should contain failure entry');
    }

    // ── Server error should log failure gracefully ──
    @IsTest
    static void testBatchExecuteServerError() {
        Account acc = [SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                              Account_Location__Latitude__s, Account_Location__Longitude__s
                       FROM Account WHERE Name = 'Test Engineering College' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new GeocodeMockError());

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();

        Test.startTest();
        scheduler.execute(null, new List<Account>{ acc });
        Test.stopTest();

        Account unchanged = [SELECT Account_Location__Latitude__s FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, unchanged.Account_Location__Latitude__s, 'Latitude should remain null on error');
    }

    // ── Finish should send email and clean up logs ──
    @IsTest
    static void testBatchFinish() {
        // Insert mock log records
        insert new List<AccountGeocodingLog__c>{
            new AccountGeocodingLog__c(
                Log_Text__c = 'Updated: Test College -> (28.6234, 77.4521)\nFailed: Bad College | Address: unknown',
                Run_Date__c = System.today()
            )
        };

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();

        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        scheduler.finish(null);
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(emailsBefore + 1, emailsAfter, 'Should send one email');

        List<AccountGeocodingLog__c> remaining = [SELECT Id FROM AccountGeocodingLog__c WHERE Run_Date__c = TODAY];
        System.assertEquals(0, remaining.size(), 'Log records should be deleted after email');
    }

    // ── Schedulable should create a scheduled job ──
    @IsTest
    static void testSchedulable() {
        // Delete all test setup accounts so the batch query returns nothing,
        // avoiding the "No more than one executeBatch" error
        delete [SELECT Id FROM Account];

        Test.startTest();
        String jobId = System.schedule(
            'Test Geocoding Schedule',
            '0 0 23 * * ?',
            new AccountGeocodingScheduler()
        );
        Test.stopTest();

        CronTrigger ct = [SELECT Id, State, CronExpression FROM CronTrigger WHERE Id = :jobId];
        System.assertNotEquals(null, ct, 'Scheduled job should exist');
    }

    // ── Build address with all fields ──
    @IsTest
    static void testBuildAddressFullFields() {
        Account acc = new Account(
            Name = 'Full Address College',
            BillingStreet = '123 Main Road',
            BillingCity = 'New Delhi',
            BillingState = 'Delhi',
            BillingPostalCode = '110001'
        );

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();
        String address = scheduler.buildAddress(acc);

        System.assert(address.contains('123 Main Road'), 'Should contain street');
        System.assert(address.contains('New Delhi'), 'Should contain city');
        System.assert(address.contains('Delhi'), 'Should contain state');
        System.assert(address.contains('110001'), 'Should contain postal code');
        System.assert(address.endsWith('India'), 'Should end with India');
    }

    // ── Build address with partial fields ──
    @IsTest
    static void testBuildAddressPartialFields() {
        Account acc = new Account(
            Name = 'Partial Address College',
            BillingCity = 'Mumbai'
        );

        AccountGeocodingScheduler scheduler = new AccountGeocodingScheduler();
        String address = scheduler.buildAddress(acc);

        System.assertEquals('Mumbai, India', address, 'Should only contain city and India');
    }
}
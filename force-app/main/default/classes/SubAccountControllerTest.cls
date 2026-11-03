@IsTest
private class SubAccountControllerTest {

    // ── Test data: creates an Account owned by the running user ──
    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name                           = 'Parent University',
            Type                           = 'University',
            Website                        = 'https://parent.edu',
            Phone                          = '555-1234',
            Account_Location__Latitude__s  = 12.892157,
            Account_Location__Longitude__s = 77.465362
        );
        insert acc;
    }

    // ── getAccountDetails: current user is the owner ──
    @IsTest
    static void testGetAccountDetails_Owner() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Parent University' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = SubAccountController.getAccountDetails(acc.Id);
        Test.stopTest();

        System.assertEquals(true,                 result.get('isOwner'),  'Running user should be owner');
        System.assertEquals('Parent University',  result.get('name'),     'Name should match');
        System.assertEquals('https://parent.edu', result.get('website'),  'Website should match');
        System.assertEquals('555-1234',           result.get('phone'),    'Phone should match');
        System.assertNotEquals(null,              result.get('latitude'), 'Latitude should be returned');
        System.assertNotEquals(null,              result.get('longitude'),'Longitude should be returned');
    }

    // ── getAccountDetails: a different user is the owner ──
    @IsTest
    static void testGetAccountDetails_NonOwner() {
        // Create a second user and make them the account owner
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User otherUser = new User(
            FirstName          = 'Other',
            LastName           = 'User',
            Email              = 'otheruser_test@example.com',
            Username           = 'otheruser_subacct_test@example.com',
            Alias              = 'other',
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
        insert otherUser;

        Account acc = [SELECT Id FROM Account WHERE Name = 'Parent University' LIMIT 1];
        acc.OwnerId = otherUser.Id;
        update acc;

        Test.startTest();
        Map<String, Object> result = SubAccountController.getAccountDetails(acc.Id);
        Test.stopTest();

        System.assertEquals(false, result.get('isOwner'), 'Running user should NOT be owner');
    }

    // ── createSubAccount: owner successfully creates a sub-account ──
    @IsTest
    static void testCreateSubAccount_Success() {
        Account parent = [SELECT Id FROM Account WHERE Name = 'Parent University' LIMIT 1];

        Test.startTest();
        Id newId = SubAccountController.createSubAccount(
            parent.Id,
            'Engineering Department',
            12.8930,
            77.4660,
            'https://eng.parent.edu',
            '555-5678'
        );
        Test.stopTest();

        System.assertNotEquals(null, newId, 'New account Id should be returned');
        Account sub = [
            SELECT Name, ParentId, Type, Website, Phone,
                   Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Id = :newId
        ];
        System.assertEquals('Engineering Department', sub.Name,     'Sub-account name should match');
        System.assertEquals(parent.Id,                sub.ParentId, 'ParentId should point to parent account');
        System.assertEquals('University',             sub.Type,     'Type should be inherited from parent');
        System.assertEquals('https://eng.parent.edu', sub.Website,  'Website should be set');
        System.assertEquals('555-5678',               sub.Phone,    'Phone should be set');
        System.assertEquals((Decimal)12.8930, sub.Account_Location__Latitude__s,  'Latitude should match');
        System.assertEquals((Decimal)77.4660, sub.Account_Location__Longitude__s, 'Longitude should match');
    }

    // ── createSubAccount: non-owner gets an error ──
    @IsTest
    static void testCreateSubAccount_NotOwner() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User otherUser = new User(
            FirstName          = 'Other',
            LastName           = 'User2',
            Email              = 'otheruser2_test@example.com',
            Username           = 'otheruser2_subacct_test@example.com',
            Alias              = 'oth2',
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US',
            ProfileId          = p.Id
        );
        insert otherUser;

        Account parent = [SELECT Id FROM Account WHERE Name = 'Parent University' LIMIT 1];
        parent.OwnerId = otherUser.Id;
        update parent;

        Test.startTest();
        try {
            SubAccountController.createSubAccount(parent.Id, 'Sub', 12.89, 77.46, null, null);
            System.assert(false, 'Expected AuraHandledException was not thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('owner'), 'Error message should mention owner');
        }
        Test.stopTest();
    }

    // ── createSubAccount: blank name gets an error ──
    @IsTest
    static void testCreateSubAccount_BlankName() {
        Account parent = [SELECT Id FROM Account WHERE Name = 'Parent University' LIMIT 1];

        Test.startTest();
        try {
            SubAccountController.createSubAccount(parent.Id, '   ', 12.89, 77.46, null, null);
            System.assert(false, 'Expected AuraHandledException was not thrown');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'), 'Error message should mention required');
        }
        Test.stopTest();
    }
}
@IsTest
private class CheckInControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name             = 'Test College',
            Type             = 'University',
            Account_Location__Latitude__s  = 12.892157,
            Account_Location__Longitude__s = 77.465362
        );
        insert acc;
    }

    // ── Check-in within 500m should succeed ──
    @IsTest
    static void testCheckInWithinRadius() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];

        // ~100m away from account
        Decimal lat = 12.8925;
        Decimal lng = 77.4650;

        Test.startTest();
        Id checkInId = CheckInController.createCheckIn(acc.Id, lat, lng);
        Test.stopTest();

        Check_In__c rec = [SELECT Status__c, Check_In_Latitude__c FROM Check_In__c WHERE Id = :checkInId];
        System.assertEquals('Checked In', rec.Status__c, 'Status should be Checked In');
        System.assertNotEquals(null, rec.Check_In_Latitude__c, 'Latitude should be populated');
    }

    // ── Check-in outside 500m should fail ──
    @IsTest
    static void testCheckInOutsideRadius() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];

        // ~5km away
        Decimal lat = 12.93;
        Decimal lng = 77.50;

        Test.startTest();
        try {
            CheckInController.createCheckIn(acc.Id, lat, lng);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('meters away'),
                'Error should mention distance. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Check-in with no geocoded account should fail ──
    @IsTest
    static void testCheckInNoGeocode() {
        Account acc = new Account(
            Name = 'No Geo College',
            Type = 'University'
        );
        insert acc;

        Test.startTest();
        try {
            CheckInController.createCheckIn(acc.Id, 12.89, 77.46);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Account Location'),
                'Error should mention Account Location. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Check-out within radius should succeed ──
    @IsTest
    static void testCheckOutWithinRadius() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];

        Id checkInId = CheckInController.createCheckIn(acc.Id, 12.8925, 77.4650);

        Test.startTest();
        CheckInController.performCheckOut(checkInId, 12.8920, 77.4655, 'Great meeting');
        Test.stopTest();

        Check_In__c rec = [SELECT Status__c, Check_Out_Time__c, Check_Out_Notes__c FROM Check_In__c WHERE Id = :checkInId];
        System.assertEquals('Checked Out', rec.Status__c, 'Status should be Checked Out');
        System.assertNotEquals(null, rec.Check_Out_Time__c, 'Check-out time should be set');
        System.assertEquals('Great meeting', rec.Check_Out_Notes__c, 'Notes should be saved');
    }

    // ── Check-out outside radius should fail ──
    @IsTest
    static void testCheckOutOutsideRadius() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];
        Id checkInId = CheckInController.createCheckIn(acc.Id, 12.8925, 77.4650);

        Test.startTest();
        try {
            CheckInController.performCheckOut(checkInId, 12.93, 77.50, 'Notes');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('meters away'),
                'Error should mention distance. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Double check-out should fail ──
    @IsTest
    static void testDoubleCheckOut() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];
        Id checkInId = CheckInController.createCheckIn(acc.Id, 12.8925, 77.4650);
        CheckInController.performCheckOut(checkInId, 12.8920, 77.4655, 'Done');

        Test.startTest();
        try {
            CheckInController.performCheckOut(checkInId, 12.8920, 77.4655, 'Again');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been checked out'),
                'Should reject double check-out. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Get active check-in ──
    @IsTest
    static void testGetActiveCheckIn() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];
        CheckInController.createCheckIn(acc.Id, 12.8925, 77.4650);

        Test.startTest();
        Check_In__c active = CheckInController.getActiveCheckIn(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, active, 'Should return active check-in');
    }

    // ── No active check-in returns null ──
    @IsTest
    static void testGetActiveCheckInNone() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];

        Test.startTest();
        Check_In__c active = CheckInController.getActiveCheckIn(acc.Id);
        Test.stopTest();

        System.assertEquals(null, active, 'Should return null when no active check-in');
    }
}
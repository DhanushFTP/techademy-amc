/******************************************************************
 * Class Name    : CheckInControllerTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 17-03-2026
 * @description  : Tests for CheckInController: Account check-in and
 *                 check-out inside and outside the check-in distance,
 *                 missing Account Location, double check-out, active
 *                 check-in, and the distance read from the custom label
 *                 Check_In_Max_Distance_Meters.
 * @author       : Karthik Kumar
 * Used By       : - CheckInController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Karthik Kumar   | 17-03-2026 | Initial version
 * 1.1 | Tharun N        | 16-11-2026 | Tests for the check-in distance from
 *     |                 |            | the Check_In_Max_Distance_Meters label
 *     |                 |            | (1000 m): label value used, a check-in
 *     |                 |            | about 750 m away, and the distance in
 *     |                 |            | the error message. Existing tests
 *     |                 |            | unchanged.
 * -----------------------------------------------------------------------------
 ******************************************************************/
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

    // ── Check-in within the check-in distance should succeed ──
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

    // ── Check-in outside the check-in distance should fail ──
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

    /**
    * Method Name: testMaxDistanceComesFromLabel
    * @author: Tharun N
    * @description: The check-in distance is read from the custom label
    *               Check_In_Max_Distance_Meters.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void testMaxDistanceComesFromLabel() {
        Test.startTest();
        Double maxDistance = CheckInController.maxDistanceMeters();
        Test.stopTest();

        System.assertEquals(Double.valueOf(System.Label.Check_In_Max_Distance_Meters.trim()), maxDistance,
            'Distance should come from Check_In_Max_Distance_Meters');
    }

    /**
    * Method Name: testCheckInAbout750MetersFollowsLabel
    * @author: Tharun N
    * @description: A check-in about 750 m from the account (refused under
    *               the old 500 m rule) is allowed when the label allows
    *               750 m or more, as with 1000 m, and refused otherwise.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void testCheckInAbout750MetersFollowsLabel() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];
        Double maxDistance = CheckInController.maxDistanceMeters();

        // ~750 m north of the account
        Decimal lat = 12.898900;
        Decimal lng = 77.465362;

        Boolean allowed;
        Test.startTest();
        try {
            CheckInController.createCheckIn(acc.Id, lat, lng);
            allowed = true;
        } catch (AuraHandledException e) {
            allowed = false;
        }
        Test.stopTest();

        System.assertEquals(maxDistance >= 750, allowed,
            'A check-in about 750 m away should follow the ' + maxDistance.intValue() + ' m limit');
    }

    /**
    * Method Name: testOutsideRadiusMessageShowsConfiguredDistance
    * @author: Tharun N
    * @description: The "too far" message shows the distance from the
    *               label, not 500.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void testOutsideRadiusMessageShowsConfiguredDistance() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test College' LIMIT 1];
        Double maxDistance = CheckInController.maxDistanceMeters();

        Test.startTest();
        try {
            // ~5 km away
            CheckInController.createCheckIn(acc.Id, 12.93, 77.50);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('within ' + maxDistance.intValue() + ' meters'),
                'Message should show the configured distance. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
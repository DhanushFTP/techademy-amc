@IsTest
private class CheckInMapControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(
            Name             = 'Map Test College',
            Type             = 'University',
            Account_Location__Latitude__s  = 12.892157,
            Account_Location__Longitude__s = 77.465362
        );
        insert acc;

        // Create a checked-in record
        Check_In__c checkedIn = new Check_In__c(
            Account__c            = acc.Id,
            Check_In_Latitude__c  = 12.8925,
            Check_In_Longitude__c = 77.4650,
            Check_In_Time__c      = System.now(),
            Rep_Name__c           = UserInfo.getUserId(),
            Status__c             = 'Checked In'
        );
        insert checkedIn;

        // Create a checked-out record
        Check_In__c checkedOut = new Check_In__c(
            Account__c              = acc.Id,
            Check_In_Latitude__c    = 12.8922,
            Check_In_Longitude__c   = 77.4652,
            Check_In_Time__c        = System.now().addHours(-2),
            Rep_Name__c             = UserInfo.getUserId(),
            Status__c               = 'Checked Out',
            Check_Out_Time__c       = System.now().addHours(-1),
            Check_Out_Latitude__c   = 12.8923,
            Check_Out_Longitude__c  = 77.4653,
            Check_Out_Notes__c      = 'Good meeting'
        );
        insert checkedOut;
    }

    // Query by Account Id
    @IsTest
    static void testGetCheckInsForAccount() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Map Test College' LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> markers = CheckInMapController.getCheckInsForParent(acc.Id);
        Test.stopTest();

        System.assert(markers.size() >= 2, 'Should return at least 2 markers. Got: ' + markers.size());
    }

    // Query by User Id
    @IsTest
    static void testGetCheckInsForUser() {
        Test.startTest();
        List<Map<String, Object>> markers = CheckInMapController.getCheckInsForParent(UserInfo.getUserId());
        Test.stopTest();

        System.assert(markers.size() >= 2, 'Should return at least 2 markers for user. Got: ' + markers.size());
    }

    // Null parent Id returns empty list
    @IsTest
    static void testGetCheckInsNullParent() {
        Test.startTest();
        List<Map<String, Object>> markers = CheckInMapController.getCheckInsForParent(null);
        Test.stopTest();

        System.assertEquals(0, markers.size(), 'Null parent should return empty list');
    }
}